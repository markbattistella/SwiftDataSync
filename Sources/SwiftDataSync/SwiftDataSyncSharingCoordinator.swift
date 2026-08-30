//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Observation
import SimpleLogger

private let logger = SimpleLogger(category: .sync)

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
    /// A zone that doesn't exist on the server yet is created before the share
    /// is saved. A collection can be shareable before its first sync has
    /// confirmed the zone — without this, the invitation would fail with a
    /// CloudKit error the person using the app can do nothing about, and
    /// retrying would never help.
    ///
    /// - Parameters:
    ///   - zoneID: The zone to share. Must be owned by this device, meaning
    ///     ``SwiftDataSyncEngine/role(for:)`` returns `.owner`.
    ///   - title: The title shown by the system sharing interface, typically
    ///     naming the specific thing being shared. Pass `nil` to use the
    ///     configuration's ``SwiftDataSyncConfiguration/shareTitle``.
    /// - Returns: `true` when a share is ready in ``activeShares``. On `false`
    ///   the reason is in ``shareError(for:)``.
    @discardableResult
    public func prepareShare(
        for zoneID: CKRecordZone.ID,
        title: String? = nil
    ) async -> Bool {
        guard syncManager.role(for: zoneID) == .owner else {
            shareErrors[zoneID] = "Only the shared data's owner can invite someone else."
            return false
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
                return true
            }
        } catch let error as CKError where error.code == .unknownItem {
            // The zone is there but has never been shared. Carry on and
            // create the share below.
            syncManager.recordSuccessfulCloudKitActivity()
        } catch let error as CKError where SwiftDataSyncEngine.isMissingZone(error.code) {
            // The zone itself has never reached the server, so there is
            // nothing to attach a share to yet. Create it first.
            guard await createZone(zoneID, in: database) else { return false }
        } catch {
            fail(zoneID, with: error, whileDoing: "read the existing share")
            return false
        }

        do {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = title ?? configuration.shareTitle
            let savedRecord = try await database.save(share)
            syncManager.recordSuccessfulCloudKitActivity()
            activeShares[zoneID] = (savedRecord as? CKShare) ?? share
            return true
        } catch let error as CKError where SwiftDataSyncEngine.isMissingZone(error.code) {
            // Lost a race with a zone deletion, or the zone vanished between
            // the read above and this save. Recreate it and try once more.
            guard await createZone(zoneID, in: database) else { return false }
            return await saveShare(for: zoneID, title: title, in: database)
        } catch {
            fail(zoneID, with: error, whileDoing: "create the share")
            return false
        }
    }

    /// Creates a zone on the server so a share has something to attach to.
    ///
    /// - Parameters:
    ///   - zoneID: The zone to create.
    ///   - database: The owner's private database.
    /// - Returns: `true` when the zone exists afterwards.
    private func createZone(
        _ zoneID: CKRecordZone.ID,
        in database: CKDatabase
    ) async -> Bool {
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            syncManager.recordSuccessfulCloudKitActivity()
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device created it first, which is the outcome we wanted.
            return true
        } catch {
            fail(zoneID, with: error, whileDoing: "create the zone to share")
            return false
        }
    }

    /// Saves a new zone-wide share, without the zone-recovery retry.
    ///
    /// - Parameters:
    ///   - zoneID: The zone to share.
    ///   - title: The share title, or `nil` for the configured default.
    ///   - database: The owner's private database.
    /// - Returns: `true` when the share is published in ``activeShares``.
    private func saveShare(
        for zoneID: CKRecordZone.ID,
        title: String?,
        in database: CKDatabase
    ) async -> Bool {
        do {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] =
                title ?? syncManager.configuration.shareTitle
            let savedRecord = try await database.save(share)
            syncManager.recordSuccessfulCloudKitActivity()
            activeShares[zoneID] = (savedRecord as? CKShare) ?? share
            return true
        } catch {
            fail(zoneID, with: error, whileDoing: "create the share")
            return false
        }
    }

    /// Records a plain-language failure for a zone and logs the underlying
    /// CloudKit error for diagnosis.
    ///
    /// - Parameters:
    ///   - zoneID: The zone the attempt was for.
    ///   - error: The underlying error.
    ///   - action: What was being attempted, for the log only.
    private func fail(
        _ zoneID: CKRecordZone.ID,
        with error: any Error,
        whileDoing action: String
    ) {
        logger.error("Failed to \(action) for zone \(zoneID.zoneName): \(error)")
        shareErrors[zoneID] = Self.message(
            for: error,
            appName: syncManager.configuration.appName
        )
    }

    /// Translates a sharing failure into something worth showing a person.
    ///
    /// CloudKit's own `localizedDescription` is written for developers — it
    /// leaks schema and record-type detail that means nothing to someone
    /// trying to invite their partner, and offers no way forward.
    ///
    /// - Parameters:
    ///   - error: The underlying error.
    ///   - appName: The app name to use in the message.
    /// - Returns: A sentence describing what happened and what to do next.
    public nonisolated static func message(
        for error: any Error,
        appName: String
    ) -> String {
        guard let error = error as? CKError else {
            return "\(appName) couldn't create the invitation. Try again in a moment."
        }

        return switch error.code {
            case .networkUnavailable, .networkFailure:
                "You appear to be offline. Reconnect and try inviting again."
            case .notAuthenticated:
                "Sign in to iCloud in Settings to invite someone."
            case .accountTemporarilyUnavailable:
                "Your iCloud account is temporarily unavailable. Try again shortly."
            case .managedAccountRestricted:
                "This iCloud account doesn't allow sharing."
            case .permissionFailure:
                "\(appName) doesn't have permission to share from this iCloud account."
            case .quotaExceeded:
                "Your iCloud storage is full, so the invitation couldn't be created."
            case .zoneBusy, .serviceUnavailable, .requestRateLimited:
                "iCloud is busy right now. Try inviting again in a moment."
            case .tooManyParticipants:
                "This share already has as many people as iCloud allows."
            case .alreadyShared:
                "That's already being shared. Close this and reopen it to see the current invitation."
            default:
                "\(appName) couldn't create the invitation. Try again in a moment."
        }
    }
}
