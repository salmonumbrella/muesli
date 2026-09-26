import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

private actor FixtureCallContacts: CallContactsClient {
    let access: CallContactsAuthorization
    var found: [String]
    let failAfterSave: Bool
    let failBeforeSave: Bool
    private var creates = 0

    init(access: CallContactsAuthorization = .full, found: [String] = [], failAfterSave: Bool = false, failBeforeSave: Bool = false) {
        self.access = access; self.found = found
        self.failAfterSave = failAfterSave; self.failBeforeSave = failBeforeSave
    }
    func authorization() async -> CallContactsAuthorization { access }
    func matches(handles: [CallHandle]) async throws -> [String] { found }
    func create(intent: CallContactIntent) async throws -> String {
        creates += 1
        try await Task.sleep(nanoseconds: 5_000_000)
        if failBeforeSave { throw NSError(domain: "FixtureReadOnly", code: 1) }
        found = ["fixture-saved-contact"]
        if failAfterSave { throw NSError(domain: "FixtureSavedThenFailed", code: 1) }
        return "fixture-saved-contact"
    }
    func createCount() -> Int { creates }
}

private actor FixtureCallOwner: CallContactWriterOwnership {
    var owner: String?
    let offline: Bool
    init(owner: String? = "fixture-device", offline: Bool = false) { self.owner = owner; self.offline = offline }
    func ownsWriter(deviceID: String) async throws -> Bool {
        if offline { throw NSError(domain: "FixtureOffline", code: 1) }
        return owner == deviceID
    }
    func claimWriter(deviceID: String) async throws -> Bool {
        if offline { throw NSError(domain: "FixtureOffline", code: 1) }
        guard owner == nil || owner == deviceID else { return false }
        owner = deviceID; return true
    }
    func releaseWriterAfterDrain(deviceID: String) async throws { if owner == deviceID { owner = nil } }
}

@Suite("Automatic call Contacts")
struct AutomaticCallContactWriterTests {
    private func fixture(handle: CallHandle? = nil) throws -> (CallIdentityStore, UUID, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = DictationStore(databaseURL: directory.appendingPathComponent("calls.sqlite"))
        try db.migrateIfNeeded()
        let store = CallIdentityStore(store: db)
        let handle = try handle ?? #require(CallIdentityNormalizer.phone("+12025550123"))
        let observation = CallObservation(id: UUID(), source: .phone, sourceDeviceID: "fixture-device",
            observedAt: Date(), evidence: .activeCallAX, handles: [handle])
        let person = try #require(try store.resolve(observation).people.first)
        try store.saveContactIntent(CallContactIntent(personID: person.id, handles: [handle], displayName: nil, state: .pending, savedContactID: nil))
        return (store, person.id, directory)
    }

    @Test func verifiedPhoneOrEmailDoesNotRequireNames() {
        var draft = NewMeetingContactDraft()
        draft.phoneNumber = "+12025550123"
        #expect(draft.canSave)
        #expect(draft.normalizedGivenName.isEmpty)
        #expect(draft.normalizedFamilyName.isEmpty)
        draft.phoneNumber = "Private Number"
        #expect(!draft.canSave)
        draft.emailAddress = "caller@example.test"
        #expect(draft.canSave)
    }

    @Test func savedBeforeLocalAcknowledgementDoesNotCreateTwice() async throws {
        let (store, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureCallContacts(failAfterSave: true)
        let owner = FixtureCallOwner()
        let first = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: owner, deviceID: "fixture-device")
        #expect(await first.process(personID: id) == .failed)
        let reopened = DictationStore(databaseURL: directory.appendingPathComponent("calls.sqlite"))
        try reopened.migrateIfNeeded()
        let recoveredStore = CallIdentityStore(store: reopened)
        let second = AutomaticCallContactWriter(store: recoveredStore, contacts: contacts, ownership: owner, deviceID: "fixture-device")
        #expect(await second.process(personID: id) == .saved)
        #expect(await contacts.createCount() == 1)
        #expect(try recoveredStore.contactIntent(personID: id)?.savedContactID == "fixture-saved-contact")
    }

    @Test func twentyConcurrentLookupsCreateOneContact() async throws {
        let (store, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureCallContacts()
        let writer = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: FixtureCallOwner(), deviceID: "fixture-device")
        await withTaskGroup(of: CallContactSaveState.self) { group in
            for _ in 0..<20 { group.addTask { await writer.process(personID: id) } }
            for await _ in group {}
        }
        #expect(await contacts.createCount() == 1)
        #expect(try store.contactIntent(personID: id)?.state == .saved)
    }

    @Test(arguments: [CallContactsAuthorization.limited, .denied, .notDetermined])
    func insufficientPermissionNeverCreatesAndPersistsState(_ access: CallContactsAuthorization) async throws {
        let (store, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureCallContacts(access: access)
        let writer = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: FixtureCallOwner(), deviceID: "fixture-device")
        #expect(await writer.process(personID: id) == .permissionRequired)
        #expect(await contacts.createCount() == 0)
        #expect(try store.contactIntent(personID: id)?.state == .permissionRequired)
    }

    @Test func ambiguousMatchNeverCreates() async throws {
        let (store, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureCallContacts(found: ["fixture-a", "fixture-b"])
        let writer = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: FixtureCallOwner(), deviceID: "fixture-device")
        #expect(await writer.process(personID: id) == .ambiguous)
        #expect(await contacts.createCount() == 0)
        #expect(try store.contactIntent(personID: id)?.state == .ambiguous)
    }

    @Test func nonOwnerAndOfflineOwnershipStayPending() async throws {
        for owner in [FixtureCallOwner(owner: "fixture-other-device"), FixtureCallOwner(offline: true)] {
            let (store, id, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let contacts = FixtureCallContacts()
            let writer = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: owner, deviceID: "fixture-device")
            #expect(await writer.process(personID: id) == .pending)
            #expect(await contacts.createCount() == 0)
            #expect(try store.contactIntent(personID: id)?.state == .pending)
        }
    }

    @Test func serviceAndUnresolvedNationalHandleNeverCreate() async throws {
        let service = try #require(CallIdentityNormalizer.service("fixture.caller", namespace: "signal"))
        let national = try #require(CallIdentityNormalizer.phone("2025550123", region: "US"))
        for handle in [service, national] {
            let (store, id, directory) = try fixture(handle: handle)
            defer { try? FileManager.default.removeItem(at: directory) }
            let contacts = FixtureCallContacts()
            let writer = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: FixtureCallOwner(), deviceID: "fixture-device")
            #expect(await writer.process(personID: id) == .disabled)
            #expect(await contacts.createCount() == 0)
        }
    }

    @Test func failedWriteRequiresExplicitRetryAfterFindBeforeCreate() async throws {
        let (store, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureCallContacts(failBeforeSave: true)
        let writer = AutomaticCallContactWriter(store: store, contacts: contacts, ownership: FixtureCallOwner(), deviceID: "fixture-device")
        #expect(await writer.process(personID: id) == .failed)
        #expect(await writer.process(personID: id) == .failed)
        #expect(await contacts.createCount() == 1)
    }
}
