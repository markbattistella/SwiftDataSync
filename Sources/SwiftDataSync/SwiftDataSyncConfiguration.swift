//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation

/// The CloudKit identifiers and user-facing terminology for one shared store.
public struct SwiftDataSyncConfiguration: Hashable, Sendable {

  /// The app's CloudKit container identifier.
  public let containerIdentifier: String

  /// The custom record-zone name containing the shareable records.
  public let zoneName: String

  /// The optional app-group suite used to persist engine state.
  public let appGroupIdentifier: String?

  /// A prefix that keeps this engine's state keys separate from other stores.
  public let stateKeyPrefix: String

  /// The title shown by the system sharing interface.
  public let shareTitle: String

  /// The app name used in plain-language sync messages.
  public let appName: String

  /// The singular name for the shared data, such as "journal" or "workspace".
  public let dataName: String

  /// Creates the configuration for one shared SwiftData-backed CloudKit zone.
  ///
  /// - Parameters:
  ///   - containerIdentifier: The app's CloudKit container identifier.
  ///   - zoneName: The custom record-zone name containing shareable records.
  ///   - appGroupIdentifier: An optional app-group suite for persisted engine state.
  ///   - stateKeyPrefix: A prefix for the engine's persisted state keys.
  ///   - shareTitle: The title shown by the system sharing interface.
  ///   - appName: The app name used in user-facing sync messages.
  ///   - dataName: The singular name for the shared collection.
  public init(
    containerIdentifier: String,
    zoneName: String,
    appGroupIdentifier: String? = nil,
    stateKeyPrefix: String = "SwiftDataSync",
    shareTitle: String,
    appName: String,
    dataName: String
  ) {
    self.containerIdentifier = containerIdentifier
    self.zoneName = zoneName
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

  /// The custom zone as it appears in its owner's private database.
  public var ownedZoneID: CKRecordZone.ID {
    CKRecordZone.ID(
      zoneName: zoneName,
      ownerName: CKCurrentUserDefaultName
    )
  }

  /// Creates the stable CloudKit identity for a locally identified record.
  ///
  /// - Parameters:
  ///   - id: The stable local UUID.
  ///   - zoneID: The owner or participant view of the shared zone.
  /// - Returns: A record ID whose name is derived from `id`.
  public func makeRecordID(
    for id: UUID,
    in zoneID: CKRecordZone.ID
  ) -> CKRecord.ID {
    CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
  }
}
