//
//  BASICEval.swift
//  BASICCore
//
//  EVAL(s$): an expression written in a string, evaluated at run time.
//

import Foundation

/// `EVAL(s$)`, as Bobby ruled it (B8 in BBC_ADINS.md, 2026-10-13):
///
/// - The string is an expression, never a statement, so `=` compares.
/// - It sees the current locals and globals, as BBC BASIC's does, and can
///   call the program's own FUNCTIONs.
/// - It is pure by default: variables, operators, and the builtins with no
///   effect outside the program. `OPTION EVAL FULL` opens the rest: `SYSTEM$`,
///   files, HTTP, the console, methods and `NEW`. `AWAIT` is never allowed.
/// - A string that does not parse is a runtime error `ON ERROR` can trap,
///   numbered 2 (GW's Syntax error), on the line holding the `EVAL`.
///
/// Both engines evaluate with the interpreter's own code. The interpreter
/// does so in place; a compiled program binds its variables and functions
/// by name and hands the string to ``BASICCompiledEval``.
enum BASICEval {
    /// The builtins an `EVAL` may call without `OPTION EVAL FULL`: arithmetic,
    /// text, conversions, and reading the clock, the held keys or the music
    /// queue. Everything else touches the world outside the program.
    static let pureBuiltins: Set<String> = [
        "ABS", "ACS", "ASC", "ASN", "ATN", "BINARY$", "CDATE", "CDATETIME", "CDEC", "CTIME",
        "CINT", "COS", "COT", "CSC", "CVD", "CVI", "CVS", "DATE$", "DEC", "DEG", "EXP", "FIX",
        "FIELDCOUNT", "FIELDMETA", "FIELDNAME$", "FIELDVALUE", "FIELDVALUE$", "FROMJSONSTRING",
        "HCS", "HEX$", "HSN", "HTN", "INSTR", "INT", "KEYDOWN", "LCT", "LEFT$", "LN", "LOG",
        "LOG10", "LTW", "MID$", "MKD$", "MKI$", "MKS$", "PLAY", "RAD", "REFLECT", "RIGHT$", "RND",
        "SCN", "SEC", "SGN", "SIN", "SPACE$", "SQR", "STR$", "STRING$", "TAN", "TIME$",
        "TOJSONSTRING", "USING$", "VAL", "EVAL",
    ]

    /// The message a syntax error in an `EVAL` string starts with; both
    /// engines number it 2.
    static let syntaxErrorPrefix = "Syntax error in EVAL"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Expression] = [:]

    /// `text` parsed as an expression, once: `EVAL` usually sits in a loop.
    static func parse(_ text: String) throws -> Expression {
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let expression: Expression
        do {
            var parser = try Parser(source: text)
            expression = try parser.parseExpressionOnly()
        } catch let error as BASICError {
            throw BASICError.runtime("\(syntaxErrorPrefix): \(error.description)")
        }
        lock.lock()
        if cache.count > 1000 { cache.removeAll() }
        cache[text] = expression
        lock.unlock()
        return expression
    }

    /// Why `expression` may not run, or nil: always for `AWAIT`, and without
    /// `OPTION EVAL FULL` for anything that reaches outside the program.
    static func refusal(of expression: Expression, fullAccess: Bool) -> String? {
        func impure(_ what: String) -> String? {
            fullAccess ? nil : "EVAL cannot use \(what) without OPTION EVAL FULL"
        }
        func first(_ expressions: [Expression]) -> String? {
            for expression in expressions {
                if let reason = refusal(of: expression, fullAccess: fullAccess) { return reason }
            }
            return nil
        }
        switch expression {
        case .number, .decimal, .temporal, .string, .interpolatedString, .boolean, .null, .variable, .timerFunction:
            return nil
        case .await:
            return "EVAL cannot AWAIT"
        case .variableReference(let reference):
            return first(reference.indexes + reference.fieldIndexes.flatMap { $0 })
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            if BASICKeywords.intrinsicFunctionNames.contains(name.normalized), !pureBuiltins.contains(name.normalized),
               let reason = impure(name.name.uppercased()) {
                return reason
            }
            return first(arguments)
        case .methodCall(let reference, let method, let arguments):
            return impure("a method such as \(method.name)") ?? first(reference.indexes + arguments)
        case .newObject(let type, let arguments):
            return impure("NEW \(type)") ?? first(arguments)
        case .closure:
            return impure("a closure")
        case .systemFunction(let argument):
            return impure("SYSTEM$") ?? first([argument])
        case .environmentFunction(let argument):
            return impure("ENVIRON$") ?? first([argument])
        case .pwdFunction:
            return impure("PWD$")
        case .unaryMinus(let inner), .logicalNot(let inner), .chrFunction(let inner), .lenFunction(let inner):
            return first([inner])
        case .binary(let left, _, let right):
            return first([left, right])
        case .pointFunction(let point):
            return first([point.x, point.y])
        }
    }

    /// The names `expression` reads as variables or calls: what a compiled
    /// program's bindings have to supply.
    static func names(in expression: Expression) -> Set<String> {
        var names: Set<String> = []
        func visit(_ expression: Expression) {
            switch expression {
            case .variable(let name):
                names.insert(name.normalized)
            case .variableReference(let reference):
                names.insert(reference.base.normalized)
                (reference.indexes + reference.fieldIndexes.flatMap { $0 }).forEach(visit)
            case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
                names.insert(name.normalized)
                arguments.forEach(visit)
            case .methodCall(let reference, _, let arguments):
                names.insert(reference.base.normalized)
                (reference.indexes + arguments).forEach(visit)
            case .newObject(_, let arguments):
                arguments.forEach(visit)
            case .unaryMinus(let inner), .logicalNot(let inner), .chrFunction(let inner), .lenFunction(let inner),
                 .systemFunction(let inner), .environmentFunction(let inner), .await(let inner):
                visit(inner)
            case .binary(let left, _, let right):
                visit(left)
                visit(right)
            case .pointFunction(let point):
                visit(point.x)
                visit(point.y)
            case .number, .decimal, .temporal, .string, .interpolatedString, .boolean, .null, .closure,
                 .pwdFunction, .timerFunction:
                break
            }
        }
        visit(expression)
        return names
    }
}

/// `EVAL` for a compiled program (BBC_ADINS.md A10.7): the string is parsed
/// and evaluated by the interpreter's own code, over the variables and
/// functions the program bound by name at the `EVAL`.
public enum BASICCompiledEval {
    /// A value crossing between the compiled runtime and the evaluator.
    public indirect enum Value: Sendable, Equatable {
        case empty
        case null
        case number(Double)
        case string(String)
        case boolean(Bool)
        /// Upper bounds, as `DIM` gives them, and the elements row by row.
        case array(upperBounds: [Int], values: [Value])
        /// A record's type and its fields, in order.
        case record(type: String, fields: [Field])
        case dictionary([String: Value])
    }

    /// One field of a record.
    public struct Field: Sendable, Equatable {
        public let name: String
        public let value: Value

        public init(name: String, value: Value) {
            self.name = name
            self.value = value
        }
    }

    /// What went wrong, as the interpreter words it without its prefix,
    /// its number for `ERR`, and whether it is a type error rather than a
    /// runtime one.
    public struct Failure: Error {
        public let message: String
        public let number: Int
        public let isTypeError: Bool
    }

    /// Evaluates `text`. `variable` answers a name the expression reads, by
    /// its normalized spelling (`TOTAL`, `NAME$`), or nil for one not bound;
    /// `function` calls one of the program's FUNCTIONs, or answers nil when
    /// there is none by that name.
    public static func evaluate(
        _ text: String,
        fullAccess: Bool,
        variable: (String) -> Value?,
        function: @escaping (String, [Value]) throws -> Value?
    ) throws -> Value {
        do {
            let expression = try BASICEval.parse(text)
            if let reason = BASICEval.refusal(of: expression, fullAccess: fullAccess) {
                throw BASICError.runtime(reason)
            }
            let runtime = BASICRuntime()
            for name in BASICEval.names(in: expression) {
                if let value = variable(name) { runtime.bindForEval(name, value: basicValue(value)) }
            }
            let interpreter = BASICInterpreter(program: BASICProgram(), host: BASICEvalHost(), runtime: runtime)
            interpreter.externalFunction = { name, arguments in
                try function(name, arguments.map(value)).map(basicValue)
            }
            return value(try interpreter.evaluateForEval(expression))
        } catch let error as BASICError {
            var isTypeError = false
            if case .type = error { isTypeError = true }
            throw Failure(message: error.eventHandlerMessage, number: BASICInterpreter.errorNumber(for: error), isTypeError: isTypeError)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "\(error)", number: 5, isTypeError: false)
        }
    }

    static func basicValue(_ value: Value) -> BASICValue {
        switch value {
        case .empty: return .empty
        case .null: return .null
        case .number(let number): return .number(number)
        case .string(let text): return .string(BASICString(text))
        case .boolean(let flag): return .boolean(flag)
        case .array(let upperBounds, let values):
            let elements = values.map(basicValue)
            return .array(BASICArray(dimensions: upperBounds, type: elementType(of: elements), isDynamic: false, values: elements))
        case .record(let type, let fields):
            return .record(type, Dictionary(fields.map { ($0.name.uppercased(), basicValue($0.value)) }, uniquingKeysWith: { $1 }))
        case .dictionary(let entries):
            return .dictionary(BASICDictionary(values: entries.mapValues(basicValue)))
        }
    }

    static func value(_ value: BASICValue) -> Value {
        switch value {
        case .empty: return .empty
        case .null: return .null
        case .number(let number): return .number(number)
        case .string(let text): return .string(text.rawString)
        case .boolean(let flag): return .boolean(flag)
        case .array(let array): return .array(upperBounds: array.dimensions, values: array.values.map(self.value))
        case .record(let type, let fields), .object(let type, let fields):
            return .record(type: type, fields: fields.keys.sorted().map { Field(name: $0, value: self.value(fields[$0]!)) })
        case .dictionary(let dictionary): return .dictionary(dictionary.values.mapValues(self.value))
        default: return .string(value.description)
        }
    }

    private static func elementType(of elements: [BASICValue]) -> BASICType {
        switch elements.first {
        case .string?: return .scalar(.string)
        case .boolean?: return .scalar(.boolean)
        case .number?: return .scalar(.double)
        default: return .scalar(.variant)
        }
    }
}

/// The host a compiled program's `EVAL` evaluates against: none of the
/// world's services, which a pure expression never asks for.
private final class BASICEvalHost: BASICHost {
    func print(_ text: String, terminator: String) {}
    func printLine(_ text: String) {}
    func readLine(prompt: String) -> String? { nil }
}
