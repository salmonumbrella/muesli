import Foundation
import MuesliCore

enum MeetingSpeakerStatePersistence {
    static func persist(
        _ state: MeetingSpeakerState?,
        to store: DictationStore,
        meetingID: Int64,
        summaryIsCurrent: Bool
    ) throws {
        guard let version = try store.meetingTranscriptVersion(id: meetingID) else { return }
        if let state, version.digest == MeetingSpeakerState.digest(state.render()) {
            _ = try store.installMeetingSpeakerState(id: meetingID, state: state, expected: version)
        }
        if summaryIsCurrent {
            try store.markMeetingSummaryCurrent(id: meetingID, expected: version)
        }
    }
}
