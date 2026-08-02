//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Observation

/// Creates or retrieves the zone-wide share for any zone an app's sync
/// engine owns — one share per zone, tracked independently, so preparing
/// one zone's share never clobbers another's in-flight state.
@MainActor
@Observable
public final class SwiftDataSyncSharingCoordinator {

    private let syncManager: SwiftDataSyncEngine

    /// The prepared shares ready for `UICloudSharingController`, keyed by zone.
    public private(set) var activeShares: [CKRecordZone.ID: CKShare] = [:]

    /// Zones whose share is currently being fetched or created.
    public private(set) var preparingZones: Set<CKRecordZone.ID> = []

    /// Plain-language descriptions of a share preparation failure, keyed by zone.
    public private(set) var shareErrors: [CKRecordZone.ID: String] = [:]

    /// Creates a coordinator for an existing sync engine.
    ///
    /// - Parameter syncManager: The engine whose owned zones can be shared.
    public init(syncManager: SwiftDataSyncEngine) {
        self.syncManager = syncManager
    }

    /// The prepared share for a zone, if one has been fetched or created.
    public func activeShare(for zoneID: CKRecordZone.ID) -> CKShare? {
        activeShares[zoneID]
    }

    /// Whether a zone's share is currently being fetched or created.
    public func isPreparingShare(for zoneID: CKRecordZone.ID) -> Bool {
        preparingZones.contains(zoneID)
    }

    /// The most recent share preparation failure for a zone, if any.
    public func shareError(for zoneID: CKRecordZone.ID) -> String? {
        shareErrors[zoneID]
    }

    /// Fetches the existing zone-wide share for `zoneID` or creates it on
    /// first use.
    ///
    /// - Parameters:
    ///   - zoneID: The owned zone to share. Must belong to this device
    ///     (`syncManager.role(for: zoneID) == .owner`).
    ///   - title: The title shown by the system sharing interface, overriding
    ///     `configuration.shareTitle` — typically the specific thing being
    ///     shared (e.g. a baby's name) rather than the app-wide default.
    public func prepareShare(for zoneID: CKRecordZone.ID, title: String? = nil) async {
        guard syncManager.role(for: zoneID) == .owner else {
            shareErrors[zoneID] = "Only the shared data's owner can invite someone else."
            return
        }

        preparingZones.insert(zoneID)
        shareErrors[zoneID] = nil
        defer { preparingZones.remove(zoneID) }

        let configuration = syncManager.configuration
        let database = configuration.container.privateCloudDatabase
        let shareRecordID = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: zoneID
        )

        do {
            if let existing = try await database.record(for: shareRecordID) as? CKShare {
                syncManager.recordSuccessfulCloudKitActivity()
                activeShares[zoneID] = existing
                return
            }
        } catch let error as CKError where error.code == .unknownItem {
            syncManager.recordSuccessfulCloudKitActivity()
        } catch {
            shareErrors[zoneID] = error.localizedDescription
            return
        }

        do {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = title ?? configuration.shareTitle
            let savedRecord = try await database.save(share)
            syncManager.recordSuccessfulCloudKitActivity()
            activeShares[zoneID] = (savedRecord as? CKShare) ?? share
        } catch {
            shareErrors[zoneID] = error.localizedDescription
        }
    }
}
