import Foundation

// LLVM IR (basicc's subset) to a WebAssembly module (BASIC-45).
//
// The translator reads the IR the LLVM path already produces, so a program
// compiled to WebAssembly means exactly what it means compiled natively; the
// runtime it calls is the same native BASICRT, through imports. See
// Documents/WASM_BACKEND.md for the whole design. In short:
//
// - **Values.** double → f64; i1/i8/i32 → i32; i64 → i64; ptr → i64 holding
//   the native address. Runtime-owned pointers are opaque; addresses of the
//   program's own globals and stack slots are `base + offset`, where `base` is
//   the native address of the module's memory, imported as a global.
// - **Memory.** Globals and stack slots whose address never escapes (only
//   loaded and stored) become WebAssembly globals and locals. The rest live in
//   linear memory at fixed offsets, in the native layout the runtime reads.
//   The memory never grows, so the native pointers the runtime keeps into it
//   stay good.
// - **Control flow.** Each function is a loop around a `br_table` on a block
//   index: any CFG at all, irreducible or not. A back-edge counts down and
//   calls the host's `__poll` every 4096 times, which is how Stop works.
// - **setjmp.** basicc uses it in two fixed shapes (ON ERROR in main, and an
//   async body's boundary). The function's loop is wrapped in `try … catch`
//   on the module's `landed` tag; the host throws that tag where the native
//   runtime would have longjmp'd, and the catch resumes after the setjmp with
//   its result 1.
// - **Calls.** A declared function is an import from module `rt`; every
//   argument and result crossing into JavaScript is a number (pointers and
//   i64s as f64, exact below 2⁵³). A defined function's address is its slot in
//   the table; slot 0 is a trap, so a null function pointer never calls
//   anything.

/// A program translated to WebAssembly, and what its host must provide.
public struct WasmProgram: Sendable {
    /// The module.
    public let bytes: [UInt8]
    /// The runtime functions it imports from module `rt`, in import order.
    public let imports: [WasmImport]
    /// The memory it imports as `env.memory`: this many 64 KiB pages, never grown.
    public let memoryPages: Int
    /// Where in that memory the runtime puts the cells of variables closures
    /// share (Documents/CLOSURES.md C1), when the module makes any: the
    /// module's loads and stores reach only its own memory.
    public var cellArena: (offset: Int, size: Int)? = nil
    /// Where its statements and variables are, when it was translated for
    /// debugging (BASIC-46); nil otherwise.
    public let debugInfo: WasmDebugInfo?
}

/// One runtime function the module imports.
public struct WasmImport: Sendable, Hashable {
    public let name: String
    public let parameters: [WasmImportKind]
    /// Nil for a void function.
    public let result: WasmImportKind?
}

/// How a value crosses between the module and its host. Every kind is a
/// JavaScript number on the way.
public enum WasmImportKind: String, Sendable, Hashable {
    /// A double, as itself.
    case double
    /// An i1, as 0 or 1.
    case boolean
    /// An i8 or i32.
    case int32
    /// An i64, as a double.
    case int64
    /// A native address, as a double.
    case pointer
}

/// Why a module could not be made.
public struct WasmTranslationError: Error, CustomStringConvertible {
    public let message: String
    public let function: String?
    public let line: String?
    public var description: String {
        var text = message
        if let function { text += " (in \(function))" }
        if let line { text += ": \(line.trimmingCharacters(in: .whitespaces))" }
        return text
    }
}

public enum WasmTranslator {
    /// Bytes reserved for the program's stack of memory-resident locals.
    public static let stackSize = 1 << 20
    /// Bytes reserved for shared variables' cells, eight each, after the stack.
    public static let cellArenaSize = 1 << 18
    /// The names the module exports.
    public static let runExport = "__run"
    public static let landedTagExport = "landed"
    public static let pollImport = "__poll"
    /// A debug build's statement hook: (statement, function, frame) (BASIC-46).
    public static let debugImport = "__debug"
    public static let callbackExports = ["__callback_ptr_void", "__callback_ptr_ptr", "__callback_void_ptr", "__callback_ptr_double",
                                         "__callback_ptr_bool"]

    /// Translates basicc's LLVM IR into a module. With `debug`, a module a
    /// debugger can stop and look into (BASIC-46): compile the IR with debug
    /// info, so its metadata names each variable's type.
    public static func translate(llvmIR: String, debug: Bool = false) throws -> WasmProgram {
        let module: IRModule
        do {
            module = try IRParser.parse(llvmIR)
        } catch let error as IRParseError {
            throw WasmTranslationError(message: error.message, function: nil, line: error.line)
        }
        var translation = ModuleTranslation(module: module)
        if debug { translation.debugNames = IRDebugNames(llvmIR: llvmIR) }
        return try translation.translate()
    }
}

// MARK: - The module

private struct ModuleTranslation {
    let module: IRModule

    var types: [WasmFunctionType] = []
    var typeIndex: [WasmFunctionType: UInt32] = [:]

    var imports: [WasmImport] = []
    var importIndex: [String: UInt32] = [:]
    var importTypeIndexes: [UInt32] = []

    /// Defined functions: their wasm index, and their table slot.
    var functionIndex: [String: UInt32] = [:]
    var tableSlot: [String: Int64] = [:]
    var declarations: [String: IRDeclaration] = [:]
    var definitions: [String: IRFunction] = [:]

    /// Memory-resident globals, by offset.
    var memoryOffset: [String: Int] = [:]
    /// Globals promoted to WebAssembly globals.
    var promoted: [String: (index: UInt32, type: IRType)] = [:]
    var promotedOrder: [IRGlobal] = []
    var data: [UInt8] = []
    var relocations: [(at: Int, target: Int)] = []
    var dataStart = 16

    // Global indexes: the imported base, then ours.
    let baseImport: UInt32 = 0
    let baseGlobal: UInt32 = 1
    let stackPointer: UInt32 = 2
    let pollCounter: UInt32 = 3
    var firstPromoted: UInt32 = 4

    /// A debug build's: the metadata's names and types, then each function's
    /// locals as they are laid out (BASIC-46).
    var debugNames: IRDebugNames?
    var debugFunctions: [WasmDebugInfo.Function] = []
    var debug: Bool { debugNames != nil }

    init(module: IRModule) {
        self.module = module
    }

    mutating func type(_ type: WasmFunctionType) -> UInt32 {
        if let index = typeIndex[type] { return index }
        let index = UInt32(types.count)
        types.append(type)
        typeIndex[type] = index
        return index
    }

    func wasmType(_ type: IRType) -> WasmValueType? {
        switch type {
        case .void: return nil
        case .double: return .f64
        case .pointer: return .i64
        case .int(let bits): return bits == 64 ? .i64 : .i32
        case .array: return nil
        }
    }

    func importKind(_ type: IRType) -> WasmImportKind? {
        switch type {
        case .void, .array: return nil
        case .double: return .double
        case .pointer: return .pointer
        case .int(let bits):
            switch bits {
            case 1: return .boolean
            case 64: return .int64
            default: return .int32
            }
        }
    }

    func boundaryType(_ kind: WasmImportKind) -> WasmValueType {
        switch kind {
        case .double, .int64, .pointer: return .f64
        case .boolean, .int32: return .i32
        }
    }

    mutating func translate() throws -> WasmProgram {
        for declaration in module.declarations { declarations[declaration.name] = declaration }
        for function in module.functions { definitions[function.name] = function }

        // Imports: the runtime functions actually called, the math
        // intrinsics wasm has no instruction for, and the host's poll.
        var called: [String] = []
        var seen: Set<String> = []
        for function in module.functions {
            for block in function.blocks {
                for instruction in block.instructions {
                    guard case .call(_, .global(let callee), _) = instruction.kind, !seen.contains(callee) else { continue }
                    seen.insert(callee)
                    if definitions[callee] == nil, !Self.inlineIntrinsics.contains(callee), callee != "setjmp" {
                        called.append(callee)
                    }
                }
            }
        }
        for name in called {
            guard let declaration = declarations[name] else {
                throw WasmTranslationError(message: "a call to \(name), which is neither defined nor declared", function: nil, line: nil)
            }
            var parameters: [WasmImportKind] = []
            for parameter in declaration.parameters {
                guard let kind = importKind(parameter) else {
                    throw WasmTranslationError(message: "\(name) takes a \(parameter), which cannot cross into the host", function: nil, line: nil)
                }
                parameters.append(kind)
            }
            let result = importKind(declaration.returns)
            addImport(WasmImport(name: name, parameters: parameters, result: result))
        }
        // The poll answers how many back-edges until the next (BASIC-47).
        addImport(WasmImport(name: WasmTranslator.pollImport, parameters: [], result: .int32))
        if debug {
            addImport(WasmImport(name: WasmTranslator.debugImport, parameters: [.int32, .int32, .int32], result: nil))
        }

        // Defined functions: slot 0 of the table is a trap.
        let importCount = UInt32(imports.count)
        for (offset, function) in module.functions.enumerated() {
            functionIndex[function.name] = importCount + 1 + UInt32(offset)
            tableSlot[function.name] = Int64(offset + 1)
        }

        try layOutGlobals()

        // Function bodies.
        var bodies: [[UInt8]] = []
        var functionTypes: [UInt32] = []
        // The trap in slot 0.
        functionTypes.append(type(WasmFunctionType(parameters: [], results: [])))
        var trap = WasmCode()
        trap.unreachable()
        trap.end()
        bodies.append(Self.body(locals: [], code: trap))
        for function in module.functions {
            var translation = try FunctionTranslation(function: function, module: self)
            let body = try translation.translate()
            // call_indirect types the function added.
            types = translation.module.types
            typeIndex = translation.module.typeIndex
            functionTypes.append(type(translation.signature))
            bodies.append(body)
            if let debugNames {
                let name = debugNames.functionNames[function.name] ?? function.name
                let types = debugNames.localTypes[function.name] ?? [:]
                debugFunctions.append(WasmDebugInfo.Function(
                    name: name, isProgram: function.name == "main",
                    locals: translation.debugSlots.map { slot in
                        let name = String(slot.register.dropFirst(2))
                        return debugVariable(name: name, type: slot.type, typeName: types[name], offset: slot.offset)
                    },
                    frameSize: translation.frameSize))
            }
        }

        // Generated: start, run, and the callback dispatchers.
        let definedCount = UInt32(bodies.count)
        let startIndex = importCount + definedCount
        functionTypes.append(type(WasmFunctionType(parameters: [], results: [])))
        bodies.append(startBody())

        let runIndex = startIndex + 1
        functionTypes.append(type(WasmFunctionType(parameters: [], results: [.i32])))
        bodies.append(try runBody())

        var callbackIndexes: [UInt32] = []
        for (number, shape) in Self.callbackShapes.enumerated() {
            callbackIndexes.append(runIndex + 1 + UInt32(number))
            functionTypes.append(type(WasmFunctionType(parameters: [.f64] + shape.parameters.map { _ in .f64 },
                                                      results: shape.result == nil ? [] : [.f64])))
            bodies.append(callbackBody(shape))
        }
        let landedType = type(WasmFunctionType(parameters: [], results: []))

        // The module.
        let arenaSize = imports.contains { $0.name == "basic_rt_cell_new" } ? WasmTranslator.cellArenaSize : 0
        let pages = max(1, (dataEndOffset + WasmTranslator.stackSize + arenaSize + 65535) / 65536)
        var out = WasmBuffer()
        out.append([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])

        out.section(1, vectorBytes(types.map(\.encoded)))

        var importEntries: [[UInt8]] = []
        for (number, entry) in imports.enumerated() {
            var item = WasmBuffer()
            item.name("rt")
            item.name(entry.name)
            item.byte(0x00)
            item.unsigned(UInt64(importTypeIndexes[number]))
            importEntries.append(item.bytes)
        }
        var memoryImport = WasmBuffer()
        memoryImport.name("env"); memoryImport.name("memory")
        memoryImport.byte(0x02); memoryImport.byte(0x01)
        memoryImport.unsigned(UInt64(pages)); memoryImport.unsigned(UInt64(pages))
        importEntries.append(memoryImport.bytes)
        var baseEntry = WasmBuffer()
        baseEntry.name("env"); baseEntry.name("base")
        baseEntry.byte(0x03); baseEntry.byte(WasmValueType.f64.rawValue); baseEntry.byte(0x00)
        importEntries.append(baseEntry.bytes)
        out.section(2, vectorBytes(importEntries))

        out.section(3, vectorBytes(functionTypes.map { index in var b = WasmBuffer(); b.unsigned(UInt64(index)); return b.bytes }))

        var table = WasmBuffer()
        table.unsigned(1)
        table.byte(0x70); table.byte(0x01)
        table.unsigned(UInt64(definedCount)); table.unsigned(UInt64(definedCount))
        out.section(4, table.bytes)

        var tags = WasmBuffer()
        tags.unsigned(1)
        tags.byte(0x00); tags.unsigned(UInt64(landedType))
        out.section(13, tags.bytes)

        var globals: [[UInt8]] = []
        globals.append(globalEntry(.i64, mutable: true) { $0.i64Const(0) })
        globals.append(globalEntry(.i32, mutable: true) { $0.i32Const(Int32(dataEndOffset + WasmTranslator.stackSize)) })
        // The countdown to a loop's first poll: 1, so the poll can size the
        // next by how long the loop's passes take (BASIC-47).
        globals.append(globalEntry(.i32, mutable: true) { $0.i32Const(1) })
        for global in promotedOrder {
            let wasm = wasmType(global.type)!
            globals.append(globalEntry(wasm, mutable: true) { code in
                Self.pushConstant(initialValue(global), type: global.type, into: &code)
            })
        }
        out.section(6, vectorBytes(globals))

        var exports: [[UInt8]] = []
        func export(_ name: String, kind: UInt8, index: UInt32) {
            var item = WasmBuffer()
            item.name(name); item.byte(kind); item.unsigned(UInt64(index))
            exports.append(item.bytes)
        }
        export(WasmTranslator.runExport, kind: 0x00, index: runIndex)
        for (number, name) in WasmTranslator.callbackExports.enumerated() {
            export(name, kind: 0x00, index: callbackIndexes[number])
        }
        export(WasmTranslator.landedTagExport, kind: 0x04, index: 0)
        out.section(7, vectorBytes(exports))

        var start = WasmBuffer()
        start.unsigned(UInt64(startIndex))
        out.section(8, start.bytes)

        var elements = WasmBuffer()
        elements.unsigned(1)
        elements.byte(0x00)
        elements.byte(0x41); elements.signed(0); elements.byte(0x0B)
        elements.unsigned(UInt64(definedCount))
        for index in 0..<definedCount { elements.unsigned(UInt64(importCount + index)) }
        out.section(9, elements.bytes)

        out.section(10, vectorBytes(bodies))

        if !data.isEmpty {
            var segment = WasmBuffer()
            segment.unsigned(1)
            segment.byte(0x00)
            segment.byte(0x41); segment.signed(Int64(dataStart)); segment.byte(0x0B)
            segment.unsigned(UInt64(data.count))
            segment.append(data)
            out.section(11, segment.bytes)
        }

        var program = WasmProgram(bytes: out.bytes, imports: imports, memoryPages: pages, debugInfo: debug ? debugInfo() : nil)
        if arenaSize > 0 { program.cellArena = (dataEndOffset + WasmTranslator.stackSize, arenaSize) }
        return program
    }

    // MARK: Debugging (BASIC-46)

    /// Whether a global or alloca is a variable of the program's, by the
    /// names basicc gives them: `G.TOTAL`, `L.X`; `L.$for.end.1` is its own.
    static func isProgramVariable(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && !name.dropFirst(prefix.count).hasPrefix("$")
    }

    func debugVariable(name: String, type: IRType, typeName: String?, offset: Int) -> WasmDebugInfo.Variable {
        let storage: WasmDebugInfo.Storage
        switch type {
        case .double: storage = .double
        case .int(1): storage = .boolean
        case .int(64): storage = .int64
        case .int: storage = .int32
        default: storage = .pointer
        }
        return WasmDebugInfo.Variable(name: name, typeName: typeName ?? "", storage: storage, offset: offset)
    }

    /// The program's globals, functions and statements, for a debugger.
    func debugInfo() -> WasmDebugInfo {
        let types = debugNames?.globalTypes ?? [:]
        let globals = module.globals.compactMap { global -> WasmDebugInfo.Variable? in
            guard Self.isProgramVariable(global.name, prefix: "G."), let offset = memoryOffset[global.name] else { return nil }
            let name = String(global.name.dropFirst(2))
            return debugVariable(name: name, type: global.type, typeName: types[name], offset: offset)
        }
        // basicc's table of statement locations: lines, columns, and the text.
        func values(_ name: String) -> [IRValue] {
            guard let global = module.globals.first(where: { $0.name == name }),
                  case .array(let values) = global.initializer else { return [] }
            return values
        }
        func text(_ value: IRValue) -> String {
            guard case .global(let name) = value, let global = module.globals.first(where: { $0.name == name }),
                  case .bytes(let bytes) = global.initializer else { return "" }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        func number(_ value: IRValue) -> Int {
            if case .integer(let number) = value { return Int(number) }
            return 0
        }
        let lines = values("basic.locations.lines").map(number)
        let columns = values("basic.locations.columns").map(number)
        let sources = values("basic.locations.sources").map(text)
        var statements: [WasmDebugInfo.Statement] = []
        for index in lines.indices {
            let column = index < columns.count ? columns[index] : 0
            let source = index < sources.count ? sources[index] : ""
            // Its place on its line: the statements of the same line before it.
            let before = lines.indices.filter { other in
                lines[other] == lines[index] && (other < sources.count ? sources[other] : "") == source
                    && (other < columns.count ? columns[other] : 0) < column
            }.count
            statements.append(WasmDebugInfo.Statement(line: lines[index], column: column, source: source, indexOnLine: before))
        }
        return WasmDebugInfo(globals: globals, functions: debugFunctions, statements: statements)
    }

    mutating func addImport(_ entry: WasmImport) {
        importIndex[entry.name] = UInt32(imports.count)
        imports.append(entry)
        importTypeIndexes.append(type(WasmFunctionType(parameters: entry.parameters.map(boundaryType),
                                                       results: entry.result.map { [boundaryType($0)] } ?? [])))
    }

    var dataEndOffset: Int { (dataStart + data.count + 15) / 16 * 16 }

    // MARK: Globals

    /// Which globals escape: anything but the address of a load or store.
    func escapingGlobals() -> Set<String> {
        var escaping: Set<String> = []
        func operand(_ value: IRValue) {
            if case .global(let name) = value { escaping.insert(name) }
        }
        for function in module.functions {
            for block in function.blocks {
                for instruction in block.instructions {
                    switch instruction.kind {
                    case .call(_, let callee, let arguments):
                        if case .register = callee { }
                        arguments.forEach { operand($0.1) }
                    case .store(_, let value, _): operand(value)
                    case .load: break
                    case .elementPointer(_, let address, _): operand(address)
                    case .floatCompare(_, let a, let b), .intCompare(_, _, let a, let b), .binary(_, _, let a, let b):
                        operand(a); operand(b)
                    case .floatNegate(let a), .convert(_, _, let a, _): operand(a)
                    case .select(let c, _, let a, let b): operand(c); operand(a); operand(b)
                    case .phi(_, let incoming): incoming.forEach { operand($0.0) }
                    case .conditionalBranch(let c, _, _): operand(c)
                    case .switchOn(_, let value, _, _): operand(value)
                    case .returnValue(_, let value): value.map(operand)
                    default: break
                    }
                }
            }
        }
        for global in module.globals {
            if case .array(let values) = global.initializer { values.forEach(operand) }
            if case .scalar(let value) = global.initializer { operand(value) }
        }
        return escaping
    }

    mutating func layOutGlobals() throws {
        let escaping = escapingGlobals()
        var index = firstPromoted
        for global in module.globals {
            let scalar: Bool
            switch global.type {
            case .array: scalar = false
            default: scalar = true
            }
            // A debug build keeps the program's own variables in memory,
            // where the debugger reads them.
            let inspected = debug && Self.isProgramVariable(global.name, prefix: "G.")
            if scalar, !global.isConstant, !escaping.contains(global.name), !inspected {
                promoted[global.name] = (index, global.type)
                promotedOrder.append(global)
                index += 1
                continue
            }
            // In memory, aligned, in the runtime's layout.
            let alignment = max(8, global.type.alignment)
            while (dataStart + data.count) % alignment != 0 { data.append(0) }
            let offset = dataStart + data.count
            memoryOffset[global.name] = offset
            data.append(contentsOf: [UInt8](repeating: 0, count: global.type.size))
        }
        // Contents, now every offset is known.
        for global in module.globals {
            guard let offset = memoryOffset[global.name] else { continue }
            try write(global.initializer, type: global.type, at: offset, in: global.name)
        }
    }

    mutating func put(_ bytes: [UInt8], at position: Int) {
        for (i, byte) in bytes.enumerated() { data[position - dataStart + i] = byte }
    }

    mutating func write(_ initializer: IRInitializer, type: IRType, at offset: Int, in name: String) throws {
        switch initializer {
        case .zero:
            break
        case .bytes(let bytes):
            put(bytes, at: offset)
        case .scalar(let value):
            try writeScalar(value, type: type, at: offset)
        case .array(let values):
            guard case .array(_, let element) = type else {
                throw WasmTranslationError(message: "an array initializer for \(type)", function: nil, line: "@\(name)")
            }
            for (i, value) in values.enumerated() {
                try writeScalar(value, type: element, at: offset + i * element.size)
            }
        }
    }

    mutating func writeScalar(_ value: IRValue, type: IRType, at offset: Int) throws {
        func little<T: FixedWidthInteger>(_ number: T) -> [UInt8] { withUnsafeBytes(of: number.littleEndian) { Array($0) } }
        switch (type, value) {
        case (.double, .float(let number)): put(little(number.bitPattern), at: offset)
        case (.double, .integer(let number)): put(little(Double(number).bitPattern), at: offset)
        case (.int(let bits), .integer(let number)):
            switch bits {
            case 1, 8: put([UInt8(truncatingIfNeeded: number)], at: offset)
            case 32: put(little(Int32(truncatingIfNeeded: number)), at: offset)
            default: put(little(number), at: offset)
            }
        case (.pointer, .null): break
        case (.pointer, .global(let target)):
            if let slot = tableSlot[target] {
                put(little(slot), at: offset)
            } else if let targetOffset = memoryOffset[target] {
                relocations.append((at: offset, target: targetOffset))
            } else {
                throw WasmTranslationError(message: "a pointer to @\(target), which has no address", function: nil, line: nil)
            }
        default:
            throw WasmTranslationError(message: "an initializer \(value) for \(type)", function: nil, line: nil)
        }
    }

    func initialValue(_ global: IRGlobal) -> IRValue {
        if case .scalar(let value) = global.initializer { return value }
        return .integer(0)
    }

    static func pushConstant(_ value: IRValue, type: IRType, into code: inout WasmCode) {
        switch type {
        case .double:
            switch value {
            case .float(let number): code.f64Const(number)
            case .integer(let number): code.f64Const(Double(number))
            default: code.f64Const(0)
            }
        case .pointer:
            if case .integer(let number) = value { code.i64Const(number) } else { code.i64Const(0) }
        case .int(let bits):
            let number: Int64 = { if case .integer(let n) = value { return n } else { return 0 } }()
            if bits == 64 { code.i64Const(number) } else { code.i32Const(Int32(truncatingIfNeeded: number)) }
        default:
            code.i32Const(0)
        }
    }

    func globalEntry(_ type: WasmValueType, mutable: Bool, _ initializer: (inout WasmCode) -> Void) -> [UInt8] {
        var code = WasmCode()
        initializer(&code)
        var out = WasmBuffer()
        out.byte(type.rawValue)
        out.byte(mutable ? 0x01 : 0x00)
        out.append(code.bytes)
        out.byte(0x0B)
        return out.bytes
    }

    // MARK: Generated functions

    /// Takes the base from the host, then writes the pointers to other
    /// globals that the data segment could not hold.
    func startBody() -> [UInt8] {
        var code = WasmCode()
        code.globalGet(baseImport)
        code.prefixed(WasmOp.i64TruncSatF64U)
        code.globalSet(baseGlobal)
        for relocation in relocations {
            code.i32Const(0)
            code.globalGet(baseGlobal)
            code.i64Const(Int64(relocation.target))
            code.op(WasmOp.i64Add)
            code.i64Store(offset: UInt32(relocation.at))
        }
        code.end()
        return Self.body(locals: [], code: code)
    }

    /// `main(0, null)`, callable from JavaScript without a BigInt.
    func runBody() throws -> [UInt8] {
        guard let main = functionIndex["main"] else {
            throw WasmTranslationError(message: "no main function", function: nil, line: nil)
        }
        var code = WasmCode()
        code.i32Const(0)
        code.i64Const(0)
        code.call(main)
        code.end()
        return Self.body(locals: [], code: code)
    }

    struct CallbackShape {
        var parameters: [WasmValueType]   // the callee's, besides none
        var result: WasmValueType?
    }

    /// The shapes the runtime calls back through: an event handler
    /// (ptr)→void, an async body (ptr)→ptr, a globals capture ()→ptr, a
    /// closure body (ptr)→double, and a closure answering a truth value
    /// (ptr)→i1 — a framework's `() -> Bool` provider (BASIC-45).
    static let callbackShapes: [CallbackShape] = [
        CallbackShape(parameters: [.i64], result: nil),
        CallbackShape(parameters: [.i64], result: .i64),
        CallbackShape(parameters: [], result: .i64),
        CallbackShape(parameters: [.i64], result: .f64),
        CallbackShape(parameters: [.i64], result: .i32),
    ]

    /// (slot, arguments…) as doubles → call_indirect → the result as a double.
    mutating func callbackBody(_ shape: CallbackShape) -> [UInt8] {
        var code = WasmCode()
        for (index, _) in shape.parameters.enumerated() {
            code.localGet(UInt32(index + 1))
            code.prefixed(WasmOp.i64TruncSatF64U)
        }
        code.localGet(0)
        code.prefixed(3) // i32.trunc_sat_f64_u
        code.callIndirect(type: type(WasmFunctionType(parameters: shape.parameters, results: shape.result.map { [$0] } ?? [])))
        if shape.result == .i64 { code.op(WasmOp.f64ConvertI64U) }
        if shape.result == .i32 { code.op(WasmOp.f64ConvertI32U) }
        code.end()
        return Self.body(locals: [], code: code)
    }

    static func body(locals: [(count: UInt32, type: WasmValueType)], code: WasmCode) -> [UInt8] {
        var content = WasmBuffer()
        content.unsigned(UInt64(locals.count))
        for group in locals {
            content.unsigned(UInt64(group.count))
            content.byte(group.type.rawValue)
        }
        content.append(code.bytes)
        var out = WasmBuffer()
        out.unsigned(UInt64(content.bytes.count))
        out.append(content.bytes)
        return out.bytes
    }

    func vectorBytes(_ items: [[UInt8]]) -> [UInt8] {
        var out = WasmBuffer()
        out.vector(items)
        return out.bytes
    }

    static let inlineIntrinsics: Set<String> = [
        "llvm.floor.f64", "llvm.trunc.f64", "llvm.fabs.f64", "llvm.sqrt.f64", "llvm.round.f64", "llvm.ceil.f64",
    ]
}

// MARK: - One function

private struct FunctionTranslation {
    let function: IRFunction
    var module: ModuleTranslation

    /// Where a pointer-valued register points, when that is known statically.
    enum Address {
        case frame(Int)       // fp + offset
        case absolute(Int)    // a memory-resident global
    }

    var signature: WasmFunctionType
    var registerType: [String: IRType] = [:]
    var local: [String: UInt32] = [:]
    var localTypes: [WasmValueType] = []
    var address: [String: Address] = [:]
    /// Allocas held in locals: never escaping, scalar.
    var promotedAlloca: Set<String> = []
    var frameSize = 0
    /// A debug build's program variables, in the frame (BASIC-46).
    var debugSlots: [(register: String, type: IRType, offset: Int)] = []
    /// The function's number, as the debug hook passes it.
    var number: Int32 { Int32(module.tableSlot[function.name]! - 1) }

    // Pseudo-blocks: the IR's, with each split after a setjmp.
    struct Piece {
        var label: String         // what branches name
        var phiLabel: String      // what phis in successors name
        var instructions: [IRInstruction]
        var isSetjmpContinuation = false
    }
    var pieces: [Piece] = []
    var pieceIndex: [String: Int] = [:]
    var setjmpSites: [(result: String, continuation: Int)] = []
    var phis: [Int: [(result: String, type: IRType, incoming: [(IRValue, String)])]] = [:]

    // Fixed locals.
    var pc: UInt32 = 0
    var fp: UInt32 = 0
    var jmpSite: UInt32 = 0
    var scratchA: UInt32 = 0
    var scratchB: UInt32 = 0

    var code = WasmCode()
    var hasTry = false

    init(function: IRFunction, module: ModuleTranslation) throws {
        self.function = function
        self.module = module
        var parameters: [WasmValueType] = []
        for (type, _) in function.parameters {
            guard let wasm = module.wasmType(type) else {
                throw WasmTranslationError(message: "a parameter of type \(type)", function: function.name, line: nil)
            }
            parameters.append(wasm)
        }
        signature = WasmFunctionType(parameters: parameters, results: module.wasmType(function.returns).map { [$0] } ?? [])
    }

    func error(_ message: String, _ instruction: IRInstruction? = nil) -> WasmTranslationError {
        WasmTranslationError(message: message, function: function.name, line: instruction?.line)
    }

    mutating func newLocal(_ type: WasmValueType) -> UInt32 {
        let index = UInt32(function.parameters.count + localTypes.count)
        localTypes.append(type)
        return index
    }

    mutating func translate() throws -> [UInt8] {
        // Types and locals for parameters.
        for (index, (type, name)) in function.parameters.enumerated() {
            registerType[name] = type
            local[name] = UInt32(index)
        }
        pc = newLocal(.i32)
        fp = newLocal(.i32)
        jmpSite = newLocal(.i32)
        scratchA = newLocal(.f64)
        scratchB = newLocal(.f64)

        try analyze()

        // Prologue: the frame.
        if frameSize > 0 {
            code.globalGet(module.stackPointer)
            code.i32Const(Int32(frameSize))
            code.op(WasmOp.i32Sub)
            code.localTee(fp)
            code.globalSet(module.stackPointer)
        }

        // loop { [try] { block… br_table … pieces } [catch landed { … }] }
        code.loop()
        if hasTry { code.tryBlock() }
        let count = pieces.count
        for _ in 0..<count { code.block() }
        code.localGet(pc)
        code.brTable(Array(0..<count), default: count - 1)
        for index in 0..<count {
            code.end()
            try emitPiece(index)
        }
        if hasTry {
            code.catchTag(0)
            // A landing for a setjmp this function has not reached yet is an
            // outer function's: pass it on.
            code.localGet(jmpSite)
            code.op(WasmOp.i32Eqz)
            code.ifThen()
            code.op(0x09); code.buffer_unsigned(1) // rethrow to the try
            code.end()
            // Inner frames are gone; this one stays.
            if frameSize > 0 {
                code.localGet(fp)
                code.globalSet(module.stackPointer)
            }
            for (site, entry) in setjmpSites.enumerated() {
                code.localGet(jmpSite)
                code.i32Const(Int32(site + 1))
                code.op(WasmOp.i32Eq)
                code.ifThen()
                code.i32Const(1)
                code.localSet(local[entry.result]!)
                code.i32Const(Int32(entry.continuation))
                code.localSet(pc)
                code.end()
            }
            code.br(1) // to the loop
            code.end() // try
        }
        code.end() // loop
        code.unreachable()
        code.end()

        // Locals, grouped.
        var groups: [(count: UInt32, type: WasmValueType)] = []
        for type in localTypes {
            if let last = groups.last, last.type == type {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((1, type))
            }
        }
        return ModuleTranslation.body(locals: groups, code: code)
    }

    // MARK: Analysis

    mutating func analyze() throws {
        // Every register's type, and which allocas escape.
        var escaping: Set<String> = []
        func operand(_ value: IRValue) {
            if case .register(let name) = value { escaping.insert(name) }
        }
        for block in function.blocks {
            for instruction in block.instructions {
                if let result = instruction.result, let type = instruction.resultType {
                    registerType[result] = type
                }
                switch instruction.kind {
                case .call(_, let callee, let arguments):
                    if case .register(let name) = callee { escaping.insert(name) }
                    arguments.forEach { operand($0.1) }
                case .store(_, let value, _): operand(value)
                case .load: break
                case .elementPointer(_, let address, _): operand(address)
                case .floatCompare(_, let a, let b), .intCompare(_, _, let a, let b), .binary(_, _, let a, let b):
                    operand(a); operand(b)
                case .floatNegate(let a), .convert(_, _, let a, _): operand(a)
                case .select(let c, _, let a, let b): operand(c); operand(a); operand(b)
                case .phi(_, let incoming): incoming.forEach { operand($0.0) }
                case .conditionalBranch(let c, _, _): operand(c)
                case .switchOn(_, let value, _, _): operand(value)
                case .returnValue(_, let value): value.map(operand)
                default: break
                }
            }
        }
        // Allocas: a local, or a slot in the frame.
        for block in function.blocks {
            for instruction in block.instructions {
                guard case .alloca(let type) = instruction.kind, let result = instruction.result else { continue }
                // A debug build keeps the program's variables in the frame.
                let inspected = module.debug && ModuleTranslation.isProgramVariable(result, prefix: "L.")
                if !escaping.contains(result), !inspected, let wasm = module.wasmType(type) {
                    promotedAlloca.insert(result)
                    local[result] = newLocal(wasm)
                } else {
                    let alignment = max(8, type.alignment)
                    frameSize = (frameSize + alignment - 1) / alignment * alignment
                    address[result] = .frame(frameSize)
                    if inspected { debugSlots.append((result, type, frameSize)) }
                    frameSize += type.size
                }
            }
        }
        // In a debug build every call has a frame: its address is the call's.
        if module.debug { frameSize = max(frameSize, 16) }
        frameSize = (frameSize + 15) / 16 * 16

        // Pieces, split after each setjmp.
        for block in function.blocks {
            var current = Piece(label: block.label, phiLabel: block.label, instructions: [])
            for instruction in block.instructions {
                current.instructions.append(instruction)
                if case .call(_, .global("setjmp"), _) = instruction.kind {
                    guard let result = instruction.result else { throw error("a setjmp with no result", instruction) }
                    pieces.append(current)
                    let continuationLabel = block.label + "\u{1}setjmp\(setjmpSites.count)"
                    setjmpSites.append((result, pieces.count))
                    current = Piece(label: continuationLabel, phiLabel: block.label, instructions: [], isSetjmpContinuation: true)
                }
            }
            pieces.append(current)
        }
        for (index, piece) in pieces.enumerated() where pieceIndex[piece.label] == nil {
            pieceIndex[piece.label] = index
        }
        hasTry = !setjmpSites.isEmpty

        // Phis, and every other register's local.
        for (index, piece) in pieces.enumerated() {
            for instruction in piece.instructions {
                if case .phi(let type, let incoming) = instruction.kind, let result = instruction.result {
                    phis[index, default: []].append((result, type, incoming))
                }
            }
        }
        for (index, piece) in pieces.enumerated() {
            for instruction in piece.instructions {
                guard let result = instruction.result, local[result] == nil, address[result] == nil else { continue }
                if case .elementPointer(let base, let pointer, let indexes) = instruction.kind,
                   let resolved = try staticAddress(of: pointer, base: base, indexes: indexes) {
                    address[result] = resolved
                    continue
                }
                guard let type = registerType[result], let wasm = module.wasmType(type) else {
                    throw error("a result of type \(registerType[result].map(\.description) ?? "?")", instruction)
                }
                local[result] = newLocal(wasm)
            }
            _ = index
        }
    }

    /// The address a getelementptr computes, when its base is known.
    func staticAddress(of pointer: IRValue, base: IRType, indexes: [Int64]) throws -> Address? {
        var offset = 0
        var type = base
        for (position, index) in indexes.enumerated() {
            if position == 0 {
                offset += Int(index) * type.size
            } else if case .array(_, let element) = type {
                offset += Int(index) * element.size
                type = element
            } else {
                return nil
            }
        }
        switch pointer {
        case .register(let name):
            switch address[name] {
            case .frame(let start)?: return .frame(start + offset)
            case .absolute(let start)?: return .absolute(start + offset)
            case nil: return nil
            }
        case .global(let name):
            if let start = module.memoryOffset[name] { return .absolute(start + offset) }
            return nil
        default:
            return nil
        }
    }

    // MARK: Values

    /// The native address of a memory slot, as an i64.
    mutating func pushNative(_ resolved: Address) {
        switch resolved {
        case .frame(let offset):
            code.globalGet(module.baseGlobal)
            code.localGet(fp)
            code.op(WasmOp.i64ExtendI32U)
            code.op(WasmOp.i64Add)
            if offset != 0 {
                code.i64Const(Int64(offset))
                code.op(WasmOp.i64Add)
            }
        case .absolute(let offset):
            code.globalGet(module.baseGlobal)
            code.i64Const(Int64(offset))
            code.op(WasmOp.i64Add)
        }
    }

    mutating func push(_ value: IRValue, as type: IRType, _ instruction: IRInstruction) throws {
        switch value {
        case .register(let name):
            if let resolved = address[name] {
                pushNative(resolved)
            } else if let index = local[name], !promotedAlloca.contains(name) {
                code.localGet(index)
            } else {
                throw error("a value %\(name) with no home", instruction)
            }
        case .global(let name):
            if let slot = module.tableSlot[name] {
                code.i64Const(slot)
            } else if let offset = module.memoryOffset[name] {
                pushNative(.absolute(offset))
            } else {
                throw error("the address of @\(name), which has none", instruction)
            }
        case .integer, .float, .null:
            ModuleTranslation.pushConstant(value, type: type, into: &code)
        }
    }

    /// Pushes the memory address (an i32 offset) for a load or store, and
    /// answers the memarg offset to use with it.
    mutating func pushMemoryAddress(_ value: IRValue, _ instruction: IRInstruction) throws -> UInt32 {
        switch value {
        case .register(let name):
            if let resolved = address[name] {
                switch resolved {
                case .frame(let offset):
                    code.localGet(fp)
                    return UInt32(offset)
                case .absolute(let offset):
                    code.i32Const(0)
                    return UInt32(offset)
                }
            }
            // A pointer computed at run time: back from native to the module.
            try push(value, as: .pointer, instruction)
            code.globalGet(module.baseGlobal)
            code.op(WasmOp.i64Sub)
            code.op(WasmOp.i32WrapI64)
            return 0
        case .global(let name):
            guard let offset = module.memoryOffset[name] else { throw error("a load or store of @\(name)", instruction) }
            code.i32Const(0)
            return UInt32(offset)
        default:
            throw error("a load or store through a constant", instruction)
        }
    }

    // MARK: Pieces

    /// Depth from code in piece `index` (outside any `if`) to the loop.
    func loopDepth(from index: Int) -> Int {
        (pieces.count - 1 - index) + (hasTry ? 1 : 0)
    }

    mutating func emitPiece(_ index: Int) throws {
        let piece = pieces[index]
        var terminated = false
        for instruction in piece.instructions {
            if case .call(_, .global("setjmp"), _) = instruction.kind {
                // Reached normally: setjmp answers 0, and this site is armed,
                // so a landing resumes here with 1. The continuation is the
                // next piece; execution falls into it.
                guard let site = setjmpSites.firstIndex(where: { $0.continuation == index + 1 }),
                      let result = instruction.result, let slot = local[result] else {
                    throw error("a setjmp the translator did not split", instruction)
                }
                code.i32Const(0)
                code.localSet(slot)
                code.i32Const(Int32(site + 1))
                code.localSet(jmpSite)
                continue
            }
            if try emitTerminator(instruction, in: index) {
                terminated = true
                break
            }
            try emitInstruction(instruction)
        }
        if !terminated {
            // A piece that ends at a setjmp falls through to its continuation.
            guard index + 1 < pieces.count, pieces[index + 1].isSetjmpContinuation else {
                throw error("a block with no terminator")
            }
        }
    }

    mutating func emitInstruction(_ instruction: IRInstruction) throws {
        switch instruction.kind {
        case .alloca, .phi:
            break
        case .elementPointer(_, let pointer, let indexes):
            guard let result = instruction.result else { return }
            if address[result] != nil { return }
            _ = (pointer, indexes)
            throw error("a getelementptr on a pointer known only at run time", instruction)
        case .load(let type, let pointer):
            guard let result = instruction.result else { return }
            if case .register(let name) = pointer, promotedAlloca.contains(name) {
                code.localGet(local[name]!)
            } else if case .global(let name) = pointer, let promoted = module.promoted[name] {
                code.globalGet(promoted.index)
            } else {
                let offset = try pushMemoryAddress(pointer, instruction)
                switch type {
                case .double: code.f64Load(offset: offset)
                case .pointer, .int(64): code.i64Load(offset: offset)
                case .int(32): code.i32Load(offset: offset)
                case .int: code.i32Load8U(offset: offset)
                default: throw error("a load of \(type)", instruction)
                }
            }
            code.localSet(local[result]!)
        case .store(let type, let value, let pointer):
            if case .register(let name) = pointer, promotedAlloca.contains(name) {
                try push(value, as: type, instruction)
                code.localSet(local[name]!)
            } else if case .global(let name) = pointer, let promoted = module.promoted[name] {
                try push(value, as: type, instruction)
                code.globalSet(promoted.index)
            } else {
                let offset = try pushMemoryAddress(pointer, instruction)
                try push(value, as: type, instruction)
                switch type {
                case .double: code.f64Store(offset: offset)
                case .pointer, .int(64): code.i64Store(offset: offset)
                case .int(32): code.i32Store(offset: offset)
                case .int: code.i32Store8(offset: offset)
                default: throw error("a store of \(type)", instruction)
                }
            }
            // A statement starts where basicc records it: a debug build asks
            // the debugger whether to stop there (BASIC-46).
            if module.debug, case .global("basic.here") = pointer, case .integer(let statement) = value, statement >= 0 {
                code.i32Const(Int32(statement))
                code.i32Const(number)
                code.localGet(fp)
                code.call(module.importIndex[WasmTranslator.debugImport]!)
            }
        case .floatCompare(let predicate, let left, let right):
            try floatCompare(predicate, left, right, instruction)
            code.localSet(local[instruction.result!]!)
        case .intCompare(let predicate, let type, let left, let right):
            try push(left, as: type, instruction)
            try push(right, as: type, instruction)
            let wide = module.wasmType(type) == .i64
            let opcode: UInt8
            switch predicate {
            case "eq": opcode = wide ? WasmOp.i64Eq : WasmOp.i32Eq
            case "ne": opcode = wide ? WasmOp.i64Ne : WasmOp.i32Ne
            case "slt": opcode = wide ? WasmOp.i64LtS : WasmOp.i32LtS
            case "sle": opcode = wide ? WasmOp.i64LeS : WasmOp.i32LeS
            case "sgt": opcode = wide ? WasmOp.i64GtS : WasmOp.i32GtS
            case "sge": opcode = wide ? WasmOp.i64GeS : WasmOp.i32GeS
            case "ult": opcode = wide ? WasmOp.i64LtU : WasmOp.i32LtU
            case "ule": opcode = wide ? WasmOp.i64LeU : WasmOp.i32LeU
            case "ugt": opcode = wide ? WasmOp.i64GtU : WasmOp.i32GtU
            case "uge": opcode = wide ? WasmOp.i64GeU : WasmOp.i32GeU
            default: throw error("icmp \(predicate)", instruction)
            }
            code.op(opcode)
            code.localSet(local[instruction.result!]!)
        case .binary(let opcode, let type, let left, let right):
            try push(left, as: type, instruction)
            try push(right, as: type, instruction)
            let wide = module.wasmType(type) == .i64
            switch opcode {
            case "fadd": code.op(WasmOp.f64Add)
            case "fsub": code.op(WasmOp.f64Sub)
            case "fmul": code.op(WasmOp.f64Mul)
            case "fdiv": code.op(WasmOp.f64Div)
            case "and": code.op(wide ? WasmOp.i64And : WasmOp.i32And)
            case "or": code.op(wide ? WasmOp.i64Or : WasmOp.i32Or)
            case "xor": code.op(wide ? WasmOp.i64Xor : WasmOp.i32Xor)
            case "add": code.op(wide ? WasmOp.i64Add : WasmOp.i32Add)
            case "sub": code.op(wide ? WasmOp.i64Sub : WasmOp.i32Sub)
            case "mul": code.op(wide ? WasmOp.i64Mul : WasmOp.i32Mul)
            default: throw error("\(opcode)", instruction)
            }
            if case .int(1) = type, opcode == "xor" || opcode == "add" || opcode == "sub" || opcode == "mul" {
                code.i32Const(1)
                code.op(WasmOp.i32And)
            }
            code.localSet(local[instruction.result!]!)
        case .floatNegate(let value):
            try push(value, as: .double, instruction)
            code.op(WasmOp.f64Neg)
            code.localSet(local[instruction.result!]!)
        case .convert(let opcode, let from, let value, let to):
            try push(value, as: from, instruction)
            try convert(opcode, from: from, to: to, instruction)
            code.localSet(local[instruction.result!]!)
        case .select(let condition, let type, let first, let second):
            try push(first, as: type, instruction)
            try push(second, as: type, instruction)
            try push(condition, as: .int(1), instruction)
            code.select()
            code.localSet(local[instruction.result!]!)
        case .call(let returns, let callee, let arguments):
            try call(returns: returns, callee: callee, arguments: arguments, instruction)
        default:
            throw error("an instruction in the wrong place", instruction)
        }
    }

    mutating func floatCompare(_ predicate: String, _ left: IRValue, _ right: IRValue, _ instruction: IRInstruction) throws {
        func both() throws {
            try push(left, as: .double, instruction)
            try push(right, as: .double, instruction)
        }
        switch predicate {
        case "oeq": try both(); code.op(WasmOp.f64Eq)
        case "ogt": try both(); code.op(WasmOp.f64Gt)
        case "oge": try both(); code.op(WasmOp.f64Ge)
        case "olt": try both(); code.op(WasmOp.f64Lt)
        case "ole": try both(); code.op(WasmOp.f64Le)
        case "une": try both(); code.op(WasmOp.f64Ne)
        case "ugt": try both(); code.op(WasmOp.f64Le); code.op(WasmOp.i32Eqz)
        case "uge": try both(); code.op(WasmOp.f64Lt); code.op(WasmOp.i32Eqz)
        case "ult": try both(); code.op(WasmOp.f64Ge); code.op(WasmOp.i32Eqz)
        case "ule": try both(); code.op(WasmOp.f64Gt); code.op(WasmOp.i32Eqz)
        case "one", "ueq", "ord", "uno":
            try push(left, as: .double, instruction)
            code.localSet(scratchA)
            try push(right, as: .double, instruction)
            code.localSet(scratchB)
            switch predicate {
            case "one", "ueq":
                code.localGet(scratchA); code.localGet(scratchB); code.op(WasmOp.f64Lt)
                code.localGet(scratchA); code.localGet(scratchB); code.op(WasmOp.f64Gt)
                code.op(WasmOp.i32Or)
                if predicate == "ueq" { code.op(WasmOp.i32Eqz) }
            case "ord":
                code.localGet(scratchA); code.localGet(scratchA); code.op(WasmOp.f64Eq)
                code.localGet(scratchB); code.localGet(scratchB); code.op(WasmOp.f64Eq)
                code.op(WasmOp.i32And)
            default: // uno
                code.localGet(scratchA); code.localGet(scratchA); code.op(WasmOp.f64Ne)
                code.localGet(scratchB); code.localGet(scratchB); code.op(WasmOp.f64Ne)
                code.op(WasmOp.i32Or)
            }
        case "true": code.i32Const(1)
        case "false": code.i32Const(0)
        default: throw error("fcmp \(predicate)", instruction)
        }
    }

    mutating func convert(_ opcode: String, from: IRType, to: IRType, _ instruction: IRInstruction) throws {
        let source = module.wasmType(from)
        let target = module.wasmType(to)
        switch (opcode, source, target) {
        case ("uitofp", .i32, .f64): code.op(WasmOp.f64ConvertI32U)
        case ("uitofp", .i64, .f64): code.op(WasmOp.f64ConvertI64U)
        case ("sitofp", .i32, .f64): code.op(WasmOp.f64ConvertI32S)
        case ("sitofp", .i64, .f64): code.op(WasmOp.f64ConvertI64S)
        case ("fptosi", .f64, .i64): code.prefixed(WasmOp.i64TruncSatF64S)
        case ("fptoui", .f64, .i64): code.prefixed(WasmOp.i64TruncSatF64U)
        case ("fptosi", .f64, .i32): code.prefixed(2)
        case ("fptoui", .f64, .i32): code.prefixed(3)
        case ("trunc", .i64, .i32): code.op(WasmOp.i32WrapI64)
        case ("trunc", .i32, .i32): break
        case ("zext", .i32, .i64): code.op(WasmOp.i64ExtendI32U)
        case ("sext", .i32, .i64): code.op(WasmOp.i64ExtendI32S)
        case ("zext", .i32, .i32), ("sext", .i32, .i32): break
        default: throw error("\(opcode) \(from) to \(to)", instruction)
        }
        if case .int(1) = to, opcode == "trunc" {
            code.i32Const(1)
            code.op(WasmOp.i32And)
        }
    }

    mutating func call(returns: IRType, callee: IRValue, arguments: [(IRType, IRValue)], _ instruction: IRInstruction) throws {
        switch callee {
        case .global(let name) where module.functionIndex[name] != nil:
            for (type, value) in arguments { try push(value, as: type, instruction) }
            code.call(module.functionIndex[name]!)
        case .global(let name) where ModuleTranslation.inlineIntrinsics.contains(name):
            guard let (_, value) = arguments.first else { throw error("an intrinsic with no argument", instruction) }
            try push(value, as: .double, instruction)
            if name == "llvm.round.f64" {
                // Half away from zero, which f64.nearest (half to even) is not:
                // t = trunc(x); if |x - t| >= 0.5 { t += copysign(1, x) }.
                code.localTee(scratchA)
                code.op(WasmOp.f64Trunc)
                code.localSet(scratchB)
                code.localGet(scratchA)
                code.localGet(scratchB)
                code.op(WasmOp.f64Sub)
                code.op(WasmOp.f64Abs)
                code.f64Const(0.5)
                code.op(WasmOp.f64Ge)
                code.ifThen()
                code.localGet(scratchB)
                code.f64Const(1)
                code.localGet(scratchA)
                code.op(WasmOp.f64Copysign)
                code.op(WasmOp.f64Add)
                code.localSet(scratchB)
                code.end()
                code.localGet(scratchB)
                break
            }
            switch name {
            case "llvm.floor.f64": code.op(WasmOp.f64Floor)
            case "llvm.ceil.f64": code.op(WasmOp.f64Ceil)
            case "llvm.trunc.f64": code.op(WasmOp.f64Trunc)
            case "llvm.fabs.f64": code.op(WasmOp.f64Abs)
            case "llvm.sqrt.f64": code.op(WasmOp.f64Sqrt)
            default: throw error("the intrinsic \(name)", instruction)
            }
        case .global(let name):
            guard let index = module.importIndex[name] else { throw error("a call to @\(name), which is not imported", instruction) }
            let entry = module.imports[Int(index)]
            for ((type, value), kind) in zip(arguments, entry.parameters) {
                try push(value, as: type, instruction)
                switch kind {
                case .pointer: code.op(WasmOp.f64ConvertI64U)
                case .int64: code.op(WasmOp.f64ConvertI64S)
                default: break
                }
            }
            code.call(index)
            switch entry.result {
            case .pointer?: code.prefixed(WasmOp.i64TruncSatF64U)
            case .int64?: code.prefixed(WasmOp.i64TruncSatF64S)
            default: break
            }
        case .register(let name):
            // Through a function pointer: a table slot.
            var parameters: [WasmValueType] = []
            for (type, value) in arguments {
                try push(value, as: type, instruction)
                guard let wasm = module.wasmType(type) else { throw error("an argument of type \(type)", instruction) }
                parameters.append(wasm)
            }
            guard let pointer = local[name] else { throw error("a call through %\(name), which has no value", instruction) }
            code.localGet(pointer)
            code.op(WasmOp.i32WrapI64)
            code.callIndirect(type: module.type(WasmFunctionType(parameters: parameters, results: module.wasmType(returns).map { [$0] } ?? [])))
        default:
            throw error("a call to a constant", instruction)
        }
        if let result = instruction.result {
            code.localSet(local[result]!)
        } else if returns != .void {
            code.drop()
        }
    }

    // MARK: Terminators

    /// Emits the instruction if it ends the piece, and says whether it did.
    mutating func emitTerminator(_ instruction: IRInstruction, in index: Int) throws -> Bool {
        switch instruction.kind {
        case .branch(let label):
            try jump(to: label, from: index, depthInside: 0, instruction)
            return true
        case .conditionalBranch(let condition, let yes, let no):
            try push(condition, as: .int(1), instruction)
            code.ifThen()
            try jump(to: yes, from: index, depthInside: 1, instruction, mayFallThrough: false)
            code.end()
            try jump(to: no, from: index, depthInside: 0, instruction)
            return true
        case .switchOn(let type, let value, let fallback, let cases):
            for (match, label) in cases {
                try push(value, as: type, instruction)
                ModuleTranslation.pushConstant(.integer(match), type: type, into: &code)
                code.op(module.wasmType(type) == .i64 ? WasmOp.i64Eq : WasmOp.i32Eq)
                code.ifThen()
                try jump(to: label, from: index, depthInside: 1, instruction, mayFallThrough: false)
                code.end()
            }
            try jump(to: fallback, from: index, depthInside: 0, instruction)
            return true
        case .returnValue(let type, let value):
            if let value { try push(value, as: type, instruction) }
            if frameSize > 0 {
                code.localGet(fp)
                code.i32Const(Int32(frameSize))
                code.op(WasmOp.i32Add)
                code.globalSet(module.stackPointer)
            }
            code.returnFromFunction()
            return true
        case .unreachable:
            code.unreachable()
            return true
        default:
            return false
        }
    }

    mutating func jump(to label: String, from index: Int, depthInside: Int, _ instruction: IRInstruction, mayFallThrough: Bool = true) throws {
        guard let target = pieceIndex[label] else { throw error("a branch to \(label), which is not a block", instruction) }
        // Phis in the target take this piece's values, all read before any is written.
        if let incoming = phis[target] {
            let from = pieces[index].phiLabel
            for phi in incoming {
                guard let (value, _) = phi.incoming.first(where: { $0.1 == from }) else {
                    throw error("a phi with no value for \(from)", instruction)
                }
                try push(value, as: phi.type, instruction)
            }
            for phi in incoming.reversed() { code.localSet(local[phi.result]!) }
        }
        if target <= index {
            // A back-edge: count down to the next poll, which says how far
            // the one after it is. The host sizes that by the clock, so a
            // loop whose passes are slow is polled as often as one whose
            // passes are fast (BASIC-47: 4096 slow passes took seconds).
            code.globalGet(module.pollCounter)
            code.i32Const(1)
            code.op(WasmOp.i32Sub)
            code.localTee(pc) // borrow pc for a moment
            code.globalSet(module.pollCounter)
            code.localGet(pc)
            code.i32Const(0)
            code.op(WasmOp.i32LeS)
            code.ifThen()
            code.call(module.importIndex[WasmTranslator.pollImport]!)
            code.globalSet(module.pollCounter)
            code.end()
        }
        if mayFallThrough, target == index + 1 {
            return
        }
        code.i32Const(Int32(target))
        code.localSet(pc)
        code.br(loopDepth(from: index) + depthInside)
    }
}

private extension WasmCode {
    /// For the one immediate (rethrow's depth) not worth a method of its own.
    mutating func buffer_unsigned(_ value: UInt64) {
        var buffer = WasmBuffer()
        buffer.unsigned(value)
        buffer.bytes.forEach { op($0) }
    }
}
