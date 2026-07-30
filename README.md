<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

# SwiftDataSync

![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmarkbattistella%2FSwiftDataSync%2Fbadge%3Ftype%3Dswift-versions)

![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmarkbattistella%2FSwiftDataSync%2Fbadge%3Ftype%3Dplatforms)

![Licence](https://img.shields.io/badge/Licence-MIT-white?labelColor=blue&style=flat)

</div>

`SwiftDataSync` connects an app-owned SwiftData store to a shared CloudKit record zone. SwiftData remains the durable local source of truth while `CKSyncEngine` delivers a transactionally maintained outbox to the owner's private database or a participant's shared database.

The package provides:

- Private and shared `CKSyncEngine` routing
- Owner and participant roles
- Custom-zone creation and recovery
- Zone-wide `CKShare` preparation
- Persistent engine state
- Account availability monitoring
- Retry classification
- Conflict and revocation hooks
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

Create one configuration:

```swift
let configuration = SwiftDataSyncConfiguration(
  containerIdentifier: "iCloud.com.example.Tasks",
  zoneName: "SharedWorkspace",
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

The outbox row should be inserted or updated in the same SwiftData transaction as the app model being changed. This guarantees that terminating the app between a local save and a network request cannot silently lose the upload.

Create and retain the engine:

```swift
let syncEngine = SwiftDataSyncEngine(
  configuration: configuration,
  store: TaskCloudStore(modelContext: modelContainer.mainContext)
)
```

Call `reconcileOutbox()` after committing a local mutation. Call `fetchChangesNow()` for an explicit user-requested refresh.

## Sharing

Prepare the owner's zone-wide share:

```swift
let sharing = SwiftDataSyncSharingCoordinator(syncManager: syncEngine)
await sharing.prepareShare()
```

Present `sharing.activeShare` with `UICloudSharingController`. Forward accepted share metadata from the app or scene delegate:

```swift
syncEngine.adoptSharedZone(metadata.share.recordID.zoneID)
```

The owner always writes to a custom zone in their private database. CloudKit exposes that zone in each accepted participant's shared database; the package selects the correct database from the persisted role.

## Data-safety contract

- Local SwiftData is authoritative.
- Network delivery is eventually consistent.
- Failed changes remain in the durable outbox.
- A participant's private data is protected before adopting a share.
- Revoked shares invoke the app's recovery hook instead of deleting local data.
- CloudKit conflicts are passed to the app for explicit preservation and merge.

## CloudSyncKit

`SwiftDataSync` is separate from [`CloudSyncKit`](https://github.com/markbattistella/CloudSyncKit). `CloudSyncKit` observes `NSPersistentCloudKitContainer` events. `SwiftDataSync` performs custom-record-zone syncing and cross-account sharing with `CKSyncEngine`.

## Licence

`SwiftDataSync` is released under the MIT licence.
