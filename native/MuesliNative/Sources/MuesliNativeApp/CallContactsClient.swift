import Contacts
import Foundation
import MuesliCore

enum CallContactsClientError: Error { case permissionRequired, invalidHandle, destinationUnavailable, missingIdentifier }

actor AppleCallContactsClient: CallContactsClient {
    func authorization() async -> CallContactsAuthorization {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        if #available(iOS 18, *), status == .limited { return .limited }
        #endif
        switch status {
        case .authorized: return .full
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Only a settings gesture requests permission. Recording lookups never
    /// interrupt the audio start with a Contacts permission prompt.
    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    func matches(handles: [CallHandle]) async throws -> [String] {
        guard await authorization() == .full else { throw CallContactsClientError.permissionRequired }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let requested = Set(handles.map(\.stableKey))
        let regions = Set(handles.filter { $0.namespace.hasPrefix("national:") }.map { String($0.namespace.dropFirst("national:".count)) })
        var identifiers: Set<String> = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            var observed = contact.emailAddresses.compactMap { CallIdentityNormalizer.email($0.value as String) }
            for number in contact.phoneNumbers {
                if let international = CallIdentityNormalizer.phone(number.value.stringValue) { observed.append(international) }
                for region in regions {
                    if let national = CallIdentityNormalizer.phone(number.value.stringValue, region: region) { observed.append(national) }
                }
            }
            if observed.contains(where: { requested.contains($0.stableKey) }) { identifiers.insert(contact.identifier) }
        }
        return identifiers.sorted()
    }

    func create(intent: CallContactIntent) async throws -> String {
        guard await authorization() == .full else { throw CallContactsClientError.permissionRequired }
        let handles = intent.handles.filter { handle in
            guard handle.canCreateAppleContact else { return false }
            let verified = handle.kind == .phone
                ? CallIdentityNormalizer.phone(handle.rawValue) : CallIdentityNormalizer.email(handle.rawValue)
            return verified?.stableKey == handle.stableKey
        }
        guard !handles.isEmpty else { throw CallContactsClientError.invalidHandle }
        let contact = CNMutableContact()
        contact.givenName = intent.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        contact.familyName = ""
        contact.phoneNumbers = handles.filter { $0.kind == .phone }.map { handle in
            let value = handle.canonicalValue + (handle.extensionValue.map { " ext " + $0 } ?? "")
            return CNLabeledValue(label: CNLabelOther, value: CNPhoneNumber(stringValue: value))
        }
        contact.emailAddresses = handles.filter { $0.kind == .email }.map {
            CNLabeledValue(label: CNLabelOther, value: $0.canonicalValue as NSString)
        }
        let store = CNContactStore()
        let container = store.defaultContainerIdentifier()
        guard !container.isEmpty else { throw CallContactsClientError.destinationUnavailable }
        let save = CNSaveRequest()
        save.add(contact, toContainerWithIdentifier: container)
        try store.execute(save)
        guard !contact.identifier.isEmpty else { throw CallContactsClientError.missingIdentifier }
        return contact.identifier
    }
}
