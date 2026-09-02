//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit

/// Classifies CloudKit failures that are safe to retry without user action.
public enum SwiftDataSyncRetryPolicy {
    /// Returns whether a failed CloudKit operation should stay queued for
    /// retry.
    ///
    /// - Parameter code: The CloudKit failure code.
    /// - Returns: `true` for transient or authentication-state failures, which
    ///   resolve on their own; `false` for failures that would fail again, such
    ///   as a permission or schema rejection.
    ///
    /// - Note: `.batchRequestFailed` is retryable because it says nothing about
    ///   the record it is reported for. CloudKit applies a zone's changes
    ///   atomically, so one genuinely bad record fails with its own code and
    ///   every innocent sibling in the same batch is rolled back with this one.
    ///   Treating it as permanent would discard, or permanently jam, changes
    ///   that never had anything wrong with them.
    public static func shouldRetry(_ code: CKError.Code) -> Bool {
        switch code {
            case .networkFailure, .networkUnavailable, .zoneBusy,
                .serviceUnavailable, .notAuthenticated, .operationCancelled,
                .requestRateLimited, .resultsTruncated,
                .accountTemporarilyUnavailable, .batchRequestFailed:
                true
            default:
                false
        }
    }
}
