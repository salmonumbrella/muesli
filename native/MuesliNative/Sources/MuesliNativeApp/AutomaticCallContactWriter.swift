import Foundation
import MuesliCore

enum CallContactsAuthorization: Sendable, Equatable { case full, limited, denied, notDetermined }

protocol CallContactsClient: Sendable {
    func authorization() async -> CallContactsAuthorization
    func matches(handles: [CallHandle]) async throws -> [String]
    func create(intent: CallContactIntent) async throws -> String
}

protocol CallContactWriterOwnership: Sendable {
    func ownsWriter(deviceID: String) async throws -> Bool
    func claimWriter(deviceID: String) async throws -> Bool
    func releaseWriterAfterDrain(deviceID: String) async throws
}

/// Actor reentrancy alone does not serialize an external save. The root-ID
/// gate remains held across every await, including crash recovery reads.
actor AutomaticCallContactWriter {
    private let store: CallIdentityStore
    private let contacts: any CallContactsClient
    private let ownership: any CallContactWriterOwnership
    private let deviceID: String
    private var inFlight: Set<UUID> = []
    private var enabled = true

    init(store: CallIdentityStore, contacts: any CallContactsClient, ownership: any CallContactWriterOwnership, deviceID: String) {
        self.store = store; self.contacts = contacts; self.ownership = ownership; self.deviceID = deviceID
    }

    func process(personID: UUID) async -> CallContactSaveState {
        guard enabled, let root = try? store.rootPersonID(personID) else { return .disabled }
        guard inFlight.insert(root).inserted else { return .pending }
        defer { inFlight.remove(root) }
        func persist(_ state: CallContactSaveState, contactID: String? = nil) -> CallContactSaveState {
            do { try store.markContactIntent(personID: root, state: state, contactID: contactID) }
            catch { return .failed }
            return state
        }
        do {
            guard let intent = try store.contactIntent(personID: root) else { return .disabled }
            if intent.state == .saved { return .saved }
            let owned: Bool
            do { owned = try await ownership.ownsWriter(deviceID: deviceID) }
            catch { return persist(.pending) }
            guard owned else { return persist(.pending) }
            guard enabled, !Task.isCancelled else { return persist(.disabled) }
            guard await contacts.authorization() == .full else { return persist(.permissionRequired) }
            let matches = Array(Set(try await contacts.matches(handles: intent.handles)))
            guard enabled, !Task.isCancelled else { return persist(.disabled) }
            guard try store.contactIntent(personID: root) != nil else { return .disabled }
            if matches.count > 1 { return persist(.ambiguous) }
            if let found = matches.first { return persist(.saved, contactID: found) }
            guard intent.handles.contains(where: { $0.canCreateAppleContact }) else { return persist(.disabled) }
            // Recovery always reads Contacts. A failed write with no saved
            // contact needs an explicit retry, rather than repeated blind saves.
            if intent.state == .failed { return .failed }
            do {
                guard try await ownership.ownsWriter(deviceID: deviceID) else { return persist(.pending) }
            } catch { return persist(.pending) }
            guard enabled, !Task.isCancelled, try store.contactIntent(personID: root) != nil else { return .disabled }
            var pending = intent
            pending.state = .pending
            try store.saveContactIntent(pending)
            let identifier = try await contacts.create(intent: pending)
            guard !identifier.isEmpty else { return persist(.failed) }
            return persist(.saved, contactID: identifier)
        } catch { return persist(.failed) }
    }

    func retry(personID: UUID) async -> CallContactSaveState {
        guard enabled, var intent = try? store.contactIntent(personID: personID) else { return .disabled }
        intent.state = .pending
        do { try store.saveContactIntent(intent) } catch { return .failed }
        return await process(personID: personID)
    }

    func disable() { enabled = false }

    func disableAndRelease() async throws {
        enabled = false
        while !inFlight.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await ownership.releaseWriterAfterDrain(deviceID: deviceID)
    }
}
