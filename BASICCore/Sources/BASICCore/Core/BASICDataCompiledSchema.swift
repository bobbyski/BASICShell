//
//  BASICDataCompiledSchema.swift
//  BASICCore
//
//  The declaration facts a compiled program carries so the ORM can map it.
//

import Foundation

/// What the compiler tells the ORM about a program's classes and enums.
///
/// A compiled program's classes are slot lists by the time it runs: the names,
/// the visibility, the `JSON` and `DATABASE` options and the `meta` entries
/// all lived in the front end. The ORM needs every one of them, and it must
/// reach exactly the same conclusion as it does for the interpreter — a table
/// that differed between the engines would be D12's failure in its most
/// expensive form, since the divergence would be in *stored data*.
///
/// So the compiler emits these facts as JSON, once per program, and this
/// reconstitutes the very ``BASICClassDefinition`` values the interpreter's
/// mapper reads. There is one mapper; this is its second front end.
///
/// The format, which ``BASICDataCompiledSchema`` and the compiler's emitter
/// are the two ends of:
///
/// ```json
/// {
///   "classes": [{
///     "name": "Customer",
///     "fields": [{
///       "name": "Id", "vis": "PUBLIC", "type": {"k": "integer"},
///       "db": {"name": "Id", "key": true},
///       "json": "id",
///       "meta": {"version": {"n": 3}}
///     }]
///   }],
///   "enums": [{"name": "Status", "cases": [{"name": "Pending", "value": 0}]}]
/// }
/// ```
///
/// Absent keys mean absent annotations, which is the same thing they mean in
/// the source: a field with no `"db"` is a field with no `DATABASE` marker.
struct BASICDataCompiledSchema {
    private(set) var classes: [String: BASICClassDefinition] = [:]
    private(set) var enums: [String: BASICEnumDefinition] = [:]

    init() {}

    /// Reads a schema from the compiler's JSON.
    init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BASICDataError.driver("The compiled program's database schema is not readable JSON")
        }
        for entry in object["enums"] as? [[String: Any]] ?? [] {
            let definition = try Self.enumeration(entry)
            enums[definition.normalizedName] = definition
        }
        for entry in object["classes"] as? [[String: Any]] ?? [] {
            let definition = try Self.classDefinition(entry)
            classes[definition.normalizedName] = definition
        }
    }

    /// Takes another schema's declarations, newer winning.
    ///
    /// A program registers once, but a test process runs several programs, and
    /// the bridge holds one runtime for the life of the process (the same
    /// reason the Rich bridge does). Replacing per name rather than resetting
    /// means a second program's `Customer` is the one in force without
    /// forgetting a first program's still-open handles.
    mutating func merge(_ other: BASICDataCompiledSchema) {
        classes.merge(other.classes) { _, new in new }
        enums.merge(other.enums) { _, new in new }
    }

    func definition(named name: String) -> BASICClassDefinition? {
        classes[name.uppercased()]
    }

    func enumeration(named name: String) -> BASICEnumDefinition? {
        enums[name.uppercased()]
    }

    // MARK: - Reading

    private static func enumeration(_ object: [String: Any]) throws -> BASICEnumDefinition {
        guard let name = object["name"] as? String else {
            throw BASICDataError.driver("An ENUM in the compiled schema has no name")
        }
        var members: [(name: String, value: Int)] = []
        for (index, entry) in (object["cases"] as? [[String: Any]] ?? []).enumerated() {
            guard let caseName = entry["name"] as? String else {
                throw BASICDataError.driver("A case of ENUM \(name) has no name")
            }
            members.append((caseName, (entry["value"] as? Int) ?? index))
        }
        return BASICEnumDefinition(
            displayName: name,
            normalizedName: name.uppercased(),
            members: members
        )
    }

    private static func classDefinition(_ object: [String: Any]) throws -> BASICClassDefinition {
        guard let name = object["name"] as? String else {
            throw BASICDataError.driver("A CLASS in the compiled schema has no name")
        }
        let fields = try (object["fields"] as? [[String: Any]] ?? []).map {
            try field($0, of: name)
        }
        return BASICClassDefinition(
            displayName: name,
            normalizedName: name.uppercased(),
            baseClassName: object["base"] as? String,
            fields: fields,
            implementedInterfaces: [],
            // The mapper reads fields; a method is not a column. A compiled
            // program's bodies are machine code and could not be listed here
            // in any case.
            methods: [:]
        )
    }

    private static func field(_ object: [String: Any], of className: String) throws -> BASICClassField {
        guard let name = object["name"] as? String else {
            throw BASICDataError.driver("A field of CLASS \(className) has no name")
        }
        var database: BASICDatabaseFieldOptions?
        if let options = object["db"] as? [String: Any] {
            database = BASICDatabaseFieldOptions(
                name: (options["name"] as? String) ?? name,
                isKey: (options["key"] as? Bool) ?? false,
                isIndexed: (options["index"] as? Bool) ?? false,
                isUnique: (options["unique"] as? Bool) ?? false
            )
        }
        return BASICClassField(
            displayName: name,
            normalizedName: name.uppercased(),
            type: type(object["type"] as? [String: Any] ?? [:]),
            arrayDimensions: (object["dims"] as? Int).map { Array(repeating: nil, count: $0) } ?? [],
            visibility: BASICMemberVisibility(rawValue: (object["vis"] as? String) ?? "PUBLIC") ?? .public,
            declaringClassName: (object["owner"] as? String) ?? className,
            json: (object["json"] as? String).map(BASICJSONFieldOptions.init(name:)),
            database: database,
            metadata: (object["meta"] as? [String: [String: Any]] ?? [:]).compactMapValues(literal),
            // A default is what an instance starts as; by the time a value
            // reaches the ORM it has one already.
            defaultValue: nil
        )
    }

    private static func type(_ object: [String: Any]) -> BASICType {
        switch (object["k"] as? String) ?? "variant" {
        case "integer": return .scalar(.integer)
        case "number", "double": return .scalar(.double)
        case "string": return .scalar(.string)
        case "boolean": return .scalar(.boolean)
        case "dictionary": return .dictionary
        case "enum": return .enumType((object["n"] as? String) ?? "")
        case "class": return .classType((object["n"] as? String) ?? "")
        case "record": return .record((object["n"] as? String) ?? "")
        default: return .scalar(.variant)
        }
    }

    private static func literal(_ object: [String: Any]) -> BASICValue? {
        if let number = object["n"] as? Double { return .number(number) }
        if let number = object["n"] as? Int { return .number(Double(number)) }
        if let text = object["s"] as? String { return .string(BASICString(text)) }
        if let flag = object["b"] as? Bool { return .boolean(flag) }
        if object["null"] != nil { return .null }
        return nil
    }
}
