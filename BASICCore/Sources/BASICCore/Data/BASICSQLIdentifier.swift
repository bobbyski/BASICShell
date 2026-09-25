import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Validation and quoting for names that cannot be bound.
///
/// SQL placeholders bind **values only**, so a table or column name has to be
/// interpolated — and in this plan those names are user input, because
/// `DATABASE NAME "…"` puts a string from the program into an identifier
/// position (DB15). Two defenses, both required:
///
/// 1. Validate at the boundary, the way `validatedBASICFilePath(_:)` already
///    guards file paths, and fail naming the class and field.
/// 2. Quote, doubling the quote character, per dialect.
public enum BASICSQLIdentifier {
    /// Checks a name is usable, returning it unchanged.
    ///
    /// Unicode letters are welcome (DB20) — a schema written in another
    /// language is a real schema. What is refused is the set that breaks
    /// quoting or confuses a driver: nothing, NUL, control characters, and
    /// line breaks.
    @discardableResult
    public static func validated(_ name: String, describing context: String? = nil) throws -> String {
        let label = context.map { "\($0): " } ?? ""
        guard !name.isEmpty else {
            throw BASICDataError.invalidIdentifier(label + "(empty)", reason: "a name cannot be empty")
        }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw BASICDataError.invalidIdentifier(label + name, reason: "it contains a NUL")
        }
        if let offender = name.unicodeScalars.first(where: { scalar in
            scalar.properties.generalCategory == .control || scalar == "\n" || scalar == "\r"
        }) {
            throw BASICDataError.invalidIdentifier(
                label + name,
                reason: "it contains the control character U+\(String(offender.value, radix: 16, uppercase: true))"
            )
        }
        return name
    }

    /// Quotes for the ANSI dialects — SQLite, PostgreSQL, Oracle, DB2.
    public static func quotedDouble(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Quotes for MySQL and MariaDB.
    public static func quotedBacktick(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// Quotes for SQL Server.
    public static func quotedBracket(_ name: String) -> String {
        "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
    }
}
