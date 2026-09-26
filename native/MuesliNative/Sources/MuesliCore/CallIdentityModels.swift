import Foundation

public enum CallSource: String, Codable, Sendable { case phone, facetime, whatsApp, signal, telegram }
public enum CallEvidence: String, Codable, Sendable { case activeCallAX, dialerHistory, explicitCorrection }
public enum CallHandleKind: String, Codable, Sendable { case phone, email, service }
public enum CallHandleValidation: String, Codable, Sendable { case internationalSyntax, emailSyntax, serviceSyntax, unresolvedNational }
public struct CallHandle: Codable, Sendable, Hashable {
    public let kind: CallHandleKind
    public let rawValue: String
    public let canonicalValue: String
    public let namespace: String
    public let extensionValue: String?
    public let validation: CallHandleValidation
    public var stableKey: String { "\(kind.rawValue)|\(namespace)|\(canonicalValue)|\(extensionValue ?? "")" }
    public var canCreateAppleContact: Bool { validation == .internationalSyntax || validation == .emailSyntax }

    public init(kind: CallHandleKind, rawValue: String, canonicalValue: String, namespace: String, extensionValue: String?, validation: CallHandleValidation) {
        self.kind = kind
        self.rawValue = rawValue
        self.canonicalValue = canonicalValue
        self.namespace = namespace
        self.extensionValue = extensionValue
        self.validation = validation
    }
}
public enum CallFieldProvenance: Int, Codable, Sendable { case automatic = 0, calendar = 1, manual = 2 }
public struct CallRevision: Codable, Sendable, Equatable {
    public let restoreEpoch: UInt64
    public let counter: UInt64
    public let deviceID: String
    public let provenance: CallFieldProvenance

    public init(restoreEpoch: UInt64, counter: UInt64, deviceID: String, provenance: CallFieldProvenance) {
        self.restoreEpoch = restoreEpoch
        self.counter = counter
        self.deviceID = deviceID
        self.provenance = provenance
    }
}
public struct CallObservation: Codable, Sendable, Equatable {
    public let id: UUID
    public let source: CallSource
    public let sourceDeviceID: String
    public let sourceCallID: String?
    public let observedAt: Date
    public let startedAt: Date?
    public let connectedAt: Date?
    public let endedAt: Date?
    public let direction: String
    public let status: String
    public let evidence: CallEvidence
    public let handles: [CallHandle]
    public let displayName: String?
    public init(id: UUID, source: CallSource, sourceDeviceID: String,
         sourceCallID: String? = nil, observedAt: Date, startedAt: Date? = nil,
         connectedAt: Date? = nil, endedAt: Date? = nil, direction: String = "unknown",
         status: String = "unknown", evidence: CallEvidence, handles: [CallHandle],
         displayName: String? = nil) {
        self.id = id; self.source = source; self.sourceDeviceID = sourceDeviceID
        self.sourceCallID = sourceCallID; self.observedAt = observedAt
        self.startedAt = startedAt; self.connectedAt = connectedAt; self.endedAt = endedAt
        self.direction = direction; self.status = status; self.evidence = evidence
        self.handles = handles; self.displayName = displayName
    }
}
public struct CallPerson: Codable, Sendable, Equatable {
    public let id: UUID
    public var handles: [CallHandle]
    public var displayName: String?
    public var revision: CallRevision
    public var nameRevision: CallRevision
    public var handleRevisions: [String: CallRevision]
    public var deletionRevision: CallRevision?
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID, handles: [CallHandle], displayName: String?, revision: CallRevision, nameRevision: CallRevision, handleRevisions: [String: CallRevision], deletionRevision: CallRevision?, createdAt: Date, updatedAt: Date, deletedAt: Date?) {
        self.id = id
        self.handles = handles
        self.displayName = displayName
        self.revision = revision
        self.nameRevision = nameRevision
        self.handleRevisions = handleRevisions
        self.deletionRevision = deletionRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
public struct CallRecordingContext: Codable, Sendable, Equatable {
    public let recordName: String
    public let generation: UUID
    public let source: CallSource?
    public let sourceFingerprint: String
    public let sourceCallID: String?
    public let startedAt: Date

    public init(recordName: String, generation: UUID, source: CallSource?, sourceFingerprint: String, sourceCallID: String?, startedAt: Date) {
        self.recordName = recordName
        self.generation = generation
        self.source = source
        self.sourceFingerprint = sourceFingerprint
        self.sourceCallID = sourceCallID
        self.startedAt = startedAt
    }
}
public struct CallPersonResolution: Codable, Sendable, Equatable {
    public let people: [CallPerson]
    public let ambiguousHandleKeys: [String]

    public init(people: [CallPerson], ambiguousHandleKeys: [String]) {
        self.people = people
        self.ambiguousHandleKeys = ambiguousHandleKeys
    }
}
public struct CallRecordingLink: Codable, Sendable, Equatable {
    public let recording: CallRecordingContext
    public let personID: UUID
    public var revision: CallRevision
    public var isSuppressed: Bool
    public var contactSaveRequested: Bool

    public init(recording: CallRecordingContext, personID: UUID, revision: CallRevision, isSuppressed: Bool, contactSaveRequested: Bool) {
        self.recording = recording
        self.personID = personID
        self.revision = revision
        self.isSuppressed = isSuppressed
        self.contactSaveRequested = contactSaveRequested
    }
}
public struct CallPersonAlias: Codable, Sendable, Equatable {
    public let fromID: UUID
    public let rootID: UUID
    public let revision: CallRevision

    public init(fromID: UUID, rootID: UUID, revision: CallRevision) {
        self.fromID = fromID
        self.rootID = rootID
        self.revision = revision
    }
}
public enum CallIdentityOutcome: Codable, Sendable, Equatable {
    case identifying
    case identified([UUID])
    case unavailable(String)
    case ambiguous
    case permissionRequired
}
public enum CallContactSaveState: String, Codable, Sendable { case disabled, pending, saved, ambiguous, permissionRequired, failed }
public struct CallContactIntent: Codable, Sendable, Equatable {
    public let personID: UUID
    public let handles: [CallHandle]
    public let displayName: String?
    public var state: CallContactSaveState
    public var savedContactID: String?

    public init(personID: UUID, handles: [CallHandle], displayName: String?, state: CallContactSaveState, savedContactID: String?) {
        self.personID = personID
        self.handles = handles
        self.displayName = displayName
        self.state = state
        self.savedContactID = savedContactID
    }
}
public enum CallMetadataKind: String, Codable, Sendable { case person, observation, recordingLink, personAlias }
public struct CallMetadataEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let recordName: String
    public let kind: CallMetadataKind
    public let payload: Data
    public let revision: CallRevision
    public let isDeleted: Bool

    public init(schemaVersion: Int, recordName: String, kind: CallMetadataKind, payload: Data, revision: CallRevision, isDeleted: Bool) {
        self.schemaVersion = schemaVersion
        self.recordName = recordName
        self.kind = kind
        self.payload = payload
        self.revision = revision
        self.isDeleted = isDeleted
    }
}

public struct CallHistoryEntry: Codable, Sendable, Equatable {
    public let observation: CallObservation
    public let recordName: String?
    public let recordingFailure: String?

    public init(observation: CallObservation, recordName: String?, recordingFailure: String?) {
        self.observation = observation
        self.recordName = recordName
        self.recordingFailure = recordingFailure
    }
}
public struct CallSourceContext: Codable, Sendable, Equatable {
    public let source: CallSource
    public let bundleID: String
    public let pid: Int32
    public let fingerprint: String
    public let sourceCallID: String?

    public init(source: CallSource, bundleID: String, pid: Int32, fingerprint: String, sourceCallID: String?) {
        self.source = source
        self.bundleID = bundleID
        self.pid = pid
        self.fingerprint = fingerprint
        self.sourceCallID = sourceCallID
    }
}
public enum CallSourceResult: Sendable, Equatable {
    case observation(CallObservation), unavailable(String), ambiguous, permissionRequired
}
public protocol CallSourceReading: Sendable {
    func capture(context: CallSourceContext) async -> CallSourceResult
}
public protocol CallIdentityClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}
public struct SystemCallIdentityClock: CallIdentityClock {
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) / 1_000_000_000 else {
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public init() {
    }
}
