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
    let stagedDescriptor: MeetingSpeakerBacklogDescriptor?

    init(meetingID: Int64, sourcePaths: [String], stagedDescriptor: MeetingSpeakerBacklogDescriptor? = nil) {
        self.meetingID = meetingID
        self.sourcePaths = sourcePaths
        self.stagedDescriptor = stagedDescriptor
    }

    var urls: [URL] { sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var hasRecoverableAudio: Bool { !sourcePaths.isEmpty || stagedDescriptor != nil }

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
        else {
            if let existing = entry.retire {
                entry.retire = { existing(); cleanup() }
            } else { entry.retire = cleanup }
            entries[id] = entry
        }
    }
    func retire(ids: Set<UUID>, cleanup: @escaping @Sendable () -> Void) {
        guard !ids.isEmpty else { cleanup(); return }
        let barrier = MeetingSpeakerRetirementBarrier(count: ids.count, cleanup: cleanup)
        for id in ids { retire(id: id) { barrier.finish() } }
    }
    func retireUnreferencedStaging(_ audio: MeetingSpeakerBacklogAudio, preserving ids: Set<UUID>, olderThan cutoff: Date) {
        for descriptor in audio.storedStagedDescriptors(olderThan: cutoff) where !ids.contains(descriptor.id) {
            retire(id: descriptor.id) { audio.discard(descriptor) }
        }
    }
    private func completed(id: UUID, result: MeetingSpeakerLabelingOutcome) {
        guard let entry = entries[id] else { return }
        for waiter in entry.waiters.values { waiter.resume(returning: result) }
        if let cleanup = entry.retire { entries[id] = nil; cleanup() }
        else { entries[id]?.result = result; entries[id]?.waiters.removeAll() }
    }
    private func expire(id: UUID, waiter: UUID) { entries[id]?.waiters.removeValue(forKey: waiter)?.resume(returning: .timedOut) }
}

private final class MeetingSpeakerRetirementBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let cleanup: @Sendable () -> Void
    init(count: Int, cleanup: @escaping @Sendable () -> Void) { remaining = count; self.cleanup = cleanup }
    func finish() {
        let shouldClean = lock.withLock { () -> Bool in
            remaining -= 1
            return remaining == 0
        }
        if shouldClean { cleanup() }
    }
}

func retireDeletedSpeakerLabelingJobs(_ jobs: [MeetingSpeakerLabelingJob]) {
    for (meetingID, meetingJobs) in Dictionary(grouping: jobs, by: \.meetingID) {
        let audio = MeetingSpeakerBacklogAudio()
        let descriptors = meetingJobs.map(\.pending.audio)
        Task {
            await MeetingSpeakerLabelingService.shared.retire(ids: Set(descriptors.map(\.id)), cleanup: {
                for descriptor in descriptors { audio.discard(descriptor) }
                try? audio.discardRecoverySources(meetingID: meetingID, fallbackDescriptors: descriptors)
            })
        }
    }
}

func retireDeletedSpeakerRecoveryRecords(_ records: [MeetingSpeakerRecoveryRecord]) {
    for recovery in records {
        let audio = MeetingSpeakerBacklogAudio()
        let descriptors = recovery.stagedDescriptor.map { [$0] } ?? []
        Task {
            await MeetingSpeakerLabelingService.shared.retire(ids: Set(descriptors.map(\.id)), cleanup: {
                try? audio.discardRecoverySources(meetingID: recovery.meetingID,
                                                  fallbackSources: recovery.urls,
                                                  fallbackDescriptors: descriptors)
            })
        }
    }
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
        let existingSources = readRecoveryRecord(meetingID: meetingID)?.urls.compactMap { try? validateRecoverySource($0) } ?? []
        let existingDescriptor = readRecoveryRecord(meetingID: meetingID)?.stagedDescriptor
            .flatMap { isStoredBacklogDescriptor($0) ? $0 : nil }
        return try writeRecoveryRecord(.init(
            meetingID: meetingID,
            sourcePaths: Array(Set(existingSources + validated).map(\.path)).sorted(),
            stagedDescriptor: existingDescriptor
        ))
    }

    func recordRecoveryDescriptor(meetingID: Int64, descriptor: MeetingSpeakerBacklogDescriptor) throws -> MeetingSpeakerRecoveryRecord {
        guard meetingID > 0, isStoredBacklogDescriptor(descriptor) else { throw CocoaError(.fileReadCorruptFile) }
        let existing = readRecoveryRecord(meetingID: meetingID)
        let sources = existing?.urls.compactMap { try? validateRecoverySource($0) } ?? []
        return try writeRecoveryRecord(.init(
            meetingID: meetingID,
            sourcePaths: Array(Set(sources.map(\.path))).sorted(),
            stagedDescriptor: descriptor
        ))
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
            guard Set(validated.map(\.path)).count == validated.count else { return nil }
            let stagedDescriptor = record.stagedDescriptor.flatMap { isStoredBacklogDescriptor($0) ? $0 : nil }
            guard !validated.isEmpty || stagedDescriptor != nil else { return nil }
            return MeetingSpeakerRecoveryRecord(meetingID: record.meetingID, sourcePaths: validated.map(\.path), stagedDescriptor: stagedDescriptor)
        }.sorted { $0.meetingID < $1.meetingID }
    }

    func discardRecoverySources(
        meetingID: Int64,
        fallbackSources: [URL] = [],
        fallbackDescriptors: [MeetingSpeakerBacklogDescriptor] = []
    ) throws {
        let manifest = recoveryManifestURL(meetingID: meetingID)
        var sources = fallbackSources
        var descriptors = fallbackDescriptors
        if let record = readRecoveryRecord(meetingID: meetingID) {
            sources.append(contentsOf: record.urls)
            if let descriptor = record.stagedDescriptor { descriptors.append(descriptor) }
        }
        for candidate in Set(sources.map(\.standardizedFileURL)) {
            guard let source = try? validateRecoverySource(candidate) else { continue }
            try FileManager.default.removeItem(at: source)
        }
        var discardedIDs: Set<UUID> = []
        for descriptor in descriptors where discardedIDs.insert(descriptor.id).inserted {
            try removeBacklogFolder(descriptor)
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

    private func readRecoveryRecord(meetingID: Int64) -> MeetingSpeakerRecoveryRecord? {
        let manifest = recoveryManifestURL(meetingID: meetingID)
        guard FileManager.default.fileExists(atPath: manifest.path), isRegularNonSymlink(manifest),
              let record = try? JSONDecoder().decode(MeetingSpeakerRecoveryRecord.self, from: Data(contentsOf: manifest)),
              record.meetingID == meetingID else { return nil }
        return record
    }

    private func writeRecoveryRecord(_ record: MeetingSpeakerRecoveryRecord) throws -> MeetingSpeakerRecoveryRecord {
        try ensureRoot()
        let manifest = recoveryManifestURL(meetingID: record.meetingID)
        if FileManager.default.fileExists(atPath: manifest.path), !isRegularNonSymlink(manifest) {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try JSONEncoder().encode(record).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return record
    }

    private func isStoredBacklogDescriptor(_ descriptor: MeetingSpeakerBacklogDescriptor) -> Bool {
        guard !descriptor.channels.isEmpty, !descriptor.channels.contains(.imported) else { return false }
        let directory = folder(descriptor)
        guard (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        let marker = directory.appendingPathComponent("recovery.json")
        guard isRegularNonSymlink(marker),
              let stored = try? JSONDecoder().decode(MeetingSpeakerBacklogDescriptor.self, from: Data(contentsOf: marker)) else { return false }
        return stored == descriptor
    }

    private func removeBacklogFolder(_ descriptor: MeetingSpeakerBacklogDescriptor) throws {
        let directory = folder(descriptor)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard (try FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try FileManager.default.removeItem(at: directory)
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
    func storedStagedDescriptors(olderThan cutoff: Date? = nil) -> [MeetingSpeakerBacklogDescriptor] {
        guard (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory,
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return children.compactMap { child in
            guard let id = UUID(uuidString: child.lastPathComponent) else { return nil }
            if let cutoff {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                      let modified = attributes[.modificationDate] as? Date, modified < cutoff else { return nil }
            }
            let marker = child.appendingPathComponent("recovery.json")
            guard isRegularNonSymlink(marker),
                  let descriptor = try? JSONDecoder().decode(MeetingSpeakerBacklogDescriptor.self, from: Data(contentsOf: marker)),
                  descriptor.id == id, isStoredBacklogDescriptor(descriptor) else { return nil }
            return descriptor
        }
    }
    func discard(_ descriptor: MeetingSpeakerBacklogDescriptor) {
        // Descriptor UUIDs cannot escape this owned directory. Refuse replaced directory symlinks.
        guard (try? FileManager.default.attributesOfItem(atPath: folder(descriptor).path)[.type]) as? FileAttributeType == .typeDirectory else { return }
        try? FileManager.default.removeItem(at: folder(descriptor))
    }
    private func folder(_ descriptor: MeetingSpeakerBacklogDescriptor) -> URL { root.appendingPathComponent(descriptor.id.uuidString, isDirectory: true) }
}
