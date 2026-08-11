//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Observation

/// Creates or retrieves the zone-wide share for any zone an app's sync engine
/// owns.
///
/// State is tracked per zone, so preparing one zone's share never clobbers
/// another's in-flight state. Each zone has at most one share.
///
/// - Important: Main-actor isolated, matching the engine it coordinates.
@MainActor
@Observable
public final class SwiftDataSyncSharingCoordinator {

    /// The engine whose owned zones this coordinator can share.
    private let syncManager: SwiftDataSyncEngine

    /// The prepared shares ready for `UICloudSharingController`, keyed by zone.
    public private(set) var activeShares: [CKRecordZone.ID: CKShare] = [:]

    /// Zones whose share is currently being fetched or created.
    public private(set) var preparingZones: Set<CKRecordZone.ID> = []

    /// Plain-language share-preparation failures, keyed by zone.
    public private(set) var shareErrors: [CKRecordZone.ID: String] = [:]

    /// Creates a coordinator for an existing sync engine.
    ///
    /// - Parameter syncManager: The engine whose owned zones can be shared.
    public init(syncManager: SwiftDataSyncEngine) {
        self.syncManager = syncManager
    }

    /// Returns the prepared share for a zone.
    ///
    /// - Parameter zoneID: The zone to look up.
    /// - Returns: The share, or `nil` when none has been prepared.
    public func activeShare(for zoneID: CKRecordZone.ID) -> CKShare? {
        activeShares[zoneID]
    }

    /// Returns whether a zone's share is currently being fetched or created.
    ///
    /// - Parameter zoneID: The zone to look up.
    /// - Returns: `true` while preparation is in flight.
    public func isPreparingShare(for zoneID: CKRecordZone.ID) -> Bool {
        preparingZones.contains(zoneID)
    }

    /// Returns the most recent share-preparation failure for a zone.
    ///
    /// - Parameter zoneID: The zone to look up.
    /// - Returns: A plain-language description, or `nil` when the last attempt
    ///   succeeded or none has been made.
    public func shareError(for zoneID: CKRecordZone.ID) -> String? {
        shareErrors[zoneID]
    }

    /// Fetches a zone's existing zone-wide share, or creates it on first use.
    ///
    /// On success the share is published in ``activeShares`` and available
    /// from ``activeShare(for:)``, ready to hand to the system sharing
    /// interface. Failures are reported through ``shareError(for:)`` rather
    /// than thrown, including an attempt to share a zone this device doesn't
    /// own.
    ///
    /// - Parameters:
    ///   - zoneID: The zone to share. Must be owned by this device, meaning
    ///     ``SwiftDataSyncEngine/role(for:)`` returns `.owner`.
    ///   - title: The title shown by the system sharing interface, typically
    ///     naming the specific thing being shared. Pass `nil` to use the
    ///     configuration's ``SwiftDataSyncConfiguration/shareTitle``.
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
