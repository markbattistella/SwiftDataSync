//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation

/// Connects the generic CloudKit engine to an app's SwiftData models and outbox.
///
/// Implementations remain main-actor isolated because `ModelContext` and its
/// model instances must not cross actor boundaries. The package moves only
/// stable identifiers and CloudKit records across its public boundary.
@MainActor
public protocol SwiftDataSyncStore: AnyObject {

    /// Returns durable changes across every collection this device tracks —
    /// each change's `collectionID` is how the engine routes it to the right
    /// zone, not an implicit single active one.
    func pendingChanges() throws -> [SwiftDataSyncPendingChange]

    /// Records that an upload or deletion has been attempted.
    func markAttempted(
        _ change: SwiftDataSyncPendingChange,
        errorCategory: String?
    ) throws

    /// Materialises a pending local save as a CloudKit record.
    func makeRecord(
        for change: SwiftDataSyncPendingChange,
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord?

    /// Materialises an older queued save that has no matching durable operation.
    func makeFallbackRecord(
        for id: UUID,
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord?

    /// Archives or otherwise protects local data before adopting somebody else's
    /// share for the given collection, if that collection needs any local
    /// preparation at all — unlike a single-zone engine, adopting one shared
    /// collection must not disturb any other collection this device already
    /// owns or participates in.
    ///
    /// - Parameter collectionID: The collection being adopted, when known.
    func prepareToAdoptShare(collectionID: UUID?) throws

    /// Applies fetched records and deletions to the local SwiftData source of truth.
    ///
    /// - Returns: `true` when the local store changed.
    func applyFetchedChanges(
        records: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        role: SwiftDataSyncRole
    ) throws -> Bool

    /// Applies the system fields from an accepted CloudKit save and clears its outbox row.
    ///
    /// - Returns: `true` when local state changed.
    func acceptSavedRecord(_ record: CKRecord) throws -> Bool

    /// Clears the durable deletion represented by a CloudKit record ID.
    ///
    /// - Returns: `true` when local state changed.
    func acceptDeletedRecordID(_ recordID: CKRecord.ID) throws -> Bool

    /// Preserves a server conflict and applies the app's merge policy.
    func resolveConflict(
        localRecord: CKRecord,
        serverRecord: CKRecord
    ) throws

    /// Marks a nonretryable record save as failed without discarding local data.
    func markRecordFailed(_ record: CKRecord) throws

    /// Records the failure category for a retryable durable operation.
    func markChangeAttemptFailed(
        recordID: UUID,
        mutation: SwiftDataSyncMutation,
        category: String
    ) throws

    /// Replaces a revoked participant collection with a safe new local
    /// collection. Scoped to the one collection whose zone was revoked —
    /// every other collection this device tracks is untouched.
    ///
    /// - Parameter collectionID: The collection whose share was revoked, when known.
    func recoverFromRevokedShare(collectionID: UUID?) throws

    /// Requeues records after their owner zone is recreated.
    ///
    /// - Parameter collectionID: The collection to requeue, or `nil` to requeue
    ///   every collection this device owns (used when the scope of a reset
    ///   can't be narrowed to one zone).
    func requeueRecords(forCollection collectionID: UUID?) throws

    /// Saves pending adapter changes.
    func save() throws

    /// Rolls back unsaved adapter changes after a failed transaction.
    func rollback()

    /// Publishes any app-specific snapshots after remote changes are committed.
    func didApplyRemoteChanges()
}

extension SwiftDataSyncStore {

    /// The default implementation has no legacy record to materialise.
    public func makeFallbackRecord(
        for id: UUID,
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord? {
        nil
    }

    /// The default implementation performs no post-fetch publishing.
    public func didApplyRemoteChanges() {}
}
