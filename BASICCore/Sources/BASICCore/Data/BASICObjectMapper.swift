import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Which tier of §3.1 decided a class's shape.
enum BASICMappingTier: String, Equatable, Sendable {
    /// `DATABASE` markers said so.
    case explicit
    /// No `DATABASE` markers, but `JSON` ones, so the Codable shape is used.
    case codable
    /// Neither, so every public field of a storable type is persisted.
    case everything
}

/// One field of a class, and the column it becomes.
struct BASICColumnMapping: Equatable, Sendable {
    /// The field name as the class writes it.
    let fieldName: String
    /// Its normalized (uppercased) form, for lookup.
    let normalizedFieldName: String
    /// The column or document field it maps to.
    let columnName: String
    /// The declared BASIC type.
    let basicType: BASICType
    /// The logical column type.
    let columnType: BASICColumnType
    /// Whether this is the primary key.
    let isKey: Bool
    /// Whether the database fills it in.
    let isGenerated: Bool
    /// The `ENUM` this column holds the case name of, when it holds one.
    let enumName: String?
}

/// A class, and the table or collection it maps to.
struct BASICTableMapping: Equatable, Sendable {
    /// The class name as written.
    let className: String
    /// The table or collection name.
    let tableName: String
    /// The columns, in declaration order.
    let columns: [BASICColumnMapping]
    /// The schema this mapping asks a provider for.
    let schema: BASICTableSchema
    /// Which tier decided it (§3.1), for `Describe` and for diagnostics.
    let tier: BASICMappingTier
    /// The declared schema version. A class with no `version` is version 0 (DB5).
    let version: Int
    /// Every field the class has that is *not* stored, at its default.
    ///
    /// An object that comes back from `Load` has to be a whole instance of its
    /// class, not just the part that was in the table: a program that reads
    /// `customer.Scratch` after loading is reading a field of its own class,
    /// and finding it missing is not an answer. The compiled engine fills a
    /// typed slot with its default whether it is told to or not, so this is
    /// also what keeps the two engines agreeing (D12).
    let unstoredFields: [String: BASICValue]

    /// The primary-key column, when there is one.
    var keyColumn: BASICColumnMapping? { columns.first(where: \.isKey) }

    /// Looks a column up by the BASIC field name, case-insensitively.
    func column(forField name: String) -> BASICColumnMapping? {
        let normalized = name.uppercased()
        return columns.first { $0.normalizedFieldName == normalized }
    }
}

/// Turns a `CLASS` into a table, and its instances into rows.
///
/// The mapper is Swift, in `BASICCore`, reading `BASICClassDefinition`
/// directly — so it needs no new BASIC-visible reflection, and it is one
/// implementation for every engine rather than three.
enum BASICObjectMapper {

    /// Builds a mapping for a class.
    ///
    /// Tier resolution is one rule applied per class, most specific wins
    /// (§3.1):
    ///
    /// ```
    /// any DATABASE markers?   -> those fields, those names, that key
    /// else any JSON markers?  -> the JSON fields, the JSON names
    /// else                    -> every public field of a storable type
    /// ```
    ///
    /// So the tiers are not three code paths. They are one mapper with a
    /// fallback chain, and a class moves up a tier by gaining annotations —
    /// never by changing how it is saved.
    static func map(
        _ definition: BASICClassDefinition,
        tableName: String? = nil,
        enumeration: (String) -> BASICEnumDefinition? = { _ in nil }
    ) throws -> BASICTableMapping {
        // Most specific wins: an explicit argument (an importer or a test), then
        // what the class itself said with `DATABASE NAME` (DB26), then the class
        // name — which is right nearly always and is why it is the default.
        let table = tableName ?? definition.databaseTableName ?? definition.displayName
        try BASICSQLIdentifier.validated(table, describing: "table for CLASS \(definition.displayName)")

        let tier: BASICMappingTier
        let chosen: [(field: BASICClassField, columnName: String, isKey: Bool, indexed: Bool, unique: Bool)]

        if definition.fields.contains(where: { $0.database != nil }) {
            tier = .explicit
            chosen = definition.fields.compactMap { field in
                guard let options = field.database else { return nil }
                return (field, options.name, options.isKey, options.isIndexed, options.isUnique)
            }
        } else if definition.fields.contains(where: { $0.json != nil }) {
            tier = .codable
            chosen = definition.fields.compactMap { field in
                guard let json = field.json else { return nil }
                return (field, json.name, false, false, false)
            }
        } else {
            tier = .everything
            chosen = definition.fields
                .filter { $0.visibility == .public }
                .map { ($0, $0.displayName, false, false, false) }
        }

        guard !chosen.isEmpty else {
            throw BASICDataError.unsupported(
                "CLASS \(definition.displayName) has no persistable fields"
            )
        }

        var columns: [BASICColumnMapping] = []
        var schemaColumns: [BASICColumnSchema] = []
        var indexes: [BASICIndexSchema] = []

        // DB4: a field named Id is the key by convention when none is marked.
        let markedKey = chosen.first(where: \.isKey)?.field.normalizedName
        let conventionKey = markedKey == nil
            ? chosen.first(where: { $0.field.normalizedName == "ID" })?.field.normalizedName
            : nil

        for entry in chosen {
            let field = entry.field
            guard field.arrayDimensions.isEmpty else {
                throw BASICDataError.unsupported(
                    "\(definition.displayName).\(field.displayName) is an array; arrays are not persisted in v1"
                )
            }
            try BASICSQLIdentifier.validated(
                entry.columnName,
                describing: "\(definition.displayName).\(field.displayName)"
            )

            let isKey = entry.isKey || field.normalizedName == conventionKey
            let (columnType, enumName) = try columnType(
                for: field,
                in: definition.displayName,
                enumeration: enumeration
            )
            // SQLite only fills in an integer key; anything else the program
            // supplies itself.
            let isGenerated = isKey && columnType == .integer

            columns.append(BASICColumnMapping(
                fieldName: field.displayName,
                normalizedFieldName: field.normalizedName,
                columnName: entry.columnName,
                // The resolved type, not the declared spelling. The
                // interpreter's parser writes an unresolved name as
                // `.record(name)` and the compiler's front end knows it is an
                // ENUM, so the same class would otherwise map to two mappings
                // that differ in this one label — which is exactly the
                // difference a D12 parity test should not have to forgive.
                basicType: enumName.map(BASICType.enumType) ?? field.type,
                columnType: columnType,
                isKey: isKey,
                isGenerated: isGenerated,
                enumName: enumName
            ))
            schemaColumns.append(BASICColumnSchema(
                name: entry.columnName,
                type: columnType,
                isNullable: !isKey,
                isPrimaryKey: isKey,
                isGenerated: isGenerated,
                enumeratedNames: enumName.flatMap { enumeration($0)?.members.map(\.name) }
            ))
            if entry.indexed && !isKey {
                indexes.append(BASICIndexSchema(
                    name: "ix_\(table)_\(entry.columnName)",
                    columns: [entry.columnName],
                    isUnique: entry.unique
                ))
            }
        }

        let stored = Set(columns.map(\.normalizedFieldName))
        let unstored = definition.fields.filter { !stored.contains($0.normalizedName) }
        return BASICTableMapping(
            className: definition.displayName,
            tableName: table,
            columns: columns,
            schema: BASICTableSchema(name: table, columns: schemaColumns, indexes: indexes),
            tier: tier,
            version: version(of: definition),
            unstoredFields: Dictionary(uniqueKeysWithValues: unstored.map {
                ($0.normalizedName, defaultValue(of: $0))
            })
        )
    }

    /// A field's value when nothing has been stored in it.
    ///
    /// Scalars get the value their type starts at, which is what the
    /// interpreter and a compiled slot both start them at. Anything else gets
    /// `EMPTY` — never set, said out loud — because a field the ORM refused to
    /// store is precisely one this has no shape for.
    private static func defaultValue(of field: BASICClassField) -> BASICValue {
        guard field.arrayDimensions.isEmpty else { return .empty }
        if let declared = field.defaultValue { return declared }
        switch field.type {
        case .scalar(.string): return .string(BASICString(""))
        case .scalar(.boolean): return .boolean(false)
        case .scalar(.integer), .scalar(.double): return .number(0)
        // A payload-free ENUM is its number, and zero usually names its first
        // member — VB's rule, and the interpreter's.
        case .enumType: return .number(0)
        case .dictionary: return .dictionary(BASICDictionary())
        default: return .empty
        }
    }

    /// A class with no `version` metadata is version 0 (DB5).
    ///
    /// So the first migration a program ever writes is 0 to 1, and an
    /// unversioned class is a legitimate starting state rather than an error.
    static func version(of definition: BASICClassDefinition) -> Int {
        for field in definition.fields {
            if case .number(let value)? = field.metadata["version"] { return Int(value) }
        }
        return 0
    }

    private static func columnType(
        for field: BASICClassField,
        in className: String,
        enumeration: (String) -> BASICEnumDefinition?
    ) throws -> (BASICColumnType, String?) {
        func refuse(_ reason: String) -> BASICDataError {
            .unsupported("\(className).\(field.displayName) \(reason)")
        }

        switch field.type {
        case .scalar(.integer):
            return (.integer, nil)
        case .scalar(.double):
            return (.double, nil)
        case .scalar(.string):
            return (.text(maximumLength: nil), nil)
        case .scalar(.boolean):
            // DB24: written as the narrowest integer the dialect has.
            return (.boolean, nil)
        // The parser writes an unresolved type name as `.record`, because at
        // parse time it cannot know whether Status is an ENUM, a RECORD or a
        // CLASS. So the mapper resolves it the way the runtime does, rather
        // than reading a declared ENUM as an embedded record.
        case .enumType(let name), .record(let name) where enumeration(name) != nil:
            guard let definition = enumeration(name) else {
                throw refuse("is declared \(name), which is not a known ENUM")
            }
            guard !definition.isPayload else {
                // §7.3: a payload ENUM is a tagged union — discriminator plus
                // prefixed columns. Refused by name until that lands, rather
                // than stored as something that loses its payload.
                throw refuse("is a payload ENUM; those are not persisted in v1")
            }
            // §7.3: the case *name*, not the ordinal, because inserting a case
            // renumbers every later one and would silently reinterpret data.
            return (.text(maximumLength: nil), name)
        case .scalar(.variant):
            throw refuse("is a VARIANT; a column needs a type the mapper can name")
        case .scalar(.task):
            throw refuse("is a TASK, which is not data")
        case .record(let name):
            throw refuse("is the RECORD \(name); embedded records are not persisted in v1")
        case .classType(let name):
            throw refuse("refers to CLASS \(name); relationships are not persisted in v1 (DB8)")
        case .interfaceType(let name):
            throw refuse("is the INTERFACE \(name), which has no storage shape")
        case .functionType(let name):
            throw refuse("is the function type \(name), which is not data")
        case .dictionary:
            throw refuse("is a DICTIONARY; those are not persisted in v1")
        case .void:
            throw refuse("has no type")
        }
    }
}

// MARK: - Values

extension BASICTableMapping {
    /// Converts an object's fields into a row the provider can bind.
    func row(
        from value: BASICValue,
        includingKey: Bool = true,
        enumeration: (String) -> BASICEnumDefinition? = { _ in nil }
    ) throws -> [(column: String, value: BASICDataValue)] {
        guard case .object(_, let fields) = value else {
            throw BASICDataError.unsupported("Expected an object of CLASS \(className)")
        }
        var row: [(column: String, value: BASICDataValue)] = []
        for column in columns {
            if !includingKey && column.isKey && column.isGenerated { continue }
            let field = fields[column.normalizedFieldName] ?? .empty
            row.append((column.columnName, try Self.dataValue(field, for: column, enumeration: enumeration)))
        }
        return row
    }

    /// Converts a row back into an object's fields.
    func fields(
        from row: [String: BASICDataValue],
        enumeration: (String) -> BASICEnumDefinition? = { _ in nil }
    ) throws -> [String: BASICValue] {
        // Seeded with the fields the table does not hold, so what comes back
        // is a whole instance of the class rather than the stored part of one.
        var fields = unstoredFields
        for column in columns {
            let stored = row[column.columnName] ?? .null
            fields[column.normalizedFieldName] = try Self.basicValue(stored, for: column, enumeration: enumeration)
        }
        return fields
    }

    /// One BASIC value, as the column holds it.
    static func dataValue(
        _ value: BASICValue,
        for column: BASICColumnMapping,
        enumeration: (String) -> BASICEnumDefinition? = { _ in nil }
    ) throws -> BASICDataValue {
        switch value {
        case .empty, .null:
            return .null
        case .boolean(let flag):
            return .boolean(flag)
        case .string(let text):
            return .text(text.description)
        case .number(let number):
            if let enumName = column.enumName {
                // §7.3: a payload-free ENUM *is* its number, so the name has
                // to be looked up in the declaring type — which is exactly how
                // PRINT resolves it, and why storing the ordinal would tie the
                // data to the declaration order.
                guard let definition = enumeration(enumName),
                      let member = definition.members.first(where: { $0.value == Int(number) }) else {
                    throw BASICDataError.typeMismatch(
                        column: column.columnName,
                        expected: "a case of \(enumName)",
                        found: "\(Int(number))"
                    )
                }
                return .text(member.name)
            }
            if column.columnType == .integer { return .integer(Int64(number)) }
            if case .decimal = column.columnType { return .decimal(Decimal(number)) }
            return .double(number)
        default:
            throw BASICDataError.typeMismatch(
                column: column.columnName,
                expected: column.columnName,
                found: value.description
            )
        }
    }

    /// One stored value, as the field holds it.
    static func basicValue(
        _ value: BASICDataValue,
        for column: BASICColumnMapping,
        enumeration: (String) -> BASICEnumDefinition? = { _ in nil }
    ) throws -> BASICValue {
        if value.isNull { return .empty }

        if let enumName = column.enumName {
            guard case .text(let caseName) = value else {
                throw BASICDataError.typeMismatch(
                    column: column.columnName, expected: "a case name of \(enumName)", found: "\(value)"
                )
            }
            guard let definition = enumeration(enumName),
                  let member = definition.members.first(where: {
                      $0.name.caseInsensitiveCompare(caseName) == .orderedSame
                  }) else {
                throw BASICDataError.typeMismatch(
                    column: column.columnName, expected: "a case of \(enumName)", found: caseName
                )
            }
            return .number(Double(member.value))
        }

        switch column.basicType {
        case .scalar(.boolean):
            // §7.2: written one way, read from every spelling a real column
            // plausibly holds, because D6 imports schemas we did not write.
            guard let flag = value.booleanValue else {
                throw BASICDataError.typeMismatch(
                    column: column.columnName, expected: "a boolean", found: "\(value)"
                )
            }
            return .boolean(flag)
        case .scalar(.string):
            if case .text(let text) = value { return .string(BASICString(text)) }
            return .string(BASICString(Self.text(of: value)))
        default:
            switch value {
            case .integer(let number): return .number(Double(number))
            case .double(let number): return .number(number)
            case .decimal(let number): return .number(NSDecimalNumber(decimal: number).doubleValue)
            case .boolean(let flag): return .number(flag ? 1 : 0)
            case .text(let text):
                guard let number = Double(text) else {
                    throw BASICDataError.typeMismatch(
                        column: column.columnName, expected: "a number", found: text
                    )
                }
                return .number(number)
            default:
                throw BASICDataError.typeMismatch(
                    column: column.columnName, expected: "a number", found: "\(value)"
                )
            }
        }
    }

    private static func text(of value: BASICDataValue) -> String {
        switch value {
        case .text(let text): return text
        case .integer(let number): return "\(number)"
        case .double(let number): return "\(number)"
        case .decimal(let number): return "\(number)"
        case .boolean(let flag): return flag ? "1" : "0"
        case .date(let date): return date.description
        case .time(let time): return time.description
        case .timestamp(let stamp): return stamp.description
        case .blob(let data): return data.base64EncodedString()
        case .null: return ""
        }
    }
}
