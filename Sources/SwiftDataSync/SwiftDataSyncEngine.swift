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

/// Mirrors a set of custom CloudKit zones while an app's SwiftData adapter
/// remains the durable local source of truth.
///
/// The engine owns CloudKit transport, zone tracking, state persistence,
/// retries, zone recovery, and private/shared database routing — for
/// however many zones the app is tracking at once, not just one. A device
/// can simultaneously own some zones (created by this device, tracked in
/// the private database) and participate in others (shared here by someone
/// else, tracked in the shared database); both engines run concurrently
/// rather than switching between a single "active" one.
///
/// Each zone is optionally associated with an app-defined `collectionID` —
/// an opaque identifier (e.g. one per shareable unit in the app's own
/// model) used only to route durable changes and fetched records to the
/// right zone. The engine never interprets what a collection *means*.
@MainActor
@Observable
public final class SwiftDataSyncEngine {

    /// The device's relationship to a tracked zone.
    public typealias Role = SwiftDataSyncRole

    /// The current availability of the configured iCloud account.
    public typealias Availability = SwiftDataSyncAvailability

    /// The CloudKit and presentation configuration for this engine.
    public let configuration: SwiftDataSyncConfiguration

    /// Zones this device owns, tracked in its private database.
    public private(set) var ownedZones: Set<CKRecordZone.ID> = []

    /// Zones shared to this device by someone else, tracked in the shared database.
    public private(set) var sharedZones: Set<CKRecordZone.ID> = []

    /// A plain-language explanation of the most recent sync failure.
    public private(set) var lastSyncError: String?

    /// The most recent time a complete fetch or send finished successfully.
    public private(set) var lastSyncedAt: Date?

    /// The current availability of the configured iCloud account.
    public private(set) var availability: Availability = .checking

    @ObservationIgnored
    private let container: CKContainer

    @ObservationIgnored
    private let store: any SwiftDataSyncStore

    @ObservationIgnored
    private let stateStore: any SwiftDataSyncStateStore

    @ObservationIgnored
    private lazy var privateEngine = CKSyncEngine(
        makeEngineConfiguration(
            database: container.privateCloudDatabase,
            stateKey: privateStateKey
        )
    )

    @ObservationIgnored
    private lazy var sharedEngine = CKSyncEngine(
        makeEngineConfiguration(
            database: container.sharedCloudDatabase,
            stateKey: sharedStateKey
        )
    )

    @ObservationIgnored
    private var accountChangeTask: Task<Void, Never>?

    /// Both directions of the zone ↔ collection association, kept in sync —
    /// a handful of zones per device at most, so a plain dictionary plus a
    /// linear reverse lookup is simpler than a bidirectional map type.
    private var zoneByCollection: [UUID: CKRecordZone.ID] = [:]

    /// Zones whose `.saveZone` has been sent this session — reset on relaunch,
    /// same as the original single-zone engine's `hasPreparedOwnedZone`, so a
    /// zone that never confirmed before termination is resent harmlessly.
    private var preparedZones: Set<CKRecordZone.ID> = []

    private var activeFetchHadError = false
    private var activeSendHadError = false
    private var accountStatusRequestID: UInt = 0

    /// Creates an engine connected to an app's SwiftData-backed store.
    ///
    /// - Parameters:
    ///   - configuration: CloudKit identifiers and user-facing terminology.
    ///   - store: The adapter for app-specific SwiftData models and outbox rows.
    ///   - startsAutomatically: Whether to check the account and reconcile at launch.
    ///   - stateStore: An optional custom store for opaque engine state.
    public init(
        configuration: SwiftDataSyncConfiguration,
        store: any SwiftDataSyncStore,
        startsAutomatically: Bool = true,
        stateStore: (any SwiftDataSyncStateStore)? = nil
    ) {
        self.configuration = configuration
        self.container = configuration.container
        self.store = store

        let resolvedStateStore =
            stateStore
            ?? UserDefaultsSwiftDataSyncStateStore(
                configuration: configuration
            )
        self.stateStore = resolvedStateStore

        for zone in Self.loadPersistedZones(
            from: resolvedStateStore,
            key: "\(configuration.stateKeyPrefix).zones"
        ) {
            let zoneID = CKRecordZone.ID(
                zoneName: zone.zoneName,
                ownerName: zone.ownerName
            )
            switch zone.role {
                case .owner: ownedZones.insert(zoneID)
                case .participant: sharedZones.insert(zoneID)
            }
            if let collectionID = zone.collectionID {
                zoneByCollection[collectionID] = zoneID
            }
        }

        guard startsAutomatically else { return }

        accountChangeTask = Task.detached { [weak self, container] in
            for await _ in NotificationCenter.default.notifications(
                named: .CKAccountChanged,
                object: container
            ) {
                guard let self, !Task.isCancelled else { return }
                await self.refreshAccountStatus()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await refreshAccountStatus()
            guard availability == .available else { return }
            for zoneID in ownedZones {
                ensureZoneExists(zoneID)
            }
            reconcileOutbox()
        }
    }

    deinit {
        accountChangeTask?.cancel()
    }

    /// The collection identifier associated with a tracked zone, if any.
    public func collectionID(for zoneID: CKRecordZone.ID) -> UUID? {
        zoneByCollection.first { $0.value == zoneID }?.key
    }

    /// The zone associated with a collection identifier, if this device
    /// owns or participates in one for it.
    public func zoneID(forCollection collectionID: UUID) -> CKRecordZone.ID? {
        zoneByCollection[collectionID]
    }

    /// This device's relationship to a tracked zone. `nil` if the zone
    /// isn't tracked at all.
    public func role(for zoneID: CKRecordZone.ID) -> Role? {
        if ownedZones.contains(zoneID) { return .owner }
        if sharedZones.contains(zoneID) { return .participant }
        return nil
    }

    /// Refreshes the configured CloudKit account's availability.
    public func refreshAccountStatus() async {
        accountStatusRequestID &+= 1
        let requestID = accountStatusRequestID

        do {
            let accountStatus = try await container.accountStatus()
            guard requestID == accountStatusRequestID else { return }

            switch accountStatus {
                case .available:
                    recordSuccessfulCloudKitActivity()

                case .noAccount:
                    availability = .signedOut
                    lastSyncError =
                        "\(configuration.appName) is saving on this device. Sign in to iCloud to sync or share this \(configuration.dataName)."

                case .restricted:
                    availability = .restricted
                    lastSyncError =
                        "This device restricts iCloud access. \(configuration.appName) will keep saving your \(configuration.dataName) locally."

                case .couldNotDetermine, .temporarilyUnavailable:
                    availability = .temporarilyUnavailable
                    lastSyncError =
                        "iCloud is temporarily unavailable. Your changes are saved on this device and will retry."

                @unknown default:
                    availability = .temporarilyUnavailable
            }
        } catch {
            guard requestID == accountStatusRequestID else { return }
            if availability != .available {
                availability = .temporarilyUnavailable
            }
            lastSyncError =
                "iCloud is temporarily unavailable. Your changes are saved on this device and will retry."
            logger.error("Account status check failed: \(error)")
        }
    }

    /// Records stronger evidence of availability than a potentially stale account check.
    public func recordSuccessfulCloudKitActivity() {
        accountStatusRequestID &+= 1
        availability = .available
        lastSyncError = nil
    }

    #if DEBUG

    /// Supplies deterministic state for previews without contacting CloudKit.
    ///
    /// - Parameters:
    ///   - ownedZoneID: A zone to preview as owned by this device, if any.
    ///   - ownedCollectionID: The collection `ownedZoneID` routes for, if any.
    ///   - sharedZoneID: A zone to preview as shared to this device, if any.
    ///   - sharedCollectionID: The collection `sharedZoneID` routes for, if any.
    public func configureForPreview(
        ownedZoneID: CKRecordZone.ID? = nil,
        ownedCollectionID: UUID? = nil,
        sharedZoneID: CKRecordZone.ID? = nil,
        sharedCollectionID: UUID? = nil,
        availability: Availability = .available,
        lastSyncedAt: Date? = .now
    ) {
        self.availability = availability
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = nil
        self.ownedZones = ownedZoneID.map { [$0] } ?? []
        self.sharedZones = sharedZoneID.map { [$0] } ?? []
        self.zoneByCollection = [:]
        if let ownedZoneID, let ownedCollectionID {
            zoneByCollection[ownedCollectionID] = ownedZoneID
        }
        if let sharedZoneID, let sharedCollectionID {
            zoneByCollection[sharedCollectionID] = sharedZoneID
        }
    }

    #endif

    /// Clears every persisted zone-tracking and CloudKit sync-token record
    /// for this engine — for recovering when that bookkeeping itself became
    /// wrong or stale (e.g. after an interrupted schema migration left zones
    /// registered under the wrong identity). Local SwiftData data is
    /// completely untouched.
    ///
    /// Takes effect from the next app launch: the `SwiftDataSyncEngine`
    /// constructed then starts with no known zones and no CloudKit change
    /// tokens, so the app's own bootstrap step re-derives zone identity
    /// fresh from its current local models, and the following fetch pulls
    /// each rediscovered zone's complete current state from CloudKit rather
    /// than "since last checkpoint" — safe to call on a live engine, but it
    /// has no effect on this session's already-running `CKSyncEngine`s.
    public func resetPersistedState() {
        stateStore.removeValue(forKey: zonesKey)
        stateStore.removeValue(forKey: privateStateKey)
        stateStore.removeValue(forKey: sharedStateKey)
        ownedZones = []
        sharedZones = []
        zoneByCollection = [:]
        preparedZones = []
    }

    /// Fetches remote changes across every tracked zone after first
    /// reconciling durable local changes.
    public func fetchChangesNow() {
        Task { [weak self] in
            guard let self else { return }
            await refreshAccountStatus()
            guard availability == .available else { return }
            for zoneID in ownedZones {
                ensureZoneExists(zoneID)
            }
            reconcileOutbox()

            do {
                if !ownedZones.isEmpty {
                    try await privateEngine.fetchChanges()
                }
                if !sharedZones.isEmpty {
                    try await sharedEngine.fetchChanges()
                }
                recordSuccessfulCloudKitActivity()
            } catch {
                recordTransientSyncFailure(error)
            }
        }
    }

    /// Rehydrates the engine's pending changes from the adapter's durable
    /// outbox, routing each one to the zone its `collectionID` maps to.
    /// Changes whose collection isn't tracked by any zone yet are left in
    /// the outbox untouched rather than guessed into the wrong zone.
    public func reconcileOutbox() {
        do {
            let changes = try store.pendingChanges()
            guard !changes.isEmpty, availability == .available else { return }

            var changesByEngine: [ObjectIdentifier: [CKSyncEngine.PendingRecordZoneChange]] =
                [:]

            for change in changes {
                guard let collectionID = change.collectionID,
                    let zoneID = zoneByCollection[collectionID]
                else {
                    logger.error(
                        "Skipping outbox change for unresolvable collection: \(change.recordID)"
                    )
                    continue
                }

                try store.markAttempted(change, errorCategory: nil)
                let recordID = configuration.makeRecordID(for: change.recordID, in: zoneID)
                let pendingChange: CKSyncEngine.PendingRecordZoneChange =
                    switch change.mutation {
                        case .save: .saveRecord(recordID)
                        case .delete: .deleteRecord(recordID)
                    }

                let engine = engine(for: zoneID)
                changesByEngine[ObjectIdentifier(engine), default: []].append(pendingChange)
            }

            try store.save()

            if let privateChanges = changesByEngine[ObjectIdentifier(privateEngine)] {
                privateEngine.state.add(pendingRecordZoneChanges: privateChanges)
                sendChanges(using: privateEngine)
            }
            if let sharedChanges = changesByEngine[ObjectIdentifier(sharedEngine)] {
                sharedEngine.state.add(pendingRecordZoneChanges: sharedChanges)
                sendChanges(using: sharedEngine)
            }
        } catch {
            lastSyncError =
                "\(configuration.appName) couldn't prepare changes for iCloud. Your \(configuration.dataName) remains saved on this device."
            logger.error("Failed to reconcile sync outbox: \(error)")
        }
    }

    /// Registers a zone this device owns — creating it in CloudKit if it
    /// doesn't already exist there. Safe to call repeatedly (e.g. once per
    /// owned zone at every launch, to re-verify a zone that never confirmed
    /// creation before the app last terminated) — a zone already tracked
    /// and already confirmed this session is a no-op.
    ///
    /// - Parameters:
    ///   - zoneID: The zone to create/verify in the owner's private database.
    ///   - collectionID: The app-defined identifier this zone belongs to, if any.
    public func ensureZoneExists(_ zoneID: CKRecordZone.ID, collectionID: UUID? = nil) {
        let isNewZone = ownedZones.insert(zoneID).inserted
        if let collectionID {
            zoneByCollection[collectionID] = zoneID
        }
        if isNewZone || collectionID != nil {
            persistZones()
        }

        guard availability == .available, !preparedZones.contains(zoneID) else { return }
        privateEngine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
        )
        preparedZones.insert(zoneID)
        sendChanges(using: privateEngine)
    }

    /// Adopts a zone someone else shared to this device, alongside whatever
    /// other zones this device already owns or participates in — accepting
    /// one shared collection never disturbs any other.
    ///
    /// - Parameters:
    ///   - zoneID: The accepted zone in the participant's shared database.
    ///   - collectionID: The app-defined identifier this zone belongs to, if any.
    public func adoptSharedZone(_ zoneID: CKRecordZone.ID, collectionID: UUID? = nil) {
        do {
            try store.prepareToAdoptShare(collectionID: collectionID)
            try store.save()
        } catch {
            store.rollback()
            lastSyncError =
                "The invitation was accepted, but \(configuration.appName) couldn't protect existing local data. No local data was deleted."
            logger.error("Failed to prepare local data before share switch: \(error)")
            return
        }

        sharedZones.insert(zoneID)
        if let collectionID {
            zoneByCollection[collectionID] = zoneID
        }
        persistZones()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await sharedEngine.fetchChanges()
                recordSuccessfulCloudKitActivity()
                reconcileOutbox()
            } catch {
                recordTransientSyncFailure(error)
            }
        }
    }

    private var privateStateKey: String {
        "\(configuration.stateKeyPrefix).state.private"
    }

    private var sharedStateKey: String {
        "\(configuration.stateKeyPrefix).state.shared"
    }

    private var zonesKey: String {
        "\(configuration.stateKeyPrefix).zones"
    }

    private func engine(for zoneID: CKRecordZone.ID) -> CKSyncEngine {
        ownedZones.contains(zoneID) ? privateEngine : sharedEngine
    }

    private struct PersistedZone: Codable {
        let zoneName: String
        let ownerName: String
        let collectionID: UUID?
        let role: SwiftDataSyncRole
    }

    private static func loadPersistedZones(
        from stateStore: any SwiftDataSyncStateStore,
        key: String
    ) -> [PersistedZone] {
        guard let data = stateStore.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([PersistedZone].self, from: data)
        } catch {
            logger.error("Failed to restore tracked zones: \(error)")
            return []
        }
    }

    private func persistZones() {
        let owned = ownedZones.map { zoneID in
            PersistedZone(
                zoneName: zoneID.zoneName,
                ownerName: zoneID.ownerName,
                collectionID: collectionID(for: zoneID),
                role: .owner
            )
        }
        let shared = sharedZones.map { zoneID in
            PersistedZone(
                zoneName: zoneID.zoneName,
                ownerName: zoneID.ownerName,
                collectionID: collectionID(for: zoneID),
                role: .participant
            )
        }
        do {
            stateStore.set(try JSONEncoder().encode(owned + shared), forKey: zonesKey)
        } catch {
            logger.error("Failed to persist tracked zones: \(error)")
        }
    }

    private func makeEngineConfiguration(
        database: CKDatabase,
        stateKey: String
    ) -> CKSyncEngine.Configuration {
        var engineConfiguration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadState(forKey: stateKey),
            delegate: self
        )
        engineConfiguration.automaticallySync = true
        return engineConfiguration
    }

    private func loadState(
        forKey key: String
    ) -> CKSyncEngine.State.Serialization? {
        guard let data = stateStore.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: data
            )
        } catch {
            logger.error("Failed to restore CKSyncEngine state: \(error)")
            return nil
        }
    }

    private func saveState(
        _ serialization: CKSyncEngine.State.Serialization,
        forKey key: String
    ) {
        do {
            stateStore.set(
                try JSONEncoder().encode(serialization),
                forKey: key
            )
        } catch {
            logger.error("Failed to persist CKSyncEngine state: \(error)")
        }
    }

    private func sendChanges(using engine: CKSyncEngine) {
        Task { [weak self] in
            do {
                try await engine.sendChanges()
            } catch {
                self?.recordTransientSyncFailure(error)
            }
        }
    }
}

extension SwiftDataSyncEngine: CKSyncEngineDelegate {

    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
            case .stateUpdate(let event):
                let key =
                    syncEngine === privateEngine
                    ? privateStateKey
                    : sharedStateKey
                saveState(event.stateSerialization, forKey: key)

            case .fetchedRecordZoneChanges(let event):
                applyFetchedChanges(event, syncEngine: syncEngine)

            case .fetchedDatabaseChanges(let event):
                handleFetchedDatabaseChanges(event, syncEngine: syncEngine)

            case .sentDatabaseChanges(let event):
                handleSentDatabaseChanges(event, syncEngine: syncEngine)

            case .sentRecordZoneChanges(let event):
                handleSentRecordZoneChanges(event, syncEngine: syncEngine)

            case .accountChange(let event):
                handleAccountChange(event)

            case .willFetchChanges:
                activeFetchHadError = false

            case .didFetchRecordZoneChanges(let event):
                if let error = event.error {
                    activeFetchHadError = true
                    lastSyncError =
                        "iCloud couldn't finish checking the \(configuration.dataName). Local changes are safe and will retry."
                    logger.error("CloudKit fetch failed for \(event.zoneID): \(error)")
                }

            case .didFetchChanges:
                if !activeFetchHadError {
                    lastSyncedAt = .now
                    recordSuccessfulCloudKitActivity()
                }

            case .willSendChanges:
                activeSendHadError = false

            case .didSendChanges:
                if !activeSendHadError {
                    lastSyncedAt = .now
                    recordSuccessfulCloudKitActivity()
                }

            case .willFetchRecordZoneChanges:
                break

            @unknown default:
                logger.info(
                    "Unhandled CKSyncEngine event: \(String(describing: event))"
                )
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingEngineChanges =
            syncEngine.state.pendingRecordZoneChanges.filter {
                context.options.scope.contains($0)
            }
        guard !pendingEngineChanges.isEmpty else { return nil }

        var records = [CKRecord.ID: CKRecord]()
        let pendingStoreChanges: [SwiftDataSyncPendingChange]

        do {
            pendingStoreChanges = try store.pendingChanges()
        } catch {
            lastSyncError =
                "\(configuration.appName) couldn't read a queued iCloud change. Local data is unchanged."
            logger.error("Failed to read pending store changes: \(error)")
            return nil
        }

        for engineChange in pendingEngineChanges {
            guard case .saveRecord(let recordID) = engineChange,
                let id = UUID(uuidString: recordID.recordName)
            else { continue }

            do {
                if let pendingChange = pendingStoreChanges.first(where: {
                    $0.recordID == id && $0.mutation == .save
                }),
                    let record = try store.makeRecord(
                        for: pendingChange,
                        in: recordID.zoneID
                    )
                {
                    records[recordID] = record
                } else if let legacyRecord = try store.makeFallbackRecord(
                    for: id,
                    in: recordID.zoneID
                ) {
                    records[recordID] = legacyRecord
                } else {
                    syncEngine.state.remove(
                        pendingRecordZoneChanges: [.saveRecord(recordID)]
                    )
                }
            } catch {
                lastSyncError =
                    "\(configuration.appName) couldn't materialise a queued iCloud change. Local data is unchanged."
                logger.error("Failed to materialise queued record: \(error)")
            }
        }

        let materialisedRecords = records
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingEngineChanges
        ) { materialisedRecords[$0] }
    }

    /// Groups a fetch event's modifications/deletions by zone and applies
    /// each zone's batch separately, since different zones in the same
    /// fetch can belong to different collections with different roles.
    private func applyFetchedChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        let trackedZones = syncEngine === privateEngine ? ownedZones : sharedZones
        let resolvedRole: Role = syncEngine === privateEngine ? .owner : .participant

        let modificationsByZone = Dictionary(
            grouping: event.modifications,
            by: { $0.record.recordID.zoneID }
        )
        let deletionsByZone = Dictionary(
            grouping: event.deletions,
            by: { $0.recordID.zoneID }
        )
        let zoneIDs = Set(modificationsByZone.keys).union(deletionsByZone.keys)

        for zoneID in zoneIDs where trackedZones.contains(zoneID) {
            let records = (modificationsByZone[zoneID] ?? []).map(\.record)
            let deletedRecordIDs = (deletionsByZone[zoneID] ?? []).map(\.recordID)

            do {
                let didChange = try store.applyFetchedChanges(
                    records: records,
                    deletedRecordIDs: deletedRecordIDs,
                    role: resolvedRole
                )
                guard didChange else { continue }
                try store.save()
                store.didApplyRemoteChanges()
            } catch {
                store.rollback()
                lastSyncError =
                    "\(configuration.appName) received iCloud changes but couldn't save them locally. It will retry."
                logger.error("Failed to apply fetched CloudKit changes: \(error)")
            }
        }
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        for deletion in event.deletions {
            let zoneID = deletion.zoneID

            if syncEngine === sharedEngine, sharedZones.contains(zoneID) {
                recoverFromRevokedShare(zoneID)
            } else if syncEngine === privateEngine, ownedZones.contains(zoneID) {
                preparedZones.remove(zoneID)
                lastSyncError =
                    "An iCloud \(configuration.dataName) zone was reset. Your local data is safe and will be uploaded again."
                ensureZoneExists(zoneID)
                requeueRecords(forCollection: collectionID(for: zoneID))
            }
        }
    }

    private func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        guard syncEngine === privateEngine else { return }

        for savedZone in event.savedZones where ownedZones.contains(savedZone.zoneID) {
            preparedZones.insert(savedZone.zoneID)
        }

        for failure in event.failedZoneSaves
        where ownedZones.contains(failure.zone.zoneID) {
            activeSendHadError = true
            preparedZones.remove(failure.zone.zoneID)

            if SwiftDataSyncRetryPolicy.shouldRetry(failure.error.code) {
                syncEngine.state.add(
                    pendingDatabaseChanges: [.saveZone(failure.zone)]
                )
                lastSyncError =
                    "iCloud couldn't prepare the \(configuration.dataName) yet. Your changes remain saved on this device and will retry."
            } else {
                lastSyncError =
                    "iCloud couldn't create the \(configuration.dataName)'s sync area. Local data remains available."
            }
            logger.error(
                "CloudKit rejected zone save \(failure.zone.zoneID): \(failure.error)"
            )
        }

        for (zoneID, error) in event.failedZoneDeletes where ownedZones.contains(zoneID) {
            activeSendHadError = true
            lastSyncError =
                "iCloud couldn't finish a shared-zone change. Your local data was not deleted."
            logger.error("CloudKit rejected zone delete \(zoneID): \(error)")
        }
    }

    private func recoverFromRevokedShare(_ zoneID: CKRecordZone.ID) {
        let revokedCollectionID = collectionID(for: zoneID)
        sharedZones.remove(zoneID)
        if let revokedCollectionID {
            zoneByCollection.removeValue(forKey: revokedCollectionID)
        }
        persistZones()

        do {
            try store.recoverFromRevokedShare(collectionID: revokedCollectionID)
            try store.save()
            lastSyncError =
                "Access to a shared \(configuration.dataName) ended. It was retained locally where possible."
        } catch {
            store.rollback()
            lastSyncError =
                "Access to a shared \(configuration.dataName) ended, but \(configuration.appName) couldn't finish cleaning up locally."
            logger.error("Failed to recover from revoked shared zone: \(error)")
        }
    }

    private func requeueRecords(forCollection collectionID: UUID?) {
        do {
            try store.requeueRecords(forCollection: collectionID)
            try store.save()
            reconcileOutbox()
        } catch {
            store.rollback()
            lastSyncError =
                "Your \(configuration.dataName) is safe locally, but \(configuration.appName) couldn't prepare it to re-upload."
            logger.error("Failed to requeue local records: \(error)")
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        var didChange = false

        for savedRecord in event.savedRecords {
            do {
                didChange =
                    try store.acceptSavedRecord(savedRecord)
                    || didChange
            } catch {
                logger.error("Failed to accept saved record: \(error)")
            }
        }

        for deletedRecordID in event.deletedRecordIDs {
            do {
                didChange =
                    try store.acceptDeletedRecordID(deletedRecordID)
                    || didChange
            } catch {
                logger.error("Failed to accept deleted record: \(error)")
            }
        }

        var retries = [CKSyncEngine.PendingRecordZoneChange]()

        for failure in event.failedRecordSaves {
            activeSendHadError = true
            let record = failure.record

            if failure.error.code == .serverRecordChanged,
                let serverRecord = failure.error.serverRecord
            {
                do {
                    try store.resolveConflict(
                        localRecord: record,
                        serverRecord: serverRecord
                    )
                    try store.save()
                } catch {
                    store.rollback()
                    logger.error("Failed to preserve CloudKit conflict: \(error)")
                }
                retries.append(.saveRecord(record.recordID))
            } else if SwiftDataSyncRetryPolicy.shouldRetry(failure.error.code) {
                retries.append(.saveRecord(record.recordID))
                recordAttemptFailure(
                    recordID: record.recordID,
                    mutation: .save,
                    category: String(describing: failure.error.code)
                )
            } else {
                do {
                    try store.markRecordFailed(record)
                    didChange = true
                } catch {
                    logger.error("Failed to mark rejected record: \(error)")
                }
                lastSyncError =
                    "A saved change couldn't sync to iCloud. It remains on this device and was not discarded."
                logger.error(
                    "CloudKit rejected save \(record.recordID): \(failure.error)"
                )
            }
        }

        for (recordID, error) in event.failedRecordDeletes {
            activeSendHadError = true

            if error.code == .unknownItem {
                do {
                    didChange =
                        try store.acceptDeletedRecordID(recordID)
                        || didChange
                } catch {
                    logger.error("Failed to clear fulfilled deletion: \(error)")
                }
            } else if SwiftDataSyncRetryPolicy.shouldRetry(error.code) {
                retries.append(.deleteRecord(recordID))
                recordAttemptFailure(
                    recordID: recordID,
                    mutation: .delete,
                    category: String(describing: error.code)
                )
            } else {
                lastSyncError =
                    "A deletion couldn't sync to iCloud. The local recovery copy remains available."
                logger.error("CloudKit rejected delete \(recordID): \(error)")
            }
        }

        if !retries.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retries)
        }

        guard didChange else { return }

        do {
            try store.save()
            lastSyncedAt = .now
            if !activeSendHadError {
                lastSyncError = nil
            }
        } catch {
            store.rollback()
            lastSyncError =
                "iCloud accepted changes, but \(configuration.appName) couldn't update their local sync status."
            logger.error("Failed to save sent-record state: \(error)")
        }
    }

    private func recordAttemptFailure(
        recordID: CKRecord.ID,
        mutation: SwiftDataSyncMutation,
        category: String
    ) {
        guard let id = UUID(uuidString: recordID.recordName) else { return }
        do {
            try store.markChangeAttemptFailed(
                recordID: id,
                mutation: mutation,
                category: category
            )
            try store.save()
        } catch {
            logger.error("Failed to update durable attempt state: \(error)")
        }
    }

    private func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange
    ) {
        switch event.changeType {
            case .signIn:
                recordSuccessfulCloudKitActivity()
                for zoneID in ownedZones {
                    ensureZoneExists(zoneID)
                }
                reconcileOutbox()

            case .switchAccounts:
                recordSuccessfulCloudKitActivity()
                preparedZones.removeAll()
                lastSyncError =
                    "The iCloud account changed. Local data is safe; \(configuration.appName) is preparing it for the new account."
                for zoneID in ownedZones {
                    ensureZoneExists(zoneID)
                }
                requeueRecords(forCollection: nil)

            case .signOut:
                availability = .signedOut
                preparedZones.removeAll()
                lastSyncError =
                    "Signed out of iCloud. \(configuration.appName) will keep saving on this device and resume syncing after sign-in."

            @unknown default:
                fetchChangesNow()
        }
    }

    private func recordTransientSyncFailure(_ error: any Error) {
        lastSyncError =
            "iCloud couldn't be reached. Your changes are saved on this device and will retry."
        logger.error("CloudKit operation failed: \(error)")
    }
}
