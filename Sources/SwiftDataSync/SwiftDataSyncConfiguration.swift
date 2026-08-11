//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation

/// The CloudKit identifiers and user-facing terminology shared by every zone
/// an app tracks.
///
/// The configuration carries no zone name of its own. An app can track any
/// number of zones side by side, each named however its model requires; see
/// ``SwiftDataSyncEngine/ensureZoneExists(_:collectionID:)``.
public struct SwiftDataSyncConfiguration: Hashable, Sendable {

    /// The app's CloudKit container identifier.
    public let containerIdentifier: String

    /// The app-group suite used to persist engine state, if any.
    public let appGroupIdentifier: String?

    /// A prefix that keeps this engine's state keys separate from other stores.
    public let stateKeyPrefix: String

    /// The default title shown by the system sharing interface.
    ///
    /// Used when no zone-specific title is passed to
    /// ``SwiftDataSyncSharingCoordinator/prepareShare(for:title:)``.
    public let shareTitle: String

    /// The app name used in plain-language sync messages.
    public let appName: String

    /// The singular name for the shared data, such as "journal" or "workspace".
    public let dataName: String

    /// Creates the shared configuration for an app's zones.
    ///
    /// - Parameters:
    ///   - containerIdentifier: The app's CloudKit container identifier.
    ///   - appGroupIdentifier: An app-group suite for persisted engine state,
    ///     or `nil` to use the standard defaults. Supply one when an extension
    ///     needs the same state.
    ///   - stateKeyPrefix: A prefix for the engine's persisted state keys.
    ///   - shareTitle: The default title shown by the system sharing interface.
    ///   - appName: The app name used in user-facing sync messages.
    ///   - dataName: The singular name for the shared collection.
    public init(
        containerIdentifier: String,
        appGroupIdentifier: String? = nil,
        stateKeyPrefix: String = "SwiftDataSync",
        shareTitle: String,
        appName: String,
        dataName: String
    ) {
        self.containerIdentifier = containerIdentifier
        self.appGroupIdentifier = appGroupIdentifier
        self.stateKeyPrefix = stateKeyPrefix
        self.shareTitle = shareTitle
        self.appName = appName
        self.dataName = dataName
    }

    /// The configured CloudKit container.
    public var container: CKContainer {
        CKContainer(identifier: containerIdentifier)
    }

    /// Returns the zone identity for a zone this device owns.
    ///
    /// The owner is always the current user, since the zone lives in this
    /// device's own private database.
    ///
    /// - Parameter zoneName: The custom record-zone name.
    /// - Returns: A zone identity owned by the current user.
    public func ownedZoneID(named zoneName: String) -> CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    /// Creates the stable CloudKit identity for a locally identified record.
    ///
    /// - Parameters:
    ///   - id: The record's stable local identity.
    ///   - zoneID: The zone the record belongs to.
    /// - Returns: A record ID whose name is derived from `id`.
    public func makeRecordID(
        for id: UUID,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }
}
