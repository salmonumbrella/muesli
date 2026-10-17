import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("Deferred meeting speaker labels")
struct MeetingDeferredSpeakerTests {
    @Test func relabelKeepsBoundariesUnicodeAndPrefix() {
        let source = fixture(), audio = MeetingSpeakerBacklogDescriptor(channels: [.system])
        let pending = MeetingSpeakerPendingLabeling(audio: audio, state: source)
        let full = "Earlier words\n\n" + source.render()
        let prepared = pending.prepared(for: full)!
        let relabeled = prepared.state.relabeling(channels: [.system: [.init(clusterID: "a", start: 0, end: 1), .init(clusterID: "b", start: 1, end: 2)]])
        #expect(relabeled.epoch != source.epoch)
        #expect(relabeled.turns.map(\.id) == source.turns.map(\.id))
        #expect(relabeled.turns.map(\.text) == source.turns.map(\.text))
        #expect(relabeled.turns.map(\.timestamp) == source.turns.map(\.timestamp))
        #expect(relabeled.turns[0].speaker != relabeled.turns[1].speaker)
        #expect(relabeled.render().hasPrefix("Earlier words\n\n"))
        #expect(TranscriptChatMessage.messages(from: relabeled.render(), speakerState: relabeled).contains { $0.text.contains("Earlier words") })
        #expect(pending.prepared(for: "edited") == nil)
    }
    @Test func pendingOwnerAuthorizationIsBoundToItsLocalProfile() throws {
        let profileID = UUID()
        let pending = MeetingSpeakerPendingLabeling(
            audio: .init(channels: [.microphone]),
            state: microphoneFixture(),
            ownerProfileID: profileID
        )
        let decoded = try JSONDecoder().decode(MeetingSpeakerPendingLabeling.self, from: JSONEncoder().encode(pending))
        #expect(decoded.ownerProfileID == profileID)
        #expect(decoded.allowsOwnerProfile(profileID))
        #expect(!decoded.allowsOwnerProfile(UUID()))
        #expect(!decoded.allowsOwnerProfile(nil))

        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MeetingSpeakerPendingLabeling(audio: pending.audio, state: pending.state))) as! [String: Any]
        var legacyWithoutOwnerID = legacy
        legacyWithoutOwnerID.removeValue(forKey: "ownerProfileID")
        let decodedLegacy = try JSONDecoder().decode(MeetingSpeakerPendingLabeling.self, from: JSONSerialization.data(withJSONObject: legacyWithoutOwnerID))
        #expect(decodedLegacy.ownerProfileID == nil)
    }
    @Test func staleSessionAuthorizationCannotAuthorizeADeferredRetry() {
        let profileID = UUID(), token = UUID()
        let pending = MeetingSpeakerPendingLabeling(
            audio: .init(channels: [.microphone]),
            state: microphoneFixture(),
            ownerProfileID: profileID
        )
        let result = MeetingSessionResult(
            title: "Meeting", originalTitle: "Meeting", calendarEventID: nil,
            startTime: Date(), endTime: Date(), durationSeconds: 1,
            rawTranscript: pending.state.render(), formattedNotes: "Notes",
            retainedRecordingURL: nil, retainedRecordingError: nil, systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            pendingSpeakerLabeling: pending,
            ownerRecognitionAuthorization: token
        )
        let revoked = result.validatingOwnerAuthorization(nil)
        #expect(revoked.pendingSpeakerLabeling?.ownerProfileID == nil)
        #expect(revoked.ownerRecognitionAuthorization == nil)
    }
    @Test func deferredRelabelAppliesOnlyProvidedOwnerEvidenceToFreshState() {
        let source = microphoneFixture(), profileID = UUID()
        let channels: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]] = [
            .microphone: [.init(clusterID: "owner", start: 0, end: 1)]
        ]
        let named = source.relabeling(
            channels: channels,
            ownerCluster: "owner",
            ownerName: "Enrolled owner",
            ownerProfileID: profileID
        )
        #expect(named.labels[named.turns[0].speaker] == "Enrolled owner (You)")
        #expect(named.voiceProfileID == profileID)
        let generic = source.relabeling(channels: channels)
        #expect(generic.labels[generic.turns[0].speaker] != "Enrolled owner (You)")
        #expect(generic.voiceProfileID == nil)
    }
    @Test func durableJobPublishesOnlyAgainstExactSavedGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        let source = fixture(), original = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let full = "Earlier session\n\n" + source.render()
        let pending = try #require(original.prepared(for: full))
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: full, formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, deferredSpeakerLabeling: pending)
        let job = try #require(store.meetingSpeakerLabelingJobs().first)
        #expect(job.meetingID == id)
        let new = pending.state.relabeling(channels: [.system: [.init(clusterID: "a", start: 0, end: 2)]])
        #expect(try store.completeMeetingSpeakerLabeling(job: job, state: new) == .updated)
        #expect(try store.meetingSpeakerSnapshot(id: id)?.state.epoch == new.epoch)
        #expect(try store.meetingSummaryIsStale(id: id))
        #expect(try store.meetingSpeakerLabelingJobs().isEmpty)
        let snapshot = try #require(store.meetingSpeakerSnapshot(id: id))
        var corrected = snapshot.state
        #expect(corrected.correct(.rename(corrected.turns[0].speaker, "Manual")))
        #expect(try store.updateMeetingSpeakerState(id: id, state: corrected, expected: snapshot) == .updated)
        #expect(try store.meeting(id: id)?.rawTranscript.hasPrefix("Earlier session\n\n") == true)
        let second = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, deferredSpeakerLabeling: original)
        let stale = try #require(store.meetingSpeakerLabelingJobs().first)
        try store.updateMeetingTranscript(id: second, rawTranscript: source.render()) // same-value writes invalidate too
        #expect(try store.completeMeetingSpeakerLabeling(job: stale, state: new) == .invalidated)
        #expect(try store.meeting(id: second)?.rawTranscript == source.render())
    }
    @Test func backlogFailureDoesNotRollBackCanonicalSpeech() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        try store.migrateIfNeeded()
        _ = try store.meetingSpeakerLabelingJobs()
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER fail_backlog BEFORE INSERT ON local_meeting_speaker_jobs BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil) == SQLITE_OK)
        let source = fixture(), pending = MeetingSpeakerPendingLabeling(audio: .init(channels: [.system]), state: source)
        let id = try store.insertMeeting(title: "Fixture", calendarEventID: nil, startTime: Date(), endTime: Date(), rawTranscript: source.render(), formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil, deferredSpeakerLabeling: pending)
        #expect(try store.meeting(id: id)?.rawTranscript == source.render())
        #expect(try store.meetingSpeakerLabelingJobs().isEmpty)
    }
    private func fixture() -> MeetingSpeakerState {
        let epoch = UUID(), keyID = "source"
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: keyID)
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Others", isAssignable: false)], turns: [
            .init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: "First 🌿 words"),
            .init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Second words")])
    }
    private func microphoneFixture() -> MeetingSpeakerState {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "source")
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Microphone")], turns: [
            .init(speaker: key, timestamp: "00:00:00", start: 0, end: 1, text: "Spoken words")])
    }
}

private actor BlockedSpeakerLabeling {
    var calls = 0
    var continuation: CheckedContinuation<MeetingSpeakerLabelingTracks, Never>?
    func run() async -> MeetingSpeakerLabelingTracks {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .init(channels: [:], ownerCluster: nil)); continuation = nil }
}
extension MeetingDeferredSpeakerTests {
    @Test func deadlineReturnsWhileNativeWorkIsBlockedAndRetryJoinsIt() async {
        let service = MeetingSpeakerLabelingService(), gate = BlockedSpeakerLabeling(), id = UUID()
        let first = await service.wait(id: id, timeout: .milliseconds(20), operation: { await gate.run() })
        if case .timedOut = first {} else { Issue.record("Blocked labeling did not time out") }
        #expect(await gate.calls == 1)
        let second = await service.wait(id: id, timeout: .milliseconds(20), retry: true, operation: { await gate.run() })
        if case .timedOut = second {} else { Issue.record("Retry did not join blocked work") }
        #expect(await gate.calls == 1)
        await gate.release()
        let final = await service.wait(id: id, timeout: .seconds(1), operation: { await gate.run() })
        if case .complete = final {} else { Issue.record("Completed task was not reused") }
    }
    @Test func privateAudioStagingRejectsSymlinksAndRetainsRecoveryMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.wav")
        try Data([0, 1]).write(to: source)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("backlog"))
        let descriptor = try audio.stage([.system: source])
        let url = try #require(audio.urls(descriptor)[.system])
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("recovery.json").path))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
        #expect(throws: (any Error).self) { try audio.urls(descriptor) }
    }
    @Test func failedAudioStagingRemovesItsPartialBacklogFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backlogRoot = root.appendingPathComponent("backlog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [root])
        let missingSource = root.appendingPathComponent("missing.wav")

        #expect(throws: (any Error).self) { try audio.stage([.system: missingSource]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backlogRoot.path).isEmpty)
    }
    @Test func recoverySourcesSurviveReconstructionAndCanBeDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("fixture.wav")
        try Data([1, 2, 3]).write(to: source)
        let unrelated = sourceDirectory.appendingPathComponent("unrelated.wav")
        try Data([9]).write(to: unrelated)
        let backlogRoot = root.appendingPathComponent("SpeakerBacklog", isDirectory: true)
        let audio = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let meetingID: Int64 = 42

        try audio.recordRecoverySources(meetingID: meetingID, sources: [source])
        let restored = MeetingSpeakerBacklogAudio(root: backlogRoot, allowedRecoveryRoots: [sourceDirectory])
        let record = try #require(restored.recoveryRecords().first { $0.meetingID == meetingID })
        #expect(record.urls == [source])
        #expect(record.preserves(source))
        #expect(record.preserves(sourceDirectory))
        #expect(!record.preserves(unrelated))
        let manifest = backlogRoot.appendingPathComponent("recovery-sources-\(meetingID).json")
        #expect((try FileManager.default.attributesOfItem(atPath: backlogRoot.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try restored.discardRecoverySources(meetingID: meetingID)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(restored.recoveryRecords().first { $0.meetingID == meetingID } == nil)
    }
    @Test func recoveryManifestRejectsUnapprovedFilesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let outside = root.appendingPathComponent("outside.wav")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try Data([4]).write(to: outside)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("SpeakerBacklog"), allowedRecoveryRoots: [allowed])
        #expect(throws: (any Error).self) { try audio.recordRecoverySources(meetingID: 1, sources: [outside]) }

        let link = allowed.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try audio.recordRecoverySources(meetingID: 2, sources: [link]) }
    }
    @Test func recoveryDiscardUsesValidatedInMemorySourcesWhenManifestIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let source = allowed.appendingPathComponent("fixture.wav")
        let unrelated = allowed.appendingPathComponent("unrelated.wav")
        try Data([1]).write(to: source)
        try Data([2]).write(to: unrelated)
        let audio = MeetingSpeakerBacklogAudio(root: root.appendingPathComponent("SpeakerBacklog"), allowedRecoveryRoots: [allowed])

        try audio.discardRecoverySources(meetingID: 9, fallbackSources: [source, root])

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
