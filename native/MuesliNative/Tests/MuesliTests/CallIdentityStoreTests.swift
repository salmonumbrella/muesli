import Foundation
import SQLite3
import MuesliCore
import Testing

@Suite("Call identity persistence")
struct CallIdentityStoreTests {
    private func database() throws -> (DictationStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("calls.sqlite")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        try store.migrateIfNeeded()
        return (store, directory)
    }

    private func observation(_ handle: CallHandle, id: UUID = UUID()) -> CallObservation {
        CallObservation(id: id, source: .facetime, sourceDeviceID: "fixture-device",
            observedAt: Date(timeIntervalSinceReferenceDate: 100), evidence: .activeCallAX, handles: [handle])
    }

    @Test func repeatedObservationCreatesOneNamelessPersonAndOneCall() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let h = try #require(CallIdentityNormalizer.email("caller@example.test"))
        let o = observation(h)
        let first = try #require(try calls.resolve(o).people.first)
        #expect(first.displayName == nil)
        #expect(first.id == CallIdentityNormalizer.personID(for: h))
        #expect(try calls.resolve(o).people.map(\.id) == [first.id])
        #expect(try calls.people().count == 1)
        #expect(try calls.history(personID: first.id).count == 1)
    }

    @Test func removalBeforeLateLookupSurvivesReopenAndRequiresExplicitRestore() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = try #require(CallIdentityNormalizer.phone("+12025550123"))
        let o = observation(h)
        let calls = CallIdentityStore(store: db)
        let person = try #require(try calls.resolve(o).people.first)
        let removal = CallRevision(restoreEpoch: 0, counter: 2, deviceID: "fixture-device", provenance: .manual)
        try calls.suppress(personID: person.id, recordName: nil, revision: removal)
        let reopened = DictationStore(databaseURL: db.resolvedDatabaseURL)
        try reopened.migrateIfNeeded()
        let reopenedCalls = CallIdentityStore(store: reopened)
        #expect(try reopenedCalls.resolve(observation(h)).people.isEmpty)
        try reopenedCalls.restore(personID: person.id, revision: removal)
        #expect(try reopenedCalls.resolve(observation(h)).people.isEmpty)
        try reopenedCalls.restore(personID: person.id,
            revision: CallRevision(restoreEpoch: 1, counter: 3, deviceID: "fixture-device", provenance: .manual))
        #expect(try reopenedCalls.resolve(observation(h)).people.map(\.id) == [person.id])
    }

    @Test func offlineRecordingNameIsStableAndDoesNotDirtyCleanText() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try db.createLiveMeeting(title: "Fixture call", calendarEventID: nil, startTime: Date())
        var sqlite: OpaquePointer?
        #expect(sqlite3_open(db.resolvedDatabaseURL.path, &sqlite) == SQLITE_OK)
        defer { sqlite3_close(sqlite) }
        #expect(sqlite3_exec(sqlite, "UPDATE meetings SET sync_dirty=0", nil, nil, nil) == SQLITE_OK)
        let name = try db.ensureCallRecordingName(meetingID: id)
        #expect(name.hasPrefix("meeting-"))
        #expect(try db.ensureCallRecordingName(meetingID: id) == name)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(sqlite, "SELECT sync_dirty FROM meetings", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 0)
    }

    @Test func recordingSuppressionBlocksReplayWithoutDeletingThePerson() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let o = observation(try #require(CallIdentityNormalizer.email("caller@example.test")))
        let person = try #require(try calls.resolve(o).people.first)
        let context = CallRecordingContext(recordName: "meeting-fixture", generation: UUID(), source: .facetime,
            sourceFingerprint: "fixture-source", sourceCallID: nil, startedAt: o.observedAt)
        #expect(try calls.bind([person.id], to: context))
        try calls.suppress(personID: person.id, recordName: context.recordName,
            revision: CallRevision(restoreEpoch: 0, counter: 9, deviceID: "fixture-device", provenance: .manual))
        #expect(try !calls.bind([person.id], to: context))
        #expect(try calls.links(recordName: context.recordName).isEmpty)
        #expect(try calls.people().count == 1)
    }

    @Test func manualPeopleSharingAHandleStayAmbiguous() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let h = try #require(CallIdentityNormalizer.phone("+12025550123"))
        let revision = CallRevision(restoreEpoch: 0, counter: 1, deviceID: "fixture-device", provenance: .manual)
        for name in ["Fixture A", "Fixture B"] {
            let p = CallPerson(id: UUID(), handles: [h], displayName: name, revision: revision,
                nameRevision: revision, handleRevisions: [h.stableKey: revision], deletionRevision: nil,
                createdAt: Date(), updatedAt: Date(), deletedAt: nil)
            try calls.savePerson(p)
        }
        let result = try calls.resolve(observation(h))
        #expect(result.people.count == 2)
        #expect(result.ambiguousHandleKeys == [h.stableKey])
    }

    @Test func aliasesRedirectLinksIntentsAndRemovalAndRejectCycles() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let h = try #require(CallIdentityNormalizer.email("other@example.test"))
        let person = try #require(try calls.resolve(observation(h)).people.first)
        let root = try #require(try calls.resolve(observation(try #require(CallIdentityNormalizer.email("caller@example.test")))).people.first)
        try calls.saveContactIntent(CallContactIntent(personID: person.id, handles: [h], displayName: nil, state: .pending, savedContactID: nil))
        let revision = CallRevision(restoreEpoch: 0, counter: 5, deviceID: "fixture-device", provenance: .manual)
        try calls.mergeAlias(CallPersonAlias(fromID: person.id, rootID: root.id, revision: revision))
        #expect(try calls.resolve(observation(h)).people.map(\.id) == [root.id])
        #expect(try calls.contactIntent(personID: root.id)?.state == .pending)
        #expect(throws: (any Error).self) {
            try calls.mergeAlias(CallPersonAlias(fromID: root.id, rootID: person.id, revision: revision))
        }
        try calls.suppress(personID: person.id, recordName: nil, revision: revision)
        #expect(try calls.resolve(observation(h)).people.isEmpty)
    }

    @Test func oneSourceCallReplayedWithANewObservationIDStaysOneCall() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let h = try #require(CallIdentityNormalizer.phone("+12025550123"))
        func call(status: String) -> CallObservation {
            CallObservation(id: UUID(), source: .phone, sourceDeviceID: "fixture-device",
                sourceCallID: "fixture-call", observedAt: Date(), status: status,
                evidence: .activeCallAX, handles: [h])
        }
        let person = try #require(try calls.resolve(call(status: "connected")).people.first)
        _ = try calls.resolve(call(status: "ended"))
        let history = try calls.history(personID: person.id)
        #expect(history.count == 1)
        #expect(history.first?.observation.status == "ended")
        try calls.recordFailure(observationID: try #require(history.first?.observation.id), reason: "captureUnavailable")
        #expect(try calls.history(personID: person.id).first?.recordingFailure == "captureUnavailable")
        #expect(try calls.history(personID: person.id).first?.recordName == nil)
    }

    @Test func separateGroupHandlesAreParticipantsInsteadOfAmbiguousCandidates() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let handles = try ["caller@example.test", "other@example.test"].map { try #require(CallIdentityNormalizer.email($0)) }
        let o = CallObservation(id: UUID(), source: .facetime, sourceDeviceID: "fixture-device",
            observedAt: Date(), evidence: .activeCallAX, handles: handles)
        let result = try calls.resolve(o)
        #expect(result.people.count == 2)
        #expect(result.ambiguousHandleKeys.isEmpty)
    }

    @Test func persistedLamportClockKeepsUnsignedRestoreEpochs() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try CallIdentityStore(store: db).nextCallRevision(provenance: .manual, restoreEpoch: UInt64.max)
        let reopened = DictationStore(databaseURL: db.resolvedDatabaseURL)
        try reopened.migrateIfNeeded()
        let second = try CallIdentityStore(store: reopened).nextCallRevision(provenance: .automatic, restoreEpoch: UInt64.max)
        #expect(first.restoreEpoch == UInt64.max)
        #expect(second.restoreEpoch == UInt64.max)
        #expect(second.counter == first.counter + 1)
        #expect(second.deviceID == first.deviceID)
    }

    @Test func deletingARecordingRemovesItsLinkButKeepsThePerson() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let o = observation(try #require(CallIdentityNormalizer.email("caller@example.test")))
        let person = try #require(try calls.resolve(o).people.first)
        let meetingID = try db.createLiveMeeting(title: "Fixture call", calendarEventID: nil, startTime: o.observedAt)
        let name = try db.ensureCallRecordingName(meetingID: meetingID)
        let context = CallRecordingContext(recordName: name, generation: UUID(), source: .facetime,
            sourceFingerprint: "fixture-source", sourceCallID: nil, startedAt: o.observedAt)
        #expect(try calls.bind([person.id], to: context))
        try db.deleteMeeting(id: meetingID)
        #expect(try calls.links(recordName: name).isEmpty)
        #expect(try !calls.bind([person.id], to: context))
        #expect(try calls.people().count == 1)
    }

    @Test func bindingSpecificObservationDoesNotGiveAnotherCallItsTranscript() throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: db)
        let h = try #require(CallIdentityNormalizer.email("caller@example.test"))
        let first = observation(h)
        let second = observation(h)
        let person = try #require(try calls.resolve(first).people.first)
        _ = try calls.resolve(second)
        let context = CallRecordingContext(recordName: "meeting-fixture", generation: UUID(), source: .facetime,
            sourceFingerprint: "fixture-source", sourceCallID: nil, startedAt: first.observedAt)
        #expect(try calls.bind([person.id], to: context, observationID: first.id))
        let history = try calls.history(personID: person.id)
        #expect(history.first(where: { $0.observation.id == first.id })?.recordName == context.recordName)
        #expect(history.first(where: { $0.observation.id == second.id })?.recordName == nil)
    }
}
