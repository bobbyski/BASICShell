//
//  BASICFrameworks.swift
//  BASICCore
//
//  IMPORT of a Swift framework the host links (BASIC-45, slice 11e):
//  `IMPORT "ActiveUI"` or `IMPORT "TUIKit"` in the interpreter, through the
//  same binding a compiled program uses. The interpreter knows nothing about
//  either framework. The host says what an import declares — its classes,
//  ENUMs and records, with the static types PRINT and DIM need — and carries
//  out every NEW, property and method on its objects; BASICCore turns BASIC
//  values into `BASICFrameworkValue`s and back, and calls BASIC when the
//  framework calls back: a closure the program handed it, or an OVERRIDES
//  method of a BASIC class that INHERITS a framework class.
//
//  A framework object is a system object whose type name is the module's,
//  `ActiveUI.AUILabel`, so it never meets the built-in pseudo classes of the
//  same name (`AUILabel("x")` without an import is still Studio's own). It is
//  held by reference, as the compiled program holds it (D15): copying the
//  variable aliases the object. An object of a BASIC class inheriting a
//  framework class is one too, its own fields kept beside it.
//

import Foundation

/// A value crossing between a BASIC program and a framework its host links.
public indirect enum BASICFrameworkValue: Sendable, Equatable {
    case empty
    case null
    case number(Double)
    case string(String)
    case boolean(Bool)
    /// A framework object: the host's handle for it, and its class.
    case object(handle: Int, className: String)
    /// A record of a TYPE the import declared, its fields by name.
    case record(typeName: String, fields: [String: BASICFrameworkValue])
    case array([BASICFrameworkValue])
    /// A BASIC closure the program handed over, which the host calls back
    /// through `BASICFrameworkCallbacks.call`.
    case callable(id: Int)
}

/// What one `IMPORT` of a framework declares to the interpreter.
public struct BASICFrameworkModule: Sendable {
    /// A static type, which PRINT and DIM need before any value exists.
    public enum TypeRef: Sendable, Equatable {
        case number, string, boolean, array, callable, void, other
        case enumeration(String)
        case record(String)
        case object(String)
    }

    public struct Class: Sendable {
        public var name: String
        public var baseName: String?
        /// Properties and method results, by uppercased name.
        public var properties: [String: TypeRef]
        public var methods: [String: TypeRef]
        /// The methods a BASIC subclass may override, uppercased.
        public var overridable: Set<String>
        public init(name: String, baseName: String?, properties: [String: TypeRef], methods: [String: TypeRef], overridable: Set<String>) {
            self.name = name
            self.baseName = baseName
            self.properties = properties
            self.methods = methods
            self.overridable = overridable
        }
    }

    public struct Enumeration: Sendable {
        public var name: String
        public var cases: [String]
        public init(name: String, cases: [String]) {
            self.name = name
            self.cases = cases
        }
    }

    public struct Record: Sendable {
        public var name: String
        public var fields: [Field]
        public init(name: String, fields: [Field]) {
            self.name = name
            self.fields = fields
        }
        public struct Field: Sendable {
            public var name: String
            public var type: TypeRef
            public init(name: String, type: TypeRef) {
                self.name = name
                self.type = type
            }
        }
    }

    public var name: String
    public var classes: [Class]
    public var enumerations: [Enumeration]
    public var records: [Record]

    public init(name: String, classes: [Class], enumerations: [Enumeration], records: [Record]) {
        self.name = name
        self.classes = classes
        self.enumerations = enumerations
        self.records = records
    }
}

/// How a host calls BASIC back during a run that imports a framework.
public final class BASICFrameworkCallbacks: @unchecked Sendable {
    weak var interpreter: BASICInterpreter?

    init(interpreter: BASICInterpreter) {
        self.interpreter = interpreter
    }

    /// Calls the BASIC callable `id` — a closure the program handed over, or
    /// an override — with `arguments`, and answers its result. Call it on the
    /// interpreter's thread only: while the interpreter waits inside a host
    /// call, or at `frameworkPoll`. A BASIC error inside it is kept, and
    /// raised in the program when the host call it happened during returns.
    public func call(_ id: Int, arguments: [BASICFrameworkValue]) -> BASICFrameworkValue {
        interpreter?.callFrameworkCallable(id, arguments: arguments) ?? .empty
    }

    /// Whether Stop was pressed: asked while the host waits on the
    /// framework, so a program waiting for a window can still be stopped.
    public var isStopRequested: Bool {
        interpreter?.isFrameworkStopRequested ?? false
    }
}

/// A host that links Swift frameworks a program may `IMPORT`: BASICStudio,
/// through the map its compiled runs use.
public protocol BASICFrameworkHost: AnyObject {
    /// Whether `IMPORT "<module>"` names a framework this host links.
    func providesFramework(named module: String) -> Bool
    /// What the framework declares, for a run: its callbacks come with it.
    func importFramework(named module: String, callbacks: BASICFrameworkCallbacks) throws -> BASICFrameworkModule
    /// What the framework declares, for the editor's checks: no run starts.
    func describeFramework(named module: String) throws -> BASICFrameworkModule
    /// `NEW className(arguments)`.
    func frameworkNew(className: String, arguments: [BASICFrameworkValue]) throws -> BASICFrameworkValue
    /// `NEW` of a BASIC class inheriting `baseName`: the framework's object,
    /// its overrides — method name (uppercased) to callable id — registered.
    func frameworkNewSubclass(baseName: String, arguments: [BASICFrameworkValue], overrides: [String: Int]) throws -> BASICFrameworkValue
    func frameworkGet(_ object: BASICFrameworkValue, property: String) throws -> BASICFrameworkValue
    func frameworkSet(_ object: BASICFrameworkValue, property: String, value: BASICFrameworkValue) throws
    func frameworkCall(_ object: BASICFrameworkValue, method: String, arguments: [BASICFrameworkValue]) throws -> BASICFrameworkValue
    /// `Type.member` or `Type.member(arguments)`: a static property when
    /// `arguments` is nil, else a static method.
    func frameworkStatic(typeName: String, member: String, arguments: [BASICFrameworkValue]?) throws -> BASICFrameworkValue
    /// Makes the framework's waiting calls back; called between statements.
    func frameworkPoll() throws
    /// The run is over: let go of its objects.
    func frameworkRunEnded()
    /// For a closure's `WEAK` capture (CLOSURES.md C5): lets go of every
    /// object but those in `kept`, which the program can still reach, and
    /// `handle`; then answers whether anything still holds `handle` — the
    /// framework, say, which keeps a window it shows — and lets go of it if
    /// nothing does.
    func frameworkCollect(keeping kept: Set<Int>, asking handle: Int) -> Bool
}

extension BASICFrameworkHost {
    /// A host that cannot tell says yes, so no object is ever let go early.
    public func frameworkCollect(keeping kept: Set<Int>, asking handle: Int) -> Bool { true }
}

// MARK: - The runtime's side

/// A framework object the program holds.
struct BASICFrameworkObject {
    /// The framework class its members are looked up in.
    var className: String
    /// The BASIC class it is an instance of, when it is one.
    var userClass: String?
}

/// Something of the program's the host may call.
enum BASICFrameworkCallable {
    case closure(BASICCapturedClosure)
    case method(userClass: String, method: String, handle: Int)
}

extension BASICRuntime {
    /// Whether `name` is a class an imported framework declares.
    func isFrameworkClass(_ name: String) -> Bool {
        frameworkClasses[name.uppercased()] != nil
    }

    /// The framework class a BASIC class inherits from, through any BASIC
    /// classes between, or nil.
    func frameworkBase(ofUserClass name: String) -> String? {
        var current: String? = name
        var seen: Set<String> = []
        while let currentName = current, seen.insert(currentName.uppercased()).inserted {
            if isFrameworkClass(currentName) { return frameworkClasses[currentName.uppercased()]?.name }
            current = classDefinitions[currentName.uppercased()]?.baseClassName
        }
        return nil
    }

    /// A `WEAK` capture's value as a closure call starts (CLOSURES.md C5):
    /// the imported object while anything holds it, else `NULL`. Nothing in
    /// the interpreter counts references, so "anything" is asked of the host
    /// (the framework's own hold) and found by walking the program's values;
    /// an object neither holds is let go, as a compiled program's would be.
    func weakCaptureValue(_ value: BASICValue) -> BASICValue {
        guard case .systemObject(let typeName, let handle) = value, typeName.contains(".") else { return value }
        guard frameworkObjects[handle] != nil else { return .null }
        let kept = reachableFrameworkObjects()
        if kept.contains(handle) { return value }
        // What the program cannot reach goes first: one of those may be
        // all that holds this object, as a stack holds its children.
        let lives = frameworkHost?.frameworkCollect(keeping: kept, asking: handle) ?? true
        frameworkObjects = frameworkObjects.filter { kept.contains($0.key) || ($0.key == handle && lives) }
        return lives ? value : .null
    }

    /// The framework objects any value the program can still reach refers
    /// to: its variables, every frame's locals, what closures share or copy
    /// (not their WEAK captures), and the closures it handed the framework.
    private func reachableFrameworkObjects() -> Set<Int> {
        var found: Set<Int> = []
        var seenClosures: Set<ObjectIdentifier> = []
        func visit(_ value: BASICValue) {
            switch value {
            case .systemObject(let typeName, let id) where typeName.contains("."):
                found.insert(id)
            case .record(_, let fields), .object(_, let fields):
                fields.values.forEach(visit)
            case .array(let array):
                array.values.forEach(visit)
            case .dictionary(let dictionary):
                dictionary.values.values.forEach(visit)
            case .closure(let closure):
                guard seenClosures.insert(ObjectIdentifier(closure)).inserted else { return }
                for cell in closure.environment.orderedCells where cell.access != .weak { visit(cell.value) }
            default:
                break
            }
        }
        allBindings().forEach { visit($0.value) }
        for case .closure(let closure) in frameworkCallables.values { visit(.closure(closure)) }
        return found
    }

    /// The framework object a value is, with its handle.
    func frameworkObject(_ value: BASICValue) -> (handle: Int, object: BASICFrameworkObject)? {
        guard case .systemObject(let typeName, let id) = value, typeName.contains("."),
              let object = frameworkObjects[id] else { return nil }
        return (id, object)
    }

    /// The type name a framework object's value carries.
    func frameworkTypeName(_ className: String) -> String {
        "\(frameworkClassModules[className.uppercased()] ?? "Framework").\(className)"
    }

    /// Whether `field` is one of the BASIC class's own fields (inherited from
    /// BASIC classes included), not the framework's.
    func isUserField(_ field: String, ofUserClass userClass: String) -> Bool {
        guard let definition = classDefinitions[userClass.uppercased()] else { return false }
        return inheritedFields(for: definition).contains { $0.normalizedName == field.uppercased() }
    }

    func requireFrameworkHost() throws -> BASICFrameworkHost {
        guard let frameworkHost else {
            throw BASICError.runtime("This host links no frameworks to import")
        }
        return frameworkHost
    }

    /// A BASIC error a call back made while the host was busy, raised now.
    func throwPendingFrameworkError() throws {
        if let error = pendingFrameworkError {
            pendingFrameworkError = nil
            throw error
        }
    }

    // MARK: Values across

    func frameworkValue(_ value: BASICValue) throws -> BASICFrameworkValue {
        switch value {
        case .empty: return .empty
        case .null: return .null
        case .number(let number): return .number(number)
        case .string(let text): return .string(text.description)
        case .boolean(let flag): return .boolean(flag)
        case .decimal(let decimal): return .number(NSDecimalNumber(decimal: decimal).doubleValue)
        case .systemObject:
            guard let (handle, object) = frameworkObject(value) else {
                throw BASICError.runtime("\(value) cannot be handed to a framework")
            }
            return .object(handle: handle, className: object.className)
        case .record(let name, let fields):
            var converted: [String: BASICFrameworkValue] = [:]
            for (field, fieldValue) in fields where !field.hasPrefix("$") {
                converted[field] = try frameworkValue(fieldValue)
            }
            return .record(typeName: recordDefinitions[name.uppercased()]?.displayName ?? name, fields: converted)
        case .array(let array):
            return .array(try array.values.map(frameworkValue))
        case .closure(let closure):
            let id = nextFrameworkCallable
            nextFrameworkCallable += 1
            frameworkCallables[id] = .closure(closure)
            return .callable(id: id)
        default:
            throw BASICError.runtime("\(value) cannot be handed to a framework")
        }
    }

    func basicValue(_ value: BASICFrameworkValue) -> BASICValue {
        switch value {
        case .empty, .callable: return .empty
        case .null: return .null
        case .number(let number): return .number(number)
        case .string(let text): return .string(BASICString(text))
        case .boolean(let flag): return .boolean(flag)
        case .object(let handle, let className):
            if let known = frameworkObjects[handle], let userClass = known.userClass {
                return .systemObject(frameworkTypeName(userClass), handle)
            }
            frameworkObjects[handle] = BASICFrameworkObject(className: className, userClass: nil)
            return .systemObject(frameworkTypeName(className), handle)
        case .record(let typeName, let fields):
            let definition = recordDefinitions[typeName.uppercased()]
            var converted: [String: BASICValue] = [:]
            for (field, fieldValue) in fields { converted[field.uppercased()] = basicValue(fieldValue) }
            return .record(definition?.displayName ?? typeName, converted)
        case .array(let elements):
            return .array(BASICArray(dimensions: [elements.count - 1], type: .scalar(.variant), isDynamic: true,
                                     values: elements.map(basicValue)))
        }
    }

    // MARK: Members

    /// `object.field`: a BASIC class's own field, or the framework's property.
    func frameworkProperty(handle: Int, object: BASICFrameworkObject, field: String) throws -> BASICValue {
        if let userClass = object.userClass, isUserField(field, ofUserClass: userClass) {
            return frameworkFields[handle]?[field.uppercased()] ?? .empty
        }
        let answer = try requireFrameworkHost().frameworkGet(.object(handle: handle, className: object.className), property: field)
        try throwPendingFrameworkError()
        return basicValue(answer)
    }

    /// `object.field = value`.
    func setFrameworkProperty(handle: Int, object: BASICFrameworkObject, field: String, value: BASICValue) throws {
        if let userClass = object.userClass, isUserField(field, ofUserClass: userClass) {
            let declared = classDefinitions[userClass.uppercased()].flatMap { definition in
                inheritedFields(for: definition).first { $0.normalizedName == field.uppercased() }
            }
            let coerced = try declared.map { try coerce(value, to: $0.type, variable: VariableName(name: field, column: 0)) } ?? value
            frameworkFields[handle, default: [:]][field.uppercased()] = coerced
            return
        }
        try requireFrameworkHost().frameworkSet(.object(handle: handle, className: object.className), property: field,
                                                value: try frameworkValue(value))
        try throwPendingFrameworkError()
    }

    /// The ENUM a framework object's property is, for PRINT.
    func frameworkPropertyEnum(className: String, property: String) -> String? {
        var current: String? = className
        var seen: Set<String> = []
        while let name = current, seen.insert(name.uppercased()).inserted, let type = frameworkClasses[name.uppercased()] {
            if case .enumeration(let enumName)? = type.properties[property.uppercased()] { return enumName }
            if type.properties[property.uppercased()] != nil { return nil }
            current = type.baseName
        }
        return nil
    }

    /// The run is over: the host lets go of its objects.
    func endFrameworkRun() {
        frameworkHost?.frameworkRunEnded()
        frameworkHost = nil
        frameworkCallbacks = nil
        frameworkClasses.removeAll()
        frameworkClassModules.removeAll()
        frameworkObjects.removeAll()
        frameworkFields.removeAll()
        frameworkCallables.removeAll()
        nextFrameworkCallable = 1
        pendingFrameworkError = nil
    }
}
