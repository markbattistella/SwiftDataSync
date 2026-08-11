//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import CloudKit
import Foundation

/// Helpers for preserving CloudKit system fields alongside SwiftData models.
///
/// A record's system fields carry its change tag, which CloudKit needs to
/// detect conflicts. Archive them when a save is accepted, and restore them
/// before building the next save for the same record.
public enum SwiftDataSyncRecordSupport {

    /// Restores a CloudKit record shell from archived system fields.
    ///
    /// The result carries identity and change-tag metadata but no field
    /// values; repopulate it before saving.
    ///
    /// - Parameter data: Data previously returned by
    ///   ``archiveSystemFields(from:)``.
    /// - Returns: The restored record, or `nil` when the archive is absent or
    ///   invalid.
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
    /// - Parameter record: The record as CloudKit stored it.
    /// - Returns: An opaque archive to persist alongside the local model.
    public static func archiveSystemFields(from record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Produces a diagnostic snapshot of a record's values.
    ///
    /// Every value is reduced to a string, so a preserved conflict can be
    /// inspected later without persisting an arbitrary object graph.
    ///
    /// - Parameter record: The record to describe.
    /// - Returns: JSON data mapping each key to a printable value, or empty
    ///   data if encoding fails.
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
