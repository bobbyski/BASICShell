import BASICSyntax
import Foundation

/// What the front end knows about the program before building BIR: every
/// type, function, and method, and every variable's type, storage, and
/// scope.
///
/// Scoping follows the interpreter's default `OPTION LET GLOBAL`: inside a
/// `FUNCTION`, a name is local when it is a parameter or was introduced with
/// `LOCAL`; every other name is the program's global. Inside a method, `ME`
/// is the receiver.
public final class SemanticModel {
    /// One `FUNCTION`, `DEF FN`, or method.
    public struct Function {
        /// The normalized name; `CLASS.METHOD` for a method.
        public let name: String
        /// The name as written.
        public let displayName: String
        /// Parameters, each a local of the function; `ME` first for a method.
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
        /// The class this is a method of, when it is one.
        public let owner: String?
        /// Who may call it.
        public let visibility: BASICMemberVisibility
        /// Interface members this method explicitly implements.
        public let explicitImplementations: [BASICExplicitInterfaceImplementation]
    }

    /// One field of a `TYPE` or `CLASS`.
    public struct Field {
        public let name: String
        public let displayName: String
        public let type: BIRType
        public let visibility: BASICMemberVisibility
        /// The class or record that declared it.
        public let owner: String
        public let defaultNumber: Double?
        public let defaultString: String?
    }

    /// A `TYPE`, `CLASS`, or `INTERFACE`.
    public struct CompositeType {
        public enum Kind { case record, classType, interface }
        public let name: String
        public let displayName: String
        public let kind: Kind
        /// The runtime type index (records and classes).
        public let index: Int
        /// Own fields, in declaration order.
        public var fields: [Field]
        /// Own methods by normalized name → function name.
        public var methods: [String: String]
        public var base: String?
        public var interfaces: [String]
        /// Interface members: name → (parameter types, return type).
        public var members: [String: (parameters: [BIRType], returnType: BIRType)]
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
    /// Types by normalized name.
    public private(set) var types: [String: CompositeType] = [:]
    /// Type names in source order.
    public private(set) var typeOrder: [String] = []
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

    func addType(_ type: CompositeType) {
        types[type.name] = type
        typeOrder.append(type.name)
    }

    func updateType(_ name: String, _ change: (inout CompositeType) -> Void) {
        change(&types[name]!)
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

    // MARK: - Types

    /// All fields of a record or class, inherited ones first — the runtime's
    /// slot order.
    public func allFields(of typeName: String) -> [Field] {
        guard let type = types[typeName] else { return [] }
        return (type.base.map { allFields(of: $0) } ?? []) + type.fields
    }

    /// The field named `field` of `typeName`, with its slot index.
    public func field(_ field: String, of typeName: String) -> (index: Int, field: Field)? {
        let fields = allFields(of: typeName)
        guard let index = fields.firstIndex(where: { $0.name == field }) else { return nil }
        return (index, fields[index])
    }

    /// The function implementing `method` for `className`, walking the base
    /// chain — the interpreter's `lookupMethod`.
    public func lookupMethod(_ method: String, in className: String) -> Function? {
        var current: String? = className
        while let name = current, let type = types[name] {
            if let functionName = type.methods[method], let function = functions[functionName] { return function }
            current = type.base
        }
        return nil
    }

    /// The function implementing interface member `member` for `className`:
    /// a method of that name, or one explicitly implementing it.
    public func implementation(of member: String, interface: String, in className: String) -> Function? {
        if let direct = lookupMethod(member, in: className) { return direct }
        var current: String? = className
        while let name = current, let type = types[name] {
            for functionName in type.methods.values {
                if let function = functions[functionName],
                   function.explicitImplementations.contains(where: { $0.normalizedInterfaceName == interface && $0.normalizedMemberName == member }) {
                    return function
                }
            }
            current = type.base
        }
        return nil
    }

    /// `className` and every class deriving from it, transitively.
    public func classFamily(of className: String) -> [String] {
        [className] + typeOrder.filter { types[$0]?.kind == .classType && isClass($0, subclassOf: className) }
    }

    /// Whether `className` derives from `baseName` (strictly).
    public func isClass(_ className: String, subclassOf baseName: String) -> Bool {
        var current = types[className]?.base
        while let name = current {
            if name == baseName { return true }
            current = types[name]?.base
        }
        return false
    }

    /// Whether a class (or one of its bases) implements an interface.
    public func classConforms(_ className: String, to interface: String) -> Bool {
        var current: String? = className
        while let name = current, let type = types[name] {
            if type.interfaces.contains(interface) { return true }
            current = type.base
        }
        return false
    }

    /// Whether a value of `source` may be stored where `target` is expected:
    /// the same type, a subclass into its base, or a conforming class into
    /// an interface.
    public func isAssignable(_ source: BIRType, to target: BIRType) -> Bool {
        if source == target { return true }
        guard case .composite(let from) = source, case .composite(let to) = target, let targetType = types[to] else { return false }
        switch targetType.kind {
        case .interface: return classConforms(from, to: to)
        case .classType: return isClass(from, subclassOf: to)
        case .record: return false
        }
    }

    /// Every class conforming to an interface, in source order.
    public func classes(conformingTo interface: String) -> [String] {
        typeOrder.filter { types[$0]?.kind == .classType && classConforms($0, to: interface) }
    }
}
