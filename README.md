<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

# SwiftDataSync

![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmarkbattistella%2FSwiftDataSync%2Fbadge%3Ftype%3Dswift-versions)

![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmarkbattistella%2FSwiftDataSync%2Fbadge%3Ftype%3Dplatforms)

![Licence](https://img.shields.io/badge/Licence-MIT-white?labelColor=blue&style=flat)

</div>

`SwiftDataSync` connects an app-owned SwiftData store to any number of shared CloudKit record zones. SwiftData remains the durable local source of truth while `CKSyncEngine` delivers a transactionally maintained outbox to the owner's private database or a participant's shared database - one zone at a time, or many at once, side by side.

A device can simultaneously own some zones (created by this device, tracked in its private database) and participate in others (shared here by someone else, tracked in the shared database). Each zone is optionally associated with an app-defined `collectionID` - an opaque identifier for whatever the app shares as a unit (a project, a workspace, a single record) - used only to route durable changes and fetched records to the right zone. The engine never interprets what a collection means.

The package provides:

- Private and shared `CKSyncEngine` routing across an arbitrary set of zones
- Per-zone owner/participant roles, resolved independently
- Custom-zone creation and recovery, per zone
- Per-zone `CKShare` preparation, so preparing one zone's share never disturbs another's
- Persistent engine state (zones, roles, and their collection associations)
- Account availability monitoring
- Retry classification
- Conflict and revocation hooks, scoped to the one collection affected
- CloudKit system-field helpers
- A type-erased adapter for app-specific SwiftData models

## Requirements

| Platform | Minimum |
| --- | --- |
| Swift | 6.0 |
| iOS / iPadOS / Mac Catalyst | 17.0 |
| macOS | 14.0 |
| tvOS | 17.0 |
| watchOS | 10.0 |
| visionOS | 1.0 |

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
  .package(
    url: "https://github.com/markbattistella/SwiftDataSync",
    from: "1.0.0"
  )
]
```

Then add `SwiftDataSync` to the app target.

## App configuration

Every consuming app still owns its CloudKit contract. Enable:

- iCloud with CloudKit
- Remote notifications
- A CloudKit container
- `CKSharingSupported` in the app's Info property list

Deploy the app's CloudKit schema before shipping.

Create one configuration. Unlike a single-zone setup, this doesn't carry a fixed zone name of its own - an app can track any number of zones side by side, each named however its own model needs:

```swift
let configuration = SwiftDataSyncConfiguration(
  containerIdentifier: "iCloud.com.example.Tasks",
  appGroupIdentifier: "group.com.example.Tasks",
  stateKeyPrefix: "tasks.sync",
  shareTitle: "Shared tasks",
  appName: "Tasks",
  dataName: "workspace"
)
```

## SwiftData adapter

The package deliberately does not reflect arbitrary `@Model` classes into CloudKit. Each app implements `SwiftDataSyncStore` so record fields, deletions, migrations, and merge policy remain explicit.

```swift
@MainActor
final class TaskCloudStore: SwiftDataSyncStore {
  let modelContext: ModelContext

  // Return durable outbox rows, materialise CKRecords, apply fetched records,
  // preserve conflicts, and commit through this same ModelContext.
}
```

Every pending change's `collectionID` (on `SwiftDataSyncPendingChange`) tells the engine which zone it belongs to - the outbox row should be inserted or updated in the same SwiftData transaction as the app model being changed. This guarantees that terminating the app between a local save and a network request cannot silently lose the upload.

Create and retain the engine:

```swift
let syncEngine = SwiftDataSyncEngine(
  configuration: configuration,
  store: TaskCloudStore(modelContext: modelContainer.mainContext)
)
```

Provision a zone this device owns - safe to call repeatedly (e.g. once per owned zone at every launch):

```swift
let zoneID = configuration.ownedZoneID(named: "Workspace-\(workspaceID)")
syncEngine.ensureZoneExists(zoneID, collectionID: workspaceID)
```

Call `reconcileOutbox()` after committing a local mutation. Call `fetchChangesNow()` for an explicit user-requested refresh.

## Sharing

Prepare a specific zone's zone-wide share:

```swift
let sharing = SwiftDataSyncSharingCoordinator(syncManager: syncEngine)
await sharing.prepareShare(for: zoneID, title: "My workspace")
```

Present `sharing.activeShare(for: zoneID)` with `UICloudSharingController`. Forward accepted share metadata from the app or scene delegate - pass the `collectionID` this zone belongs to, if the app can determine it (e.g. by encoding it in the zone's own name):

```swift
syncEngine.adoptSharedZone(
  metadata.share.recordID.zoneID,
  collectionID: workspaceID
)
```

The owner always writes to a custom zone in their private database. CloudKit exposes that zone in each accepted participant's shared database; the package selects the correct database per zone from that zone's own persisted role - a device can own some zones and participate in others at the same time. `syncEngine.role(for:)`, `.zoneID(forCollection:)`, and `.collectionID(for:)` let the app move between a zone and the collection it represents in either direction.

## Data-safety contract

- Local SwiftData is authoritative.
- Network delivery is eventually consistent.
- Failed changes remain in the durable outbox.
- A participant's private data is protected before adopting a share, scoped to the one collection being adopted - every other collection this device already owns or participates in is untouched.
- A revoked share invokes the app's recovery hook for just that one collection instead of deleting local data.
- CloudKit conflicts are passed to the app for explicit preservation and merge.

## CloudSyncKit

`SwiftDataSync` is separate from [`CloudSyncKit`](https://github.com/markbattistella/CloudSyncKit). `CloudSyncKit` observes `NSPersistentCloudKitContainer` events. `SwiftDataSync` performs custom-record-zone syncing and cross-account sharing with `CKSyncEngine`.

## Licence

`SwiftDataSync` is released under the MIT licence.
