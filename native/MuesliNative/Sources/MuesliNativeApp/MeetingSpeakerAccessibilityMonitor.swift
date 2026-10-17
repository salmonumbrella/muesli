import AppKit
import ApplicationServices
import Foundation
import MuesliCore

/// One bounded scan at a time on this actor, never on the UI executor. No tree or names are logged.
actor MeetingSpeakerAccessibilityMonitor {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var continuity = UUID()
    private var timeline = MeetingSpeakerTimeline()

    func start(authorization: UUID, token: @escaping () async -> UUID?, clock: @escaping () -> Double?) {
        task?.cancel(); generation = UUID(); continuity = UUID(); timeline = .init()
        let generation = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll(generation: generation, authorization: authorization, token: token, clock: clock)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func breakContinuity() { continuity = UUID() }
    func stop() -> MeetingSpeakerTimeline {
        task?.cancel(); task = nil; generation = UUID(); return timeline
    }
    private func poll(generation: UUID, authorization: UUID, token: () async -> UUID?, clock: () -> Double?) async {
        guard self.generation == generation, await token() == authorization, let start = clock() else { breakContinuity(); return }
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> RunningAppSnapshot? in
                guard let id = app.bundleIdentifier else { return nil }
                return .init(bundleID: id, appName: "", processIdentifier: app.processIdentifier, isActive: app.isActive)
            }
        }
        guard await token() == authorization, self.generation == generation, !Task.isCancelled else { return }
        let frame = MeetingSpeakerAXReader.read(apps)
        guard await token() == authorization, self.generation == generation, !Task.isCancelled,
              let end = clock(), end >= start, end - start <= 0.5 else { breakContinuity(); return }
        guard timeline.observations.count < 14_400 else { timeline.incomplete = true; return }
        timeline.observations.append(.init(time: end, continuity: continuity.uuidString, frame: frame))
    }
}

private enum MeetingSpeakerAXReader {
    static func kind(_ id: String) -> MeetingSpeakerApp? {
        switch id {
        case "us.zoom.xos": .zoom
        case "com.microsoft.teams", "com.microsoft.teams2": .teams
        case "com.tinyspeck.slackmacgap": .slack
        case "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox": .meet
        default: nil
        }
    }
    static func read(_ apps: [RunningAppSnapshot]) -> MeetingSpeakerFrame {
        guard AXIsProcessTrusted() else { return .init(scope: "", app: .zoom, reason: .unavailable) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var frames: [MeetingSpeakerFrame] = []
        for app in apps where kind(app.bundleID) != nil {
            guard ProcessInfo.processInfo.systemUptime < deadline, let kind = kind(app.bundleID) else {
                return .init(scope: "", app: .zoom, reason: .truncated)
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], windows.count <= 8 else {
                frames.append(.init(scope: "", app: kind, reason: .unavailable)); continue
            }
            for window in windows {
                var reader = Reader(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.25))
                let root = reader.node(window, depth: 0)
                let documents = reader.documents
                let meetURLs = documents.filter { URLComponents(string: $0)?.host?.lowercased() == "meet.google.com" }
                // An unrelated browser window contributes nothing; incomplete browser reads still abstain.
                if kind == .meet, meetURLs.isEmpty, !reader.failed { continue }
                var hasher = Hasher(); hasher.combine(rootFingerprint(root))
                let scope = "\(app.processIdentifier)/\(CFHash(window))/\(hasher.finalize())"
                frames.append(MeetingSpeakerSources.decode(.init(scope: scope, app: kind,
                    documentURL: meetURLs.count == 1 ? meetURLs.first : nil, root: root,
                    truncated: reader.failed || (kind == .meet && meetURLs.count != 1))))
            }
        }
        return MeetingSpeakerSources.combine(frames)
    }
    static func rootFingerprint(_ node: MeetingSpeakerAXNode) -> [String] {
        // Ignore activity status and order; changed participant/name layouts break continuity.
        ([node.id + node.detail + (node.detail.lowercased().contains("name") ? (node.value ?? "") : "")]
            + node.children.flatMap(rootFingerprint)).sorted()
    }
    struct Reader {
        let deadline: Double
        var remaining = 600
        var visited: Set<CFHashCode> = []
        var failed = false
        var documents: [String] = []
        mutating func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { failed = true; return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if error != .success, error != .attributeUnsupported, error != .noValue { failed = true }
            return value
        }
        mutating func text(_ element: AXUIElement, _ key: String) -> String? {
            guard let value = attribute(element, key) else { return nil }
            let text: String?
            if CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? NSNumber {
                text = boolean.boolValue ? "true" : "false"
            } else { text = (value as? String) ?? (value as? NSNumber)?.stringValue }
            if let text, text.count > 500 { failed = true; return nil }
            return text
        }
        mutating func node(_ element: AXUIElement, depth: Int) -> MeetingSpeakerAXNode {
            let id = String(CFHash(element))
            guard remaining > 0, depth <= 14, visited.insert(CFHash(element)).inserted,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                failed = true; return .init(id: id, role: "", detail: "")
            }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let role = text(element, kAXRoleAttribute) ?? ""
            let detail = text(element, kAXDescriptionAttribute) ?? text(element, kAXRoleDescriptionAttribute) ?? ""
            let value = text(element, kAXValueAttribute)
            if let document = text(element, kAXDocumentAttribute) { documents.append(document) }
            var children: [MeetingSpeakerAXNode] = []
            var count: CFIndex = 0
            let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
            if countError == .success, count > 0 {
                guard count <= 100, ProcessInfo.processInfo.systemUptime < deadline else {
                    failed = true; return .init(id: id, role: role, detail: detail, value: value)
                }
                var raw: CFArray?
                if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &raw) == .success,
                   let elements = raw as? [AXUIElement] {
                    for child in elements { children.append(node(child, depth: depth + 1)) }
                } else { failed = true }
            } else if countError != .success, countError != .attributeUnsupported, countError != .noValue { failed = true }
            return .init(id: id, role: role, detail: detail, value: value, children: children)
        }
    }
}
