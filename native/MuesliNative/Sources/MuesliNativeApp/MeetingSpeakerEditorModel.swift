import Foundation
import MuesliCore
import Observation

enum MeetingSpeakerEditorError: LocalizedError {
    case busy, invalidAction, conflict
    var errorDescription: String? {
        switch self {
        case .busy: return "Speaker editing is unavailable while audio capture or meeting processing is active."
        case .invalidAction: return "That correction is unavailable. Select a speaker and complete words from one block."
        case .conflict: return "The transcript or speakers changed. Reload the editor before making another correction."
        }
    }
}

@MainActor @Observable
final class MeetingSpeakerEditorModel {
    var snapshot: MeetingSpeakerSnapshot?
    var samples: [MeetingSpeakerKey: MeetingSpeakerSampleRange] = [:]
    var isBusy = false
    var error: String?
    private var generation = UUID()

    func load(id: Int64, controller: MuesliController) async {
        let token = UUID(); generation = token; isBusy = true
        let loaded = await controller.loadMeetingSpeakerPresentation(id: id)
        let ranges = await sampleRanges(loaded.snapshot)
        guard generation == token, !Task.isCancelled else { return }
        snapshot = loaded.snapshot; samples = ranges; isBusy = false; error = nil
    }

    func apply(_ action: MeetingSpeakerCorrection, id: Int64, controller: MuesliController) async {
        guard !isBusy, let expected = snapshot else { return }
        let token = UUID(); generation = token; isBusy = true; error = nil
        do {
            let saved = try await controller.applyMeetingSpeakerCorrection(id: id, action: action, expected: expected)
            let ranges = await sampleRanges(saved)
            guard generation == token, !Task.isCancelled else { return }
            snapshot = saved; samples = ranges
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription
        }
        if generation == token { isBusy = false }
    }

    private func sampleRanges(_ snapshot: MeetingSpeakerSnapshot?) async -> [MeetingSpeakerKey: MeetingSpeakerSampleRange] {
        await Task.detached(priority: .utility) { () -> [MeetingSpeakerKey: MeetingSpeakerSampleRange] in
            guard let state = snapshot?.state else { return [:] }
            return Dictionary(uniqueKeysWithValues: state.activeSpeakers.compactMap { speaker in
                state.sampleRange(for: speaker.key).map { (speaker.key, $0) }
            })
        }.value
    }

    func cancelPendingPresentation() { generation = UUID(); isBusy = false }
}
