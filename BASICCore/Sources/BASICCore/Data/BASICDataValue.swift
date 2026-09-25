import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One value crossing the boundary between BASIC and a database.
public enum BASICDataValue: Equatable, Hashable, Sendable {
    /// SQL `NULL`, or an absent document field.
    case null
    /// A whole number, up to 64 bits signed.
    case integer(Int64)
    /// A binary floating-point number.
    case double(Double)
    /// An exact decimal, for money and anything else where binary rounding is a defect.
    case decimal(Decimal)
    /// Unicode text (DB20).
    case text(String)
    /// Bytes, uninterpreted.
    case blob(Data)
    /// True or false. Written as the dialect's narrowest integer (DB24).
    case boolean(Bool)
    /// A calendar date.
    case date(BASICDataDate)
    /// A wall-clock time.
    case time(BASICDataTime)
    /// A date and time.
    case timestamp(BASICDataTimestamp)

    /// Whether this is `null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The logical column type this value would be stored in.
    public var columnType: BASICColumnType? {
        switch self {
        case .null: return nil
        case .integer: return .integer
        case .double: return .double
        case .decimal: return .decimal(precision: 28, scale: 4)
        case .text: return .text(maximumLength: nil)
        case .blob: return .blob
        case .boolean: return .boolean
        case .date: return .date
        case .time: return .time
        case .timestamp: return .timestamp
        }
    }
}

public extension BASICDataValue {
    /// Reads a boolean from any spelling a real column plausibly holds (§7.2).
    ///
    /// The ORM writes one form per dialect and reads all of them, because D6
    /// imports schemas this project did not write. `-1` is included because it
    /// is what a classic VB or GW-BASIC application wrote for true.
    var booleanValue: Bool? {
        switch self {
        case .boolean(let value):
            return value
        case .integer(let value):
            if value == 0 { return false }
            if value == 1 || value == -1 { return true }
            return nil
        case .double(let value):
            if value == 0 { return false }
            if value == 1 || value == -1 { return true }
            return nil
        case .text(let value):
            switch value.trimmingCharacters(in: .whitespaces).uppercased() {
            case "1", "-1", "T", "TRUE", "Y", "YES": return true
            case "0", "F", "FALSE", "N", "NO": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}
