import Foundation

/// Arithmetic on numbers.
public enum BIRArithmetic: String, Sendable {
    case add, subtract, multiply, divide
}

/// The six comparisons. Each yields the number `1` or `0`.
public enum BIRComparison: String, Sendable {
    case equal, notEqual, less, lessEqual, greater, greaterEqual
}

/// `AND` / `OR` on truthiness. Each yields the number `1` or `0`.
public enum BIRLogical: String, Sendable {
    case and, or
}

/// A typed expression tree.
public indirect enum BIRExpression: Sendable {
    /// A numeric constant.
    case number(Double)
    /// A string constant.
    case string(String)
    /// A boolean constant.
    case boolean(Bool)
    /// The current value of a variable.
    case load(BIRVariable)
    /// Unary minus on a number.
    case negate(BIRExpression)
    /// Arithmetic on two numbers.
    case arithmetic(BIRArithmetic, BIRExpression, BIRExpression)
    /// Concatenation of two strings.
    case concat(BIRExpression, BIRExpression)
    /// A comparison of two operands of the same type; yields a number.
    case compare(BIRComparison, BIRExpression, BIRExpression)
    /// `AND` / `OR` of two truthiness tests; yields a number.
    case logical(BIRLogical, BIRExpression, BIRExpression)
    /// A builtin function.
    case intrinsic(BIRIntrinsic, [BIRExpression])
    /// A call to a user `FUNCTION` that returns a value.
    case call(String, [BIRExpression], returns: BIRType)
    /// One element of an array variable.
    case element(BIRVariable, [BIRExpression])
    /// The text a value shows as — `PRINT`'s rendering — for interpolation.
    case text(BIRExpression)
    /// Field `index` of a composite value.
    case field(BIRExpression, index: Int, type: BIRType)
    /// A default instance of a `TYPE` or `CLASS` (before any `NEW` runs).
    case construct(String)
    /// `USING$(format, values…)`: PRINT USING's rendering as a string.
    case usingString(format: BIRExpression, values: [BIRExpression])

    /// The static type of the value this expression produces.
    public var type: BIRType {
        switch self {
        case .number, .negate, .arithmetic, .compare, .logical:
            return .number
        case .string, .concat:
            return .string
        case .boolean:
            return .boolean
        case .load(let variable):
            return variable.type
        case .intrinsic(let intrinsic, _):
            return intrinsic.returnType
        case .call(_, _, let returns):
            return returns
        case .element(let variable, _):
            return variable.type
        case .text:
            return .string
        case .field(_, _, let type):
            return type
        case .construct(let name):
            return .composite(name)
        case .usingString:
            return .string
        }
    }
}
