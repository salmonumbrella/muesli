import Foundation
import MuesliCore
import Testing

@Suite("Meeting speaker corrections")
struct MeetingSpeakerEditingTests {
    @Test func mergeChainKeepsSurvivorAndUndoKeepsRevision() {
        var state = fixture()
        let keys = state.speakers.map(\.key), original = state.turns
        #expect(state.correct(.rename(keys[2], "Survivor")) == true)
        #expect(state.correct(.merge(keys[0], into: keys[1])) == true)
        #expect(state.correct(.merge(keys[1], into: keys[2])) == true)
        #expect(state.canonicalKey(for: keys[0]) == keys[2])
        #expect(state.labels[keys[2]] == "Survivor")
        #expect(state.turns.allSatisfy { $0.speaker == keys[2] })
        state.revision = 42
        #expect(state.correct(.undo) == true)
        #expect(state.revision == 42)
        #expect(state.correct(.undo) == true)
        #expect(state.turns == original)
        #expect(state.isValid)
    }

    @Test func selectedWordsPreserveExactBytesAndUnrelatedTurns() {
        var state = fixture(text: "Cafe\u{301} 👩‍💻  words\nend")
        let original = state.turns[0], unaffected = state.turns[1]
        let range = (original.text as NSString).range(of: "👩‍💻  words")
        #expect(state.correct(.reassignSelection(original.id, range, to: state.speakers[1].key)) == true)
        #expect(Array(state.turns.dropLast().map(\.text).joined().utf8) == Array(original.text.utf8))
        #expect(state.turns.last == unaffected)
        #expect(state.turns.dropLast().allSatisfy { $0.start == original.start && $0.end == original.end && $0.sampleEligible == false })
        #expect(state.correct(.undo) == true)
        #expect(state.turns == [original, unaffected])
    }

    @Test func invalidSelectionsAreAtomicAndFullSelectionKeepsID() {
        var state = fixture(text: "e\u{301} 👩‍💻")
        let original = state, turn = state.turns[0], target = state.speakers[1].key
        for range in [NSRange(location: 0, length: 0), NSRange(location: Int.max, length: 2),
                      NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)] {
            #expect(state.correct(.reassignSelection(turn.id, range, to: target)) == false)
            #expect(state == original)
        }
        #expect(state.correct(.reassignSelection(turn.id, NSRange(location: 0, length: turn.text.utf16.count), to: target)) == true)
        #expect(state.turns[0].id == turn.id)
        #expect(state.turns[0].text == turn.text)
    }

    @Test func sampleBoundsOverlapAndSearch() {
        var state = fixture(text: "Search words")
        let key = state.speakers[0].key
        #expect(state.sampleRange(for: key)?.duration == 6)
        #expect(state.correct(.rename(key, "Example")) == true)
        #expect(state.matchingTurns(query: "example").count == 1)
        #expect(state.matchingTurns(query: "search").count == 1)
        state.turns.append(.init(speaker: state.speakers[1].key, timestamp: "00:00:01", start: 1, end: 3, text: "Overlap"))
        #expect(state.sampleRange(for: key) == nil)
    }

    private func fixture(text: String = "Original words") -> MeetingSpeakerState {
        let epoch = UUID()
        let speakers = (0..<3).map { index in MeetingSpeaker(key: .init(epoch: epoch, channel: .system, clusterID: "c\(index)"), rank: index + 1, fallbackLabel: "Speaker \(index + 1)") }
        return .init(epoch: epoch, speakers: speakers,
            turns: [.init(speaker: speakers[0].key, timestamp: "00:00:00", start: 0, end: 10, text: text),
                    .init(speaker: speakers[1].key, timestamp: "00:00:12", start: 12, end: 14, text: "Unchanged")])
    }
}

extension MeetingSpeakerEditingTests {
    @Test func manualCreationResetDeclineAndUndoStayReversible() {
        var state = fixture()
        let key = state.speakers[0].key
        #expect(state.assign(.init(name: "Example", provenance: .accessibility), to: key) == true)
        #expect(state.correct(.declineName(key)) == true)
        #expect(state.assign(.init(name: "Example", provenance: .accessibility), to: key) == false)
        #expect(state.correct(.undo) == true)
        #expect(state.speakers[0].assignment?.name == "Example")
        #expect(state.correct(.resetName(key)) == true)
        #expect(state.speakers[0].assignment == nil)
        #expect(state.correct(.undo) == true)
        #expect(state.correct(.addSpeaker("Example", .system)) == true)
        #expect(state.activeSpeakers.count == 4)
        #expect(state.speakers[0].key != state.speakers[3].key)
        #expect(state.correct(.undo) == true)
        #expect(state.activeSpeakers.count == 3)
    }

    @Test func assigningWordsToCurrentSpeakerDoesNotSplitText() {
        var state = fixture()
        let before = state
        let turn = state.turns[0]
        #expect(state.correct(.reassignSelection(turn.id, NSRange(location: 0, length: 8), to: turn.speaker)) == false)
        #expect(state == before)
    }
}
