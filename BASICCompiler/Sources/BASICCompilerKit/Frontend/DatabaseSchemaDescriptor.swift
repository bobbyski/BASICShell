import BASICSyntax
import Foundation

// The declaration facts the ORM needs, as JSON, for a compiled program.
//
// A compiled CLASS is a slot list: the names as written, the visibility, the
// `JSON` and `DATABASE` options and the `meta { … }` entries were all front-end
// knowledge, and a program running as machine code has no session to ask. The
// ORM needs every one of them, and — D12 — it must reach the same conclusion
// it reaches for the interpreter, because a table that differed between the
// engines would be a divergence in *stored data*.
//
// So the mapper is not reimplemented here. The declaration is described, once,
// and BASICCore's `BASICDataCompiledSchema` reads it back into the very
// definitions the interpreter's mapper reads. One mapper, two front ends.

enum DatabaseSchemaDescriptor {

    /// The schema for a program, or nil when it declares no class the ORM
    /// could map.
    ///
    /// Every class is described, not just the ones with `DATABASE` markers:
    /// tiers 1 and 0 of §3.1 persist a class that carries no marker at all, so
    /// "has an annotation" is not the test for "could be a table".
    static func json(for model: SemanticModel) -> String? {
        var classes: [[String: Any]] = []
        for name in model.typeOrder {
            guard let type = model.types[name], type.kind == .classType else { continue }
            classes.append([
                "name": type.displayName,
                "base": type.base.flatMap { model.types[$0]?.displayName } as Any? ?? NSNull(),
                "fields": model.allFields(of: name).map { field($0, model: model) },
            ])
        }
        guard !classes.isEmpty else { return nil }

        // Every ENUM, because §7.3 stores a case's *name*: the runtime has
        // nothing left that knows `1` is `Shipped` — a payload-free ENUM
        // lowers to a number — so the table has to travel with the program.
        let enums = model.enums.values.map { enumeration -> [String: Any] in
            [
                "name": enumeration.displayName,
                "cases": enumeration.members.map { ["name": $0.name, "value": $0.value] },
            ]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        let object: [String: Any] = ["classes": classes, "enums": enums]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func field(_ field: SemanticModel.Field, model: SemanticModel) -> [String: Any] {
        var object: [String: Any] = [
            "name": field.displayName,
            "vis": field.visibility.rawValue,
            "type": typeObject(field, model: model),
        ]
        if !field.dimensions.isEmpty { object["dims"] = field.dimensions.count }
        if field.owner != "" { object["owner"] = field.owner }
        if let json = field.jsonName { object["json"] = json }
        if let database = field.database {
            var options: [String: Any] = ["name": database.name]
            if database.isKey { options["key"] = true }
            if database.isIndexed { options["index"] = true }
            if database.isUnique { options["unique"] = true }
            object["db"] = options
        }
        if !field.metadata.isEmpty { object["meta"] = field.metadata.mapValues(literal) }
        return object
    }

    private static func typeObject(_ field: SemanticModel.Field, model: SemanticModel) -> [String: Any] {
        // An ENUM-typed field is a number in BIR (E1), so the declaration is
        // the only thing left that knows which table names its cases.
        if let enumName = field.enumName {
            let display = model.enums[enumName.uppercased()]?.displayName ?? enumName
            return ["k": "enum", "n": display]
        }
        switch field.type {
        case .number: return ["k": field.isInteger ? "integer" : "number"]
        case .string: return ["k": "string"]
        case .boolean: return ["k": "boolean"]
        case .dictionary: return ["k": "dictionary"]
        case .composite(let name):
            // Described as what it is so the mapper refuses it by name; an
            // embedded record is a v1 non-goal, not a silent column.
            return ["k": "record", "n": model.types[name]?.displayName ?? name]
        case .array(let element, _):
            var inner: [String: Any] = ["k": "array"]
            inner["of"] = element.name
            return inner
        default: return ["k": "variant"]
        }
    }

    private static func literal(_ value: BIRDefault) -> [String: Any] {
        switch value {
        case .number(let value): return ["n": value]
        case .string(let value): return ["s": value]
        case .boolean(let value): return ["b": value]
        case .null: return ["null": true]
        case .empty: return ["empty": true]
        }
    }
}
