import BASICSyntax
import Foundation

/// What the front end knows about the program before building BIR: every
/// function's signature and body range, and every variable's type, storage,
/// and scope.
///
/// Scoping follows the interpreter's default `OPTION LET GLOBAL`: inside a
/// `FUNCTION`, a name is local when it is a parameter or was introduced with
/// `LOCAL`; every other name is the program's global.
public final class SemanticModel {
    /// One `FUNCTION` or `DEF FN`.
    public struct Function {
        /// The normalized name.
        public let name: String
        /// The name as written.
        public let displayName: String
        /// Parameters, each a local of the function.
        public var parameters: [BIRVariable]
        /// The return type; `.void` for a `FUNCTION ... AS VOID`.
        public let returnType: BIRType
        /// Parsed-line indexes of the body, excluding the declaration and
        /// the `END FUNCTION`. Empty for `DEF FN`.
        public let body: Range<Int>
        /// The expression body of a `DEF FN`.
        public let expression: BASICSyntax.Expression?
        /// Where the declaration is, for diagnostics.
        public let location: BIRLocation
    }

    /// What is known about one variable.
    struct VariableInfo {
        var type: BIRType?
        var rank: Int?
        var wasDimensioned = false
    }

    /// Functions by normalized name.
    public private(set) var functions: [String: Function] = [:]
    /// Function names in source order.
    public private(set) var functionOrder: [String] = []
    /// Global variables by normalized name.
    var globals: [String: VariableInfo] = [:]
    /// Global names in first-seen order.
    var globalOrder: [String] = []
    /// Local variables, by function name then variable name.
    var locals: [String: [String: VariableInfo]] = [:]
    /// Local names in first-seen order, per function.
    var localOrder: [String: [String]] = [:]

    func addFunction(_ function: Function) {
        functions[function.name] = function
        functionOrder.append(function.name)
        locals[function.name] = Dictionary(uniqueKeysWithValues: function.parameters.map {
            ($0.name, VariableInfo(type: $0.type, rank: nil))
        })
        localOrder[function.name] = function.parameters.map(\.name)
    }

    /// Whether `name` resolves to a local of `function`.
    func isLocal(_ name: String, in function: String?) -> Bool {
        guard let function else { return false }
        return locals[function]?[name] != nil
    }

    /// Declares `name` as a local of `function` (a parameter or `LOCAL`).
    func declareLocal(_ name: String, in function: String) {
        if locals[function]?[name] == nil {
            locals[function, default: [:]][name] = VariableInfo()
            localOrder[function, default: []].append(name)
        }
    }

    /// Reads a variable's info wherever it resolves.
    func info(_ name: String, in function: String?) -> VariableInfo? {
        if let function, let local = locals[function]?[name] { return local }
        return globals[name]
    }

    /// Updates a variable's info wherever it resolves, creating a global
    /// when it is new.
    func update(_ name: String, in function: String?, _ change: (inout VariableInfo) -> Void) {
        if let function, locals[function]?[name] != nil {
            change(&locals[function]![name]!)
            return
        }
        if globals[name] == nil {
            globals[name] = VariableInfo(type: SemanticAnalyzer.suffixType(name))
            globalOrder.append(name)
        }
        change(&globals[name]!)
    }

    /// The resolved variable for a name used in `function` (nil = main).
    public func variable(_ name: String, in function: String?) -> BIRVariable {
        let scope: BIRScope = isLocal(name, in: function) ? .local : .global
        let known = info(name, in: function)
        let type = known?.type ?? SemanticAnalyzer.suffixType(name) ?? .number
        let storage: BIRStorage = known?.rank.map { .array(rank: $0) } ?? .scalar
        return BIRVariable(name: name, type: type, scope: scope, storage: storage)
    }

    /// All globals, in first-seen order.
    public var globalVariables: [BIRVariable] {
        globalOrder.map { variable($0, in: nil) }
    }

    /// The locals of a function, parameters first, in first-seen order.
    public func localVariables(of function: String) -> [BIRVariable] {
        (localOrder[function] ?? []).map { variable($0, in: function) }
    }
}
