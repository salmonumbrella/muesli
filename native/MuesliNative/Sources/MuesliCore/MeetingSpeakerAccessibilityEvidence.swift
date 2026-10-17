import Foundation

public enum MeetingSpeakerApp: String, CaseIterable, Sendable {
    case zoom, teams, meet, slack
    public var tileMarker: String {
        switch self { case .zoom: "zoom participant"; case .teams: "teams participant"
        case .meet: "video tile"; case .slack: "huddle participant" }
    }
}
public enum MeetingSpeakerEvidenceReason: String, Sendable {
    case clear, rosterOnly, unrecognized, truncated, ambiguous, multipleHosts, multipleWindows, unavailable
}
public struct MeetingSpeakerAXNode: Sendable {
    public let id: String
    public let role: String
    public let detail: String
    public let value: String?
    public var children: [Self]
    public init(id: String, role: String, detail: String, value: String? = nil, children: [Self] = []) {
        self.id = id; self.role = role; self.detail = detail; self.value = value; self.children = children
    }
}
public struct MeetingSpeakerAXWindow: Sendable {
    public let scope: String
    public let app: MeetingSpeakerApp
    public let documentURL: String?
    public var root: MeetingSpeakerAXNode
    public var truncated: Bool
    public init(scope: String, app: MeetingSpeakerApp, documentURL: String? = nil, root: MeetingSpeakerAXNode, truncated: Bool = false) {
        self.scope = scope; self.app = app; self.documentURL = documentURL; self.root = root; self.truncated = truncated
    }
}
public struct MeetingSpeakerParticipant: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isSelf: Bool
    public init(id: String, name: String, isSelf: Bool) { self.id = id; self.name = name; self.isSelf = isSelf }
}
public struct MeetingSpeakerFrame: Sendable {
    public let scope: String
    public let app: MeetingSpeakerApp
    public let participants: [MeetingSpeakerParticipant]
    public let activeID: String?
    public let reason: MeetingSpeakerEvidenceReason
    public var active: MeetingSpeakerParticipant? {
        reason == .clear ? participants.first { $0.id == activeID } : nil
    }
    public init(scope: String, app: MeetingSpeakerApp, participants: [MeetingSpeakerParticipant] = [], activeID: String? = nil, reason: MeetingSpeakerEvidenceReason = .clear) {
        self.scope = scope; self.app = app; self.participants = participants; self.activeID = activeID; self.reason = reason
    }
}

/// Semantic contracts pending validation against real application layouts. Selection/focus is never activity.
public enum MeetingSpeakerSources {
    public static func decode(_ window: MeetingSpeakerAXWindow) -> MeetingSpeakerFrame {
        func result(_ reason: MeetingSpeakerEvidenceReason, _ people: [MeetingSpeakerParticipant] = [], _ active: String? = nil) -> MeetingSpeakerFrame {
            .init(scope: window.scope, app: window.app, participants: people, activeID: active, reason: reason)
        }
        guard !window.truncated else { return result(.truncated) }
        if window.app == .meet {
            guard let raw = window.documentURL, let url = URLComponents(string: raw),
                  url.scheme == "https", url.host?.lowercased() == "meet.google.com", !url.path.isEmpty else { return result(.unrecognized) }
        }
        var people: [MeetingSpeakerParticipant] = [], speaking: [String] = [], invalid = false
        func walk(_ node: MeetingSpeakerAXNode) {
            if node.role == "AXGroup", node.detail.lowercased() == window.app.tileMarker {
                let names = node.children.filter { ["participant name", "display name"].contains($0.detail.lowercased()) }
                guard names.count == 1, let raw = names.first?.value else { invalid = true; return }
                let name = MeetingSpeakerState.safeLabel(raw)
                guard !name.isEmpty, name.count <= 120 else { invalid = true; return }
                let statuses = node.children.filter { $0.detail.lowercased() == "speaking status" }
                guard statuses.count <= 1 else { invalid = true; return }
                let id = window.scope + "/" + node.id
                people.append(.init(id: id, name: name, isSelf: node.children.contains { $0.detail.lowercased() == "self status" && $0.value == "true" }))
                if statuses.first?.value == "true" { speaking.append(id) }
            } else { node.children.forEach(walk) }
        }
        walk(window.root)
        guard !invalid, Set(people.map(\.id)).count == people.count, speaking.count <= 1 else { return result(.ambiguous) }
        guard !people.isEmpty else { return result(.unrecognized) }
        return result(speaking.isEmpty ? .rosterOnly : .clear, people, speaking.first)
    }
    public static func combine(_ frames: [MeetingSpeakerFrame]) -> MeetingSpeakerFrame {
        let relevant = frames.filter { $0.reason != .unrecognized }
        guard let first = relevant.first else { return .init(scope: "", app: .zoom, reason: .unrecognized) }
        func failure(_ reason: MeetingSpeakerEvidenceReason) -> MeetingSpeakerFrame { .init(scope: first.scope, app: first.app, reason: reason) }
        guard !relevant.contains(where: { [.truncated, .unavailable, .ambiguous].contains($0.reason) }) else { return failure(.unavailable) }
        guard Set(relevant.map(\.app)).count <= 1 else { return failure(.multipleHosts) }
        guard relevant.count == 1 else { return failure(.multipleWindows) }
        return first
    }
}
public struct MeetingSpeakerObservation: Sendable {
    public let time: Double
    public let continuity: String
    public let microphoneTime: Double?
    public let frame: MeetingSpeakerFrame
    public init(time: Double, continuity: String, frame: MeetingSpeakerFrame, microphoneTime: Double? = nil) { self.time = time; self.continuity = continuity; self.frame = frame; self.microphoneTime = microphoneTime }
}
public struct MeetingSpeakerActivity: Sendable {
    public let key: MeetingSpeakerKey
    public let start: Double
    public let end: Double
    public init(key: MeetingSpeakerKey, start: Double, end: Double) { self.key = key; self.start = start; self.end = end }
}
public struct MeetingSpeakerEvidenceAssignments: Sendable {
    public var names: [MeetingSpeakerKey: MeetingSpeakerAssignment] = [:]
    public var explicitSelf: Set<MeetingSpeakerKey> = []
}
public struct MeetingSpeakerTimeline: Sendable {
    public var observations: [MeetingSpeakerObservation]
    public var incomplete: Bool
    public init(observations: [MeetingSpeakerObservation] = [], incomplete: Bool = false) { self.observations = observations; self.incomplete = incomplete }
    public func assignments(activities: [MeetingSpeakerActivity], channel: MeetingSpeakerKey.Channel = .system) -> MeetingSpeakerEvidenceAssignments {
        if channel == .microphone, observations.contains(where: { $0.microphoneTime == nil }) { return .init() }
        let observations = channel == .microphone ? self.observations.map { MeetingSpeakerObservation(time: $0.microphoneTime ?? .nan, continuity: $0.continuity, frame: $0.frame) } : self.observations
        guard !incomplete, observations.count >= 3 else { return .init() }
        guard zip(observations, observations.dropFirst()).allSatisfy({ pair in pair.0.time.isFinite && pair.1.time.isFinite && pair.1.time > pair.0.time }) else { return .init() }
        let valid = activities.filter { $0.key.channel == channel && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        let grouped = Dictionary(grouping: valid, by: \.key)
        struct Vote { var seconds = 0.0; var polls: Set<Int> = []; var person: MeetingSpeakerParticipant }
        var winners: [MeetingSpeakerKey: Vote] = [:]
        for (key, chunks) in grouped {
            guard !valid.contains(where: { other in other.key != key && chunks.contains { max($0.start, other.start) < min($0.end, other.end) } }) else { continue }
            var union: [(Double, Double)] = []
            for chunk in chunks.sorted(by: { $0.start < $1.start }) {
                if let last = union.last, chunk.start <= last.1 { union[union.count - 1].1 = max(last.1, chunk.end) }
                else { union.append((chunk.start, chunk.end)) }
            }
            let duration = union.reduce(0) { $0 + $1.1 - $1.0 }
            var votes: [String: Vote] = [:]
            for index in 1..<observations.count {
                let a = observations[index - 1], b = observations[index]
                guard a.time.isFinite, b.time.isFinite, a.time >= 0, b.time > a.time, b.time - a.time <= 1.25,
                      a.continuity == b.continuity, a.frame.scope == b.frame.scope, a.frame.app == b.frame.app,
                      let person = a.frame.active, person == b.frame.active else { continue }
                let seconds = union.reduce(0) { $0 + max(0, min($1.1, b.time) - max($1.0, a.time)) }
                guard seconds > 0 else { continue }
                var vote = votes[person.id] ?? Vote(person: person)
                vote.seconds += seconds; vote.polls.formUnion([index - 1, index]); votes[person.id] = vote
            }
            let supported = votes.values.reduce(0) { $0 + $1.seconds }
            guard let best = votes.values.max(by: { $0.seconds < $1.seconds }), best.seconds >= 2, best.polls.count >= 3,
                  supported / duration >= 0.60, best.seconds / supported >= 0.85 else { continue }
            winners[key] = best
        }
        let counts = Dictionary(grouping: winners.values, by: { $0.person.id }).mapValues(\.count)
        var result = MeetingSpeakerEvidenceAssignments()
        for (key, vote) in winners where counts[vote.person.id] == 1 {
            result.names[key] = .init(name: vote.person.name, provenance: .accessibility)
            if vote.person.isSelf { result.explicitSelf.insert(key) }
        }
        return result
    }
    public func apply(activities: [MeetingSpeakerActivity], to state: inout MeetingSpeakerState) {
        for (key, assignment) in assignments(activities: activities).names { state.assign(assignment, to: key) }
    }
}

extension MeetingSpeakerState {
    /// Revocation removes structured overrides, including undo evidence, without touching speech text.
    public mutating func removeAccessibilityAssignments() {
        func scrub(_ speaker: inout MeetingSpeaker) {
            if speaker.assignment?.provenance == .accessibility { speaker.assignment = nil }
            speaker.history.removeAll { $0.provenance == .accessibility }
        }
        for index in speakers.indices { scrub(&speakers[index]) }
        if var history = correctionHistory {
            for entry in history.indices {
                for index in history[entry].speakers.indices { scrub(&history[entry].speakers[index]) }
            }
            correctionHistory = history
        }
    }
}
