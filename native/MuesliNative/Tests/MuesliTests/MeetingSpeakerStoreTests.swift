import Foundation
import MuesliCore
import SQLite3
import Testing

@Suite("Guarded meeting speaker storage")
struct MeetingSpeakerStoreTests {
    @Test func renameRoundtripAndStaleWriter() throws {
        let (store, id, state) = try fixture()
        let version = try #require(store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(store.meetingSpeakerSnapshot(id: id))
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
            let version = try #require(store.meetingTranscriptVersion(id: id))
            #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
            let snapshot = try #require(store.meetingSpeakerSnapshot(id: id))
            try store.updateMeetingTranscript(id: id, rawTranscript: replacement)
            #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
            #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
            #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .conflict)
            #expect(try store.meeting(id: id)?.rawTranscript == replacement)
        }
    }

    @Test func sqlCloudLikeEditCannotBeUndoneByStaleEpoch() throws {
        let (store, id, state) = try fixture()
        let version = try #require(store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let snapshot = try #require(store.meetingSpeakerSnapshot(id: id))
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE meetings SET raw_transcript = 'User words'", nil, nil, nil) == SQLITE_OK)
        #expect(try store.updateMeetingSpeakerState(id: id, state: state, expected: snapshot) == .invalidated)
        #expect(try store.meeting(id: id)?.rawTranscript == "User words")
    }

    @Test func failedSummaryRegenerationDoesNotClaimCurrentNotes() throws {
        let (store, id, _) = try fixture()
        let before = try #require(store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscriptAndSummary(id: id, rawTranscript: "New speech", formattedNotes: "Retained notes",
            selectedTemplateID: "test", selectedTemplateName: "Test", selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "", expectedTranscript: before, summaryIsCurrent: false)
        #expect(try store.meetingSummaryIsStale(id: id))
    }

    @Test func processingInvalidatesPriorIdentityBeforeNewInference() throws {
        let (store, id, state) = try fixture()
        let before = try #require(store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: before) == .updated)
        try store.updateMeetingStatus(id: id, status: .processing)
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        #expect(try store.meetingTranscriptVersion(id: id)?.generation != before.generation)
    }

    @Test func onlyMatchingSummaryGenerationCanClearStaleness() throws {
        let (store, id, state) = try fixture()
        let before = try #require(store.meetingTranscriptVersion(id: id))
        try store.updateMeetingTranscript(id: id, rawTranscript: "New speech")
        try store.markMeetingSummaryCurrent(id: id, expected: before)
        #expect(try store.meetingSummaryIsStale(id: id))
        let current = try #require(store.meetingTranscriptVersion(id: id))
        try store.markMeetingSummaryCurrent(id: id, expected: current)
        #expect(try !store.meetingSummaryIsStale(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: current) == .invalidated)
    }

    @Test func legacyAndResumeStayUnavailable() throws {
        let (store, id, state) = try fixture()
        #expect(try store.meetingSpeakerSnapshot(id: id) == nil)
        let version = try #require(store.meetingTranscriptVersion(id: id))
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
}

extension MeetingSpeakerStoreTests {
    @Test func correctionUsesTheSnapshotThatProducedIt() throws {
        let (store, id, state) = try fixture()
        let version = try #require(store.meetingTranscriptVersion(id: id))
        #expect(try store.installMeetingSpeakerState(id: id, state: state, expected: version) == .updated)
        let captured = try #require(store.meetingSpeakerSnapshot(id: id))
        var first = captured.state, stale = captured.state
        #expect(first.correct(.rename(state.speakers[0].key, "First")))
        #expect(stale.correct(.rename(state.speakers[0].key, "Stale")))
        #expect(try store.updateMeetingSpeakerState(id: id, state: first, expected: captured) == .updated)
        #expect(try store.updateMeetingSpeakerState(id: id, state: stale, expected: captured) == .conflict)
        let current = try #require(store.meetingSpeakerSnapshot(id: id))
        var undone = current.state
        #expect(undone.correct(.undo))
        #expect(try store.updateMeetingSpeakerState(id: id, state: undone, expected: current) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript == "[00:00:01] Speaker 1: Original words")
    }
}
