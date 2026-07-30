//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Observation
import os.log

private let logger = Logger(
    subsystem: "com.markbattistella.SwiftDataSync",
    category: "sync"
)

/// Mirrors a custom CloudKit zone while an app's SwiftData adapter remains the
/// durable local source of truth.
///
/// The engine owns CloudKit transport, role selection, state persistence,
/// retries, zone recovery, and private/shared database routing. The supplied
/// ``SwiftDataSyncStore`` owns model lookup, record mapping, the durable
/// outbox, and app-specific conflict policy.
@MainActor
@Observable
public final class SwiftDataSyncEngine {

    /// The device's relationship to the active shared zone.
    public typealias Role = SwiftDataSyncRole

    /// The current availability of the configured iCloud account.
    public typealias Availability = SwiftDataSyncAvailability

    /// The CloudKit and presentation configuration for this engine.
    public let configuration: SwiftDataSyncConfiguration

    /// The device's relationship to the active shared zone.
    public private(set) var role: Role

    /// The participant view of the owner's shared zone, when one is active.
    public private(set) var sharedZoneID: CKRecordZone.ID?

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

    private var hasPreparedOwnedZone = false
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
        let persistedRoleKey = "\(configuration.stateKeyPrefix).role"
        self.role =
            Role(
                rawValue: resolvedStateStore.string(forKey: persistedRoleKey) ?? ""
            )
            ?? .owner

        let persistedOwnerKey =
            "\(configuration.stateKeyPrefix).sharedZone.ownerName"
        if let ownerName = resolvedStateStore.string(
            forKey: persistedOwnerKey
        ) {
            self.sharedZoneID = CKRecordZone.ID(
                zoneName: configuration.zoneName,
                ownerName: ownerName
            )
        }

        guard startsAutomatically else { return }

        accountChangeTask = Task { [weak self, container] in
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
            if role == .owner {
                ensureOwnedZoneExists()
            }
            reconcileOutbox()
        }
    }

    isolated deinit {
        accountChangeTask?.cancel()
    }

    /// The custom zone currently used by this device.
    public var activeZoneID: CKRecordZone.ID {
        switch role {
        case .owner:
            configuration.ownedZoneID
        case .participant:
            sharedZoneID ?? configuration.ownedZoneID
        }
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
        public func configureForPreview(
            role: Role,
            availability: Availability = .available,
            lastSyncedAt: Date? = .now
        ) {
            self.role = role
            self.availability = availability
            self.lastSyncedAt = lastSyncedAt
            self.lastSyncError = nil
            if role == .participant {
                self.sharedZoneID = CKRecordZone.ID(
                    zoneName: configuration.zoneName,
                    ownerName: "_previewOwner"
                )
            } else {
                self.sharedZoneID = nil
            }
        }

    #endif

    /// Fetches remote changes after first reconciling durable local changes.
    public func fetchChangesNow() {
        Task { [weak self] in
            guard let self else { return }
            await refreshAccountStatus()
            guard availability == .available else { return }
            if role == .owner {
                ensureOwnedZoneExists()
            }
            reconcileOutbox()

            do {
                try await activeEngine.fetchChanges()
                recordSuccessfulCloudKitActivity()
            } catch {
                recordTransientSyncFailure(error)
            }
        }
    }

    /// Rehydrates the engine's pending changes from the adapter's durable outbox.
    public func reconcileOutbox() {
        do {
            let changes = try store.pendingChanges()
            guard !changes.isEmpty, availability == .available else { return }

            let pendingChanges = try changes.map { change in
                try store.markAttempted(change, errorCategory: nil)
                let recordID = configuration.makeRecordID(
                    for: change.recordID,
                    in: activeZoneID
                )
                switch change.mutation {
                case .save:
                    return CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)
                case .delete:
                    return CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
                }
            }

            activeEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            try store.save()
            sendChanges(using: activeEngine)
        } catch {
            lastSyncError =
                "\(configuration.appName) couldn't prepare changes for iCloud. Your \(configuration.dataName) remains saved on this device."
            logger.error("Failed to reconcile sync outbox: \(error)")
        }
    }

    /// Switches this device from its private collection to an accepted shared zone.
    ///
    /// The adapter receives a chance to archive local data first. Existing local
    /// data is never uploaded into the newly accepted share automatically.
    ///
    /// - Parameter zoneID: The accepted zone in the participant's shared database.
    public func adoptSharedZone(_ zoneID: CKRecordZone.ID) {
        do {
            try store.prepareToAdoptShare()
            try store.save()
        } catch {
            store.rollback()
            lastSyncError =
                "The invitation was accepted, but \(configuration.appName) couldn't protect the current \(configuration.dataName). No local data was deleted."
            logger.error("Failed to prepare local data before share switch: \(error)")
            return
        }

        sharedZoneID = zoneID
        role = .participant
        stateStore.set(zoneID.ownerName, forKey: sharedZoneOwnerNameKey)
        stateStore.set(Role.participant.rawValue, forKey: roleKey)

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

    private var roleKey: String {
        "\(configuration.stateKeyPrefix).role"
    }

    private var privateStateKey: String {
        "\(configuration.stateKeyPrefix).state.private"
    }

    private var sharedStateKey: String {
        "\(configuration.stateKeyPrefix).state.shared"
    }

    private var sharedZoneOwnerNameKey: String {
        "\(configuration.stateKeyPrefix).sharedZone.ownerName"
    }

    private var activeEngine: CKSyncEngine {
        switch role {
        case .owner: privateEngine
        case .participant: sharedEngine
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
        engineConfiguration.automaticallySync = false
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

    private func ensureOwnedZoneExists() {
        guard availability == .available, !hasPreparedOwnedZone else { return }
        privateEngine.state.add(
            pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: configuration.ownedZoneID))
            ]
        )
        hasPreparedOwnedZone = true
        sendChanges(using: privateEngine)
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
            guard syncEngine === activeEngine else { return }
            applyFetchedChanges(event)

        case .fetchedDatabaseChanges(let event):
            handleFetchedDatabaseChanges(event, syncEngine: syncEngine)

        case .sentDatabaseChanges(let event):
            handleSentDatabaseChanges(event, syncEngine: syncEngine)

        case .sentRecordZoneChanges(let event):
            handleSentRecordZoneChanges(event, syncEngine: syncEngine)

        case .accountChange(let event):
            handleAccountChange(event)

        case .willFetchChanges:
            guard syncEngine === activeEngine else { return }
            activeFetchHadError = false

        case .didFetchRecordZoneChanges(let event):
            guard syncEngine === activeEngine else { return }
            if let error = event.error {
                activeFetchHadError = true
                lastSyncError =
                    "iCloud couldn't finish checking the \(configuration.dataName). Local changes are safe and will retry."
                logger.error("CloudKit fetch failed for \(event.zoneID): \(error)")
            }

        case .didFetchChanges:
            guard syncEngine === activeEngine else { return }
            if !activeFetchHadError {
                lastSyncedAt = .now
                recordSuccessfulCloudKitActivity()
            }

        case .willSendChanges:
            guard syncEngine === activeEngine else { return }
            activeSendHadError = false

        case .didSendChanges:
            guard syncEngine === activeEngine else { return }
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
        guard syncEngine === activeEngine else { return nil }

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

    private func applyFetchedChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) {
        let records = event.modifications.map(\.record).filter {
            $0.recordID.zoneID == activeZoneID
        }
        let deletedRecordIDs = event.deletions.map(\.recordID).filter {
            $0.zoneID == activeZoneID
        }

        do {
            let didChange = try store.applyFetchedChanges(
                records: records,
                deletedRecordIDs: deletedRecordIDs,
                role: role
            )
            guard didChange else { return }
            try store.save()
            store.didApplyRemoteChanges()
        } catch {
            store.rollback()
            lastSyncError =
                "\(configuration.appName) received iCloud changes but couldn't save them locally. It will retry."
            logger.error("Failed to apply fetched CloudKit changes: \(error)")
        }
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        guard syncEngine === activeEngine else { return }

        for deletion in event.deletions
        where deletion.zoneID == activeZoneID {
            switch role {
            case .participant:
                recoverFromRevokedShare()

            case .owner:
                hasPreparedOwnedZone = false
                lastSyncError =
                    "The iCloud \(configuration.dataName) zone was reset. Your local data is safe and will be uploaded again."
                ensureOwnedZoneExists()
                requeueAllRecords()
            }
        }
    }

    private func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        guard role == .owner, syncEngine === privateEngine else { return }

        if event.savedZones.contains(where: {
            $0.zoneID == configuration.ownedZoneID
        }) {
            hasPreparedOwnedZone = true
        }

        for failure in event.failedZoneSaves
        where failure.zone.zoneID == configuration.ownedZoneID {
            activeSendHadError = true
            hasPreparedOwnedZone = false

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

        for (zoneID, error) in event.failedZoneDeletes
        where zoneID == configuration.ownedZoneID {
            activeSendHadError = true
            lastSyncError =
                "iCloud couldn't finish a shared-zone change. Your local data was not deleted."
            logger.error("CloudKit rejected zone delete \(zoneID): \(error)")
        }
    }

    private func recoverFromRevokedShare() {
        role = .owner
        sharedZoneID = nil
        hasPreparedOwnedZone = false
        stateStore.set(Role.owner.rawValue, forKey: roleKey)
        stateStore.removeValue(forKey: sharedZoneOwnerNameKey)

        do {
            try store.recoverFromRevokedShare()
            try store.save()
            ensureOwnedZoneExists()
            reconcileOutbox()
            lastSyncError =
                "Access to the shared \(configuration.dataName) ended. It was retained locally, and \(configuration.appName) started a new private \(configuration.dataName) without deleting anything."
        } catch {
            store.rollback()
            lastSyncError =
                "Access to the shared \(configuration.dataName) ended. Local data was retained, but \(configuration.appName) couldn't start a new \(configuration.dataName)."
            logger.error("Failed to recover from revoked shared zone: \(error)")
        }
    }

    private func requeueAllRecords() {
        do {
            try store.requeueAllRecords()
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
        guard syncEngine === activeEngine else { return }
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
            if role == .owner {
                ensureOwnedZoneExists()
            }
            reconcileOutbox()

        case .switchAccounts:
            recordSuccessfulCloudKitActivity()
            hasPreparedOwnedZone = false
            lastSyncError =
                "The iCloud account changed. Local data is safe; \(configuration.appName) is preparing it for the new account."
            if role == .owner {
                ensureOwnedZoneExists()
                requeueAllRecords()
            }

        case .signOut:
            availability = .signedOut
            hasPreparedOwnedZone = false
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
