import Foundation
import SQLite3

public enum CallIdentityStoreError: Error {
    case database(Int32)
    case invalidAlias
    case missingPerson
    case counterExhausted
    case invalidPayload
}

/// Uses the recording store's own connection and transaction boundary. No
/// Contacts identifiers or caller data escape through diagnostics.
public final class CallIdentityStore: @unchecked Sendable {
    private let store: DictationStore

    public init(store: DictationStore) { self.store = store }

    private func transaction<T>(_ body: (CallIdentityDatabase) throws -> T) throws -> T {
        try store.withCallIdentityDatabase { try body(CallIdentityDatabase(db: $0)) }
    }

    public func resolve(_ observation: CallObservation) throws -> CallPersonResolution {
        try transaction { try $0.resolve(observation) }
    }

    public func savePerson(_ person: CallPerson) throws {
        try transaction { try $0.savePerson(person) }
    }

    public func people() throws -> [CallPerson] {
        try transaction { db in
            try db.allPeople().filter { try db.root($0.id) == $0.id && !db.isSuppressed($0.id) }
        }
    }

    public func bind(_ people: [UUID], to context: CallRecordingContext, observationID: UUID? = nil) throws -> Bool {
        try transaction { try $0.bind(people, to: context, observationID: observationID) }
    }

    public func links(recordName: String) throws -> [CallRecordingLink] {
        try transaction { try $0.links(recordName: recordName) }
    }

    public func history(personID: UUID) throws -> [CallHistoryEntry] {
        try transaction { try $0.history(personID: personID) }
    }

    public func suppress(personID: UUID, recordName: String?, revision: CallRevision) throws {
        try transaction { try $0.suppress(personID: personID, recordName: recordName, revision: revision) }
    }

    public func restore(personID: UUID, revision: CallRevision) throws {
        try transaction { try $0.restore(personID: personID, revision: revision) }
    }

    public func mergeAlias(_ alias: CallPersonAlias) throws {
        try transaction { try $0.mergeAlias(alias) }
    }

    public func recordFailure(observationID: UUID, reason: String) throws {
        try transaction { try $0.execute("UPDATE call_observations SET recording_failure=? WHERE id=?", [reason, observationID.uuidString]) }
    }

    public func nextCallRevision(provenance: CallFieldProvenance, restoreEpoch: UInt64) throws -> CallRevision {
        try transaction { try $0.nextRevision(provenance: provenance, restoreEpoch: restoreEpoch) }
    }

    public func saveContactIntent(_ intent: CallContactIntent) throws {
        try transaction { try $0.saveIntent(intent) }
    }

    public func contactIntent(personID: UUID) throws -> CallContactIntent? {
        try transaction { try $0.intent(personID: personID) }
    }

    public func markContactIntent(personID: UUID, state: CallContactSaveState, contactID: String?) throws {
        try transaction { db in
            guard var intent = try db.intent(personID: personID) else { return }
            intent.state = state
            intent.savedContactID = contactID
            try db.saveIntent(intent)
        }
    }

    public func rootPersonID(_ id: UUID) throws -> UUID {
        try transaction { try $0.root(id) }
    }
}

struct CallIdentityDatabase {
    let db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func migrate(_ db: OpaquePointer?) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS call_people (
          id TEXT PRIMARY KEY, display_name TEXT, person_json BLOB NOT NULL,
          revision_json BLOB NOT NULL, deleted_at REAL, cloud_system_fields BLOB, dirty INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS call_handles (stable_key TEXT PRIMARY KEY, handle_json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS call_person_handles (
          person_id TEXT NOT NULL REFERENCES call_people(id), stable_key TEXT NOT NULL REFERENCES call_handles(stable_key),
          PRIMARY KEY(person_id,stable_key));
        CREATE TABLE IF NOT EXISTS call_observations (
          id TEXT PRIMARY KEY, source_key TEXT UNIQUE, observation_json BLOB NOT NULL,
          recording_failure TEXT, dirty INTEGER NOT NULL DEFAULT 0, cloud_system_fields BLOB);
        CREATE TABLE IF NOT EXISTS call_observation_people (
          observation_id TEXT NOT NULL, person_id TEXT NOT NULL, PRIMARY KEY(observation_id,person_id));
        CREATE TABLE IF NOT EXISTS call_recording_links (
          record_name TEXT NOT NULL, person_id TEXT NOT NULL, context_json BLOB NOT NULL, revision_json BLOB NOT NULL,
          observation_id TEXT, suppressed INTEGER NOT NULL DEFAULT 0, contact_save_requested INTEGER NOT NULL DEFAULT 0,
          dirty INTEGER NOT NULL DEFAULT 0, cloud_system_fields BLOB, PRIMARY KEY(record_name,person_id));
        CREATE TABLE IF NOT EXISTS call_person_aliases (from_id TEXT PRIMARY KEY, root_id TEXT NOT NULL, revision_json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS call_suppressions (scope_key TEXT PRIMARY KEY, epoch TEXT NOT NULL, revision_json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS call_contact_write_intents (person_id TEXT PRIMARY KEY, state TEXT NOT NULL, intent_json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS call_contact_mappings (
          person_id TEXT NOT NULL, device_account TEXT NOT NULL, contact_id TEXT NOT NULL, PRIMARY KEY(person_id,device_account));
        CREATE TABLE IF NOT EXISTS call_sync_state (account_scope TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(account_scope,key));
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CallIdentityStoreError.database(sqlite3_errcode(db)) }
    }

    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CallIdentityStoreError.database(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let result: Int32
            if let value {
                result = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, Self.transient) }
            } else {
                result = sqlite3_bind_null(statement, Int32(offset + 1))
            }
            guard result == SQLITE_OK else { throw CallIdentityStoreError.database(result) }
        }
        var output: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw CallIdentityStoreError.database(result) }
            output.append((0..<sqlite3_column_count(statement)).map { index in
                guard let text = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: text)
            })
        }
    }

    func execute(_ sql: String, _ values: [String?] = []) throws { _ = try rows(sql, values) }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func decode<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T {
        guard let text else { throw CallIdentityStoreError.invalidPayload }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    func person(_ id: UUID) throws -> CallPerson? {
        guard let row = try rows("SELECT person_json FROM call_people WHERE id=?", [id.uuidString]).first else { return nil }
        return try decode(CallPerson.self, row[0])
    }

    func allPeople() throws -> [CallPerson] {
        try rows("SELECT person_json FROM call_people ORDER BY id").map { try decode(CallPerson.self, $0[0]) }
    }

    func root(_ id: UUID) throws -> UUID {
        var current = id
        var seen: Set<UUID> = []
        while let row = try rows("SELECT root_id FROM call_person_aliases WHERE from_id=?", [current.uuidString]).first {
            guard seen.insert(current).inserted, let value = row[0], let next = UUID(uuidString: value) else {
                throw CallIdentityStoreError.invalidAlias
            }
            current = next
        }
        return current
    }

    func suppression(_ id: UUID, recordName: String? = nil) throws -> CallRevision? {
        let key = recordName.map { "recording|" + $0 + "|" + id.uuidString } ?? "person|" + id.uuidString
        guard let row = try rows("SELECT revision_json FROM call_suppressions WHERE scope_key=?", [key]).first else { return nil }
        return try decode(CallRevision.self, row[0])
    }

    func isSuppressed(_ id: UUID, recordName: String? = nil) throws -> Bool {
        let id = try root(id)
        if try suppression(id) != nil { return true }
        if let recordName, try suppression(id, recordName: recordName) != nil { return true }
        return try person(id)?.deletedAt != nil
    }

    func nextRevision(provenance: CallFieldProvenance, restoreEpoch: UInt64) throws -> CallRevision {
        let counterText = try rows("SELECT value FROM call_sync_state WHERE account_scope='local' AND key='counter'").first?[0]
        let counter = counterText.flatMap(UInt64.init) ?? 0
        guard counter < UInt64.max else { throw CallIdentityStoreError.counterExhausted }
        var device = try rows("SELECT value FROM call_sync_state WHERE account_scope='local' AND key='device'").first?[0]
        if device == nil {
            device = UUID().uuidString
            try execute("INSERT INTO call_sync_state(account_scope,key,value) VALUES('local','device',?)", [device])
        }
        try execute("INSERT INTO call_sync_state(account_scope,key,value) VALUES('local','counter',?) ON CONFLICT(account_scope,key) DO UPDATE SET value=excluded.value", [String(counter + 1)])
        return CallRevision(restoreEpoch: restoreEpoch, counter: counter + 1, deviceID: device!, provenance: provenance)
    }

    func savePerson(_ person: CallPerson) throws {
        try execute("""
          INSERT INTO call_people(id,display_name,person_json,revision_json,deleted_at,dirty) VALUES(?,?,?,?,?,1)
          ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,person_json=excluded.person_json,
            revision_json=excluded.revision_json,deleted_at=excluded.deleted_at,dirty=1
          """, [person.id.uuidString, person.displayName, try encode(person), try encode(person.revision), person.deletedAt.map { String($0.timeIntervalSince1970) }])
        for handle in person.handles {
            try execute("INSERT INTO call_handles(stable_key,handle_json) VALUES(?,?) ON CONFLICT(stable_key) DO NOTHING", [handle.stableKey, try encode(handle)])
            try execute("INSERT OR IGNORE INTO call_person_handles(person_id,stable_key) VALUES(?,?)", [person.id.uuidString, handle.stableKey])
        }
    }

    private func sourceKey(_ observation: CallObservation) -> String? {
        observation.sourceCallID.map { callID in
            [observation.sourceDeviceID, observation.source.rawValue, callID].map { "\($0.utf8.count):\($0)" }.joined()
        }
    }

    func resolve(_ incoming: CallObservation) throws -> CallPersonResolution {
        var observation = incoming
        let key = sourceKey(incoming)
        if let key, let row = try rows("SELECT observation_json FROM call_observations WHERE source_key=?", [key]).first {
            let previous = try decode(CallObservation.self, row[0])
            if previous.observedAt > incoming.observedAt { observation = previous }
            else {
                observation = CallObservation(id: previous.id, source: incoming.source, sourceDeviceID: incoming.sourceDeviceID,
                    sourceCallID: incoming.sourceCallID, observedAt: incoming.observedAt, startedAt: incoming.startedAt ?? previous.startedAt,
                    connectedAt: incoming.connectedAt ?? previous.connectedAt, endedAt: incoming.endedAt ?? previous.endedAt,
                    direction: incoming.direction, status: incoming.status, evidence: incoming.evidence,
                    handles: incoming.handles.isEmpty ? previous.handles : incoming.handles, displayName: incoming.displayName ?? previous.displayName)
            }
        }
        try execute("""
          INSERT INTO call_observations(id,source_key,observation_json,dirty) VALUES(?,?,?,1)
          ON CONFLICT(id) DO UPDATE SET observation_json=excluded.observation_json,dirty=1
          """, [observation.id.uuidString, key, try encode(observation)])
        var people: [UUID: CallPerson] = [:]
        var ambiguous: [String] = []
        for handle in observation.handles {
            let matches = try rows("SELECT person_id FROM call_person_handles WHERE stable_key=?", [handle.stableKey])
            var roots: Set<UUID> = []
            for row in matches {
                guard let string = row[0], let id = UUID(uuidString: string) else { continue }
                roots.insert(try root(id))
            }
            if roots.isEmpty {
                let id = try root(CallIdentityNormalizer.personID(for: handle))
                if try isSuppressed(id) { continue }
                let revision = try nextRevision(provenance: .automatic, restoreEpoch: 0)
                let person = CallPerson(id: id, handles: [handle], displayName: observation.displayName,
                    revision: revision, nameRevision: revision, handleRevisions: [handle.stableKey: revision],
                    deletionRevision: nil, createdAt: observation.observedAt, updatedAt: observation.observedAt, deletedAt: nil)
                try savePerson(person)
                roots.insert(id)
            }
            let liveRoots = try roots.filter { try !isSuppressed($0) }
            if liveRoots.count > 1 { ambiguous.append(handle.stableKey) }
            for id in liveRoots {
                guard let person = try person(id) else { throw CallIdentityStoreError.missingPerson }
                people[id] = person
                try execute("INSERT OR IGNORE INTO call_observation_people(observation_id,person_id) VALUES(?,?)", [observation.id.uuidString, id.uuidString])
            }
        }
        return CallPersonResolution(people: people.values.sorted { $0.id.uuidString < $1.id.uuidString }, ambiguousHandleKeys: ambiguous.sorted())
    }

    func recordingDeleted(_ recordName: String) throws -> Bool {
        // A portable link can arrive before its recording. An existing local
        // tombstone is decisive and must never be revived by late identity.
        let table = try rows("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('meetings','recording_sessions')").first?[0]
        guard let table else { return false }
        return try !rows("SELECT 1 FROM \(table) WHERE cloud_record_name=? AND deleted_at IS NOT NULL", [recordName]).isEmpty
    }

    func bind(_ ids: [UUID], to context: CallRecordingContext, observationID: UUID?) throws -> Bool {
        guard !ids.isEmpty, !context.recordName.isEmpty, try !recordingDeleted(context.recordName) else { return false }
        let roots = try Set(ids.map { try root($0) })
        for id in roots {
            guard try person(id) != nil, try !isSuppressed(id, recordName: context.recordName) else { return false }
        }
        for id in roots {
            let epoch = try person(id)?.revision.restoreEpoch ?? 0
            let revision = try nextRevision(provenance: .automatic, restoreEpoch: epoch)
            try execute("""
              INSERT INTO call_recording_links(record_name,person_id,context_json,revision_json,observation_id,dirty)
              VALUES(?,?,?,?,?,1) ON CONFLICT(record_name,person_id) DO NOTHING
              """, [context.recordName, id.uuidString, try encode(context), try encode(revision), observationID?.uuidString])
        }
        return true
    }

    func links(recordName: String) throws -> [CallRecordingLink] {
        guard try !recordingDeleted(recordName) else { return [] }
        return try rows("SELECT person_id,context_json,revision_json,suppressed,contact_save_requested,observation_id FROM call_recording_links WHERE record_name=?", [recordName]).compactMap { row in
            guard let string = row[0], let id = UUID(uuidString: string), row[3] != "1",
                  try !isSuppressed(id, recordName: recordName) else { return nil }
            return CallRecordingLink(recording: try decode(CallRecordingContext.self, row[1]), personID: try root(id),
                revision: try decode(CallRevision.self, row[2]), isSuppressed: false, contactSaveRequested: row[4] == "1",
                observationID: row[5].flatMap(UUID.init(uuidString:)))
        }
    }

    func history(personID: UUID) throws -> [CallHistoryEntry] {
        let id = try root(personID)
        guard try !isSuppressed(id) else { return [] }
        let rows = try rows("""
          SELECT o.observation_json,o.recording_failure FROM call_observations o
          JOIN call_observation_people p ON p.observation_id=o.id WHERE p.person_id=?
          """, [id.uuidString])
        return try rows.map { row in
            let observation = try decode(CallObservation.self, row[0])
            let candidates = try self.rows("SELECT record_name FROM call_recording_links WHERE observation_id=? AND person_id=? AND suppressed=0", [observation.id.uuidString, id.uuidString])
            var recordName: String?
            for candidate in candidates {
                if let name = candidate[0], try !isSuppressed(id, recordName: name), try !recordingDeleted(name) { recordName = name; break }
            }
            return CallHistoryEntry(observation: observation, recordName: recordName, recordingFailure: row[1])
        }.sorted { $0.observation.observedAt > $1.observation.observedAt }
    }

    func suppress(personID: UUID, recordName: String?, revision: CallRevision) throws {
        let id = try root(personID)
        if let person = try person(id), person.revision.restoreEpoch > revision.restoreEpoch { return }
        let key = recordName.map { "recording|" + $0 + "|" + id.uuidString } ?? "person|" + id.uuidString
        if let current = try suppression(id, recordName: recordName), current.restoreEpoch > revision.restoreEpoch { return }
        try execute("INSERT INTO call_suppressions(scope_key,epoch,revision_json) VALUES(?,?,?) ON CONFLICT(scope_key) DO UPDATE SET epoch=excluded.epoch,revision_json=excluded.revision_json", [key, String(revision.restoreEpoch), try encode(revision)])
        if let recordName {
            try execute("UPDATE call_recording_links SET suppressed=1,revision_json=?,dirty=1 WHERE record_name=? AND person_id=?", [try encode(revision), recordName, id.uuidString])
        } else if var person = try person(id) {
            person.deletedAt = Date()
            person.deletionRevision = revision
            person.revision = revision
            try savePerson(person)
            try execute("DELETE FROM call_contact_write_intents WHERE person_id=?", [id.uuidString])
        }
    }

    func restore(personID: UUID, revision: CallRevision) throws {
        let id = try root(personID)
        guard revision.provenance == .manual, var person = try person(id) else { return }
        let current = try suppression(id)
        let epoch = max(current?.restoreEpoch ?? 0, person.deletionRevision?.restoreEpoch ?? 0)
        guard revision.restoreEpoch > epoch else { return }
        try execute("DELETE FROM call_suppressions WHERE scope_key=?", ["person|" + id.uuidString])
        person.deletedAt = nil
        person.deletionRevision = nil
        person.revision = revision
        person.updatedAt = Date()
        try savePerson(person)
    }

    func intent(personID: UUID) throws -> CallContactIntent? {
        let id = try root(personID)
        guard try !isSuppressed(id), let row = try rows("SELECT intent_json FROM call_contact_write_intents WHERE person_id=?", [id.uuidString]).first else { return nil }
        return try decode(CallContactIntent.self, row[0])
    }

    func saveIntent(_ incoming: CallContactIntent) throws {
        let id = try root(incoming.personID)
        guard try !isSuppressed(id) else { return }
        let intent = CallContactIntent(personID: id, handles: incoming.handles, displayName: incoming.displayName,
            state: incoming.state, savedContactID: incoming.savedContactID)
        try execute("INSERT INTO call_contact_write_intents(person_id,state,intent_json) VALUES(?,?,?) ON CONFLICT(person_id) DO UPDATE SET state=excluded.state,intent_json=excluded.intent_json", [id.uuidString, intent.state.rawValue, try encode(intent)])
    }

    func mergeAlias(_ alias: CallPersonAlias) throws {
        let from = try root(alias.fromID)
        let target = try root(alias.rootID)
        if from == target {
            guard alias.fromID != target else { throw CallIdentityStoreError.invalidAlias }
            return
        }
        guard from != target, target.uuidString < from.uuidString,
              var rootPerson = try person(target), let oldPerson = try person(from) else { throw CallIdentityStoreError.invalidAlias }
        let previousRemovals = try rows("SELECT scope_key,revision_json FROM call_suppressions")
            .filter { $0[0]?.hasSuffix("|" + from.uuidString) == true }
        // Proven merges only; never infer this edge from shared handles.
        for handle in oldPerson.handles where !rootPerson.handles.contains(where: { $0.stableKey == handle.stableKey }) {
            rootPerson.handles.append(handle)
            rootPerson.handleRevisions[handle.stableKey] = oldPerson.handleRevisions[handle.stableKey]
        }
        try savePerson(rootPerson)
        try execute("INSERT INTO call_person_aliases(from_id,root_id,revision_json) VALUES(?,?,?) ON CONFLICT(from_id) DO UPDATE SET root_id=excluded.root_id,revision_json=excluded.revision_json", [from.uuidString, target.uuidString, try encode(alias.revision)])
        try execute("UPDATE OR IGNORE call_recording_links SET person_id=? WHERE person_id=?", [target.uuidString, from.uuidString])
        try execute("DELETE FROM call_recording_links WHERE person_id=?", [from.uuidString])
        try execute("UPDATE OR IGNORE call_observation_people SET person_id=? WHERE person_id=?", [target.uuidString, from.uuidString])
        try execute("DELETE FROM call_observation_people WHERE person_id=?", [from.uuidString])
        if let row = try rows("SELECT intent_json FROM call_contact_write_intents WHERE person_id=?", [from.uuidString]).first {
            let pending = try decode(CallContactIntent.self, row[0])
            if try intent(personID: target) == nil { try saveIntent(pending) }
        }
        try execute("DELETE FROM call_contact_write_intents WHERE person_id=?", [from.uuidString])
        if let removal = try suppression(from) { try suppress(personID: target, recordName: nil, revision: removal) }
        for row in previousRemovals {
            guard let key = row[0], key.hasPrefix("recording|") else { continue }
            let recordName = String(key.dropFirst("recording|".count).dropLast(from.uuidString.count + 1))
            try suppress(personID: target, recordName: recordName, revision: decode(CallRevision.self, row[1]))
        }
        for row in try rows("SELECT record_name,revision_json FROM call_recording_links WHERE person_id=? AND suppressed=1", [target.uuidString]) {
            if let name = row[0] { try suppress(personID: target, recordName: name, revision: decode(CallRevision.self, row[1])) }
        }
    }
}
