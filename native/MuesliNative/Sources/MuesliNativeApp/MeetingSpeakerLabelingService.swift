import Foundation
import MuesliCore

struct MeetingSpeakerLabelingTracks: Sendable {
    let channels: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]]
    let ownerCluster: String?
}
enum MeetingSpeakerLabelingOutcome: Sendable { case complete(MeetingSpeakerLabelingTracks), failed, timedOut }

struct MeetingSpeakerRecoveryRecord: Codable, Sendable, Equatable {
    let meetingID: Int64
    let sourcePaths: [String]

    var urls: [URL] { sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL } }

    func preserves(_ candidate: URL) -> Bool {
        Self.preserves(candidate, sourceURLs: urls)
    }

    static func preserves(_ candidate: URL, sourceURLs: [URL]) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return sourceURLs.contains { source in
            let sourceComponents = source.pathComponents
            return candidateComponents.count <= sourceComponents.count
                && sourceComponents.starts(with: candidateComponents)
        }
    }
}

/// One unstructured worker per descriptor. A timeout removes only its waiter; it never joins native cancellation.
actor MeetingSpeakerLabelingService {
    static let shared = MeetingSpeakerLabelingService()
    private struct Entry {
        var result: MeetingSpeakerLabelingOutcome?
        var waiters: [UUID: CheckedContinuation<MeetingSpeakerLabelingOutcome, Never>] = [:]
        var retire: (@Sendable () -> Void)?
    }
    private var entries: [UUID: Entry] = [:]
    func wait(id: UUID, timeout: Duration? = nil, retry: Bool = false,
              operation: @escaping @Sendable () async throws -> MeetingSpeakerLabelingTracks) async -> MeetingSpeakerLabelingOutcome {
        if retry, case .failed? = entries[id]?.result { entries[id] = nil }
        if entries[id] == nil {
            entries[id] = Entry()
            Task { [weak self] in
                let result: MeetingSpeakerLabelingOutcome
                do { result = .complete(try await operation()) } catch { result = .failed }
                await self?.completed(id: id, result: result)
            }
        }
        if let result = entries[id]?.result { return result }
        let waiter = UUID()
        return await withCheckedContinuation { continuation in
            entries[id]?.waiters[waiter] = continuation
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expire(id: id, waiter: waiter)
                }
            }
        }
    }
    func retire(id: UUID, cleanup: @escaping @Sendable () -> Void) {
        guard var entry = entries[id] else { cleanup(); return }
        for waiter in entry.waiters.values { waiter.resume(returning: .failed) }; entry.waiters.removeAll()
        if entry.result != nil { entries[id] = nil; cleanup() }
        else { entry.retire = cleanup; entries[id] = entry }
    }
    private func completed(id: UUID, result: MeetingSpeakerLabelingOutcome) {
        guard let entry = entries[id] else { return }
        for waiter in entry.waiters.values { waiter.resume(returning: result) }
        if let cleanup = entry.retire { entries[id] = nil; cleanup() }
        else { entries[id]?.result = result; entries[id]?.waiters.removeAll() }
    }
    private func expire(id: UUID, waiter: UUID) { entries[id]?.waiters.removeValue(forKey: waiter)?.resume(returning: .timedOut) }
}

struct MeetingSpeakerBacklogAudio: Sendable {
    let root: URL
    let allowedRecoveryRoots: [URL]
    init(
        root: URL = AppIdentity.supportDirectoryURL.appendingPathComponent("SpeakerBacklog", isDirectory: true),
        allowedRecoveryRoots: [URL] = MeetingSpeakerBacklogAudio.defaultRecoveryRoots
    ) {
        self.root = root.standardizedFileURL
        self.allowedRecoveryRoots = allowedRecoveryRoots.map(\.standardizedFileURL)
    }
    static var defaultRecoveryRoots: [URL] {
        [
            FileManager.default.temporaryDirectory.appendingPathComponent("muesli-system-audio", isDirectory: true),
            FileManager.default.temporaryDirectory.appendingPathComponent(MeetingSession.micDiarizationDirectoryName, isDirectory: true)
        ]
    }

    func recordRecoverySources(meetingID: Int64, sources: [URL]) throws -> MeetingSpeakerRecoveryRecord {
        guard meetingID > 0, !sources.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let validated = try sources.map(validateRecoverySource).sorted { $0.path < $1.path }
        guard Set(validated.map(\.path)).count == validated.count else { throw CocoaError(.fileReadCorruptFile) }
        try ensureRoot()
        let record = MeetingSpeakerRecoveryRecord(meetingID: meetingID, sourcePaths: validated.map(\.path))
        let manifest = recoveryManifestURL(meetingID: meetingID)
        try JSONEncoder().encode(record).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return record
    }

    func recoveryRecords() -> [MeetingSpeakerRecoveryRecord] {
        guard (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory,
              let manifests = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return manifests.compactMap { manifest in
            guard manifest.lastPathComponent.hasPrefix("recovery-sources-"),
                  manifest.pathExtension == "json",
                  isRegularNonSymlink(manifest),
                  let record = try? JSONDecoder().decode(MeetingSpeakerRecoveryRecord.self, from: Data(contentsOf: manifest)),
                  record.meetingID > 0,
                  manifest.path == recoveryManifestURL(meetingID: record.meetingID).path else { return nil }
            let validated = record.sourcePaths.compactMap { try? validateRecoverySource(URL(fileURLWithPath: $0)) }
            guard Set(validated.map(\.path)).count == validated.count,
                  !validated.isEmpty else { return nil }
            return MeetingSpeakerRecoveryRecord(meetingID: record.meetingID, sourcePaths: validated.map(\.path))
        }.sorted { $0.meetingID < $1.meetingID }
    }

    func discardRecoverySources(meetingID: Int64, fallbackSources: [URL] = []) throws {
        let manifest = recoveryManifestURL(meetingID: meetingID)
        var sources = fallbackSources
        if FileManager.default.fileExists(atPath: manifest.path), isRegularNonSymlink(manifest),
           let record = try? JSONDecoder().decode(MeetingSpeakerRecoveryRecord.self, from: Data(contentsOf: manifest)),
           record.meetingID == meetingID {
            sources.append(contentsOf: record.urls)
        }
        for candidate in Set(sources.map(\.standardizedFileURL)) {
            guard let source = try? validateRecoverySource(candidate) else { continue }
            try FileManager.default.removeItem(at: source)
        }
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard isRegularNonSymlink(manifest) else { throw CocoaError(.fileReadUnsupportedScheme) }
            try FileManager.default.removeItem(at: manifest)
        }
    }

    private func ensureRoot() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory,
                  try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func validateRecoverySource(_ candidate: URL) throws -> URL {
        let source = candidate.standardizedFileURL
        guard allowedRecoveryRoots.contains(where: { $0.path == source.deletingLastPathComponent().path }),
              isRegularNonSymlink(source) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return source
    }

    private func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func recoveryManifestURL(meetingID: Int64) -> URL {
        root.appendingPathComponent("recovery-sources-\(meetingID).json")
    }
    func stage(_ sources: [MeetingSpeakerKey.Channel: URL]) throws -> MeetingSpeakerBacklogDescriptor {
        guard !sources.isEmpty, sources.keys.allSatisfy({ $0 != .imported }) else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: root.path) {
            guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadUnsupportedScheme) }
        }
        let descriptor = MeetingSpeakerBacklogDescriptor(channels: Set(sources.keys))
        let directory = folder(descriptor)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        do {
            try JSONEncoder().encode(descriptor).write(to: directory.appendingPathComponent("recovery.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("recovery.json").path)
            for (channel, source) in sources {
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
                let target = directory.appendingPathComponent(channel.rawValue + ".wav")
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
                defer { try? input.close(); try? output.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
                try output.synchronize()
            }
        } catch {
            discard(descriptor)
            throw error
        }
        return descriptor
    }
    func urls(_ descriptor: MeetingSpeakerBacklogDescriptor) throws -> [MeetingSpeakerKey.Channel: URL] {
        guard !descriptor.channels.isEmpty, !descriptor.channels.contains(.imported) else { throw CocoaError(.fileReadCorruptFile) }
        for directory in [root, folder(descriptor)] {
            guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadUnsupportedScheme) }
        }
        return try Dictionary(uniqueKeysWithValues: descriptor.channels.map { channel in
            let url = folder(descriptor).appendingPathComponent(channel.rawValue + ".wav")
            guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
            return (channel, url)
        })
    }
    func cleanAbandonedStaging(now: Date = Date()) {
        guard (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory,
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) > 86_400,
                  !FileManager.default.fileExists(atPath: child.appendingPathComponent("recovery.json").path) else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
    func discard(_ descriptor: MeetingSpeakerBacklogDescriptor) {
        // Descriptor UUIDs cannot escape this owned directory. Refuse replaced directory symlinks.
        guard (try? FileManager.default.attributesOfItem(atPath: folder(descriptor).path)[.type]) as? FileAttributeType == .typeDirectory else { return }
        try? FileManager.default.removeItem(at: folder(descriptor))
    }
    private func folder(_ descriptor: MeetingSpeakerBacklogDescriptor) -> URL { root.appendingPathComponent(descriptor.id.uuidString, isDirectory: true) }
}
