//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Testing

@testable import SwiftDataSync

@Suite("SwiftDataSync contracts")
struct SwiftDataSyncTests {

    private let configuration = SwiftDataSyncConfiguration(
        containerIdentifier: "iCloud.com.example.Example",
        appGroupIdentifier: "group.com.example.Example",
        stateKeyPrefix: "example.sync",
        shareTitle: "Example workspace",
        appName: "Example",
        dataName: "workspace"
    )

    @Test("Stable UUIDs produce stable record names")
    func stableRecordIdentity() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let participantZone = CKRecordZone.ID(
            zoneName: "SharedWorkspace",
            ownerName: "owner"
        )

        let recordID = configuration.makeRecordID(
            for: id,
            in: participantZone
        )

        #expect(recordID.recordName == id.uuidString)
        #expect(recordID.zoneID == participantZone)
    }

    @Test("Owned zones use the given name")
    func ownedZoneIdentity() {
        let zoneID = configuration.ownedZoneID(named: "SharedWorkspace")
        #expect(zoneID.zoneName == "SharedWorkspace")
        #expect(zoneID.ownerName == CKCurrentUserDefaultName)
    }

    @Test(
        "Only definite account failures require a local-data notice",
        arguments: [
            (SwiftDataSyncAvailability.checking, false),
            (.available, false),
            (.signedOut, true),
            (.restricted, true),
            (.temporarilyUnavailable, false),
        ]
    )
    func localDataNotice(
        availability: SwiftDataSyncAvailability,
        expected: Bool
    ) {
        #expect(availability.requiresLocalDataNotice == expected)
    }

    @Test(
        "Transient CloudKit errors remain retryable",
        arguments: [
            CKError.Code.networkFailure,
            .networkUnavailable,
            .zoneBusy,
            .serviceUnavailable,
            .requestRateLimited,
            .accountTemporarilyUnavailable,
        ]
    )
    func transientErrorsRetry(code: CKError.Code) {
        #expect(SwiftDataSyncRetryPolicy.shouldRetry(code))
    }

    @Test(
        "Permanent CloudKit errors are not retried indefinitely",
        arguments: [
            CKError.Code.badDatabase,
            .invalidArguments,
            .permissionFailure,
            .quotaExceeded,
        ]
    )
    func permanentErrorsStopRetrying(code: CKError.Code) {
        #expect(!SwiftDataSyncRetryPolicy.shouldRetry(code))
    }

    @Test("Pending changes retain app-defined scoping")
    func pendingChangeScoping() {
        let recordID = UUID()
        let collectionID = UUID()
        let change = SwiftDataSyncPendingChange(
            recordID: recordID,
            recordType: "Task",
            collectionID: collectionID,
            mutation: .save
        )

        #expect(change.recordID == recordID)
        #expect(change.recordType == "Task")
        #expect(change.collectionID == collectionID)
        #expect(change.mutation == .save)
    }

    @Test("Diagnostic snapshots include record identity")
    func diagnosticSnapshot() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "SharedWorkspace",
            ownerName: "owner"
        )
        let record = CKRecord(
            recordType: "Task",
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        record["title"] = "Prepare release"

        let data = SwiftDataSyncRecordSupport.diagnosticSnapshot(of: record)
        let values = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        #expect(values["recordType"] == "Task")
        #expect(values["recordName"] == record.recordID.recordName)
        #expect(values["title"] == "Prepare release")
    }
}
