@preconcurrency import CloudKit
import Foundation

/// Contains only a device ID. Claiming the writer does not share caller handles.
/// There is no automatic failover: the previous worker must drain and release.
actor CloudKitCallContactWriterOwnership: CallContactWriterOwnership {
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "MuesliSyncZone", ownerName: CKCurrentUserDefaultName)

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.mueslihq.muesli")) {
        self.container = container; self.database = container.privateCloudDatabase
    }

    private var recordID: CKRecord.ID { CKRecord.ID(recordName: "call-contact-writer", zoneID: zoneID) }

    func ownsWriter(deviceID: String) async throws -> Bool {
        guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        return try await fetch()?["deviceID"] as? String == deviceID
    }

    func claimWriter(deviceID: String) async throws -> Bool {
        guard !deviceID.isEmpty, try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        let zone = CKRecordZone(zoneID: zoneID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.save(zone) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let record = try await fetch() ?? CKRecord(recordType: "MuesliCallContactWriter", recordID: recordID)
        if let owner = record["deviceID"] as? String, !owner.isEmpty, owner != deviceID { return false }
        record["deviceID"] = deviceID as NSString
        record["updatedAt"] = Date() as NSDate
        do { try await conditionalSave(record); return true }
        catch {
            let ck = error as? CKError
            if ck?.code == .serverRecordChanged || ck?.partialErrorsByItemID?.values.contains(where: { ($0 as? CKError)?.code == .serverRecordChanged }) == true { return false }
            throw error
        }
    }

    func releaseWriterAfterDrain(deviceID: String) async throws {
        guard let record = try await fetch(), record["deviceID"] as? String == deviceID else { return }
        record["deviceID"] = nil as NSString?
        record["updatedAt"] = Date() as NSDate
        try await conditionalSave(record)
    }

    private func fetch() async throws -> CKRecord? {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let ck = error as? CKError, ck.code == .unknownItem || ck.code == .zoneNotFound { continuation.resume(returning: nil) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: record) }
            }
        }
    }

    private func conditionalSave(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = true
            operation.modifyRecordsResultBlock = { continuation.resume(with: $0) }
            database.add(operation)
        }
    }
}
