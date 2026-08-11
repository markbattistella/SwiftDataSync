//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation

/// Connects the generic CloudKit engine to an app's SwiftData models and
/// outbox.
///
/// The engine calls these methods to read durable local changes, materialise
/// them as CloudKit records, and apply whatever comes back. The adapter owns
/// every decision the engine can't make generically: how models map to
/// records, what a collection means, and how conflicts merge.
///
/// Mutating methods leave the adapter's changes unsaved; the engine calls
/// ``save()`` once a batch succeeds and ``rollback()`` if it doesn't, so a
/// failed batch never half-applies.
///
/// - Important: Implementations are main-actor isolated because
///   `ModelContext` and its model instances must not cross actor boundaries.
///   Only stable identifiers and CloudKit records cross this boundary.
@MainActor
public protocol SwiftDataSyncStore: AnyObject {

    /// Returns durable changes across every collection this device tracks.
    ///
    /// Each change's `collectionID` is how the engine routes it to a zone, so
    /// changes from different collections can be returned together.
    ///
    /// - Returns: Every change still awaiting CloudKit delivery.
    func pendingChanges() throws -> [SwiftDataSyncPendingChange]

    /// Records that an upload or deletion has been attempted.
    ///
    /// - Parameters:
    ///   - change: The change being sent.
    ///   - errorCategory: The `CKError.Code` name from a previous failure, or
    ///     `nil` for a first attempt.
    func markAttempted(
        _ change: SwiftDataSyncPendingChange,
        errorCategory: String?
    ) throws

    /// Materialises a pending local save as a CloudKit record.
    ///
    /// - Parameters:
    ///   - change: The durable change to materialise.
    ///   - zoneID: The zone the record belongs to.
    /// - Returns: The record to upload, or `nil` when the model no longer
    ///   exists, which drops the change from the engine's queue.
    func makeRecord(
        for change: SwiftDataSyncPendingChange,
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord?

    /// Materialises a queued save that has no matching durable operation.
    ///
    /// Called only after ``makeRecord(for:in:)`` finds nothing, to rescue
    /// changes queued by an earlier version of the app.
    ///
    /// - Parameters:
    ///   - id: The stable local identity of the queued save.
    ///   - zoneID: The zone the record belongs to.
    /// - Returns: The record to upload, or `nil` when none can be rebuilt.
    func makeFallbackRecord(
        for id: UUID,
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord?

    /// Protects local data before adopting somebody else's share.
    ///
    /// Archive or otherwise preserve anything the incoming share would
    /// displace, if the collection needs preparation at all. Adopting one
    /// shared collection must not disturb any other collection this device
    /// owns or participates in.
    ///
    /// Throwing cancels the adoption, so raise an error rather than let local
    /// data be lost.
    ///
    /// - Parameter collectionID: The collection being adopted, when known.
    func prepareToAdoptShare(collectionID: UUID?) throws

    /// Applies fetched records and deletions to the local source of truth.
    ///
    /// Called once per zone, so every record in a call shares one role.
    ///
    /// - Parameters:
    ///   - records: The records CloudKit reported as created or updated.
    ///   - deletedRecordIDs: The records CloudKit reported as deleted.
    ///   - role: This device's relationship to the zone they came from.
    /// - Returns: `true` when the local store changed.
    func applyFetchedChanges(
        records: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        role: SwiftDataSyncRole
    ) throws -> Bool

    /// Applies the system fields from an accepted save and clears its outbox
    /// row.
    ///
    /// Store the record's system fields — see
    /// ``SwiftDataSyncRecordSupport/archiveSystemFields(from:)`` — so later
    /// saves can be conflict-aware.
    ///
    /// - Parameter record: The record as CloudKit stored it.
    /// - Returns: `true` when local state changed.
    func acceptSavedRecord(_ record: CKRecord) throws -> Bool

    /// Clears the durable deletion represented by a CloudKit record ID.
    ///
    /// Also called when CloudKit reports the record as already gone, since
    /// that satisfies the deletion just as well.
    ///
    /// - Parameter recordID: The record CloudKit deleted.
    /// - Returns: `true` when local state changed.
    func acceptDeletedRecordID(_ recordID: CKRecord.ID) throws -> Bool

    /// Preserves a server conflict and applies the app's merge policy.
    ///
    /// The engine retries the save afterwards, so leave local state in the
    /// form that should be uploaded next.
    ///
    /// - Parameters:
    ///   - localRecord: The record this device tried to save.
    ///   - serverRecord: The record CloudKit already holds.
    func resolveConflict(
        localRecord: CKRecord,
        serverRecord: CKRecord
    ) throws

    /// Marks a nonretryable save as failed without discarding local data.
    ///
    /// - Parameter record: The record CloudKit permanently rejected.
    func markRecordFailed(_ record: CKRecord) throws

    /// Records the failure category for a retryable durable operation.
    ///
    /// - Parameters:
    ///   - recordID: The stable local identity of the failed change.
    ///   - mutation: The operation that failed.
    ///   - category: The `CKError.Code` name describing the failure.
    func markChangeAttemptFailed(
        recordID: UUID,
        mutation: SwiftDataSyncMutation,
        category: String
    ) throws

    /// Replaces a revoked participant collection with a safe local one.
    ///
    /// Scoped to the collection whose zone was revoked; every other collection
    /// this device tracks is untouched.
    ///
    /// - Parameter collectionID: The collection whose share was revoked, when
    ///   known.
    func recoverFromRevokedShare(collectionID: UUID?) throws

    /// Requeues records after their owner zone is recreated.
    ///
    /// - Parameter collectionID: The collection to requeue, or `nil` to
    ///   requeue every collection this device owns, used when the scope of a
    ///   reset can't be narrowed to one zone.
    func requeueRecords(forCollection collectionID: UUID?) throws

    /// Saves pending adapter changes.
    func save() throws

    /// Rolls back unsaved adapter changes after a failed transaction.
    func rollback()

    /// Publishes any app-specific snapshots after remote changes are
    /// committed.
    ///
    /// Called after ``save()`` succeeds, so derived caches and published state
    /// can be refreshed from data that's already durable.
    func didApplyRemoteChanges()
}

extension SwiftDataSyncStore {

    /// Returns `nil`, for adapters with no legacy queued saves to rebuild.
    ///
    /// - Parameters:
    ///   - id: The stable local identity of the queued save.
    ///   - zoneID: The zone the record would belong to.
    /// - Returns: Always `nil`.
    public func makeFallbackRecord(
        for id: UUID,
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord? {
        nil
    }

    /// Does nothing, for adapters with no derived state to publish.
    public func didApplyRemoteChanges() {}
}
