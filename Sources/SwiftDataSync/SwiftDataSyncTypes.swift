//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// The device's relationship to a tracked CloudKit zone.
///
/// A device can hold both roles at once, for different zones.
public enum SwiftDataSyncRole: String, Codable, Sendable {

    /// This user owns the custom zone in their private database.
    case owner

    /// This user accesses another person's zone through the shared database.
    case participant
}

/// The availability of the configured iCloud account.
public enum SwiftDataSyncAvailability: Equatable, Sendable {

    /// The initial account check hasn't completed.
    case checking

    /// CloudKit has confirmed successful account access.
    case available

    /// No iCloud account is available on this device.
    case signedOut

    /// System policy restricts this device's iCloud access.
    case restricted

    /// CloudKit couldn't determine availability and will retry.
    case temporarilyUnavailable

    /// Whether the app should explain that data is currently device-local.
    ///
    /// `true` only for states the person can act on. A temporary outage
    /// resolves itself, so it doesn't warrant a notice.
    public var requiresLocalDataNotice: Bool {
        switch self {
        case .signedOut, .restricted:
            true
        case .checking, .available, .temporarilyUnavailable:
            false
        }
    }

    /// An alias of ``requiresLocalDataNotice`` kept for journal-style apps
    /// that adopted the earlier name.
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
///
/// This is the only shape in which outbox rows cross the package boundary,
/// which keeps `ModelContext` and its models on the main actor.
public struct SwiftDataSyncPendingChange: Hashable, Sendable {

    /// The stable local identity used as the CloudKit record name.
    public let recordID: UUID

    /// The app-defined record-type identifier.
    public let recordType: String

    /// The collection this change belongs to, used to route it to a zone.
    public let collectionID: UUID?

    /// The operation CloudKit needs to perform.
    public let mutation: SwiftDataSyncMutation

    /// Creates a pending CloudKit change.
    ///
    /// - Parameters:
    ///   - recordID: The stable local identity.
    ///   - recordType: The app-defined record-type identifier.
    ///   - collectionID: The collection this change belongs to. A change with
    ///     no collection stays in the outbox until one can be resolved.
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
