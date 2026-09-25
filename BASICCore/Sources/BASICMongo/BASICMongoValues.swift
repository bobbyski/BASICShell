//
//  BASICMongoValues.swift
//  BASICMongo
//
//  BSON on one side, BASIC's boundary values on the other.
//

import BASICCore
import Foundation
import MongoKitten

extension BASICMongoProvider {

    /// Makes this driver available to the process (DB11).
    ///
    /// Called by a host that wants Mongo. Until it is, a program naming a
    /// `mongodb://` URL is told no provider recognizes it — which names the
    /// connection string and points at a *driver*, a thing an operator can add.
    public static func register() {
        BASICDataProviders.register(document: BASICDataProviders.Registration(
            providerName: providerName,
            handles: { handles($0) },
            make: { BASICMongoProvider() }
        ))
    }

    // MARK: - Out

    static func bson(_ document: BASICDocument) -> Document {
        var bson = Document()
        for (key, value) in document.pairs {
            bson[key] = primitive(value)
        }
        return bson
    }

    static func primitive(_ value: BASICDocumentValue) -> Primitive {
        switch value {
        case .scalar(let scalar): return primitive(scalar)
        case .document(let nested): return bson(nested)
        case .array(let items):
            var array = Document(isArray: true)
            for item in items { array.append(primitive(item)) }
            return array
        }
    }

    static func primitive(_ value: BASICDataValue) -> Primitive {
        switch value {
        case .null: return BSON.Null()
        case .integer(let number): return Int(number)
        case .double(let number): return number
        case .boolean(let flag): return flag
        case .text(let text): return text
        case .blob(let data): return Binary(buffer: .init(data: data))
        // DB19's four cross as text, not as BSON's own date: a `DATE` has no
        // time and BSON's has no way to say so, and a `DECIMAL` written as a
        // double would lose the exactness it exists for. Read back by the same
        // rule, so what goes in comes out.
        case .decimal(let number): return "\(number)"
        case .date(let date): return date.description
        case .time(let time): return time.description
        case .timestamp(let stamp): return stamp.description
        }
    }

    // MARK: - In

    static func document(_ bson: Document) -> BASICDocument {
        var document = BASICDocument()
        for pair in bson.pairs {
            document[pair.key] = documentValue(pair.value)
        }
        return document
    }

    static func documentValue(_ primitive: Primitive) -> BASICDocumentValue {
        if let nested = primitive as? Document {
            return nested.isArray
                ? .array(nested.values.map(documentValue))
                : .document(document(nested))
        }
        return .scalar(value(primitive) ?? .null)
    }

    static func value(_ primitive: Primitive?) -> BASICDataValue? {
        switch primitive {
        case let text as String: return .text(text)
        case let number as Int: return .integer(Int64(number))
        case let number as Int32: return .integer(Int64(number))
        case let number as Int64: return .integer(number)
        case let number as Double: return .double(number)
        case let flag as Bool: return .boolean(flag)
        case let identifier as ObjectId: return .text(identifier.hexString)
        case let binary as Binary: return .blob(binary.data)
        case let date as Foundation.Date:
            // A BSON date is an instant; BASIC's timestamp is what it becomes.
            let parts = Calendar(identifier: .gregorian).dateComponents(
                in: TimeZone(identifier: "UTC")!, from: date
            )
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
                return .null
            }
            return .timestamp(BASICDataTimestamp(
                date: BASICDataDate(year: year, month: month, day: day),
                time: BASICDataTime(hour: hour, minute: minute, second: second),
                utcOffsetMinutes: 0
            ))
        case is BSON.Null: return BASICDataValue.null
        case .none: return nil
        default: return .text("\(primitive!)")
        }
    }

    // MARK: - Filters

    /// A predicate as a Mongo query.
    ///
    /// **Built, never parsed.** DB15's whole point on this side: a filter
    /// assembled from a program-supplied *string* is how `$gt`, `$ne` and
    /// `$where` get in, so the predicate tree is walked and each operator is
    /// written here by name.
    static func query(_ predicate: BASICQueryPredicate) throws -> Document {
        switch predicate {
        case .all:
            return Document()
        case .and(let parts):
            guard !parts.isEmpty else { return Document() }
            return try ["$and": operands(parts)]
        case .or(let parts):
            guard !parts.isEmpty else { return Document() }
            return try ["$or": operands(parts)]
        case .not(let inner):
            return try ["$nor": [query(inner)] as Document]
        case .compare(let field, let op, let operand):
            return try comparison(field: field, op: op, operand: operand)
        }
    }

    private static func operands(_ parts: [BASICQueryPredicate]) throws -> Document {
        var array = Document(isArray: true)
        for part in parts { array.append(try query(part)) }
        return array
    }

    private static func comparison(
        field: String,
        op: BASICPredicateOperator,
        operand: BASICPredicateOperand
    ) throws -> Document {
        func refuse() -> BASICDataError {
            .unsupportedOperator(op, provider: BASICMongoProvider.providerName)
        }
        switch operand {
        case .value(let value):
            let primitive = primitive(value)
            switch op {
            case .equal: return [field: primitive]
            case .notEqual: return [field: ["$ne": primitive] as Document]
            case .lessThan: return [field: ["$lt": primitive] as Document]
            case .lessThanOrEqual: return [field: ["$lte": primitive] as Document]
            case .greaterThan: return [field: ["$gt": primitive] as Document]
            case .greaterThanOrEqual: return [field: ["$gte": primitive] as Document]
            case .beginsWith, .endsWith, .contains, .like:
                guard case .text(let text) = value else { throw refuse() }
                return [field: ["$regex": pattern(for: op, text), "$options": ""] as Document]
            // §7.1 declines MATCHES in `capabilities`, so the predicate is
            // refused where it is built rather than translated into a regular
            // expression the program did not write.
            case .matches: throw refuse()
            default: throw refuse()
            }
        case .list(let values):
            guard op == .in else { throw refuse() }
            var array = Document(isArray: true)
            for value in values { array.append(primitive(value)) }
            return [field: ["$in": array] as Document]
        case .range(let lower, let upper):
            guard op == .between else { throw refuse() }
            return [field: ["$gte": primitive(lower), "$lte": primitive(upper)] as Document]
        }
    }

    /// The regular expression a text operator becomes, with the program's text
    /// escaped — it is data, never pattern syntax.
    private static func pattern(for op: BASICPredicateOperator, _ text: String) -> String {
        let escaped = text.map { character -> String in
            "\\^$.|?*+()[]{}".contains(character) ? "\\\(character)" : String(character)
        }.joined()
        switch op {
        case .beginsWith: return "^" + escaped
        case .endsWith: return escaped + "$"
        case .like:
            // SQL's wildcards, translated: `%` is any run, `_` is one.
            let translated = escaped
                .replacingOccurrences(of: "%", with: ".*")
                .replacingOccurrences(of: "_", with: ".")
            return "^" + translated + "$"
        default: return escaped
        }
    }
}
