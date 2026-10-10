//
//  StudioInterpretedFrameworks.swift
//  BASICStudio
//
//  ▶ Run of a program that imports a framework Studio contains (BASIC-45,
//  slice 11e): the interpreter's `IMPORT "ActiveUI"` / `IMPORT "TUIKit"`.
//
//  ⚡ compiles such a program and its module calls the framework map's
//  entries by name. ▶ Run calls the very same entries, through the same
//  shims, so the two cannot disagree about what a member does. BASICCore
//  asks for a member by its BASIC name; this finds the shim in the compiler's
//  own model of the map (`SwiftPackageResolver.shimModel`), turns BASIC
//  values into the numbers the entry takes — runtime strings, records,
//  arrays and closures made by `WasmHostedCalls` — and the result back.
//
//  The framework calls BASIC back as it does a module: a handler, a closure
//  or an override reaches `callBASIC` with a number this run gave out, on the
//  interpreter's thread — while it waits inside a framework call, or between
//  statements (`frameworkPoll`).
//

import BASICCore
import BASICDialectSwift
import BASICFrameworkMap
import BASICWasmRunner
import Foundation

// MARK: - One framework, as ▶ Run looks members up in it

/// A framework's API and its map's shims, indexed by BASIC name. Built once
/// per framework and kept: reading ActiveUI's graph takes a few seconds.
final class StudioFrameworkModel: @unchecked Sendable {
    struct ClassInfo {
        let name: String
        let baseName: String?
        let declared: SwiftAPI.Class
    }

    let module: String
    let api: SwiftAPI
    let shims: SwiftAsyncShim
    private(set) var classes: [String: ClassInfo] = [:]
    /// Methods by their shim's owner (`AUIView`, or `AUIColor_shared` for a
    /// static or a box's member), then by uppercased name.
    private(set) var methods: [String: [String: SwiftAsyncShim.Method]] = [:]
    /// Initializers by class, then by BASIC arity.
    private(set) var initializers: [String: [Int: SwiftAsyncShim.Method]] = [:]
    /// Properties by "OWNER.NAME", uppercased.
    private(set) var plainProperties: [String: SwiftAsyncShim.PlainProperty] = [:]
    private(set) var enumProperties: [String: SwiftAsyncShim.EnumProperty] = [:]
    private(set) var structProperties: [String: SwiftAsyncShim.StructProperty] = [:]
    private(set) var opaqueProperties: [String: SwiftAsyncShim.OpaqueProperty] = [:]
    private(set) var handlerProperties: [String: SwiftAsyncShim.HandlerProperty] = [:]
    /// Records by BASIC name (uppercased), and the BASIC name of each by
    /// the struct's Swift spelling.
    private(set) var records: [String: (name: String, shape: SwiftAsyncShim.RecordStruct)] = [:]
    private(set) var recordNames: [String: String] = [:]
    /// The BASIC name of each class a box holds, by its Swift spelling.
    private(set) var boxNames: [String: String] = [:]
    /// What an import declares, made once.
    private(set) var declarations = BASICFrameworkModule(name: "", classes: [], enumerations: [], records: [])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: StudioFrameworkModel] = [:]

    /// The framework a program imports by `name`, or nil when Studio does not
    /// contain it.
    static func named(_ name: String) throws -> StudioFrameworkModel? {
        guard let framework = StudioFrameworkMap.imports.framework(named: name) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = loaded[framework.module] { return known }
        let made = StudioFrameworkModel(module: framework.module, api: try StudioFrameworkMap.imports.api(of: framework))
        loaded[framework.module] = made
        return made
    }

    private init(module: String, api: SwiftAPI) {
        self.module = module
        self.api = api
        shims = SwiftPackageResolver.shimModel(for: api, mapped: true)
        for declared in api.classes {
            let base = declared.superclassPrecise.flatMap { api.class(precise: $0)?.name }
            classes[declared.name.uppercased()] = ClassInfo(name: declared.name, baseName: base, declared: declared)
        }
        for method in shims.methods {
            if method.isInitializer {
                initializers[method.className.uppercased(), default: [:]][method.basicArity] = method
            } else {
                methods[method.className.uppercased(), default: [:]][method.name.uppercased()] = method
            }
        }
        func key(_ owner: String, _ name: String) -> String { "\(owner).\(name)".uppercased() }
        for property in shims.plainProperties { plainProperties[key(property.className, property.name)] = property }
        for property in shims.properties { enumProperties[key(property.className, property.name)] = property }
        for property in shims.structProperties { structProperties[key(property.className, property.name)] = property }
        for property in shims.opaqueProperties { opaqueProperties[key(property.className, property.name)] = property }
        for property in shims.handlerProperties { handlerProperties[key(property.className, property.name)] = property }
        for structure in api.structures.values {
            guard let shape = SwiftPackageResolver.recordStruct(.structure(precise: structure.precise), in: api) else { continue }
            let name = structure.name.replacingOccurrences(of: ".", with: "_")
            records[name.uppercased()] = (name, shape)
            recordNames[shape.swiftName] = name
        }
        // A box is a CLASS of its struct's name.
        for declared in api.classes where declared.isOpaque {
            boxNames[api.structures[declared.precise]?.name ?? declared.name] = declared.name
        }
        declarations = describe()
    }

    /// The class `name` and every class above it, nearest first.
    func chain(of name: String) -> [ClassInfo] {
        var out: [ClassInfo] = []
        var current: String? = name
        var seen: Set<String> = []
        while let here = current, seen.insert(here.uppercased()).inserted, let info = classes[here.uppercased()] {
            out.append(info)
            current = info.baseName
        }
        return out
    }

    /// The BASIC name of the ENUM a shim's plain enum is.
    func enumName(_ type: SwiftAsyncShim.PlainEnum) -> String {
        api.enumerations.values.first { $0.swiftName == type.swiftName || $0.name == type.swiftName }?.name
            ?? type.swiftName.replacingOccurrences(of: ".", with: "_")
    }

    /// The BASIC name of a box's class, from a shim's Swift spelling.
    func boxName(_ swiftName: String) -> String {
        let bare = swiftName.hasSuffix("?") ? String(swiftName.dropLast()) : swiftName
        let unqualified = bare.hasPrefix(module + ".") ? String(bare.dropFirst(module.count + 1)) : bare
        return boxNames[unqualified] ?? unqualified.replacingOccurrences(of: ".", with: "_")
    }

    /// The BASIC name of a record, from its shape's Swift spelling.
    func recordName(_ shape: SwiftAsyncShim.RecordStruct) -> String {
        recordNames[shape.swiftName] ?? shape.swiftName.replacingOccurrences(of: ".", with: "_")
    }

    // MARK: What the import declares

    private func describe() -> BASICFrameworkModule {
        func typeRef(_ type: SwiftAPI.ValueType) -> BASICFrameworkModule.TypeRef {
            switch type {
            case .double, .int, .cgFloat, .duration: return .number
            case .bool: return .boolean
            case .string: return .string
            case .object(let precise): return api.class(precise: precise).map { .object($0.name) } ?? .other
            case .protocolType: return .other
            case .enumeration(let precise): return api.enumerations[precise].map { .enumeration($0.name) } ?? .other
            case .structure(let precise):
                return api.structures[precise].map { .record($0.name.replacingOccurrences(of: ".", with: "_")) } ?? .other
            case .opaque(let precise, _): return api.class(precise: precise).map { .object($0.name) } ?? .other
            case .array: return .array
            case .handler, .voidClosure: return .callable
            case .void: return .void
            default: return .other
            }
        }
        let declaredClasses = api.classes.map { declared -> BASICFrameworkModule.Class in
            var properties: [String: BASICFrameworkModule.TypeRef] = [:]
            for property in declared.properties + declared.boxProperties + declared.staticProperties {
                properties[property.name.uppercased()] = typeRef(property.type)
            }
            var results: [String: BASICFrameworkModule.TypeRef] = [:]
            for method in declared.methods + declared.boxMethods + declared.staticMethods {
                results[method.name.uppercased()] = typeRef(method.returns)
            }
            let overridable = declared.isOpen
                ? Set(SwiftForwarding.methods(of: declared, in: api).map { $0.name.uppercased() }) : []
            return BASICFrameworkModule.Class(
                name: declared.name, baseName: declared.superclassPrecise.flatMap { api.class(precise: $0)?.name },
                properties: properties, methods: results, overridable: overridable)
        }
        let enumerations = api.enumerations.values.filter { !$0.isPayload }.map {
            BASICFrameworkModule.Enumeration(name: $0.name, cases: $0.cases)
        }
        let declaredRecords = records.values.map { record in
            BASICFrameworkModule.Record(name: record.name, fields: zip(record.shape.leafPaths, record.shape.leafTypes).map { path, type in
                BASICFrameworkModule.Record.Field(name: path.replacingOccurrences(of: ".", with: "_"), type: Self.leafType(type))
            })
        }
        return BASICFrameworkModule(name: module, classes: declaredClasses, enumerations: enumerations, records: declaredRecords)
    }

    /// A leaf's or an array element's type: a Swift spelling (`Bool`,
    /// `Swift.String`) or a shim's element tag (`bool`, `string`).
    static func leafType(_ swift: String) -> BASICFrameworkModule.TypeRef {
        switch swift.lowercased() {
        case "bool", "swift.bool": return .boolean
        case "string", "swift.string": return .string
        default: return .number
        }
    }
}

// MARK: - One ▶ Run

/// The run of a program that imports a framework: the objects it holds, the
/// numbers it gave out for BASIC callables, and the entries it calls.
final class StudioInterpretedFrameworks: WasmCallbackHost, @unchecked Sendable {
    /// The one run in progress: the interpreter runs one program at a time.
    nonisolated(unsafe) static var current: StudioInterpretedFrameworks?

    let basicThread: Thread
    private let callbacks: BASICFrameworkCallbacks
    private let entries: [String: WasmEntryPoint]
    private var frameworks: [String: StudioFrameworkModel] = [:]
    /// The objects the program holds, by handle, and each one's handle.
    private var objects: [Int: AnyObject] = [:]
    private var handles: [ObjectIdentifier: Int] = [:]
    private var classOfHandle: [Int: (module: String, name: String)] = [:]
    private var nextHandle = 1
    /// Record types registered with the runtime for this run.
    private var recordTypeIndexes: [String: Int] = [:]
    private var nextTypeIndex = 1
    /// Overrides: the callable's id to the framework method it overrides.
    private var overrides: [Int: SwiftAPI.Function] = [:]
    /// Providers: the callable's id to what the framework reads its answer
    /// as — `Bool`, `String`, or a number.
    private var providers: [Int: String] = [:]
    /// What the runtime wrote: a shim's error message.
    private var written = ""

    init(callbacks: BASICFrameworkCallbacks, entries: [String: WasmEntryPoint]) {
        self.callbacks = callbacks
        self.entries = entries
        basicThread = Thread.current
        WasmHostedCalls.begin(callbacks: self, output: { [weak self] text in self?.written += text },
                              isStopRequested: { [weak callbacks] in callbacks?.isStopRequested ?? false })
    }

    func end() {
        WasmHostedCalls.end()
        // A UI object lets go on the main thread, where it lives.
        let held = objects
        objects = [:]
        handles = [:]
        DispatchQueue.main.async { _ = held }
    }

    func add(_ framework: StudioFrameworkModel) {
        frameworks[framework.module] = framework
        for record in framework.records.values where recordTypeIndexes[record.name.uppercased()] == nil {
            let index = nextTypeIndex
            nextTypeIndex += 1
            recordTypeIndexes[record.name.uppercased()] = index
            WasmHostedCalls.registerRecord(typeIndex: index, name: record.name, fields: zip(record.shape.leafPaths, record.shape.leafTypes).map {
                (name: $0.replacingOccurrences(of: ".", with: "_"), kind: Self.kind(StudioFrameworkModel.leafType($1)))
            })
        }
    }

    // MARK: Calling an entry

    private func call(_ symbol: String, _ arguments: [Double]) throws -> Double {
        guard let entry = entries[symbol] else {
            throw BASICError.runtime("\(symbol) is not in Studio's map of the framework")
        }
        var padded = arguments
        while padded.count < entry.arity { padded.append(0) }
        written = ""
        let (result, code) = WasmHostedCalls.call(entry, padded)
        try check(code)
        return result
    }

    /// An unwind code as the program sees it: an error raised in a shim is a
    /// BASIC error, which ON ERROR can catch; Stop is left for the
    /// interpreter's own check at its next statement.
    private func check(_ code: Int32) throws {
        guard code != 0, code != WasmHostedCalls.stopCode else { return }
        var message = written.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Runtime error: ", "Error: "] where message.hasPrefix(prefix) { message = String(message.dropFirst(prefix.count)) }
        written = ""
        throw BASICError.runtime(message.isEmpty ? "The framework call failed" : message)
    }

    // MARK: Objects

    private func object(_ handle: Int) throws -> AnyObject {
        guard let held = objects[handle] else { throw BASICError.runtime("That framework object is gone") }
        return held
    }

    private func bits(of handle: Int) throws -> Double {
        Double(UInt(bitPattern: Unmanaged.passUnretained(try object(handle)).toOpaque()))
    }

    /// A +1 object a shim handed out, as a value: the same object is always
    /// the same handle, so `A = B` aliases and comparisons hold.
    private func adopt(_ bits: Double, declared: String, in framework: StudioFrameworkModel) -> BASICFrameworkValue {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else { return .null }
        let held = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        if let known = handles[ObjectIdentifier(held)] {
            return .object(handle: known, className: classOfHandle[known]?.name ?? declared)
        }
        let handle = nextHandle
        nextHandle += 1
        objects[handle] = held
        handles[ObjectIdentifier(held)] = handle
        let name = dynamicClass(of: bits, declared: declared, in: framework)
        classOfHandle[handle] = (framework.module, name)
        return .object(handle: handle, className: name)
    }

    /// The nearest class the map knows of an object, as the compiled program
    /// asks it: through the framework's class index.
    private func dynamicClass(of bits: Double, declared: String, in framework: StudioFrameworkModel) -> String {
        guard let index = entries["basic_classid_\(framework.module)"] else { return declared }
        var argument = [bits]
        let position = Int(argument.withUnsafeMutableBufferPointer { index.call(UnsafePointer($0.baseAddress!)) })
        guard framework.shims.mappedClasses.indices.contains(position) else { return declared }
        return framework.shims.mappedClasses[position]
    }

    private func framework(ofHandle handle: Int) throws -> StudioFrameworkModel {
        guard let module = classOfHandle[handle]?.module, let framework = frameworks[module] else {
            throw BASICError.runtime("That framework object is gone")
        }
        return framework
    }

    private func framework(ofClass name: String) throws -> StudioFrameworkModel {
        if let found = frameworks.values.first(where: { $0.classes[name.uppercased()] != nil }) { return found }
        throw BASICError.runtime("\(name) is not a class of an imported framework")
    }

    // MARK: NEW

    func new(className: String, arguments: [BASICFrameworkValue]) throws -> BASICFrameworkValue {
        let framework = try framework(ofClass: className)
        guard let initializers = framework.initializers[className.uppercased()], !initializers.isEmpty else {
            throw BASICError.runtime("\(className) has no NEW a program can call")
        }
        let initializer = initializers[arguments.count] ?? initializers.values.min { $0.basicArity < $1.basicArity }!
        var cleanup: [() -> Void] = []
        defer { cleanup.forEach { $0() } }
        let made = try call(initializer.symbol, try encode(arguments, for: initializer, receiver: nil, in: framework, cleanup: &cleanup))
        if made == 0 { return .null }
        if let box = initializer.opaqueResult { return adopt(made, declared: framework.boxName(box), in: framework) }
        return adopt(made, declared: className, in: framework)
    }

    func newSubclass(baseName: String, arguments: [BASICFrameworkValue], overrides requested: [String: Int]) throws -> BASICFrameworkValue {
        let framework = try framework(ofClass: baseName)
        guard let base = framework.classes[baseName.uppercased()], base.declared.isOpen,
              let initializers = framework.initializers[baseName.uppercased()],
              let initializer = initializers[arguments.count] ?? initializers.values.min(by: { $0.basicArity < $1.basicArity }) else {
            throw BASICError.runtime("\(baseName) cannot be inherited by a BASIC class")
        }
        var cleanup: [() -> Void] = []
        defer { cleanup.forEach { $0() } }
        let symbol = "basic_new_BASICForward_\(base.name)_\(initializer.basicArity)"
        let made = try call(symbol, try encode(arguments, for: initializer, receiver: nil, in: framework, cleanup: &cleanup))
        guard made != 0 else { return .null }
        // The record a compiled object keeps its own fields in: BASICCore
        // keeps them, so there is none.
        _ = try call("basic_forward_setup", [made, -1, 0])
        let slots = SwiftForwarding.methods(of: base.declared, in: framework.api)
        for (method, id) in requested {
            guard let slot = slots.firstIndex(where: { $0.name.uppercased() == method }) else {
                throw BASICError.runtime("\(base.name) has no method \(method) a BASIC class can override")
            }
            overrides[id] = slots[slot]
            _ = try call("basic_forward_override", [made, Double(slot), Double(id)])
        }
        let value = adopt(made, declared: base.name, in: framework)
        if case .object(let handle, _) = value { classOfHandle[handle] = (framework.module, base.name) }
        return value.withClass(base.name)
    }

    // MARK: Members

    private func propertyKey(_ owner: String, _ name: String) -> String { "\(owner).\(name)".uppercased() }

    func get(_ value: BASICFrameworkValue, property: String) throws -> BASICFrameworkValue {
        guard case .object(let handle, let className) = value else { throw BASICError.runtime("Not a framework object") }
        let framework = try framework(ofHandle: handle)
        let me = try bits(of: handle)
        for owner in framework.chain(of: className).map(\.name) {
            let key = propertyKey(owner, property)
            if let plain = framework.plainProperties[key] {
                return try decodePlain(try call(plain.getter, [me]), kind: plain.kind, in: framework)
            }
            if let enumerated = framework.enumProperties[key] {
                return .number(try call(enumerated.getter, [me]))
            }
            if let structured = framework.structProperties[key] {
                return try decodeRecord(try call(structured.getter, [me, Double(typeIndex(structured.type, in: framework))]),
                                        shape: structured.type, in: framework)
            }
            if let boxed = framework.opaqueProperties[key] {
                return adopt(try call(boxed.getter, [me, 0]), declared: framework.boxName(boxed.swiftName), in: framework)
            }
            if framework.handlerProperties[key] != nil {
                throw BASICError.runtime("\(owner).\(property) is a handler: it can be set, not read")
            }
            // A box's property is its member function, called with the box.
            if let member = framework.methods["\(owner)_shared".uppercased()]?[property.uppercased()], member.isProperty,
               case .opaque = member.receiver {
                return try invoke(member, receiver: me, arguments: [], in: framework)
            }
        }
        // A method with no arguments read as a property.
        return try callMethod(value, method: property, arguments: [])
    }

    func set(_ value: BASICFrameworkValue, property: String, to newValue: BASICFrameworkValue) throws {
        guard case .object(let handle, let className) = value else { throw BASICError.runtime("Not a framework object") }
        let framework = try framework(ofHandle: handle)
        let me = try bits(of: handle)
        var cleanup: [() -> Void] = []
        defer { cleanup.forEach { $0() } }
        for owner in framework.chain(of: className).map(\.name) {
            let key = propertyKey(owner, property)
            if let plain = framework.plainProperties[key] {
                guard plain.isSettable else { break }
                _ = try call(plain.setter, [me, try encodePlain(newValue, kind: plain.kind, cleanup: &cleanup)])
                return
            }
            if let enumerated = framework.enumProperties[key] {
                guard enumerated.isSettable else { break }
                _ = try call(enumerated.setter, [me, try number(newValue)])
                return
            }
            if let structured = framework.structProperties[key] {
                guard structured.isSettable else { break }
                let record = try encodeRecord(newValue, shape: structured.type, in: framework)
                cleanup.append { WasmHostedCalls.releaseRecord(record) }
                _ = try call(structured.setter, [me, record])
                return
            }
            if let boxed = framework.opaqueProperties[key] {
                guard boxed.isSettable else { break }
                _ = try call(boxed.setter, [me, try objectBits(newValue)])
                return
            }
            if let handler = framework.handlerProperties[key] {
                switch newValue {
                case .callable(let id):
                    if let answers = handler.returns { providers[id] = answers }
                    _ = try call(handler.setter, [me, Double(id), 0])
                case .null, .empty: _ = try call(handler.setter, [me, 0, 0])
                default: throw BASICError.runtime("\(owner).\(property) takes a FUNCTION")
                }
                return
            }
        }
        throw BASICError.runtime("\(className) has no property \(property) a program can set")
    }

    func callMethod(_ value: BASICFrameworkValue, method: String, arguments: [BASICFrameworkValue]) throws -> BASICFrameworkValue {
        guard case .object(let handle, let className) = value else { throw BASICError.runtime("Not a framework object") }
        let framework = try framework(ofHandle: handle)
        let me = try bits(of: handle)
        for owner in framework.chain(of: className).map(\.name) {
            if let found = framework.methods[owner.uppercased()]?[method.uppercased()] {
                return try invoke(found, receiver: me, arguments: arguments, in: framework)
            }
            if let found = framework.methods["\(owner)_shared".uppercased()]?[method.uppercased()], case .opaque = found.receiver {
                return try invoke(found, receiver: me, arguments: arguments, in: framework)
            }
        }
        throw BASICError.runtime("\(className) has no method \(method)")
    }

    func callStatic(typeName: String, member: String, arguments: [BASICFrameworkValue]?) throws -> BASICFrameworkValue {
        let framework = try framework(ofClass: typeName)
        guard let found = framework.methods["\(typeName)_shared".uppercased()]?[member.uppercased()] else {
            throw BASICError.runtime("\(typeName) has no shared member \(member)")
        }
        return try invoke(found, receiver: nil, arguments: arguments ?? [], in: framework)
    }

    private func invoke(_ method: SwiftAsyncShim.Method, receiver: Double?, arguments: [BASICFrameworkValue],
                        in framework: StudioFrameworkModel) throws -> BASICFrameworkValue {
        var cleanup: [() -> Void] = []
        defer { cleanup.forEach { $0() } }
        let answer = try call(method.symbol, try encode(arguments, for: method, receiver: receiver, in: framework, cleanup: &cleanup))
        return try decodeResult(answer, of: method, in: framework)
    }

    // MARK: Values in

    private static func kind(_ type: BASICFrameworkModule.TypeRef) -> WasmHostedCalls.Kind {
        switch type {
        case .string: return .string
        case .boolean: return .boolean
        default: return .number
        }
    }

    private func number(_ value: BASICFrameworkValue) throws -> Double {
        switch value {
        case .number(let number): return number
        case .boolean(let flag): return flag ? 1 : 0
        case .empty, .null: return 0
        case .string(let text): return Double(text) ?? 0
        default: throw BASICError.type(message: "Type Mismatch")
        }
    }

    private func objectBits(_ value: BASICFrameworkValue) throws -> Double {
        switch value {
        case .object(let handle, _): return try bits(of: handle)
        case .null, .empty: return 0
        default: throw BASICError.type(message: "Expected a framework object")
        }
    }

    private func string(_ value: BASICFrameworkValue, cleanup: inout [() -> Void]) -> Double {
        let text: String
        switch value {
        case .string(let words): text = words
        case .number(let number): text = number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .boolean(let flag): text = flag ? "TRUE" : "FALSE"
        default: text = ""
        }
        let made = WasmHostedCalls.newString(text)
        cleanup.append { WasmHostedCalls.releaseString(made) }
        return made
    }

    private func encodePlain(_ value: BASICFrameworkValue, kind: SwiftAsyncShim.PlainProperty.Kind,
                             cleanup: inout [() -> Void]) throws -> Double {
        switch kind {
        case .string: return string(value, cleanup: &cleanup)
        case .object, .protocolType: return try objectBits(value)
        default: return try number(value)
        }
    }

    private func typeIndex(_ shape: SwiftAsyncShim.RecordStruct, in framework: StudioFrameworkModel) -> Int {
        recordTypeIndexes[framework.recordName(shape).uppercased()] ?? 0
    }

    private func encodeRecord(_ value: BASICFrameworkValue, shape: SwiftAsyncShim.RecordStruct,
                              in framework: StudioFrameworkModel) throws -> Double {
        guard case .record(_, let fields) = value else { throw BASICError.type(message: "Expected a \(framework.recordName(shape))") }
        let byName = Dictionary(fields.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let values = try zip(shape.leafPaths, shape.leafTypes).map { path, type -> WasmHostedCalls.Value in
            let field = byName[path.replacingOccurrences(of: ".", with: "_").uppercased()] ?? .empty
            switch StudioFrameworkModel.leafType(type) {
            case .string: if case .string(let text) = field { return .string(text) }; return .string("")
            case .boolean: return .boolean(try number(field) != 0)
            default: return .number(try number(field))
            }
        }
        return WasmHostedCalls.makeRecord(typeIndex: typeIndex(shape, in: framework), values: values)
    }

    /// The numbers an entry takes for `method`: the receiver, then each
    /// parameter as the shim lays it out — a struct as its leaves (BASIC
    /// passes them one by one), a `() -> Void` as two slots, the closure in
    /// the second — and the record type index a record or box result needs.
    private func encode(_ arguments: [BASICFrameworkValue], for method: SwiftAsyncShim.Method, receiver: Double?,
                        in framework: StudioFrameworkModel, cleanup: inout [() -> Void]) throws -> [Double] {
        var out: [Double] = []
        if let receiver { out.append(receiver) }
        var next = 0
        func take() -> BASICFrameworkValue {
            defer { next += 1 }
            return arguments.indices.contains(next) ? arguments[next] : .empty
        }
        for index in method.parameterTypes.indices {
            if method.closureParameters.contains(index) {
                guard case .callable(let id) = take() else { throw BASICError.runtime("\(method.name) takes a FUNCTION") }
                let closure = WasmHostedCalls.closure(target: id)
                cleanup.append { WasmHostedCalls.releaseClosure(closure) }
                out += [0, closure]
            } else if let structure = method.structParameters[index] {
                for leaf in structure.leafTypes {
                    let value = take()
                    out.append(StudioFrameworkModel.leafType(leaf) == .string ? string(value, cleanup: &cleanup) : try number(value))
                }
            } else if method.opaqueParameters[index] != nil || method.objectParameters[index] != nil
                        || method.protocolParameters[index] != nil {
                out.append(try objectBits(take()))
            } else if method.payloadParameters[index] != nil {
                throw BASICError.runtime("\(method.name) takes an ENUM with values, which ▶ Run cannot pass yet; use ⚡")
            } else if let element = method.arrayParameters[index] {
                guard case .array(let elements) = take() else { throw BASICError.runtime("\(method.name) takes an array") }
                let kind = Self.kind(StudioFrameworkModel.leafType(element))
                let values = try elements.map { element -> WasmHostedCalls.Value in
                    switch kind {
                    case .string: if case .string(let text) = element { return .string(text) }; return .string("")
                    case .boolean: return .boolean(try number(element) != 0)
                    case .number: return .number(try number(element))
                    }
                }
                let array = WasmHostedCalls.makeArray(values, kind: kind)
                cleanup.append { WasmHostedCalls.releaseValue(array) }
                out.append(array)
            } else if method.stringParameters.contains(index) {
                out.append(string(take(), cleanup: &cleanup))
            } else {
                out.append(try number(take()))
            }
        }
        if let shape = method.structResult {
            out.append(Double(typeIndex(shape, in: framework)))
        } else if method.opaqueResult != nil {
            out.append(0)
        } else if method.payloadResult != nil {
            out.append(0)
        }
        return out
    }

    // MARK: Values out

    private func decodePlain(_ answer: Double, kind: SwiftAsyncShim.PlainProperty.Kind,
                             in framework: StudioFrameworkModel) throws -> BASICFrameworkValue {
        switch kind {
        case .string:
            defer { WasmHostedCalls.releaseString(answer) }
            return .string(WasmHostedCalls.readString(answer))
        case .bool: return .boolean(answer != 0)
        case .object(let name), .protocolType(let name): return adopt(answer, declared: name, in: framework)
        default: return .number(answer)
        }
    }

    private func decodeRecord(_ answer: Double, shape: SwiftAsyncShim.RecordStruct,
                              in framework: StudioFrameworkModel) throws -> BASICFrameworkValue {
        defer { WasmHostedCalls.releaseRecord(answer) }
        let kinds = shape.leafTypes.map { Self.kind(StudioFrameworkModel.leafType($0)) }
        let values = WasmHostedCalls.readRecord(answer, kinds: kinds)
        var fields: [String: BASICFrameworkValue] = [:]
        for (path, value) in zip(shape.leafPaths, values) {
            let name = path.replacingOccurrences(of: ".", with: "_")
            switch value {
            case .number(let number): fields[name] = .number(number)
            case .string(let text): fields[name] = .string(text)
            case .boolean(let flag): fields[name] = .boolean(flag)
            }
        }
        return .record(typeName: framework.recordName(shape), fields: fields)
    }

    private func decodeResult(_ answer: Double, of method: SwiftAsyncShim.Method,
                              in framework: StudioFrameworkModel) throws -> BASICFrameworkValue {
        if method.stringResult {
            defer { WasmHostedCalls.releaseString(answer) }
            return .string(WasmHostedCalls.readString(answer))
        }
        if let className = method.objectResult { return adopt(answer, declared: className, in: framework) }
        if let shape = method.structResult { return try decodeRecord(answer, shape: shape, in: framework) }
        if let box = method.opaqueResult { return adopt(answer, declared: framework.boxName(box), in: framework) }
        if let element = method.arrayResult {
            let values = WasmHostedCalls.takeArray(answer, kind: Self.kind(StudioFrameworkModel.leafType(element)))
            return .array(values.map { value in
                switch value {
                case .number(let number): return .number(number)
                case .string(let text): return .string(text)
                case .boolean(let flag): return .boolean(flag)
                }
            })
        }
        if method.payloadResult != nil { return .empty }
        if method.enumResult != nil || method.durationResult { return .number(answer) }
        switch method.returns {
        case nil: return .empty
        case "Swift.Bool"?, "Bool"?: return .boolean(answer != 0)
        case "Swift.Void"?, "Void"?, "()"?: return .empty
        default: return .number(answer)
        }
    }

    // MARK: BASIC, called back

    /// The framework calls back with a number this run gave out: an
    /// override's (its arguments and result in `argument`, a frame), or a
    /// closure's.
    func callBASIC(_ target: Double, argument: UnsafeMutableRawPointer?) -> Double {
        let id = Int(target)
        guard let method = overrides[id], let frame = argument else {
            let answer = callbacks.call(id, arguments: [])
            // A provider's answer, as its native function reads it: a
            // string owned by the shim, which releases it; a truth value as
            // 1 or 0.
            switch providers[id] {
            case "String"?:
                switch answer {
                case .string(let text): return WasmHostedCalls.newString(text)
                case .number(let number): return WasmHostedCalls.newString(number == number.rounded() ? String(Int(number)) : String(number))
                case .boolean(let flag): return WasmHostedCalls.newString(flag ? "TRUE" : "FALSE")
                default: return WasmHostedCalls.newString("")
                }
            case "Bool"?:
                switch answer {
                case .boolean(let flag): return flag ? 1 : 0
                case .number(let number): return number != 0 ? 1 : 0
                default: return 0
                }
            default:
                switch answer {
                case .number(let number): return number
                case .boolean(let flag): return flag ? 1 : 0
                case .string(let text): return Double(text) ?? 0
                default: return 0
                }
            }
        }
        let frameBits = Double(UInt(bitPattern: frame))
        var arguments: [BASICFrameworkValue] = []
        for (position, parameter) in method.passed.enumerated() {
            let slot = Double(position + 1)
            switch parameter.type {
            case .bool:
                arguments.append(.boolean((try? call("basic_forward_arg_boolean", [frameBits, slot])) ?? 0 != 0))
            case .string:
                // Owned by the body, as a module's thunk owns it.
                let text = (try? call("basic_forward_arg_pointer", [frameBits, slot])) ?? 0
                arguments.append(.string(WasmHostedCalls.readString(text)))
                WasmHostedCalls.releaseString(text)
            default:
                arguments.append(.number((try? call("basic_forward_arg_number", [frameBits, slot])) ?? 0))
            }
        }
        let result = callbacks.call(id, arguments: arguments)
        switch (method.returns, result) {
        case (.bool, .boolean(let flag)):
            _ = try? call("basic_forward_result_boolean", [frameBits, flag ? 1 : 0])
        case (.string, .string(let text)):
            _ = try? call("basic_forward_result_pointer", [frameBits, WasmHostedCalls.newString(text)])
        case (.double, .number(let number)), (.int, .number(let number)), (.cgFloat, .number(let number)):
            _ = try? call("basic_forward_result_number", [frameBits, number])
        default:
            break
        }
        return 0
    }

    /// The framework's waiting calls back, made now.
    func poll() throws {
        written = ""
        try check(WasmHostedCalls.service())
    }
}

private extension BASICFrameworkValue {
    func withClass(_ name: String) -> BASICFrameworkValue {
        if case .object(let handle, _) = self { return .object(handle: handle, className: name) }
        return self
    }
}

// MARK: - The host BASICCore talks to

extension StudioModel: BASICFrameworkHost {
    nonisolated func providesFramework(named module: String) -> Bool {
        StudioFrameworkMap.imports.framework(named: module) != nil
    }

    nonisolated func importFramework(named module: String, callbacks: BASICFrameworkCallbacks) throws -> BASICFrameworkModule {
        guard let framework = try StudioFrameworkModel.named(module) else {
            throw BASICError.runtime("\(module) is not a framework Studio contains")
        }
        let run: StudioInterpretedFrameworks
        if let current = StudioInterpretedFrameworks.current {
            run = current
        } else {
            // The window `AUIApplication.run` opens is named for the program.
            let title = valueOnMainSync { self.currentProgramURL.map { $0.deletingPathExtension().lastPathComponent } ?? "program" }
            run = StudioInterpretedFrameworks(callbacks: callbacks, entries: StudioFrameworkMap.entries(for: self, title: title))
            StudioInterpretedFrameworks.current = run
        }
        run.add(framework)
        return framework.declarations
    }

    nonisolated func describeFramework(named module: String) throws -> BASICFrameworkModule {
        guard let framework = try StudioFrameworkModel.named(module) else {
            throw BASICError.runtime("\(module) is not a framework Studio contains")
        }
        return framework.declarations
    }

    private nonisolated var frameworkRun: StudioInterpretedFrameworks {
        get throws {
            guard let run = StudioInterpretedFrameworks.current else { throw BASICError.runtime("No framework is imported") }
            return run
        }
    }

    nonisolated func frameworkNew(className: String, arguments: [BASICFrameworkValue]) throws -> BASICFrameworkValue {
        try frameworkRun.new(className: className, arguments: arguments)
    }

    nonisolated func frameworkNewSubclass(baseName: String, arguments: [BASICFrameworkValue], overrides: [String: Int]) throws -> BASICFrameworkValue {
        try frameworkRun.newSubclass(baseName: baseName, arguments: arguments, overrides: overrides)
    }

    nonisolated func frameworkGet(_ object: BASICFrameworkValue, property: String) throws -> BASICFrameworkValue {
        try frameworkRun.get(object, property: property)
    }

    nonisolated func frameworkSet(_ object: BASICFrameworkValue, property: String, value: BASICFrameworkValue) throws {
        try frameworkRun.set(object, property: property, to: value)
    }

    nonisolated func frameworkCall(_ object: BASICFrameworkValue, method: String, arguments: [BASICFrameworkValue]) throws -> BASICFrameworkValue {
        try frameworkRun.callMethod(object, method: method, arguments: arguments)
    }

    nonisolated func frameworkStatic(typeName: String, member: String, arguments: [BASICFrameworkValue]?) throws -> BASICFrameworkValue {
        try frameworkRun.callStatic(typeName: typeName, member: member, arguments: arguments)
    }

    nonisolated func frameworkPoll() throws {
        try StudioInterpretedFrameworks.current?.poll()
    }

    nonisolated func frameworkRunEnded() {
        StudioInterpretedFrameworks.current?.end()
        StudioInterpretedFrameworks.current = nil
    }
}
