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

/// Mirrors an app's SwiftData store into a set of custom CloudKit zones.
///
/// The engine owns CloudKit transport, zone tracking, state persistence,
/// retries, zone recovery, and routing between the private and shared
/// databases. The app's ``SwiftDataSyncStore`` adapter remains the durable
/// local source of truth.
///
/// A device can own zones and participate in zones shared to it by other
/// people at the same time. Both databases sync concurrently rather than the
/// engine switching between a single active zone.
///
/// Each zone may be associated with an app-defined `collectionID`: an opaque
/// identifier, typically one per shareable unit in the app's own model, used
/// only to route durable changes and fetched records to the correct zone. The
/// engine never interprets what a collection represents.
///
/// - Important: The engine is main-actor isolated because `ModelContext` and
///   its models must not cross actor boundaries.
@MainActor
@Observable
public final class SwiftDataSyncEngine {

    /// The device's relationship to a tracked zone.
    public typealias Role = SwiftDataSyncRole

    /// The availability of the configured iCloud account.
    public typealias Availability = SwiftDataSyncAvailability

    /// The CloudKit and presentation configuration for this engine.
    public let configuration: SwiftDataSyncConfiguration

    /// Zones this device owns, tracked in its private database.
    public private(set) var ownedZones: Set<CKRecordZone.ID> = []

    /// Zones shared to this device by someone else, tracked in the shared database.
    public private(set) var sharedZones: Set<CKRecordZone.ID> = []

    /// A plain-language description of the most recent sync failure.
    public private(set) var lastSyncError: String?

    /// The raw `CKError.Code` name for the change CloudKit last refused.
    ///
    /// Intended for support and diagnostics. ``lastSyncError`` is deliberately
    /// plain language, so every rejection reads alike from the outside; this
    /// keeps the underlying reason available without Console.app.
    public private(set) var lastRejectionReason: String?

    /// The time the most recent complete fetch or send succeeded.
    public private(set) var lastSyncedAt: Date?

    /// The availability of the configured iCloud account.
    public private(set) var availability: Availability = .checking

    /// The CloudKit container described by the configuration.
    @ObservationIgnored
    private let container: CKContainer

    /// The app's adapter for SwiftData models and outbox rows.
    @ObservationIgnored
    private let store: any SwiftDataSyncStore

    /// Persistence for zone tracking and opaque `CKSyncEngine` state.
    @ObservationIgnored
    private let stateStore: any SwiftDataSyncStateStore

    /// The sync engine for zones this device owns.
    @ObservationIgnored
    private lazy var privateEngine = CKSyncEngine(
        makeEngineConfiguration(
            database: container.privateCloudDatabase,
            stateKey: privateStateKey
        )
    )

    /// The sync engine for zones shared to this device.
    @ObservationIgnored
    private lazy var sharedEngine = CKSyncEngine(
        makeEngineConfiguration(
            database: container.sharedCloudDatabase,
            stateKey: sharedStateKey
        )
    )

    /// The task observing `CKAccountChanged` for this container.
    @ObservationIgnored
    private var accountChangeTask: Task<Void, Never>?

    /// The zone each app-defined collection routes to.
    ///
    /// A device tracks a handful of zones at most, so a plain dictionary with
    /// a linear reverse lookup is simpler than a bidirectional map.
    private var zoneByCollection: [UUID: CKRecordZone.ID] = [:]

    /// Zones whose `.saveZone` has been sent this session.
    ///
    /// Reset on relaunch, so a zone that never confirmed creation before
    /// termination is resent harmlessly.
    private var preparedZones: Set<CKRecordZone.ID> = []

    /// Whether any zone failed during the fetch currently in flight.
    private var activeFetchHadError = false

    /// Whether any change failed during the send currently in flight.
    private var activeSendHadError = false

    /// A monotonic token used to discard out-of-order account checks.
    private var accountStatusRequestID: UInt = 0

    /// Creates an engine connected to an app's SwiftData-backed store.
    ///
    /// Zones tracked by a previous session are restored before the engine
    /// contacts CloudKit.
    ///
    /// - Parameters:
    ///   - configuration: CloudKit identifiers and user-facing terminology.
    ///   - store: The adapter for app-specific SwiftData models and outbox rows.
    ///   - startsAutomatically: Whether to check the account and reconcile at
    ///     launch. Pass `false` to drive the engine manually, such as in tests.
    ///   - stateStore: A custom store for opaque engine state, or `nil` to
    ///     persist in `UserDefaults`.
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
            activateSharedEngineIfNeeded()
            reconcileOutbox()
        }
    }

    deinit {
        accountChangeTask?.cancel()
    }

    /// Brings the shared-database engine into existence on a participant device.
    ///
    /// `CKSyncEngine` only receives pushes and runs scheduled syncs while the
    /// instance exists. Nothing else constructs `sharedEngine` in the steady
    /// state — `reconcileOutbox()` returns at its empty-outbox guard before
    /// reaching either engine lookup — so deleting this apparent no-op leaves a
    /// participant with no live engine, and their device stops fetching
    /// automatically at all.
    private func activateSharedEngineIfNeeded() {
        guard !sharedZones.isEmpty else { return }
        _ = sharedEngine
    }

    /// Returns the collection identifier a tracked zone routes for.
    ///
    /// - Parameter zoneID: The zone to look up.
    /// - Returns: The associated collection identifier, or `nil` when the zone
    ///   has none.
    public func collectionID(for zoneID: CKRecordZone.ID) -> UUID? {
        zoneByCollection.first { $0.value == zoneID }?.key
    }

    /// Returns the zone a collection identifier routes to.
    ///
    /// - Parameter collectionID: The app-defined collection identifier.
    /// - Returns: The associated zone, or `nil` when this device neither owns
    ///   nor participates in one for that collection.
    public func zoneID(forCollection collectionID: UUID) -> CKRecordZone.ID? {
        zoneByCollection[collectionID]
    }

    /// Returns this device's relationship to a tracked zone.
    ///
    /// - Parameter zoneID: The zone to look up.
    /// - Returns: The device's role, or `nil` when the zone isn't tracked.
    public func role(for zoneID: CKRecordZone.ID) -> Role? {
        if ownedZones.contains(zoneID) { return .owner }
        if sharedZones.contains(zoneID) { return .participant }
        return nil
    }

    /// Refreshes ``availability`` from the configured CloudKit account.
    ///
    /// Overlapping calls are tolerated: only the most recent one is allowed to
    /// publish its result.
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

    /// Marks the account as available and clears ``lastSyncError``.
    ///
    /// A completed CloudKit operation is stronger evidence of availability
    /// than a possibly stale account check, so calling this also invalidates
    /// any account check still in flight.
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
    ///   - availability: The account availability to present.
    ///   - lastSyncedAt: The last successful sync time to present, if any.
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

    /// Clears every persisted zone-tracking and CloudKit sync-token record for
    /// this engine, leaving local SwiftData data untouched.
    ///
    /// Use this to recover when the bookkeeping itself has become wrong or
    /// stale, such as after an interrupted schema migration left zones
    /// registered under the wrong identity.
    ///
    /// The reset takes effect at the next launch. The engine constructed then
    /// starts with no known zones and no change tokens, so the app's own
    /// bootstrap step re-derives zone identity from its current local models,
    /// and the following fetch pulls each rediscovered zone's complete state
    /// rather than changes since the last checkpoint.
    ///
    /// - Note: Safe to call on a live engine, but it has no effect on the
    ///   `CKSyncEngine` instances already running in this session.
    public func resetPersistedState() {
        stateStore.removeValue(forKey: zonesKey)
        stateStore.removeValue(forKey: privateStateKey)
        stateStore.removeValue(forKey: sharedStateKey)
        ownedZones = []
        sharedZones = []
        zoneByCollection = [:]
        preparedZones = []
    }

    /// Fetches remote changes across every tracked zone, after first
    /// reconciling durable local changes.
    ///
    /// Returns immediately; the fetch proceeds in a detached task for the same
    /// reason as `sendChanges(using:)`. A task inheriting this type's
    /// main-actor isolation can resume inside a suspended `CKSyncEngine`
    /// delegate callback, and awaiting `fetchChanges()` there re-enters the
    /// engine from its own delegate — which CloudKit treats as a fatal client
    /// bug rather than a recoverable error. Main-actor work is hopped back
    /// onto explicitly, so only the two engine awaits run off it.
    public func fetchChangesNow() {
        Task.detached { [weak self] in
            guard let self else { return }
            await refreshAccountStatus()

            let zones = await MainActor.run { () -> (owned: Bool, shared: Bool)? in
                guard self.availability == .available else { return nil }
                for zoneID in self.ownedZones {
                    self.ensureZoneExists(zoneID)
                }
                self.reconcileOutbox()
                return (!self.ownedZones.isEmpty, !self.sharedZones.isEmpty)
            }
            guard let zones else { return }

            do {
                if zones.owned {
                    try await privateEngine.fetchChanges()
                }
                if zones.shared {
                    try await sharedEngine.fetchChanges()
                }
                await recordSuccessfulCloudKitActivity()
            } catch {
                await recordTransientSyncFailure(error)
            }
        }
    }

    /// Rehydrates the engine's pending changes from the adapter's durable
    /// outbox, routing each one to the zone its `collectionID` maps to.
    ///
    /// Changes whose collection isn't tracked by any zone yet are left in the
    /// outbox untouched rather than guessed into the wrong zone.
    ///
    /// - Returns: The engines that received changes and now need a send.
    private func stageOutbox() -> [CKSyncEngine] {
        do {
            let changes = try store.pendingChanges()
            guard !changes.isEmpty, availability == .available else { return [] }

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

            var staged: [CKSyncEngine] = []
            if let privateChanges = changesByEngine[ObjectIdentifier(privateEngine)] {
                privateEngine.state.add(pendingRecordZoneChanges: privateChanges)
                staged.append(privateEngine)
            }
            if let sharedChanges = changesByEngine[ObjectIdentifier(sharedEngine)] {
                sharedEngine.state.add(pendingRecordZoneChanges: sharedChanges)
                staged.append(sharedEngine)
            }
            return staged
        } catch {
            lastSyncError =
                "\(configuration.appName) couldn't prepare changes for iCloud. Your \(configuration.dataName) remains saved on this device."
            logger.error("Failed to reconcile sync outbox: \(error)")
            return []
        }
    }

    /// Stages the durable outbox and sends it without waiting for the result.
    public func reconcileOutbox() {
        for engine in stageOutbox() {
            sendChanges(using: engine)
        }
    }

    /// Stages and sends pending changes, returning only once the send has
    /// finished or failed.
    ///
    /// Awaitable so a caller holding a background task assertion can keep the
    /// app alive until the upload actually lands. The send runs detached for
    /// the same reason as ``sendChanges(using:)``, so this must never be called
    /// from a `CKSyncEngine` delegate callback.
    public func flushPendingChanges() async {
        let staged = stageOutbox()
        guard !staged.isEmpty else { return }

        await Task.detached { [weak self] in
            for engine in staged {
                do {
                    try await engine.sendChanges()
                } catch {
                    await self?.recordTransientSyncFailure(error)
                }
            }
        }.value
    }

    /// Registers a zone this device owns, creating it in CloudKit if it
    /// doesn't already exist there.
    ///
    /// Safe to call repeatedly — for example once per owned zone at every
    /// launch, to re-verify a zone that never confirmed creation before the
    /// app last terminated. A zone already tracked and already confirmed this
    /// session is a no-op.
    ///
    /// - Parameters:
    ///   - zoneID: The zone to create or verify in the owner's private database.
    ///   - collectionID: The app-defined identifier this zone routes for, if any.
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

    /// Adopts a zone someone else shared to this device, alongside any zones
    /// it already owns or participates in.
    ///
    /// Accepting one shared collection never disturbs another. The adapter is
    /// given a chance to protect existing local data first; if that fails, the
    /// zone isn't adopted and no local data is deleted.
    ///
    /// - Parameters:
    ///   - zoneID: The accepted zone in the participant's shared database.
    ///   - collectionID: The app-defined identifier this zone routes for, if any.
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

        // Detached for the same reason as `fetchChangesNow()`: accepting a
        // share can happen while the engine is mid-callback, and awaiting
        // `fetchChanges()` from a main-actor task would re-enter it.
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await sharedEngine.fetchChanges()
                await recordSuccessfulCloudKitActivity()
                await reconcileOutbox()
            } catch {
                await recordTransientSyncFailure(error)
            }
        }
    }

    /// The state-store key for the private engine's serialized state.
    private var privateStateKey: String {
        "\(configuration.stateKeyPrefix).state.private"
    }

    /// The state-store key for the shared engine's serialized state.
    private var sharedStateKey: String {
        "\(configuration.stateKeyPrefix).state.shared"
    }

    /// The state-store key for the tracked-zone manifest.
    private var zonesKey: String {
        "\(configuration.stateKeyPrefix).zones"
    }

    /// Returns the engine responsible for a zone's database.
    ///
    /// - Parameter zoneID: The zone to route.
    /// - Returns: The private engine for owned zones, otherwise the shared one.
    private func engine(for zoneID: CKRecordZone.ID) -> CKSyncEngine {
        ownedZones.contains(zoneID) ? privateEngine : sharedEngine
    }

    /// A tracked zone in its persisted form.
    private struct PersistedZone: Codable {
        let zoneName: String
        let ownerName: String
        let collectionID: UUID?
        let role: SwiftDataSyncRole
    }

    /// Restores the tracked-zone manifest written by a previous session.
    ///
    /// Static so it can run before `self` is fully initialized.
    ///
    /// - Parameters:
    ///   - stateStore: The store holding the manifest.
    ///   - key: The manifest's key.
    /// - Returns: The persisted zones, or an empty array when absent or
    ///   undecodable.
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

    /// Writes the current owned and shared zones to the state store.
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

    /// Builds a `CKSyncEngine` configuration bound to one database.
    ///
    /// - Parameters:
    ///   - database: The private or shared database to sync.
    ///   - stateKey: The key holding that database's serialized engine state.
    /// - Returns: A configuration restoring any previously persisted state.
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

    /// Restores a persisted `CKSyncEngine` state serialization.
    ///
    /// - Parameter key: The state-store key to read.
    /// - Returns: The stored state, or `nil` when absent or undecodable, which
    ///   makes the engine resync from scratch.
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

    /// Persists a `CKSyncEngine` state serialization.
    ///
    /// - Parameters:
    ///   - serialization: The state CloudKit asked to have stored.
    ///   - key: The state-store key to write.
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

    /// Sends queued changes without re-entering the engine from its own
    /// delegate.
    ///
    /// A plain `Task` is not sufficient. This type is main-actor isolated, so
    /// a plain `Task` inherits that context and is queued behind whatever
    /// main-actor work is already running — including a suspended
    /// `CKSyncEngine` delegate callback. ``ensureZoneExists(_:collectionID:)``
    /// and ``reconcileOutbox()`` both call this from inside such callbacks, so
    /// the send would land within the callback, which CloudKit treats as a
    /// fatal client bug rather than a recoverable error:
    ///
    ///     BUG IN CLIENT OF CLOUDKIT: Cannot await a call into CKSyncEngine
    ///     from within a delegate callback… Try performing this in a detached
    ///     Task.
    ///
    /// `Task.detached` is that advice: it inherits no actor context, so the
    /// send runs off the main actor and outside any callback in flight.
    ///
    /// - Parameter engine: The engine whose pending changes should be sent.
    private func sendChanges(using engine: CKSyncEngine) {
        Task.detached { [weak self] in
            do {
                try await engine.sendChanges()
            } catch {
                await self?.recordTransientSyncFailure(error)
            }
        }
    }
}

extension SwiftDataSyncEngine: CKSyncEngineDelegate {

    /// Handles an event reported by either sync engine.
    ///
    /// Called by CloudKit; don't call it directly.
    ///
    /// - Parameters:
    ///   - event: The event to handle.
    ///   - syncEngine: The engine that reported it, which identifies whether
    ///     the event concerns the private or the shared database.
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

    /// Materialises the next batch of records for CloudKit to upload.
    ///
    /// Pending changes with no matching durable operation and no fallback
    /// record are dropped from the engine's queue rather than sent as empty
    /// saves. Called by CloudKit; don't call it directly.
    ///
    /// - Parameters:
    ///   - context: The scope and options for the send in flight.
    ///   - syncEngine: The engine requesting the batch.
    /// - Returns: The batch to upload, or `nil` when nothing in scope is
    ///   pending or the durable outbox couldn't be read.
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

    /// Applies fetched records and deletions to the local store, one zone at
    /// a time.
    ///
    /// The batch is grouped by zone because zones in the same fetch can belong
    /// to different collections, and a failure in one zone must not abandon
    /// the others.
    ///
    /// - Parameters:
    ///   - event: The fetched changes to apply.
    ///   - syncEngine: The engine that fetched them, which determines the role
    ///     the changes are applied under.
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

    /// Recovers from zones that disappeared from a database.
    ///
    /// A deleted shared zone means access was revoked; a deleted owned zone
    /// means the zone was reset and its records must be recreated and
    /// re-uploaded.
    ///
    /// - Parameters:
    ///   - event: The database changes CloudKit reported.
    ///   - syncEngine: The engine that reported them.
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

    /// Records the outcome of zone creations and deletions.
    ///
    /// Confirmed zones are marked prepared for this session; retryable
    /// failures are requeued, and permanent ones surface as a sync error.
    ///
    /// - Parameters:
    ///   - event: The zone changes CloudKit accepted or rejected.
    ///   - syncEngine: The engine that sent them. Only the private engine
    ///     creates zones, so shared-database events are ignored.
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

    /// Stops tracking a shared zone this device no longer has access to and
    /// asks the adapter to retain what it can locally.
    ///
    /// - Parameter zoneID: The revoked zone.
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

    /// Asks the adapter to requeue a collection's records for upload, then
    /// reconciles the outbox.
    ///
    /// - Parameter collectionID: The collection to requeue, or `nil` to
    ///   requeue every collection this device owns.
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

    /// Records the outcome of every record CloudKit accepted or rejected.
    ///
    /// Accepted changes clear their outbox rows. Conflicts are handed to the
    /// adapter's merge policy and retried, other retryable failures are
    /// requeued, and permanent rejections are marked failed without
    /// discarding local data.
    ///
    /// - Parameters:
    ///   - event: The record changes CloudKit accepted or rejected.
    ///   - syncEngine: The engine that sent them, and which receives retries.
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
        var missingZoneIDs = Set<CKRecordZone.ID>()

        for failure in event.failedRecordSaves {
            activeSendHadError = true
            let record = failure.record

            if Self.isMissingZone(failure.error.code) {
                missingZoneIDs.insert(record.recordID.zoneID)
            } else if failure.error.code == .serverRecordChanged,
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
                lastRejectionReason = String(describing: failure.error.code)
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
            } else if Self.isMissingZone(error.code) {
                missingZoneIDs.insert(recordID.zoneID)
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
                lastRejectionReason = String(describing: error.code)
                logger.error("CloudKit rejected delete \(recordID): \(error)")
            }
        }

        if !retries.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retries)
        }

        if didChange {
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

        // Runs after the save above, never before: recovery rolls the context
        // back on failure, which would discard the records CloudKit just
        // accepted if they were still unsaved.
        for zoneID in missingZoneIDs {
            recoverFromMissingZone(zoneID, syncEngine: syncEngine)
        }
    }

    /// Whether a failure means the zone a change targeted no longer exists.
    ///
    /// - Parameter code: The CloudKit failure code.
    /// - Returns: `true` when the zone is gone and the change can only succeed
    ///   after the zone is restored or abandoned.
    nonisolated static func isMissingZone(_ code: CKError.Code) -> Bool {
        code == .zoneNotFound || code == .userDeletedZone
    }

    /// Recovers a send that failed because its zone no longer exists.
    ///
    /// The same failure means opposite things per database, so the two are
    /// never merged: an owned zone was reset and its records must be recreated
    /// and re-uploaded, while a shared zone means access was revoked. Treating
    /// the shared case as a reset would recreate a zone the owner deliberately
    /// withdrew.
    ///
    /// - Parameters:
    ///   - zoneID: The zone CloudKit reported as missing.
    ///   - syncEngine: The engine that reported it, which identifies the database.
    private func recoverFromMissingZone(
        _ zoneID: CKRecordZone.ID,
        syncEngine: CKSyncEngine
    ) {
        // `privateEngine` is tested first so the comparison itself doesn't
        // construct `sharedEngine` on a device that has no shares at all.
        if syncEngine === privateEngine, ownedZones.contains(zoneID) {
            preparedZones.remove(zoneID)
            lastSyncError =
                "An iCloud \(configuration.dataName) zone was reset. Your local data is safe and will be uploaded again."
            ensureZoneExists(zoneID)
            requeueRecords(forCollection: collectionID(for: zoneID))
        } else if syncEngine === sharedEngine, sharedZones.contains(zoneID) {
            recoverFromRevokedShare(zoneID)
        } else {
            logger.error("Missing zone \(zoneID) is not tracked; nothing to recover")
        }
    }

    /// Durably notes why a retryable change failed, so the reason survives
    /// relaunch.
    ///
    /// - Parameters:
    ///   - recordID: The CloudKit identity of the failed change.
    ///   - mutation: The operation that failed.
    ///   - category: The `CKError.Code` name to record.
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

    /// Reacts to the iCloud account signing in, out, or switching.
    ///
    /// Switching accounts invalidates every zone confirmation, so owned zones
    /// are recreated and their records requeued under the new identity.
    ///
    /// - Parameter event: The account change CloudKit reported.
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

    /// Reports a failure that leaves local data intact and will be retried.
    ///
    /// - Parameter error: The underlying CloudKit failure, logged rather than
    ///   shown to the person using the app.
    private func recordTransientSyncFailure(_ error: any Error) {
        lastSyncError =
            "iCloud couldn't be reached. Your changes are saved on this device and will retry."
        logger.error("CloudKit operation failed: \(error)")
    }
}
