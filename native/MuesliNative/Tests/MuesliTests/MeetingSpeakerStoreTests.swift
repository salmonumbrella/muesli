import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("Guarded meeting speaker storage")
struct MeetingSpeakerStoreTests {
    @Test func renameRoundtripAndStaleWriter() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try store.speakerStateMeetingIDs().contains(id))
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var renamed = snapshot.state
        _ = renamed.assign(.init(name: "長い名前: Example", provenance: .manual), to: state.speakers[0].key)
        #expect(try store.updateMeetingSpeakerState(id: id, state: renamed, expected: snapshot) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript == "[00:00:01] 長い名前: Example: Original words")
        #expect(try store.meetingSpeakerSnapshot(id: id)?.summaryIsStale == true)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .conflict)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.turns == state.turns)
    }

    @Test func directAndSameValueEditsInvalidateAuthority() throws {
        for replacement in ["Changed words", "[00:00:01] Speaker 1: Original words"] {
            let (store, id, state) = try fixture()
            let version = try #require(try store.meetingTranscriptVersion(id: id))
            #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
            let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
            try store.updateMeetingTranscript(id: id, rawTranscript: replacement)
            #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
            #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
            #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .conflict)
            #expect(try store.meeting(id: id)?.rawTranscript == replacement)
        }
    }

    @Test func deletingMeetingErasesSerializedSpeakerTranscript() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateJSON(id: id, store: store)?.contains("Original words") == true)

        try store.deleteMeeting(id: id)

        #expect(try rawSpeakerStateJSON(id: id, store: store) == nil)
    }

    @Test func clearingMeetingsErasesSerializedSpeakerTranscript() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        #expect(try rawSpeakerStateJSON(id: id, store: store)?.contains("Original words") == true)

        try store.clearMeetings()

        #expect(try rawSpeakerStateJSON(id: id, store: store) == nil)
    }

    @Test func metadataOnlySyncPreservesSpeakerMappingButTranscriptSyncInvalidatesIt() throws {
        let (store, id, state) = try fixture()
        let recordName = "speaker-sync-fixture"
        try setCloudRecordName(recordName, meetingID: id, store: store)
        let base = Date()
        let transcript = state.render()

        func syncedRecord(title: String, transcript: String, updatedAt: Date) -> SyncTextRecord {
            SyncTextRecord(
                id: recordName,
                kind: .meeting,
                title: title,
                text: transcript,
                speakerTranscript: transcript,
                summaryText: "Notes for \(title)",
                source: "ios",
                meetingStatus: .completed,
                createdAt: base,
                updatedAt: updatedAt,
                startedAt: base,
                endedAt: base.addingTimeInterval(60),
                durationSeconds: 60,
                wordCount: 2
            )
        }

        #expect(try store.upsertSyncedTextRecord(syncedRecord(
            title: "Remote title", transcript: transcript, updatedAt: base.addingTimeInterval(60)
        )))
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let installed = try #require(try store.meetingSpeakerSnapshot(id: id))

        #expect(try store.upsertSyncedTextRecord(syncedRecord(
            title: "Updated title", transcript: transcript, updatedAt: base.addingTimeInterval(120)
        )))

        #expect(try store.meeting(id: id)?.title == "Updated title")
        #expect(try store.meeting(id: id)?.formattedNotes == "Notes for Updated title")
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state == installed.state)

        #expect(try store.upsertSyncedTextRecord(syncedRecord(
            title: "Transcript changed", transcript: "Changed transcript", updatedAt: base.addingTimeInterval(180)
        )))
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meeting(id: id)?.rawTranscript == "Changed transcript")
    }

    @Test func sqlCloudLikeEditCannotBeUndoneByStaleEpoch() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(try store.meetingSpeakerSnapshot(id: id))
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE meetings SET raw_transcript = 'User words'", nil, nil, nil) == SQLITE_OK)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
        #expect(try store.meeting(id: id)?.rawTranscript == "User words")
    }

    @Test func failedSummaryRegenerationDoesNotClaimCurrentNotes() throws {
        let (store, id, _) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscriptAndSummary(id: id, rawTranscript: "New speech", formattedNotes: "Retained notes",
            selectedTemplateID: "test", selectedTemplateName: "Test", selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "", expectedTranscript: before, summaryIsCurrent: false)
        try MeetingSpeakerStatePersistence.persist(nil, to: store, meetingID: id, summaryIsCurrent: false)
        #expect(try store.meetingSummaryIsStale(id: id))
    }

    @Test func successfulSummaryWithoutSpeakerStateClearsStaleness() throws {
        let (store, id, _) = try fixture()
        try store.updateMeetingTranscript(id: id, rawTranscript: "Resumed transcript")
        #expect(try store.meetingSummaryIsStale(id: id))

        try MeetingSpeakerStatePersistence.persist(nil, to: store, meetingID: id, summaryIsCurrent: true)

        #expect(try !store.meetingSummaryIsStale(id: id))
    }

    @Test func failedRetranscriptionPreservesSavedSpeakerIdentity() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: before) == .updated)
        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state == state)
        #expect(try store.meetingTranscriptVersion(id: id)?.generation == before.generation)
        try store.updateMeetingStatus(id: id, status: .completed)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state == state)
    }

    @Test func startingANewRecordingInvalidatesPriorIdentity() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: before) == .updated)
        try store.updateMeetingStatus(id: id, status: .recording)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meetingTranscriptVersion(id: id)?.generation != before.generation)
    }

    @Test func onlyMatchingSummaryGenerationCanClearStaleness() throws {
        let (store, id, state) = try fixture()
        let before = try #require(try store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscript(id: id, rawTranscript: "New speech")
        try store.markMeetingSummaryCurrent(id: id, expected: before)
        #expect(try store.meetingSummaryIsStale(id: id))
        let current = try #require(try store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: current)
        #expect(try !store.meetingSummaryIsStale(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: current) == .invalidated)
    }

    @Test func legacyAndResumeStayUnavailable() throws {
        let (store, id, state) = try fixture()
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        _ = try store.prepareMeetingForResume(id: id)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
    }

    private func fixture() throws -> (DictationStore, Int64, MeetingSpeakerState) {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID()).db"))
        try store.migrateIfNeeded()
        let epoch = UUID()
        let actual = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "a")
        let state = MeetingSpeakerState(epoch: epoch, speakers: [.init(key: actual, rank: 1, fallbackLabel: "Speaker 1")],
                                       turns: [.init(speaker: actual, timestamp: "00:00:01", start: 1, end: 2, text: "Original words")])
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(),
                                        rawTranscript: state.render(), formattedNotes: "Summary", micAudioPath: nil, systemAudioPath: nil)
        return (store, id, state)
    }

    private func rawSpeakerStateJSON(id: Int64, store: DictationStore) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
            throw sqliteError("failed to open speaker-state database")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state_json FROM local_meeting_speaker_state WHERE meeting_id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError("failed to prepare speaker-state query")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError("failed to read speaker state") }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private func setCloudRecordName(_ recordName: String, meetingID: Int64, store: DictationStore) throws {
        var db: OpaquePointer?
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
            throw sqliteError("failed to open sync fixture database")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE meetings SET cloud_record_name = ?, sync_dirty = 0 WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError("failed to prepare sync fixture update")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (recordName as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw sqliteError("failed to attach sync fixture record name")
        }
    }

    private func sqliteError(_ message: String) -> NSError {
        NSError(domain: "MeetingSpeakerStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension MeetingSpeakerStoreTests {
    @Test func correctionUsesTheSnapshotThatProducedIt() throws {
        let (store, id, state) = try fixture()
        let version = try #require(try store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let captured = try #require(try store.meetingSpeakerSnapshot(id: id))
        var first = captured.state, stale = captured.state
        #expect(first.correct(.rename(state.speakers[0].key, "First")) == true)
        #expect(stale.correct(.rename(state.speakers[0].key, "Stale")) == true)
        #expect(try store.updateMeetingSpeakerState(id: id, state: first, expected: captured) == .updated)
        #expect(try store.updateMeetingSpeakerState(id: id, state: stale, expected: captured) == .conflict)
        let current = try #require(try store.meetingSpeakerSnapshot(id: id))
        var undone = current.state
        #expect(undone.correct(.undo) == true)
        #expect(try store.updateMeetingSpeakerState(id: id, state: undone, expected: current) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript == "[00:00:01] Speaker 1: Original words")
    }
}
