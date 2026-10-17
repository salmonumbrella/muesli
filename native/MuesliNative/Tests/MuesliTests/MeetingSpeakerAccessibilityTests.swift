import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker Accessibility evidence")
struct MeetingSpeakerAccessibilityTests {
    @Test func syntheticSourceContractsNeedIndependentSpeakingStatus() {
        for kind in MeetingSpeakerApp.allCases {
            let tile = MeetingSpeakerAXNode(id: "tile", role: "AXGroup", detail: kind.tileMarker,
                children: [.init(id: "name", role: "AXStaticText", detail: "participant name", value: "Example 🌿"),
                           .init(id: "activity", role: "AXImage", detail: "speaking status", value: "true"),
                           .init(id: "self", role: "AXImage", detail: "self status", value: "true")])
            let window = MeetingSpeakerAXWindow(scope: "pid/window/layout", app: kind,
                documentURL: kind == .meet ? "https://meet.google.com/abc-defg-hij" : nil, root: tile)
            let frame = MeetingSpeakerSources.decode(window)
            #expect(frame.participants.count == 1)
            #expect(frame.active?.name == "Example 🌿")
            #expect(frame.active?.isSelf == true)
            var roster = window
            roster.root.children.removeAll { $0.id == "activity" }
            #expect(MeetingSpeakerSources.decode(roster).reason == .rosterOnly)
            roster.truncated = true
            #expect(MeetingSpeakerSources.decode(roster).reason == .truncated)
        }
    }

    @Test func multipleWindowsHostsAndUnrelatedBrowserWithhold() {
        let a = frame(scope: "window-a", app: .zoom), b = frame(scope: "window-b", app: .teams)
        #expect(MeetingSpeakerSources.combine([a, b]).reason == .multipleHosts)
        #expect(MeetingSpeakerSources.combine([a, frame(scope: "window-c", app: .zoom)]).reason == .multipleWindows)
        let unrelated = MeetingSpeakerAXWindow(scope: "browser", app: .meet, documentURL: "https://example.test", root: .init(id: "x", role: "AXGroup", detail: "video tile"))
        #expect(MeetingSpeakerSources.decode(unrelated).active == nil)
    }

    @Test func votesUseRealSpeechAndDistinctPolls() {
        var state = fixture()
        let key = state.speakers[0].key
        let observations = (0...3).map { MeetingSpeakerObservation(time: Double($0), continuity: "one", frame: frame()) }
        let timeline = MeetingSpeakerTimeline(observations: observations)
        let activity = [MeetingSpeakerActivity(key: key, start: 0, end: 3)]
        #expect(timeline.assignments(activities: activity).names[key]?.name == "Example")
        timeline.apply(activities: activity, to: &state)
        #expect(state.labels[key] == "Example")
        #expect(state.turns[0].text == "Words")
        #expect(state.assign(.init(name: "Manual", provenance: .manual), to: key))
        timeline.apply(activities: activity, to: &state)
        #expect(state.labels[key] == "Manual")
        let reset = MeetingSpeakerTimeline(observations: [observations[0], observations[1], observations[0], observations[2], observations[3]])
        #expect(reset.assignments(activities: activity).names.isEmpty)
        state.declineAutomaticName(for: key)
        #expect(state.labels[key] == "Manual")
        let gap = MeetingSpeakerTimeline(observations: [observations[0], .init(time: 3, continuity: "two", frame: frame())])
        #expect(gap.assignments(activities: activity).names.isEmpty)
        #expect(MeetingSpeakerTimeline(observations: observations, incomplete: true).assignments(activities: activity).names.isEmpty)
    }

    @Test func overlappingClustersAndOneParticipantForTwoClustersWithhold() {
        let state = fixture(), key = state.speakers[0].key
        let other = MeetingSpeakerKey(epoch: state.epoch, channel: .system, clusterID: "other")
        let timeline = MeetingSpeakerTimeline(observations: (0...7).map { .init(time: Double($0), continuity: "one", frame: frame()) })
        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 4), .init(key: other, start: 3, end: 7)]).names.isEmpty)
        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 3), .init(key: other, start: 4, end: 7)]).names.isEmpty)
    }

    @Test func sampleClockAndExperimentalDefault() throws {
        var tracker = MeetingChunkTimingTracker()
        #expect(tracker.elapsedTimeSeconds == nil)
        tracker.start(); tracker.append(sampleCount: 32_000)
        #expect(tracker.elapsedTimeSeconds == 2)
        _ = tracker.rotate(); tracker.append(sampleCount: 16_000)
        #expect(tracker.elapsedTimeSeconds == 3)
        _ = tracker.finish(); #expect(tracker.elapsedTimeSeconds == nil)
        #expect(!AppConfig().enableMeetingSpeakerAccessibility)
        var config = AppConfig(); config.enableMeetingSpeakerAccessibility = true
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.enableMeetingSpeakerAccessibility)
        var state = fixture()
        let key = state.speakers[0].key
        state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        state.removeAccessibilityAssignments()
        #expect(state.labels[key] == "Speaker 1")
        #expect(state.speakers[0].history.isEmpty)
    }

    private func frame(scope: String = "window", app: MeetingSpeakerApp = .zoom) -> MeetingSpeakerFrame {
        .init(scope: scope, app: app, participants: [.init(id: "\(scope)/tile", name: "Example", isSelf: false)], activeID: "\(scope)/tile")
    }
    private func fixture() -> MeetingSpeakerState {
        let epoch = UUID(), keyID = "cluster"
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: keyID)
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")], turns: [.init(speaker: key, timestamp: "00:00:00", start: 0, end: 3, text: "Words")])
    }
}
