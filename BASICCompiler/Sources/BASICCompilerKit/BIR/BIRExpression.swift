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
    /// A `File.*` service call: `method` is the normalized member name.
    case fileService(method: String, arguments: [BIRExpression], returns: BIRType)
    /// Makes a closure: its body function, the environment type holding the
    /// captures, and the captured values in field order. Owned.
    case makeClosure(function: String, environment: String?, captures: [BIRExpression], signature: String)
    /// Calls a closure value.
    case callClosure(BIRExpression, [BIRExpression], returns: BIRType)
    /// Calls a method on a record or object place: the receiver is copied in
    /// and written back. An expression, not an operation, so it evaluates in
    /// source order with the reads beside it.
    case callMethod(receiver: BIRPlace, candidates: [BIRMethodCandidate], arguments: [BIRExpression], returns: BIRType)
    /// A whole array variable as a value (borrowed).
    case loadArray(BIRVariable)
    /// An element of an array-typed expression (an array field, say).
    case elementOf(BIRExpression, [BIRExpression], name: String)
    /// A statically typed value boxed as a VARIANT.
    case box(BIRExpression)
    /// A VARIANT read as `type`. With a variable `name` the failure is the
    /// assignment's type error; without, the expression's runtime error.
    case unbox(BIRExpression, BIRType, name: String?)
    /// `d(key)` on a dictionary: the entry, or EMPTY.
    case dictionaryGet(BIRExpression, key: BIRExpression, name: String)
    /// `v(i, …)` on a VARIANT holding an array or dictionary.
    case valueIndex(BIRExpression, [BIRExpression], name: String)
    /// `v.Field` on a VARIANT holding a record or object.
    case valueField(BIRExpression, field: String, name: String)
    /// `+` with a VARIANT operand: concatenation or addition, decided at runtime.
    case valueAdd(BIRExpression, BIRExpression)
    /// `=` with a VARIANT operand: the interpreter's strict equality, as 1 or 0.
    case valueEqual(BIRExpression, BIRExpression)
    /// `LEN` of a VARIANT (a string's characters or an array's elements).
    case valueLen(BIRExpression)
    /// `LEN` of an array.
    case arrayLen(BIRExpression, name: String)
    /// `ToJsonString(value, pretty)`.
    case jsonEncode(BIRExpression, pretty: BIRExpression)
    /// `FromJsonString(source, permissive)`.
    case jsonDecode(BIRExpression, permissive: BIRExpression)
    /// `EMPTY`.
    case emptyValue
    /// `NULL`.
    case nullValue
    /// A fresh, empty DICTIONARY.
    case newDictionary
    /// A call into the runtime by symbol, with arguments passed by their
    /// static types — the builtins with optional arguments (`MKI$`, `CVI`,
    /// `INPUT$(n, #f)`, `SEEK(n)`).
    case hostCall(String, [BIRExpression], returns: BIRType)
    /// `File(args…)` / `NEW File(args…)`: a system object.
    case systemNew(String, [BIRExpression])
    /// `object.Method(args…)` on a system object, typed by its member table.
    case systemCall(BIRExpression, method: String, [BIRExpression], returns: BIRType)

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
        case .fileService(_, _, let returns):
            return returns
        case .makeClosure(_, _, _, let signature):
            return .closure(signature)
        case .callClosure(_, _, let returns):
            return returns
        case .callMethod(_, _, _, let returns):
            return returns
        case .loadArray(let variable):
            return .array(variable.type, rank: variable.rank ?? 1)
        case .elementOf(let array, _, _):
            return array.type.elementType ?? .number
        case .box, .valueIndex, .valueField, .valueAdd, .jsonDecode, .emptyValue, .nullValue, .dictionaryGet:
            return .variant
        case .unbox(_, let type, _):
            return type
        case .valueEqual, .valueLen, .arrayLen:
            return .number
        case .jsonEncode:
            return .string
        case .newDictionary:
            return .dictionary
        case .hostCall(_, _, let returns), .systemCall(_, _, _, let returns):
            return returns
        case .systemNew(let name, _):
            return .system(name)
        }
    }
}
