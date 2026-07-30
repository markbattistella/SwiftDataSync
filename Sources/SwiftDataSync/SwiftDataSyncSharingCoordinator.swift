//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Observation

/// Creates or retrieves the zone-wide share presented by an app's sharing UI.
@MainActor
@Observable
public final class SwiftDataSyncSharingCoordinator {

  private let syncManager: SwiftDataSyncEngine

  /// The prepared share ready for `UICloudSharingController`.
  public var activeShare: CKShare?

  /// Whether a share is currently being fetched or created.
  public var isPreparingShare = false

  /// A plain-language description of a share preparation failure.
  public var shareError: String?

  /// Creates a coordinator for an existing sync engine.
  ///
  /// - Parameter syncManager: The engine whose owned zone will be shared.
  public init(syncManager: SwiftDataSyncEngine) {
    self.syncManager = syncManager
  }

  /// Fetches the existing zone-wide share or creates it on first use.
  public func prepareShare() async {
    guard syncManager.role == .owner else {
      shareError = "Only the shared data's owner can invite someone else."
      return
    }

    isPreparingShare = true
    shareError = nil
    defer { isPreparingShare = false }

    let configuration = syncManager.configuration
    let database = configuration.container.privateCloudDatabase
    let zoneID = configuration.ownedZoneID
    let shareRecordID = CKRecord.ID(
      recordName: CKRecordNameZoneWideShare,
      zoneID: zoneID
    )

    do {
      if let existing = try await database.record(for: shareRecordID) as? CKShare {
        syncManager.recordSuccessfulCloudKitActivity()
        activeShare = existing
        return
      }
    } catch let error as CKError where error.code == .unknownItem {
      syncManager.recordSuccessfulCloudKitActivity()
    } catch {
      shareError = error.localizedDescription
      return
    }

    do {
      let share = CKShare(recordZoneID: zoneID)
      share[CKShare.SystemFieldKey.title] = configuration.shareTitle
      let savedRecord = try await database.save(share)
      syncManager.recordSuccessfulCloudKitActivity()
      activeShare = (savedRecord as? CKShare) ?? share
    } catch {
      shareError = error.localizedDescription
    }
  }
}
