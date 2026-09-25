//
//  BASICSchemaLedger.swift
//  BASICCore
//
//  What the database remembers about the classes stored in it (D7).
//

import Foundation

/// One class's row in the `_basic_schema` ledger.
///
/// The ledger is how a database answers "which version of this class wrote
/// you?" — without it, `EnsureSchema` could compare shapes but never know
/// whether a difference was a migration waiting to run or a mistake.
struct BASICSchemaRecord: Equatable, Sendable {
    /// The class name as written.
    let className: String
    /// The version the database is at (DB5; a class with no `version` is 0).
    let version: Int
    /// When it was recorded, ISO-8601 in UTC.
    let appliedAt: String
    /// The mapped shape, canonically, so a change with no version bump is
    /// visible — and so it can be said *which* change.
    ///
    /// The plan called for a checksum. A checksum answers "something moved",
    /// which is enough for a relational store (whose live table can then be
    /// asked what) and not enough for a document store, where the ledger is the
    /// only record there is: a digest cannot tell a field that was *added* —
    /// free, in a schemaless store — from one that was renamed. So the shape
    /// itself is kept, and ``BASICSchemaLedger/checksum(of:)`` remains the short
    /// form of it for anyone reading the table by eye.
    let shape: String
}

/// The `_basic_schema` table or collection.
enum BASICSchemaLedger {

    /// The name, leading underscore and all: a table a program did not declare
    /// should not look like one it did.
    static let tableName = "_basic_schema"

    static let schema = BASICTableSchema(
        name: tableName,
        columns: [
            BASICColumnSchema(name: "class_name", type: .text(maximumLength: nil), isNullable: false, isPrimaryKey: true),
            BASICColumnSchema(name: "version", type: .integer, isNullable: false),
            BASICColumnSchema(name: "applied_at", type: .text(maximumLength: nil), isNullable: false),
            BASICColumnSchema(name: "shape", type: .text(maximumLength: nil), isNullable: false),
        ],
        indexes: []
    )

    /// Everything about a mapping that decides its storage, canonically.
    ///
    /// Column names, types, key and index shape, and the table name — never the
    /// BASIC field names, which a program may rename freely without touching the
    /// database.
    static func shape(of mapping: BASICTableMapping) -> String {
        var parts: [String] = ["table \(mapping.tableName)"]
        for column in mapping.schema.columns.sorted(by: { $0.name < $1.name }) {
            parts.append("\(column.name):\(column.type)\(column.isPrimaryKey ? ":key" : "")")
        }
        for index in mapping.schema.indexes.sorted(by: { $0.name < $1.name }) {
            parts.append("ix \(index.name):\(index.columns.joined(separator: ","))\(index.isUnique ? ":unique" : "")")
        }
        return parts.joined(separator: "|")
    }

    /// What a stored shape says about one column, by column name.
    static func columns(in shape: String) -> [String: String] {
        var found: [String: String] = [:]
        for part in shape.split(separator: "|").dropFirst() where !part.hasPrefix("ix ") {
            let pieces = part.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            found[String(pieces[0])] = String(pieces[1])
        }
        return found
    }

    /// A checksum of everything about a mapping that decides its storage.
    ///
    /// Column names, types, key and index shape, and the table name — never the
    /// BASIC field names, which a program may rename freely without touching the
    /// database. DB2 shrinks this job: under opt-in, adding a field cannot
    /// change the schema by accident, so the checksum is not a safety net for
    /// ordinary editing. It earns its place for the changes that *are*
    /// deliberate and still dangerous — a `DATABASE NAME` edited in place, a
    /// field's type changed, a `DATABASE` marker removed.
    static func checksum(of mapping: BASICTableMapping) -> String {
        digest(shape(of: mapping))
    }

    /// A short, stable digest.
    ///
    /// FNV-1a rather than a hash from the standard library: `Hasher` is seeded
    /// per process, so a checksum written today would not match the same shape
    /// tomorrow — which for a value stored in a database is not a hash at all.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Now, as the ledger records it.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// One registered migration: a version step, and the BASIC function that does it.
///
/// Registered, never discovered by name (§1.5.1). A compiled program resolves
/// the functions a string could reach at *build* time, from a known set — so a
/// migration found by convention would run interpreted and silently do nothing
/// compiled, which is D12's most deniable failure. And a *named function* rather
/// than a closure: a BASIC closure captures by snapshot and its assignments do
/// not escape, so a closure migration would run and discard its work.
struct BASICMigration: Equatable, Sendable {
    let className: String
    let fromVersion: Int
    let toVersion: Int
    let functionName: String
}
