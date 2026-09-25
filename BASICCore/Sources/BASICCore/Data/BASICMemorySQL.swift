import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A value a statement carries: a bound parameter, or a literal written inline.
enum MemorySQLTerm: Equatable {
    /// `?` — the nth bound parameter (DB15: values are never interpolated).
    case placeholder(Int)
    /// A literal the statement itself wrote.
    case literal(BASICDataValue)

    func bound(_ parameters: [BASICDataValue]) throws -> BASICDataValue {
        switch self {
        case .literal(let value):
            return value
        case .placeholder(let index):
            guard index < parameters.count else {
                throw BASICDataError.driver("Statement wants parameter \(index + 1); \(parameters.count) supplied")
            }
            return parameters[index]
        }
    }
}

/// The right-hand side of a comparison, before parameters are bound.
enum MemorySQLOperand: Equatable {
    case term(MemorySQLTerm)
    case list([MemorySQLTerm])
    case range(MemorySQLTerm, MemorySQLTerm)

    func bound(_ parameters: [BASICDataValue]) throws -> BASICPredicateOperand {
        switch self {
        case .term(let term):
            return .value(try term.bound(parameters))
        case .list(let terms):
            return .list(try terms.map { try $0.bound(parameters) })
        case .range(let low, let high):
            return .range(try low.bound(parameters), try high.bound(parameters))
        }
    }
}

/// A `WHERE` clause parsed but not yet bound.
///
/// Separate from `BASICQueryPredicate` for one reason: `prepare` happens before
/// the parameters exist, so the tree has to hold placeholders until `execute`
/// supplies them. Binding turns it into the shared predicate the evaluator and
/// every other provider already understand.
indirect enum MemorySQLCondition: Equatable {
    case all
    case compare(field: String, op: BASICPredicateOperator, operand: MemorySQLOperand)
    case and([MemorySQLCondition])
    case or([MemorySQLCondition])
    case not(MemorySQLCondition)

    func bound(_ parameters: [BASICDataValue]) throws -> BASICQueryPredicate {
        switch self {
        case .all:
            return .all
        case .compare(let field, let op, let operand):
            return .compare(field: field, op: op, operand: try operand.bound(parameters))
        case .and(let children):
            return .and(try children.map { try $0.bound(parameters) })
        case .or(let children):
            return .or(try children.map { try $0.bound(parameters) })
        case .not(let child):
            return .not(try child.bound(parameters))
        }
    }
}

/// One statement the reference provider understands.
enum MemorySQLStatement: Equatable {
    case insert(table: String, columns: [String], values: [MemorySQLTerm], returning: [String])
    case update(table: String, assignments: [(column: String, term: MemorySQLTerm)], condition: MemorySQLCondition)
    case delete(table: String, condition: MemorySQLCondition)
    case select(columns: [String]?, table: String, condition: MemorySQLCondition, orderBy: [(column: String, ascending: Bool)], limit: Int?)

    static func == (lhs: MemorySQLStatement, rhs: MemorySQLStatement) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }

    var table: String {
        switch self {
        case .insert(let table, _, _, _), .update(let table, _, _),
             .delete(let table, _), .select(_, let table, _, _, _):
            return table
        }
    }

    var isQuery: Bool {
        switch self {
        case .select: return true
        case .insert(_, _, _, let returning): return !returning.isEmpty
        default: return false
        }
    }
}

/// A deliberately small SQL parser: exactly the statement shapes the ORM emits.
///
/// The reference provider is a *conformance*, not a database. Anything outside
/// this grammar is refused by name rather than half-understood — which is also
/// what keeps the provider honest about being a reference.
struct MemorySQLParser {
    private enum Token: Equatable {
        case word(String)
        case string(String)
        case number(String)
        case symbol(String)
        case placeholder
    }

    private var tokens: [Token] = []
    private var position = 0
    private var placeholderCount = 0

    static func parse(_ sql: String) throws -> MemorySQLStatement {
        var parser = MemorySQLParser()
        parser.tokens = try MemorySQLParser.tokenize(sql)
        let statement = try parser.parseStatement(sql)
        // Every token must be consumed. Without this the parser reads
        // `select Name from Customer join Orders on 1 = 1` as the select and
        // silently drops the join — a statement half-understood rather than
        // refused, which is the one thing a reference provider must not do.
        _ = parser.matchSymbol(";")
        guard parser.position == parser.tokens.count else {
            throw parser.unsupported(sql, "unexpected text after the statement")
        }
        return statement
    }

    // MARK: - Tokenizer

    private static func tokenize(_ sql: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(sql)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "?" {
                tokens.append(.placeholder)
                index += 1
            } else if character == "'" {
                var value = ""
                index += 1
                while index < characters.count {
                    if characters[index] == "'" {
                        if index + 1 < characters.count && characters[index + 1] == "'" {
                            value.append("'")
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    value.append(characters[index])
                    index += 1
                }
                tokens.append(.string(value))
            } else if character == "\"" {
                var value = ""
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    value.append(characters[index])
                    index += 1
                }
                index += 1
                tokens.append(.word(value))
            } else if character.isNumber || (character == "-" && index + 1 < characters.count && characters[index + 1].isNumber) {
                var value = String(character)
                index += 1
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    value.append(characters[index])
                    index += 1
                }
                tokens.append(.number(value))
            } else if character.isLetter || character == "_" {
                var value = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    value.append(characters[index])
                    index += 1
                }
                tokens.append(.word(value))
            } else {
                let twoCharacter = index + 1 < characters.count ? String([character, characters[index + 1]]) : ""
                if ["<=", ">=", "<>", "!="].contains(twoCharacter) {
                    tokens.append(.symbol(twoCharacter))
                    index += 2
                } else {
                    tokens.append(.symbol(String(character)))
                    index += 1
                }
            }
        }
        return tokens
    }

    // MARK: - Cursor

    private var current: Token? { position < tokens.count ? tokens[position] : nil }

    private mutating func advance() -> Token? {
        guard position < tokens.count else { return nil }
        defer { position += 1 }
        return tokens[position]
    }

    private mutating func matchWord(_ word: String) -> Bool {
        guard case .word(let value)? = current, value.caseInsensitiveCompare(word) == .orderedSame else { return false }
        position += 1
        return true
    }

    private mutating func matchSymbol(_ symbol: String) -> Bool {
        guard case .symbol(let value)? = current, value == symbol else { return false }
        position += 1
        return true
    }

    private func peekWord(_ word: String) -> Bool {
        guard case .word(let value)? = current else { return false }
        return value.caseInsensitiveCompare(word) == .orderedSame
    }

    private mutating func expectWord(_ word: String, _ sql: String) throws {
        guard matchWord(word) else { throw unsupported(sql, "expected \(word)") }
    }

    private mutating func expectSymbol(_ symbol: String, _ sql: String) throws {
        guard matchSymbol(symbol) else { throw unsupported(sql, "expected \(symbol)") }
    }

    private mutating func identifier(_ sql: String) throws -> String {
        guard case .word(let value)? = advance() else { throw unsupported(sql, "expected a name") }
        return value
    }

    private func unsupported(_ sql: String, _ detail: String) -> BASICDataError {
        .unsupported("the reference provider cannot parse this statement (\(detail)): \(sql)")
    }

    // MARK: - Statements

    private mutating func parseStatement(_ sql: String) throws -> MemorySQLStatement {
        if matchWord("INSERT") { return try parseInsert(sql) }
        if matchWord("UPDATE") { return try parseUpdate(sql) }
        if matchWord("DELETE") { return try parseDelete(sql) }
        if matchWord("SELECT") { return try parseSelect(sql) }
        throw unsupported(sql, "unknown statement")
    }

    private mutating func parseInsert(_ sql: String) throws -> MemorySQLStatement {
        try expectWord("INTO", sql)
        let table = try identifier(sql)
        var columns: [String] = []
        try expectSymbol("(", sql)
        repeat {
            columns.append(try identifier(sql))
        } while matchSymbol(",")
        try expectSymbol(")", sql)
        try expectWord("VALUES", sql)
        try expectSymbol("(", sql)
        var values: [MemorySQLTerm] = []
        repeat {
            values.append(try parseTerm(sql))
        } while matchSymbol(",")
        try expectSymbol(")", sql)
        var returning: [String] = []
        if matchWord("RETURNING") {
            repeat {
                returning.append(try identifier(sql))
            } while matchSymbol(",")
        }
        guard columns.count == values.count else {
            throw unsupported(sql, "\(columns.count) columns but \(values.count) values")
        }
        return .insert(table: table, columns: columns, values: values, returning: returning)
    }

    private mutating func parseUpdate(_ sql: String) throws -> MemorySQLStatement {
        let table = try identifier(sql)
        try expectWord("SET", sql)
        var assignments: [(column: String, term: MemorySQLTerm)] = []
        repeat {
            let column = try identifier(sql)
            try expectSymbol("=", sql)
            assignments.append((column, try parseTerm(sql)))
        } while matchSymbol(",")
        let condition = try parseOptionalWhere(sql)
        return .update(table: table, assignments: assignments, condition: condition)
    }

    private mutating func parseDelete(_ sql: String) throws -> MemorySQLStatement {
        try expectWord("FROM", sql)
        let table = try identifier(sql)
        let condition = try parseOptionalWhere(sql)
        return .delete(table: table, condition: condition)
    }

    private mutating func parseSelect(_ sql: String) throws -> MemorySQLStatement {
        var columns: [String]? = nil
        if matchSymbol("*") {
            columns = nil
        } else {
            var named: [String] = []
            repeat {
                named.append(try identifier(sql))
            } while matchSymbol(",")
            columns = named
        }
        try expectWord("FROM", sql)
        let table = try identifier(sql)
        let condition = try parseOptionalWhere(sql)
        var orderBy: [(column: String, ascending: Bool)] = []
        if matchWord("ORDER") {
            try expectWord("BY", sql)
            repeat {
                let column = try identifier(sql)
                var ascending = true
                if matchWord("DESC") { ascending = false } else { _ = matchWord("ASC") }
                orderBy.append((column, ascending))
            } while matchSymbol(",")
        }
        var limit: Int?
        if matchWord("LIMIT") {
            guard case .number(let text)? = advance(), let value = Int(text) else {
                throw unsupported(sql, "LIMIT wants a number")
            }
            limit = value
        }
        return .select(columns: columns, table: table, condition: condition, orderBy: orderBy, limit: limit)
    }

    // MARK: - Conditions

    private mutating func parseOptionalWhere(_ sql: String) throws -> MemorySQLCondition {
        guard matchWord("WHERE") else { return .all }
        return try parseOr(sql)
    }

    private mutating func parseOr(_ sql: String) throws -> MemorySQLCondition {
        var children = [try parseAnd(sql)]
        while matchWord("OR") {
            children.append(try parseAnd(sql))
        }
        return children.count == 1 ? children[0] : .or(children)
    }

    private mutating func parseAnd(_ sql: String) throws -> MemorySQLCondition {
        var children = [try parseNot(sql)]
        while matchWord("AND") {
            children.append(try parseNot(sql))
        }
        return children.count == 1 ? children[0] : .and(children)
    }

    private mutating func parseNot(_ sql: String) throws -> MemorySQLCondition {
        if matchWord("NOT") { return .not(try parseNot(sql)) }
        if matchSymbol("(") {
            let inner = try parseOr(sql)
            try expectSymbol(")", sql)
            return inner
        }
        return try parseComparison(sql)
    }

    private mutating func parseComparison(_ sql: String) throws -> MemorySQLCondition {
        let field = try identifier(sql)

        if matchWord("IS") {
            let negated = matchWord("NOT")
            try expectWord("NULL", sql)
            return .compare(field: field, op: negated ? .notEqual : .equal, operand: .term(.literal(.null)))
        }
        if matchWord("IN") {
            try expectSymbol("(", sql)
            var terms: [MemorySQLTerm] = []
            repeat {
                terms.append(try parseTerm(sql))
            } while matchSymbol(",")
            try expectSymbol(")", sql)
            return .compare(field: field, op: .in, operand: .list(terms))
        }
        if matchWord("BETWEEN") {
            let low = try parseTerm(sql)
            try expectWord("AND", sql)
            let high = try parseTerm(sql)
            return .compare(field: field, op: .between, operand: .range(low, high))
        }
        if matchWord("LIKE") {
            return .compare(field: field, op: .like, operand: .term(try parseTerm(sql)))
        }

        let op: BASICPredicateOperator
        if matchSymbol("=") { op = .equal }
        else if matchSymbol("<>") || matchSymbol("!=") { op = .notEqual }
        else if matchSymbol("<=") { op = .lessThanOrEqual }
        else if matchSymbol(">=") { op = .greaterThanOrEqual }
        else if matchSymbol("<") { op = .lessThan }
        else if matchSymbol(">") { op = .greaterThan }
        else { throw unsupported(sql, "unknown comparison after \(field)") }

        return .compare(field: field, op: op, operand: .term(try parseTerm(sql)))
    }

    private mutating func parseTerm(_ sql: String) throws -> MemorySQLTerm {
        switch advance() {
        case .placeholder:
            defer { placeholderCount += 1 }
            return .placeholder(placeholderCount)
        case .string(let value):
            return .literal(.text(value))
        case .number(let value):
            if value.contains(".") {
                guard let number = Double(value) else { throw unsupported(sql, "bad number \(value)") }
                return .literal(.double(number))
            }
            guard let number = Int64(value) else { throw unsupported(sql, "bad number \(value)") }
            return .literal(.integer(number))
        case .word(let value) where value.caseInsensitiveCompare("NULL") == .orderedSame:
            return .literal(.null)
        case .word(let value) where value.caseInsensitiveCompare("TRUE") == .orderedSame:
            return .literal(.boolean(true))
        case .word(let value) where value.caseInsensitiveCompare("FALSE") == .orderedSame:
            return .literal(.boolean(false))
        default:
            throw unsupported(sql, "expected a value")
        }
    }
}
