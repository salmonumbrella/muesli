import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Live speaker attribution")
struct MeetingLiveSpeakerTests {
    @Test func settleAndChannelSeparationKeepTextAndRowIdentity() {
        var registry = MeetingLiveSpeakerRegistry()
        let a = turn(channel: .microphone), b = turn(channel: .system)
        registry.append(a, channel: .microphone); registry.append(b, channel: .system)
        #expect(registry.state.labels[registry.state.turns[0].speaker] == "Identifying speaker")
        for channel in [MeetingSpeakerKey.Channel.microphone, .system] {
            registry.complete(channel: channel, start: 0, end: 3, segments: [.init(clusterID: "same", start: 0, end: 1)])
        }
        #expect(registry.state.turns.map(\.text) == [a.text, b.text])
        #expect(registry.state.turns.map(\.id) == [a.id, b.id])
        #expect(registry.state.turns[0].speaker != registry.state.turns[1].speaker)
        #expect(registry.state.speakers.filter(\.isAssignable).count == 2)
        let old = registry.state.turns
        registry.complete(channel: .system, start: 3, end: 8, segments: [.init(clusterID: "different", start: 3, end: 8)])
        #expect(registry.state.turns == old)
    }
    @Test func capturedClockExpiresPendingWithoutInferenceAndMixedSpeechWithholds() {
        var registry = MeetingLiveSpeakerRegistry()
        let a = turn(channel: .system)
        registry.append(a, channel: .system)
        registry.advanceCaptured(channel: .system, to: 9)
        #expect(registry.state.labels[registry.state.turns[0].speaker] == "Others")
        var mixed = MeetingLiveSpeakerRegistry()
        mixed.append(a, channel: .system)
        mixed.complete(channel: .system, start: 0, end: 3, segments: [.init(clusterID: "a", start: 0, end: 1), .init(clusterID: "b", start: 0.5, end: 1)])
        #expect(mixed.state.labels[mixed.state.turns[0].speaker] == "Multiple speakers")
    }
    @Test func delayedRowTouchingGapNeverUsesNearbyEvidence() {
        var registry = MeetingLiveSpeakerRegistry()
        registry.complete(channel: .system, start: 0, end: 5, segments: [], failed: true)
        registry.complete(channel: .system, start: 5, end: 10, segments: [.init(clusterID: "other", start: 5, end: 10)])
        let delayed = turn(channel: .system)
        registry.append(delayed, channel: .system)
        #expect(registry.state.labels[registry.state.turns[0].speaker] == "Others")
        #expect(registry.state.turns[0].text == delayed.text)
    }
    @Test func queueIsBoundedAndPauseCreatesGap() {
        var queue = MeetingSpeakerPCMQueue()
        queue.append([Float](repeating: 0.1, count: 400_001), channel: .microphone, startSample: 0)
        #expect(queue.pendingCount <= 2)
        #expect(!queue.takeGaps().isEmpty)
        let gaps = queue.resetPartial()
        #expect(!gaps.isEmpty)
    }
    @Test func microphoneGateRejectsInvalidSignalAndShortSpeech() {
        let speech = [Float](repeating: 0.01, count: 80_000)
        #expect(MeetingMicrophoneSpeechGate.accepts(speech, speechSeconds: 1))
        #expect(!MeetingMicrophoneSpeechGate.accepts(speech, speechSeconds: 0.1))
        #expect(!MeetingMicrophoneSpeechGate.accepts([.nan], speechSeconds: 1))
        #expect(!MeetingMicrophoneSpeechGate.accepts([Float](repeating: 1, count: 80_000), speechSeconds: 1))
        #expect(!AppConfig().enableLiveSpeakerLabels)
    }
    @Test func shortAndEvictedCoverageNeverBorrowsIdentity() {
        var registry = MeetingLiveSpeakerRegistry()
        registry.complete(channel: .system, start: 0, end: 5, segments: [.init(clusterID: "first", start: 0, end: 0.2)])
        registry.append(turn(channel: .system), channel: .system)
        #expect(registry.state.labels[registry.state.turns[0].speaker] == "Others")
        var evicted = MeetingLiveSpeakerRegistry()
        let segments = (0..<100_001).map { MeetingLiveSpeakerSegment(clusterID: "same", start: Double($0), end: Double($0) + 1) }
        evicted.complete(channel: .system, start: 0, end: 100_001, segments: segments)
        evicted.append(turn(channel: .system), channel: .system)
        #expect(evicted.state.labels[evicted.state.turns[0].speaker] == "Others")
    }
    private func turn(channel: MeetingSpeakerKey.Channel) -> MeetingSpeakerTurn {
        .init(speaker: .init(epoch: UUID(), channel: channel, clusterID: "ignored"), timestamp: "00:00:00", start: 0, end: 1, text: " exact 🌿 words ")
    }
}

private actor SuspendedLiveSpeakerInference {
    var calls = 0
    private var continuation: CheckedContinuation<[MeetingLiveSpeakerSegment], Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func infer(_ window: MeetingSpeakerAudioWindow) async -> [MeetingLiveSpeakerSegment] {
        calls += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation; started = true; waiter?.resume(); waiter = nil
        }
    }
    func waitForStart() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func release() { continuation?.resume(returning: [.init(clusterID: "late", start: 0, end: 5)]); continuation = nil }
}

extension MeetingLiveSpeakerTests {
    @Test func stoppingInFlightInferenceCannotPublishIdentity() async {
        let inference = SuspendedLiveSpeakerInference()
        let feed = MeetingLiveSpeakerFeed(epoch: UUID(), infer: { await inference.infer($0) }, publish: { _ in })
        let row = turn(channel: .system)
        await feed.appendTurns([row], channel: .system)
        feed.appendPCM([Float](repeating: 0.01, count: 400_000), channel: .system, startSample: 0)
        await inference.waitForStart()
        #expect(await inference.calls == 1)
        await feed.finish()
        await inference.release()
        await feed.testingWaitForDrain()
        let state = await feed.testingState()
        #expect(state.turns[0].id == row.id)
        #expect(state.labels[state.turns[0].speaker] == "Others")
        #expect(!state.speakers.contains(where: \.isAssignable))
    }
}
