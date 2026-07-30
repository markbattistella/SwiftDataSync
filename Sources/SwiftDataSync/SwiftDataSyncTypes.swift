//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// The device's relationship to the active CloudKit shared zone.
public enum SwiftDataSyncRole: String, Codable, Sendable {

    /// This user owns the custom zone in their private database.
    case owner

    /// This user accesses another person's zone through the shared database.
    case participant
}

/// The current availability of the configured iCloud account.
public enum SwiftDataSyncAvailability: Equatable, Sendable {

    /// The initial account check has not completed.
    case checking

    /// CloudKit has confirmed successful account access.
    case available

    /// No iCloud account is available on this device.
    case signedOut

    /// System policy restricts this device's iCloud access.
    case restricted

    /// CloudKit could not determine availability and will be retried.
    case temporarilyUnavailable

    /// Whether the app should explain that data is currently device-local.
    public var requiresLocalDataNotice: Bool {
        switch self {
        case .signedOut, .restricted:
            true
        case .checking, .available, .temporarilyUnavailable:
            false
        }
    }

    /// Backwards-compatible terminology for journal-style apps.
    public var requiresLocalJournalNotice: Bool {
        requiresLocalDataNotice
    }
}

/// A durable local operation awaiting CloudKit delivery.
public enum SwiftDataSyncMutation: String, Codable, Sendable {

    /// Create or update a record.
    case save

    /// Delete a record.
    case delete
}

/// A type-erased durable change supplied by an app's SwiftData store.
public struct SwiftDataSyncPendingChange: Hashable, Sendable {

    /// The stable local identity used as the CloudKit record name.
    public let recordID: UUID

    /// The app-defined record-type identifier.
    public let recordType: String

    /// The optional shared-collection identity used for local scoping.
    public let collectionID: UUID?

    /// The operation CloudKit needs to perform.
    public let mutation: SwiftDataSyncMutation

    /// Creates a pending CloudKit change.
    ///
    /// - Parameters:
    ///   - recordID: The stable local identity.
    ///   - recordType: The app-defined record-type identifier.
    ///   - collectionID: The optional shared-collection identity.
    ///   - mutation: The operation CloudKit needs to perform.
    public init(
        recordID: UUID,
        recordType: String,
        collectionID: UUID? = nil,
        mutation: SwiftDataSyncMutation
    ) {
        self.recordID = recordID
        self.recordType = recordType
        self.collectionID = collectionID
        self.mutation = mutation
    }
}
