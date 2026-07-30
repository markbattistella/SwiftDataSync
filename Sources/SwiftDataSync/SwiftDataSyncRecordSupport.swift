//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation

/// Helpers for preserving CloudKit system fields alongside SwiftData models.
public enum SwiftDataSyncRecordSupport {

    /// Restores a CloudKit record shell from archived system fields.
    ///
    /// - Parameter data: Data previously returned by ``archiveSystemFields(from:)``.
    /// - Returns: The restored record, or `nil` when the archive is absent or invalid.
    public static func restoreRecord(from data: Data?) -> CKRecord? {
        guard let data,
            let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// Archives the system fields required for conflict-aware future saves.
    ///
    /// - Parameter record: The accepted server record.
    /// - Returns: An opaque archive containing its system fields.
    public static func archiveSystemFields(from record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Produces a diagnostic snapshot that avoids storing arbitrary object graphs.
    ///
    /// - Parameter record: The record to describe.
    /// - Returns: JSON data containing printable record values.
    public static func diagnosticSnapshot(of record: CKRecord) -> Data {
        var values = [String: String]()
        values["recordType"] = record.recordType
        values["recordName"] = record.recordID.recordName

        for key in record.allKeys().sorted() {
            let value = record[key]
            switch value {
            case let date as Date:
                values[key] = date.ISO8601Format()
            case let data as Data:
                values[key] = data.base64EncodedString()
            case let strings as [String]:
                values[key] = strings.joined(separator: ",")
            case let value?:
                values[key] = String(describing: value)
            case nil:
                values[key] = "nil"
            }
        }

        return (try? JSONEncoder().encode(values)) ?? Data()
    }
}
