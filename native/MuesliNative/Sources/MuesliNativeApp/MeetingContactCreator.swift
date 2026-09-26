import Contacts
import Foundation
import MuesliCore

struct NewMeetingContactDraft: Equatable, Sendable {
    var givenName = ""
    var familyName = ""
    var companyName = ""
    var phoneNumber = ""
    var emailAddress = ""

    var canSave: Bool {
        !normalizedGivenName.isEmpty || !normalizedFamilyName.isEmpty
            || CallIdentityNormalizer.phone(normalizedPhoneNumber)?.canCreateAppleContact == true
            || CallIdentityNormalizer.email(normalizedEmailAddress)?.canCreateAppleContact == true
    }

    var normalizedCompanyName: String { companyName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedPhoneNumber: String { phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines) }

    var normalizedGivenName: String {
        givenName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedFamilyName: String {
        familyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedEmailAddress: String {
        emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MeetingContactCreatorError: LocalizedError, Equatable {
    case nameRequired
    case accessDenied
    case destinationUnavailable
    case missingIdentifier

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Add a name, international phone number, or email before saving this contact."
        case .accessDenied:
            return "Muesli does not have permission to add contacts. Enable Contacts access in System Settings."
        case .missingIdentifier:
            return "Apple Contacts saved the person without returning an identifier. Try choosing them from Contacts instead."
        case .destinationUnavailable:
            return "Your default Contacts account is unavailable. Check the default account in Contacts settings and try again."
        }
    }
}

enum MeetingContactCreator {
    static func create(_ draft: NewMeetingContactDraft) async throws -> MeetingParticipantDraft {
        guard draft.canSave else {
            throw MeetingContactCreatorError.nameRequired
        }

        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted:
            throw MeetingContactCreatorError.accessDenied
        default:
            guard try await requestAccess(using: store) else {
                throw MeetingContactCreatorError.accessDenied
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            let contact = CNMutableContact()
            contact.givenName = draft.normalizedGivenName
            contact.familyName = draft.normalizedFamilyName
            contact.organizationName = draft.normalizedCompanyName
            if !draft.normalizedPhoneNumber.isEmpty {
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelOther, value: CNPhoneNumber(stringValue: draft.normalizedPhoneNumber))]
            }
            if !draft.normalizedEmailAddress.isEmpty {
                contact.emailAddresses = [
                    CNLabeledValue(label: CNLabelWork, value: draft.normalizedEmailAddress as NSString),
                ]
            }

            let store = CNContactStore()
            let container = store.defaultContainerIdentifier()
            guard !container.isEmpty else { throw MeetingContactCreatorError.destinationUnavailable }
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: container)
            try store.execute(request)

            guard !contact.identifier.isEmpty else {
                throw MeetingContactCreatorError.missingIdentifier
            }
            return MeetingContactIdentity.participant(for: contact)
        }.value
    }

    private static func requestAccess(using store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
