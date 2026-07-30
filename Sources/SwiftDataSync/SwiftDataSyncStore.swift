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

  /// Returns durable changes belonging to the currently active shared collection.
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

  /// Archives or otherwise protects local data before adopting somebody else's share.
  func prepareToAdoptShare() throws

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

  /// Replaces a revoked participant collection with a safe new local collection.
  func recoverFromRevokedShare() throws

  /// Requeues the active local collection after its owner zone is recreated.
  func requeueAllRecords() throws

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
