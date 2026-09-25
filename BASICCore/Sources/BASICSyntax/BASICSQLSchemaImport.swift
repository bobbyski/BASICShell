//
//  BASICSQLSchemaImport.swift
//  BASICSyntax
//
//  `IMPORT "schema.sql"` — a BASIC class per table (D6).
//

import Foundation

/// A table read out of a `.sql` file, and the BASIC class it becomes.
///
/// The other direction of D5. Whichever side a program starts from, the other
/// can be generated: a class already describes a table (`EnsureSchema`), and a
/// table already describes a class (this).
///
/// This lives in `BASICSyntax` rather than `BASICCore` because it is a front-end
/// feature and both front ends have an import loader of their own — the
/// interpreter's and the compiler's. One generator, reached from both, is what
/// makes `IMPORT "schema.sql"` mean the same thing in all three engines.
public enum BASICSQLSchemaImport {

    /// What a column was declared as, once the dialect's spelling is set aside.
    public enum ColumnKind: Equatable, Sendable {
        case integer
        case double
        case string
        case boolean
        /// D0.7 gave the language these, so a column that is one is generated
        /// as one: `DECIMAL(12,2)` is a `DECIMAL`, not text that happens to
        /// hold digits.
        case date
        case time
        case datetime
        case decimal
        /// A type the language still has no word for -- binary, today.
        /// Carried as text, with what it was said out loud in a comment.
        case textFor(String)

        /// The BASIC type the generated field is declared as.
        public var basicTypeName: String {
            switch self {
            case .integer: return "integer"
            case .double: return "double"
            case .string, .textFor: return "string"
            case .boolean: return "boolean"
            case .date: return "date"
            case .time: return "time"
            case .datetime: return "datetime"
            case .decimal: return "decimal"
            }
        }
    }

    /// One column of an imported table.
    public struct Column: Equatable, Sendable {
        /// The name as the SQL wrote it.
        public let sqlName: String
        /// The BASIC field name generated for it.
        public let fieldName: String
        public let kind: ColumnKind
        public let isPrimaryKey: Bool
        public let isUnique: Bool
        public let isIndexed: Bool
        /// `NOT NULL` — recorded, not yet expressed: a BASIC field always has
        /// a value, so nullability has nowhere to go in the generated class.
        public let isNotNull: Bool
    }

    /// One imported table.
    public struct Table: Equatable, Sendable {
        /// The name as the SQL wrote it.
        public let sqlName: String
        /// The BASIC class name generated for it.
        public let className: String
        public let columns: [Column]
    }

    /// What went wrong, with where.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: - The whole job

    /// Reads a `.sql` file's DDL and renders one BASIC class per table.
    ///
    /// Returns nil when the file declares no table at all, so a caller can say
    /// so in its own words rather than importing an empty program.
    public static func basicSource(fromSQL sql: String, fileName: String? = nil) throws -> String? {
        let tables = try self.tables(fromSQL: sql)
        guard !tables.isEmpty else { return nil }
        return render(tables, fileName: fileName)
    }

    /// The tables a `.sql` file declares.
    ///
    /// Statements this does not understand are skipped rather than refused: a
    /// real schema file carries `INSERT`s, `GRANT`s, `SET`s and comments, and an
    /// importer that died on the first one would be useless. A `CREATE TABLE`
    /// it cannot read is a different matter, and says so.
    public static func tables(fromSQL sql: String) throws -> [Table] {
        var tables: [Table] = []
        var indexed: [String: Set<String>] = [:]
        var uniqueIndexed: [String: Set<String>] = [:]

        for statement in Self.statements(in: sql) {
            var scanner = Scanner(statement)
            guard scanner.match("CREATE") else { continue }
            _ = scanner.match("OR") ; _ = scanner.match("REPLACE")
            _ = scanner.match("TEMP") ; _ = scanner.match("TEMPORARY")
            _ = scanner.match("GLOBAL") ; _ = scanner.match("LOCAL")

            if scanner.match("TABLE") {
                tables.append(try table(&scanner, statement: statement))
                continue
            }
            let isUnique = scanner.match("UNIQUE")
            guard scanner.match("INDEX") else { continue }
            if let (table, columns) = index(&scanner) {
                let key = table.uppercased()
                if isUnique {
                    uniqueIndexed[key, default: []].formUnion(columns.map { $0.uppercased() })
                } else {
                    indexed[key, default: []].formUnion(columns.map { $0.uppercased() })
                }
            }
        }

        // A separate CREATE INDEX is the same statement about the same column,
        // so it lands on the column rather than beside it.
        let withIndexes = tables.map { table -> Table in
            let key = table.sqlName.uppercased()
            guard indexed[key] != nil || uniqueIndexed[key] != nil else { return table }
            return Table(sqlName: table.sqlName, className: table.className, columns: table.columns.map { column in
                let name = column.sqlName.uppercased()
                let unique = column.isUnique || uniqueIndexed[key]?.contains(name) == true
                let index = column.isIndexed || unique || indexed[key]?.contains(name) == true
                return Column(
                    sqlName: column.sqlName, fieldName: column.fieldName, kind: column.kind,
                    isPrimaryKey: column.isPrimaryKey, isUnique: unique, isIndexed: index,
                    isNotNull: column.isNotNull
                )
            })
        }

        // Two tables whose names differ only in ways BASIC cannot see would
        // generate one class twice. Named, rather than silently merged.
        var seen: [String: String] = [:]
        for table in withIndexes {
            let key = table.className.uppercased()
            if let first = seen[key] {
                throw Failure(message: "tables \(first) and \(table.sqlName) both become CLASS \(table.className)")
            }
            seen[key] = table.sqlName
        }
        return withIndexes
    }

    // MARK: - CREATE TABLE

    private static func table(_ scanner: inout Scanner, statement: String) throws -> Table {
        _ = scanner.match("IF") ; _ = scanner.match("NOT") ; _ = scanner.match("EXISTS")
        guard let qualified = scanner.identifier() else {
            throw Failure(message: "CREATE TABLE without a name: \(Self.excerpt(statement))")
        }
        // `schema.table` names the table; the schema is the connection's business.
        let name = qualified.split(separator: ".").last.map(String.init) ?? qualified
        guard scanner.match("(") else {
            throw Failure(message: "CREATE TABLE \(name) has no column list")
        }
        let body = scanner.balancedRemainder()

        var columns: [Column] = []
        var keyNames: Set<String> = []
        var uniqueNames: Set<String> = []

        for item in Self.split(body) {
            var element = Scanner(item)
            // A table constraint, not a column: it renames no field, it only
            // says more about ones already declared.
            if element.matchAny(["CONSTRAINT"]) { _ = element.identifier() }
            if element.match("PRIMARY") {
                _ = element.match("KEY")
                keyNames.formUnion(element.parenthesizedIdentifiers().map { $0.uppercased() })
                continue
            }
            if element.match("UNIQUE") {
                _ = element.match("KEY")
                uniqueNames.formUnion(element.parenthesizedIdentifiers().map { $0.uppercased() })
                continue
            }
            if element.matchAny(["FOREIGN", "CHECK", "KEY", "INDEX", "EXCLUDE", "PERIOD"]) { continue }

            guard let columnName = element.identifier() else {
                throw Failure(message: "cannot read a column of \(name): \(Self.excerpt(item))")
            }
            let rest = element.remainder()
            columns.append(Column(
                sqlName: columnName,
                fieldName: identifier(from: columnName),
                kind: kind(ofType: rest),
                isPrimaryKey: Self.mentions(rest, "PRIMARY"),
                isUnique: Self.mentions(rest, "UNIQUE"),
                isIndexed: Self.mentions(rest, "UNIQUE") || Self.mentions(rest, "PRIMARY"),
                isNotNull: Self.mentions(rest, "NOT") && Self.mentions(rest, "NULL")
            ))
        }

        guard !columns.isEmpty else {
            throw Failure(message: "CREATE TABLE \(name) declares no columns")
        }

        let resolved = columns.map { column -> Column in
            let upper = column.sqlName.uppercased()
            let isKey = column.isPrimaryKey || keyNames.contains(upper)
            let unique = column.isUnique || uniqueNames.contains(upper)
            return Column(
                sqlName: column.sqlName, fieldName: column.fieldName, kind: column.kind,
                isPrimaryKey: isKey, isUnique: unique,
                isIndexed: column.isIndexed || unique || isKey, isNotNull: column.isNotNull
            )
        }
        return Table(sqlName: name, className: className(fromTable: name), columns: resolved)
    }

    private static func index(_ scanner: inout Scanner) -> (table: String, columns: [String])? {
        _ = scanner.match("IF") ; _ = scanner.match("NOT") ; _ = scanner.match("EXISTS")
        guard scanner.identifier() != nil, scanner.match("ON"),
              let qualified = scanner.identifier(), scanner.match("(") else { return nil }
        let table = qualified.split(separator: ".").last.map(String.init) ?? qualified
        let columns = Self.split(scanner.balancedRemainder()).compactMap { item -> String? in
            var element = Scanner(item)
            return element.identifier()
        }
        return columns.isEmpty ? nil : (table, columns)
    }

    // MARK: - Types

    /// The kind a declared SQL type maps to.
    ///
    /// Matched on what the type *contains* rather than on an exact spelling:
    /// every dialect writes the same handful of ideas a dozen ways
    /// (`INT`, `INT4`, `INTEGER`, `BIGINT`, `MEDIUMINT UNSIGNED`), and an
    /// exact-match table would silently fall through to text for the next one.
    public static func kind(ofType declaration: String) -> ColumnKind {
        let text = declaration.uppercased()
        // Checked first: DB24 stores a boolean as the narrowest integer, and
        // `TINYINT(1)` is what MySQL writes for one.
        if text.contains("BOOL") || text.hasPrefix("BIT") { return .boolean }
        if text.contains("TINYINT(1)") { return .boolean }
        if text.contains("INT") || text.contains("SERIAL") { return .integer }
        if text.contains("DOUBLE") || text.contains("REAL") || text.contains("FLOAT") { return .double }
        // DB19: exactness is the point of DECIMAL, so it is never quietly a
        // double -- and since D0.7 the language has the type to say so.
        if text.contains("DECIMAL") || text.contains("NUMERIC") || text.contains("MONEY") {
            return .decimal
        }
        if text.contains("TIMESTAMP") || text.contains("DATETIME") { return .datetime }
        if text.contains("DATE") { return .date }
        if text.contains("TIME") { return .time }
        if text.contains("BLOB") || text.contains("BINARY") || text.contains("BYTEA") {
            return .textFor("BINARY")
        }
        return .string
    }

    // MARK: - Names

    /// Whether a SQL name is already spelled as a BASIC identifier.
    public static func isLegalIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        return !BASICKeywords.isKeyword(name)
    }

    /// The CLASS name for a table.
    ///
    /// Verbatim when the table name is already a legal identifier, and *not*
    /// prettified -- because a class names its table by being called the same
    /// thing, and `customers` becoming `Customers` is, on a case-sensitive
    /// server, the difference between the right table and a brand new one.
    ///
    /// A name BASIC cannot spell (`order items`, or one the language owns) gets
    /// a legal one, and the generated class says which table it means with a
    /// class-level `DATABASE NAME` (DB26).
    public static func className(fromTable sqlName: String) -> String {
        isLegalIdentifier(sqlName) ? sqlName : identifier(from: sqlName)
    }

    /// A BASIC identifier for a SQL column name.
    ///
    /// `order_date` is already legal; `"Order Date"`, `order-date` and `2024_qty`
    /// are not. Whatever comes out, the generated field keeps the original in
    /// `DATABASE NAME`, so the class still maps to the column it came from --
    /// which is what makes prettifying safe here and unsafe for a table.
    public static func identifier(from sqlName: String) -> String {
        var result = ""
        var capitalize = false
        for character in sqlName {
            if character.isLetter || character.isNumber {
                result.append(capitalize ? Character(character.uppercased()) : character)
                capitalize = false
            } else {
                // A separator becomes a word boundary rather than an
                // underscore: `order_date` reads as `OrderDate`, which is what
                // someone writing the class by hand would have typed.
                capitalize = !result.isEmpty
            }
        }
        if let first = result.first, first.isNumber { result = "T" + result }
        if result.isEmpty { result = "Column" }
        result = result.prefix(1).uppercased() + result.dropFirst()
        // A name the language already owns would not parse as a field.
        if BASICKeywords.isKeyword(result) { result += "Field" }
        return result
    }

    // MARK: - Rendering

    private static func render(_ tables: [Table], fileName: String?) -> String {
        var lines: [String] = [
            "' Generated from \(fileName ?? "a SQL schema") by IMPORT.",
            "'",
            "' One CLASS per table. Do not edit: change the SQL and import again.",
            "' Every field carries DATABASE because persistence is opt in (DB2) --",
            "' generated fields with no marker would persist nothing.",
            "",
        ]
        for table in tables {
            lines.append("CLASS \(table.className)")
            // DB26: only when the class cannot simply be called after its table.
            if table.className != table.sqlName {
                lines.append("    DATABASE NAME \"\(table.sqlName)\"")
            }
            for column in table.columns {
                var marker = "DATABASE"
                if column.sqlName != column.fieldName {
                    marker += " NAME \"\(column.sqlName)\""
                }
                if column.isPrimaryKey { marker += " KEY" }
                else if column.isUnique { marker += " UNIQUE" }
                else if column.isIndexed { marker += " INDEX" }
                var line = "    PUBLIC \(column.fieldName) AS \(column.kind.basicTypeName) \(marker)"
                if case .textFor(let original) = column.kind {
                    line += "   ' \(original) in SQL; carried as text until the language has the type"
                }
                lines.append(line)
            }
            lines.append("END CLASS")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lexing

    /// Whether a column's trailing declaration says a bare word, as a word.
    ///
    /// `NOTNULLABLE` does not say `NOT NULL`, and a default string `'primary'`
    /// does not say `PRIMARY` — so quoted text is dropped before looking.
    private static func mentions(_ declaration: String, _ word: String) -> Bool {
        var text = ""
        var quote: Character?
        for character in declaration {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if character == "'" || character == "\"" { quote = character; continue }
            text.append(character.isLetter || character.isNumber || character == "_" ? character : " ")
        }
        return text.uppercased().split(separator: " ").contains(Substring(word.uppercased()))
    }

    private static func excerpt(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= 60 ? flat : String(flat.prefix(60)) + "..."
    }

    /// The statements in a file: split on top-level `;`, comments removed.
    static func statements(in sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var index = sql.startIndex

        func peek(_ offset: Int) -> Character? {
            let next = sql.index(index, offsetBy: offset, limitedBy: sql.endIndex)
            guard let next, next < sql.endIndex else { return nil }
            return sql[next]
        }

        while index < sql.endIndex {
            let character = sql[index]
            if let open = quote {
                current.append(character)
                // A doubled quote is an escaped one, which is how SQL spells it.
                if character == open, peek(1) == open {
                    current.append(open)
                    index = sql.index(index, offsetBy: 2)
                    continue
                }
                if character == open { quote = nil }
                index = sql.index(after: index)
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                quote = character
                current.append(character)
                index = sql.index(after: index)
                continue
            }
            if character == "-", peek(1) == "-" {
                while index < sql.endIndex, sql[index] != "\n" { index = sql.index(after: index) }
                continue
            }
            if character == "#", current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                while index < sql.endIndex, sql[index] != "\n" { index = sql.index(after: index) }
                continue
            }
            if character == "/", peek(1) == "*" {
                index = sql.index(index, offsetBy: 2)
                while index < sql.endIndex {
                    if sql[index] == "*", peek(1) == "/" { index = sql.index(index, offsetBy: 2); break }
                    index = sql.index(after: index)
                }
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == ";", depth == 0 {
                statements.append(current)
                current = ""
                index = sql.index(after: index)
                continue
            }
            current.append(character)
            index = sql.index(after: index)
        }
        statements.append(current)
        return statements.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Splits a parenthesized body on top-level commas.
    static func split(_ body: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in body {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"", "`": quote = character; current.append(character)
            case "(": depth += 1; current.append(character)
            case ")": depth -= 1; current.append(character)
            case "," where depth == 0:
                items.append(current)
                current = ""
            default: current.append(character)
            }
        }
        items.append(current)
        return items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A word-and-identifier reader over one statement.
    struct Scanner {
        private var text: Substring

        init(_ source: String) { text = Substring(source) }

        private mutating func skipSpace() {
            while let first = text.first, first.isWhitespace { text.removeFirst() }
        }

        /// Consumes `word` when it is next, as a whole word.
        mutating func match(_ word: String) -> Bool {
            skipSpace()
            guard text.uppercased().hasPrefix(word.uppercased()) else { return false }
            let after = text.index(text.startIndex, offsetBy: word.count, limitedBy: text.endIndex)
            if word.count > 1 || word.first!.isLetter, let after, after < text.endIndex,
               text[after].isLetter || text[after].isNumber || text[after] == "_" {
                return false
            }
            text = text.dropFirst(word.count)
            return true
        }

        mutating func matchAny(_ words: [String]) -> Bool {
            for word in words where match(word) { return true }
            return false
        }

        /// The next identifier, quoted in any of the three ways or bare.
        mutating func identifier() -> String? {
            skipSpace()
            guard let first = text.first else { return nil }
            let closing: Character?
            switch first {
            case "\"": closing = "\""
            case "`": closing = "`"
            case "[": closing = "]"
            default: closing = nil
            }
            if let closing {
                text.removeFirst()
                guard let end = text.firstIndex(of: closing) else { return nil }
                let name = String(text[text.startIndex..<end])
                text = text[text.index(after: end)...]
                return name.isEmpty ? nil : name
            }
            var name = ""
            while let character = text.first, character.isLetter || character.isNumber || character == "_" || character == "." || character == "$" {
                name.append(character)
                text.removeFirst()
            }
            return name.isEmpty ? nil : name
        }

        /// Every identifier inside the next `( … )`.
        mutating func parenthesizedIdentifiers() -> [String] {
            skipSpace()
            guard match("(") else { return [] }
            return BASICSQLSchemaImport.split(balancedRemainder()).compactMap {
                var element = Scanner($0)
                return element.identifier()
            }
        }

        /// What is left up to the `)` that closes the `(` just consumed.
        mutating func balancedRemainder() -> String {
            var depth = 1
            var body = ""
            var quote: Character?
            while let character = text.first {
                text.removeFirst()
                if let open = quote {
                    body.append(character)
                    if character == open { quote = nil }
                    continue
                }
                switch character {
                case "'", "\"", "`": quote = character; body.append(character)
                case "(": depth += 1; body.append(character)
                case ")":
                    depth -= 1
                    if depth == 0 { return body }
                    body.append(character)
                default: body.append(character)
                }
            }
            return body
        }

        mutating func remainder() -> String {
            skipSpace()
            let rest = String(text)
            text = Substring("")
            return rest
        }
    }
}
