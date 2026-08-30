//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation
import Testing

@testable import SwiftDataSync

@Suite("Sharing failures")
struct SharingFailureTests {
    private let appName = "Example"

    private func message(_ code: CKError.Code) -> String {
        SwiftDataSyncSharingCoordinator.message(
            for: CKError(code),
            appName: appName
        )
    }

    @Test("A missing zone is not treated as a missing share")
    func missingZoneIsDistinctFromMissingShare() {
        // `prepareShare` continues past `.unknownItem` to create the share,
        // but a missing zone needs the zone creating first. Conflating them
        // makes an un-synced collection permanently unshareable.
        #expect(SwiftDataSyncEngine.isMissingZone(.zoneNotFound))
        #expect(SwiftDataSyncEngine.isMissingZone(.userDeletedZone))
        #expect(!SwiftDataSyncEngine.isMissingZone(.unknownItem))
    }

    @Test("Recoverable failures say what to do next")
    func recoverableFailuresAreActionable() {
        #expect(message(.networkUnavailable).contains("offline"))
        #expect(message(.networkFailure).contains("offline"))
        #expect(message(.notAuthenticated).contains("Sign in to iCloud"))
        #expect(message(.quotaExceeded).contains("iCloud storage is full"))
        #expect(message(.zoneBusy).contains("busy"))
        #expect(message(.requestRateLimited).contains("busy"))
    }

    @Test("CloudKit's developer-facing detail never reaches a person")
    func schemaErrorsAreNotShownRaw() {
        // The failure that shipped to TestFlight surfaced CloudKit's own
        // description: "Cannot create new type cloudkit.share in production
        // schema". Nothing in that sentence helps whoever is reading it.
        let underlying = CKError(
            .serverRejectedRequest,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type cloudkit.share in production schema"
            ]
        )

        let shown = SwiftDataSyncSharingCoordinator.message(
            for: underlying,
            appName: appName
        )

        #expect(!shown.contains("cloudkit.share"))
        #expect(!shown.contains("schema"))
        #expect(shown.contains(appName))
    }

    @Test("A non-CloudKit error still gets a usable message")
    func nonCloudKitErrorsAreHandled() {
        struct Opaque: Error {}

        let shown = SwiftDataSyncSharingCoordinator.message(
            for: Opaque(),
            appName: appName
        )

        #expect(shown.contains(appName))
        #expect(!shown.isEmpty)
    }

    @Test("Adoption outcomes report whether the zone is tracked")
    func adoptionOutcomeReportsTracking() {
        #expect(SwiftDataSyncAdoptionOutcome.adopted.isAdopted)
        #expect(SwiftDataSyncAdoptionOutcome.adoptedPendingSync("later").isAdopted)
        #expect(!SwiftDataSyncAdoptionOutcome.failed("no").isAdopted)
    }

    @Test("Only a clean adoption stays silent")
    func onlyCleanAdoptionIsSilent() {
        #expect(SwiftDataSyncAdoptionOutcome.adopted.message == nil)
        #expect(SwiftDataSyncAdoptionOutcome.adoptedPendingSync("later").message == "later")
        #expect(SwiftDataSyncAdoptionOutcome.failed("no").message == "no")
    }
}
