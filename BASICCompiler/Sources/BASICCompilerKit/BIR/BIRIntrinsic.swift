import Foundation

/// The builtin functions BIR knows how to name.
///
/// Each maps to one runtime entry point (or, for the numeric ones, one LLVM
/// intrinsic). The table in ``BIRIntrinsic/lookup(_:argumentCount:)`` is the
/// compiler's list of what it can compile; a builtin missing from it is
/// reported as not-yet-supported rather than miscompiled.
public enum BIRIntrinsic: String, Sendable, CaseIterable {
    // Numbers → number
    case abs = "ABS"
    case int = "INT"
    case fix = "FIX"
    case cint = "CINT"
    // DB19's conversions. Each takes a VARIANT because what converts is a
    // value of any kind -- text, most often, since that is how a date arrives.
    case cdate = "CDATE"
    case ctime = "CTIME"
    case cdatetime = "CDATETIME"
    case cdec = "CDEC"
    case sqr = "SQR"
    case sin = "SIN"
    case cos = "COS"
    case tan = "TAN"
    case atn = "ATN"
    case exp = "EXP"
    case log = "LOG"
    case sgn = "SGN"
    /// The rest of the one-argument math family (BBC add-ins A3/A4). Each
    /// lowers to a `basic_rt_<name>` entry that checks its domain the way
    /// the interpreter's `BASICMathIntrinsic` does.
    case acs = "ACS", asn = "ASN", cot = "COT", csc = "CSC", sec = "SEC"
    case hcs = "HCS", hsn = "HSN", htn = "HTN"
    case lct = "LCT", ln = "LN", log10 = "LOG10", ltw = "LTW"
    case rad = "RAD", dec = "DEC", deg = "DEG", scn = "SCN"
    /// `PLAY(n)`: notes left in the background queue.
    case play = "PLAY"
    case rnd = "RND"
    /// `ERR` and `ERL` read like variables but are runtime state.
    case err = "ERR"
    case erl = "ERL"
    // Files → number
    case eof = "EOF"
    case lof = "LOF"
    case loc = "LOC"
    case fileExists = "FILEEXISTS"
    // Clock and pauses
    case date = "DATE$"
    case time = "TIME$"
    /// `INPUT$(n)`: the next n characters typed, blocking.
    case inputChars = "INPUT$"
    // Strings → number
    case len = "LEN"
    case asc = "ASC"
    case val = "VAL"
    case instr = "INSTR"
    // → string
    case str = "STR$"
    case chr = "CHR$"
    case left = "LEFT$"
    case right = "RIGHT$"
    case mid = "MID$"
    case space = "SPACE$"
    case stringRepeat = "STRING$"

    /// The type of the value the intrinsic returns.
    public var returnType: BIRType {
        switch self {
        case .abs, .int, .fix, .cint, .sqr, .sin, .cos, .tan, .atn, .exp, .log, .sgn, .rnd, .err, .erl,
             .len, .asc, .val, .instr, .lof, .loc, .fileExists:
            return .number
        case .acs, .asn, .cot, .csc, .sec, .hcs, .hsn, .htn, .lct, .ln, .log10, .ltw, .rad, .dec, .deg, .scn, .play:
            return .number
        case .eof:
            return .boolean
        case .str, .chr, .left, .right, .mid, .space, .stringRepeat, .date, .time, .inputChars:
            return .string
        case .cdate: return .exact(.date)
        case .ctime: return .exact(.time)
        case .cdatetime: return .exact(.datetime)
        case .cdec: return .exact(.decimal)
        }
    }

    /// The parameter types, in order. `MID$` and `INSTR` accept an optional
    /// argument; ``lookup(_:argumentCount:)`` checks the count.
    public var parameterTypes: [BIRType] {
        switch self {
        case .abs, .int, .fix, .cint, .sqr, .sin, .cos, .tan, .atn, .exp, .log, .sgn, .str, .chr, .space, .eof, .lof, .loc, .inputChars:
            return [.number]
        case .acs, .asn, .cot, .csc, .sec, .hcs, .hsn, .htn, .lct, .ln, .log10, .ltw, .rad, .dec, .deg, .scn, .play:
            return [.number]
        case .rnd, .err, .erl, .date, .time:
            return []
        case .cdate, .ctime, .cdatetime, .cdec:
            return [.variant]
        case .len, .asc, .val, .fileExists:
            return [.string]
        case .left, .right:
            return [.string, .number]
        case .mid:
            return [.string, .number, .number]
        case .instr:
            return [.number, .string, .string]
        case .stringRepeat:
            return [.number, .string]
        }
    }

    /// Finds the intrinsic for a BASIC name, or nil when the name is not one
    /// this compiler implements (yet) or the argument count cannot fit.
    public static func lookup(_ name: String, argumentCount: Int) -> BIRIntrinsic? {
        guard let intrinsic = BIRIntrinsic(rawValue: name.uppercased()) else { return nil }
        switch intrinsic {
        case .mid:
            return (2...3).contains(argumentCount) ? intrinsic : nil
        case .instr:
            return (2...3).contains(argumentCount) ? intrinsic : nil
        case .rnd:
            return (0...1).contains(argumentCount) ? intrinsic : nil
        default:
            return intrinsic.parameterTypes.count == argumentCount ? intrinsic : nil
        }
    }
}
