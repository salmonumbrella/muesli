import Foundation

public struct MeetingSpeakerBacklogDescriptor: Codable, Sendable, Equatable {
    public let id: UUID
    public let channels: Set<MeetingSpeakerKey.Channel>
    public init(id: UUID = UUID(), channels: Set<MeetingSpeakerKey.Channel>) { self.id = id; self.channels = channels }
}
public struct MeetingSpeakerPendingLabeling: Codable, Sendable, Equatable {
    public let audio: MeetingSpeakerBacklogDescriptor
    public var state: MeetingSpeakerState
    public var ownerProfileID: UUID?
    public init(audio: MeetingSpeakerBacklogDescriptor, state: MeetingSpeakerState, ownerProfileID: UUID? = nil) {
        self.audio = audio; self.state = state; self.ownerProfileID = ownerProfileID
    }
    public func allowsOwnerProfile(_ profileID: UUID?) -> Bool {
        guard let ownerProfileID else { return false }
        return profileID == ownerProfileID
    }
    public func prepared(for transcript: String) -> Self? {
        let tail = state.render()
        guard !tail.isEmpty, transcript.utf8.count >= tail.utf8.count,
              Array(transcript.utf8.suffix(tail.utf8.count)) == Array(tail.utf8) else { return nil }
        var copy = self
        copy.state.transcriptPrefix = String(transcript.dropLast(tail.count)) + (state.transcriptPrefix ?? "")
        return copy
    }
}
public enum MeetingSpeakerLabelingStatus: String, Codable, Sendable {
    case pending, running, failed, superseded, recovery
    public var message: String {
        switch self {
        case .pending: "Speaker labels are pending. Transcript and labeling audio are saved."
        case .running: "Speaker labels are being prepared. Transcript and labeling audio are saved."
        case .failed: "Speaker labeling did not finish. The saved transcript and labeling audio are available."
        case .superseded: "The transcript changed. Older labeling results will not replace it."
        case .recovery: "Labeling recovery needs attention. Open the recovery folder to preserve available audio."
        }
    }
}
public struct MeetingSpeakerLabelingJob: Codable, Sendable {
    public let meetingID: Int64
    public let pending: MeetingSpeakerPendingLabeling
    public let expected: MeetingTranscriptVersion
    public var status: MeetingSpeakerLabelingStatus
    public init(meetingID: Int64, pending: MeetingSpeakerPendingLabeling, expected: MeetingTranscriptVersion, status: MeetingSpeakerLabelingStatus = .pending) {
        self.meetingID = meetingID; self.pending = pending; self.expected = expected; self.status = status
    }
}
extension MeetingSpeakerState {
    /// A fresh inference epoch may change keys, never ASR boundaries or an opaque earlier-session prefix.
    public func relabeling(
        channels: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]],
        ownerCluster: String? = nil,
        ownerName: String? = nil,
        ownerProfileID: UUID? = nil
    ) -> Self {
        var result = MeetingSpeakerState(); result.transcriptPrefix = transcriptPrefix
        var identities: [String: MeetingSpeakerKey] = [:]
        for turn in turns {
            let channel = turn.speaker.channel
            let old = speakers.first { $0.key == turn.speaker }
            let active = channels[channel]?.filter { !$0.clusterID.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && max(turn.start, $0.start) < min(turn.end, $0.end) }
            let ids = Set((active ?? []).map(\.clusterID))
            var raw = "source", label = old?.fallbackLabel ?? "Unknown speaker", person = false
            if let active {
                label = "Unknown speaker"
                if ids.count > 1 { raw = "aggregate:mixed"; label = "Multiple speakers" }
                else if let id = ids.first {
                    let sorted = active.sorted { $0.start < $1.start }
                    var end = turn.start, supported = 0.0
                    for part in sorted {
                        let lower = max(max(turn.start, part.start), end), upper = min(turn.end, part.end)
                        supported += max(0, upper - lower); end = max(end, upper)
                    }
                    if turn.end > turn.start, supported / (turn.end - turn.start) >= 0.8 { raw = id; person = true }
                    else { raw = "aggregate:unknown" }
                } else { raw = "aggregate:unknown" }
            }
            let storage = channel.rawValue + "/" + raw
            let key: MeetingSpeakerKey
            if let existing = identities[storage] { key = existing }
            else {
                key = .init(epoch: result.epoch, channel: channel, clusterID: raw); identities[storage] = key
                if person {
                    let rank = result.speakers.filter { $0.key.channel == channel && $0.isAssignable }.count + 1
                    label = channel == .microphone ? "Local speaker \(rank)" : "Speaker \(rank)"
                }
                result.speakers.append(.init(key: key, rank: result.speakers.count + 1, fallbackLabel: label, isAssignable: person || (active == nil && old?.isAssignable == true),
                    isSelf: active == nil && old?.isSelf == true && old?.selfProvenance == nil))
            }
            var copy = turn; copy.speaker = key; result.turns.append(copy)
        }
        if let ownerCluster, let ownerName, let ownerProfileID {
            let key = MeetingSpeakerKey(epoch: result.epoch, channel: .microphone, clusterID: ownerCluster)
            if result.turns.contains(where: { $0.speaker == key }) {
                result.applySelfEvidence(accessibility: [], voice: [key], ownerName: ownerName, profileID: ownerProfileID)
            }
        }
        return result
    }
    public func preservesSpeech(of source: Self) -> Bool {
        guard turns.count == source.turns.count, Array((transcriptPrefix ?? "").utf8) == Array((source.transcriptPrefix ?? "").utf8) else { return false }
        return zip(turns, source.turns).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.start == pair.1.start && pair.0.end == pair.1.end && pair.0.timestamp == pair.1.timestamp && Array(pair.0.text.utf8) == Array(pair.1.text.utf8)
        }
    }
}
