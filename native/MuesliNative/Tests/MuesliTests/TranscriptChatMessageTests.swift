import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Transcript chat message parsing")
struct TranscriptChatMessageTests {
    @Test("uncertain recorded-audio speakers retain their explicit labels")
    func uncertainSpeakers() {
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] Multiple speakers: Hello\n[00:00:06] Unknown speaker: Goodbye")
        #expect(messages.map(\.speaker) == ["Multiple speakers", "Unknown speaker"])
        #expect(messages.map(\.text) == ["Hello", "Goodbye"])
        #expect(messages.allSatisfy { !$0.isUser })
    }

    @Test("in-room microphone speakers keep their local labels")
    func localSpeakers() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] Local speaker 1: Ahoj.
        [10:00:02] Local speaker 12: Dobrý den.
        [10:00:05] Local speaker: Ano.
        """)
        #expect(messages.map(\.speaker) == ["Local speaker 1", "Local speaker 12", "Local speaker"])
        #expect(messages.map(\.text) == ["Ahoj.", "Dobrý den.", "Ano."])
        #expect(messages.allSatisfy { !$0.isUser })
    }

    @Test("timestamped speaker lines become chat messages")
    func timestampedSpeakerLinesBecomeChatMessages() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] You: Hello there.
        [10:00:04] Speaker 1: Hi back.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].timestamp == "10:00:00")
        #expect(messages[0].speaker == "You")
        #expect(messages[0].text == "Hello there.")
        #expect(messages[0].isUser)
        #expect(messages[1].speaker == "Speaker 1")
        #expect(messages[1].text == "Hi back.")
        #expect(!messages[1].isUser)
    }

    @Test("timestamped custom speaker labels survive without structured state")
    func timestampedCustomSpeakerLabels() {
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] Alice: Hello there.")

        #expect(messages.count == 1)
        #expect(messages[0].speaker == "Alice")
        #expect(messages[0].text == "Hello there.")
    }

    @Test("plain transcript lines are preserved")
    func plainTranscriptLinesArePreserved() {
        let messages = TranscriptChatMessage.messages(from: """
        Product: launch timeline changed.

        This line has no speaker.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].speaker == nil)
        #expect(messages[0].text == "Product: launch timeline changed.")
        #expect(messages[1].text == "This line has no speaker.")
    }
}

extension TranscriptChatMessageTests {
    @Test func multilineStructuredTurnsKeepCitationIdentity() throws {
        let epoch = UUID()
        let first = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "first")
        let second = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "second")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: first, rank: 1, fallbackLabel: "Speaker 1"),
                       .init(key: second, rank: 2, fallbackLabel: "Speaker 2")],
            turns: [.init(speaker: first, timestamp: "00:00:01", start: 1, end: 2, text: "First line\ncontinued first line"),
                    .init(speaker: second, timestamp: "00:00:03", start: 3, end: 4, text: "Second turn")])
        let transcript = state.render()
        let messages = TranscriptChatMessage.messages(from: transcript, speakerState: state)
        let continued = (transcript as NSString).range(of: "continued first line")
        let secondTurn = (transcript as NSString).range(of: "Second turn")

        #expect(MeetingTranscriptScrollTarget.messageID(
            highlightedRange: continued, transcript: transcript, messages: messages, speakerState: state
        ) == 0)
        #expect(MeetingTranscriptScrollTarget.messageID(
            highlightedRange: secondTurn, transcript: transcript, messages: messages, speakerState: state
        ) == 1)
    }

    @Test func transcriptCitationScrollTargetWaitsForRowsToLoad() throws {
        let transcript = """
        [00:00:01] Speaker 1: First sentence.

        [00:00:03] Speaker 2: Cited sentence.
        """
        let range = (transcript as NSString).range(of: "Cited sentence")
        let expectedID = try #require(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: range))
        let messages = TranscriptChatMessage.messages(from: transcript)

        #expect(MeetingTranscriptScrollTarget.messageID(highlightedRange: range, transcript: transcript, messages: []) == nil)
        #expect(MeetingTranscriptScrollTarget.messageID(highlightedRange: range, transcript: transcript, messages: messages) == expectedID)
    }

    @Test func structuredMessagesKeepIdentityAndColonNames() {
        let epoch = UUID()
        let a = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "a")
        let b = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "b")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: a, rank: 1, fallbackLabel: "Speaker 1", assignment: .init(name: "Team: Example", provenance: .manual)),
                       .init(key: b, rank: 2, fallbackLabel: "Speaker 2", assignment: .init(name: "You", provenance: .manual))],
            turns: [.init(speaker: a, timestamp: "00:00:01", start: 1, end: 2, text: "Product: unchanged"),
                    .init(speaker: b, timestamp: "00:00:03", start: 3, end: 4, text: "Second")])
        let messages = TranscriptChatMessage.messages(from: state.render(), speakerState: state)
        #expect(messages[0].speaker == "Team: Example")
        #expect(messages[0].text == "Product: unchanged")
        #expect(messages[0].speakerKey == a)
        #expect(messages[1].speakerKey == b)
        #expect(!messages[1].isUser)
        #expect(TranscriptChatMessage.messages(from: "Edited text", speakerState: state)[0].speakerKey == nil)
    }
}
