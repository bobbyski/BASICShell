import BASICCompilerKit
import Foundation

/// Lowers a ``BIRModule`` to textual LLVM IR for the traditional dialect.
///
/// ```text
///   BIR globals   ─► @"G.NAME" = global double 0.0 | ptr null | i1 false
///   BIR functions ─► define <type> @"F.NAME"(params)   (main is @main)
///   BIR locals    ─► %"L.NAME" = alloca ...            (in the prologue)
///   BIR blocks    ─► "b.<label>": ... terminator
///   expressions   ─► SSA temporaries; strings and arrays are runtime pointers
///   GOSUB/RETURN  ─► basic_rt_gosub_push / a switch over resume blocks
///   DATA          ─► constant tables registered at start
/// ```
///
/// String ownership: a runtime call that yields a string yields it owned
/// (+1); a variable load is borrowed. A store transfers an owned value or
/// retains a borrowed one, and releases the slot's previous value. Every
/// owned temporary left at the end of an instruction is released there;
/// a function releases its string locals on every return.
struct LLVMLowering {
    private let module: BIRModule
    private let options: CompileOptions
    private let constants = ConstantPool()
    /// Where objects live — the runtime, unless a dialect says otherwise.
    /// See `ObjectModel`.
    private let objectModel: any ObjectModel

    init(module: BIRModule, options: CompileOptions, objectModel: any ObjectModel = RuntimeObjectModel()) {
        self.module = module
        self.options = options
        self.objectModel = objectModel
    }

    /// The whole module as `.ll` text.
    func render() -> String {
        var functions: [String] = []
        if !options.omitsEntryPoint {
            var mainEmitter = FunctionEmitter(function: module.main, module: module, constants: constants, isMain: true, objectModel: objectModel)
            functions.append(mainEmitter.render())
        }
        // An imported class's members have no body here: the framework has
        // them, and the object model emits a thunk onto its symbol.
        for function in module.functions where !function.isExternal {
            var emitter = FunctionEmitter(function: function, module: module, constants: constants, isMain: false, objectModel: objectModel)
            functions.append(emitter.render())
        }

        var text = "; basicc — \(module.name), traditional dialect\n"
        text += "target triple = \"\(options.target.rawValue)\"\n\n"
        text += Self.runtimeDeclarations + "\n\n"
        // Only when there is something to say: an empty model leaves Rev 1's
        // IR byte for byte what it was, which the seam is measured against.
        if !objectModel.declarations.isEmpty { text += objectModel.declarations + "\n" }
        for variable in module.globals {
            text += "@\"G.\(variable.name)\" = global \(FunctionEmitter.llvmType(of: variable)) \(FunctionEmitter.zero(of: variable))\n"
        }
        text += "\n" + renderDataTables() + "\n"
        if options.omitsEntryPoint {
            // `main` normally registers the program's types with the runtime.
            // A library has no main, so a constructor does it when the image
            // loads — before any Swift caller can reach a class.
            var setup = LLVMText()
            setup.raw("define internal void @\"basic.library.setup\"() {")
            setup.label("entry")
            setup.emit("call void @basic_rt_start()")
            for type in module.types {
                setup.emit("call void @basic_rt_type_register(i64 \(type.index), ptr \(constants.constant(LLVMLowering.typeDescriptor(type, module: module))))")
            }
            setup.emit("ret void")
            setup.raw("}")
            functions.append(setup.lines.joined(separator: "\n"))
            text += "@llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] "
            text += "[{ i32, ptr, ptr } { i32 65535, ptr @\"basic.library.setup\", ptr null }]\n"
        }
        if module.functions.contains(where: \.isAsync) {
            functions.append(renderTaskSupport())
        }
        if module.functions.contains(where: \.isEventHandler) {
            functions.append(renderEventSupport())
        }
        text += constants.definitions.joined(separator: "\n") + "\n\n"
        text += functions.joined(separator: "\n\n")
        let definitions = objectModel.definitions(for: module)
        if !definitions.isEmpty { text += "\n\n" + definitions }
        return text
    }

    /// A trampoline per event handler: it takes the payload the runtime
    /// built (a boxed dictionary, or a boxed event object when the handler's
    /// parameter names an event class), unboxes it to the parameter's type,
    /// and calls the handler. A handler that declares no parameter is called
    /// as one, the way the interpreter calls it.
    private func renderEventSupport() -> String {
        var out = LLVMText()
        for function in module.functions where function.isEventHandler {
            out.raw("define void @\"E.\(function.name)\"(ptr %payload) {")
            out.label("entry")
            var arguments: [String] = []
            var owned: [(String, String)] = []
            if let parameter = function.parameters.first {
                let value = out.temp()
                switch parameter.type {
                case .number, .void: out.emit("\(value) = call double @basic_rt_value_number(ptr %payload, ptr null)")
                case .boolean: out.emit("\(value) = call i1 @basic_rt_value_boolean(ptr %payload, ptr null)")
                case .string: out.emit("\(value) = call ptr @basic_rt_value_string(ptr %payload, ptr null)"); owned.append((value, "basic_rt_string_release"))
                case .composite(let name): out.emit("\(value) = call ptr @\(objectModel.symbols.unbox)(ptr %payload, i64 \(module.typeIndex(of: name) ?? -1), ptr null)"); owned.append((value, objectModel.symbols.release))
                case .dictionary: out.emit("\(value) = call ptr @basic_rt_value_dictionary(ptr %payload, ptr null)"); owned.append((value, "basic_rt_dictionary_release"))
                case .closure: out.emit("\(value) = call ptr @basic_rt_value_closure(ptr %payload, ptr null)"); owned.append((value, "basic_rt_closure_release"))
                case .variant, .system, .array: out.emit("\(value) = call ptr @basic_rt_value_copy(ptr %payload)"); owned.append((value, "basic_rt_value_release"))
                }
                arguments.append("\(FunctionEmitter.llvmType(of: parameter)) \(value)")
            }
            let call = "call \(FunctionEmitter.llvmType(function.returnType)) @\"F.\(function.name)\"(\(arguments.joined(separator: ", ")))"
            if function.returnType == .void {
                out.emit(call)
            } else {
                let result = out.temp()
                out.emit("\(result) = \(call)")
                if FunctionEmitter.isManaged(function.returnType) {
                    out.emit("call void @\(FunctionEmitter.releaseFunction(function.returnType))(ptr \(result))")
                }
            }
            for (value, release) in owned { out.emit("call void @\(release)(ptr \(value))") }
            out.emit("ret void")
            out.raw("}")
            out.raw("")
        }
        return out.lines.joined(separator: "\n")
    }

    /// The task plumbing for a module with ASYNC FUNCTIONs: `globals.capture`
    /// boxes every global into a snapshot, `globals.restore` puts one back,
    /// and each async function gets a trampoline `A.NAME` that unboxes its
    /// arguments, runs the body inside an error boundary, and boxes the
    /// result (nil when the body failed).
    private func renderTaskSupport() -> String {
        var out = LLVMText()
        var counter = 0
        func temp() -> String { counter += 1; return "%s\(counter)" }
        func box(_ value: String, _ type: BIRType, rank: Int?) -> String {
            let result = temp()
            if rank != nil { out.emit("\(result) = call ptr @basic_rt_value_from_array(ptr \(value))"); return result }
            switch type {
            case .number: out.emit("\(result) = call ptr @basic_rt_value_from_number(double \(value))")
            case .string: out.emit("\(result) = call ptr @basic_rt_value_from_string(ptr \(value))")
            case .boolean: out.emit("\(result) = call ptr @basic_rt_value_from_boolean(i1 \(value))")
            case .composite: out.emit("\(result) = call ptr @\(objectModel.symbols.box)(ptr \(value))")
            case .dictionary: out.emit("\(result) = call ptr @basic_rt_value_from_dictionary(ptr \(value))")
            case .closure: out.emit("\(result) = call ptr @basic_rt_value_from_closure(ptr \(value))")
            case .variant, .system: out.emit("\(result) = call ptr @basic_rt_value_copy(ptr \(value))")
            case .void, .array: out.emit("\(result) = call ptr @basic_rt_value_empty()")
            }
            return result
        }
        /// Unboxes `boxValue` as `type` into `slot`, releasing the slot's old managed value.
        func unboxInto(_ boxValue: String, _ type: BIRType, rank: Int?, slot: String) {
            let old = temp()
            if rank != nil {
                let copy = temp()
                out.emit("\(copy) = call ptr @basic_rt_value_array_copy(ptr \(boxValue))")
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_array_release(ptr \(old))")
                out.emit("store ptr \(copy), ptr \(slot)")
                return
            }
            switch type {
            case .number, .void:
                let value = temp()
                out.emit("\(value) = call double @basic_rt_value_number(ptr \(boxValue), ptr null)")
                out.emit("store double \(value), ptr \(slot)")
            case .boolean:
                let value = temp()
                out.emit("\(value) = call i1 @basic_rt_value_boolean(ptr \(boxValue), ptr null)")
                out.emit("store i1 \(value), ptr \(slot)")
            case .string:
                let value = temp()
                out.emit("\(value) = call ptr @basic_rt_value_string(ptr \(boxValue), ptr null)")
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_string_release(ptr \(old))")
                out.emit("store ptr \(value), ptr \(slot)")
            case .composite(let name):
                let value = temp()
                out.emit("\(value) = call ptr @\(objectModel.symbols.unbox)(ptr \(boxValue), i64 \(module.typeIndex(of: name) ?? -1), ptr null)")
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @\(objectModel.symbols.release)(ptr \(old))")
                out.emit("store ptr \(value), ptr \(slot)")
            case .dictionary:
                let value = temp()
                out.emit("\(value) = call ptr @basic_rt_value_dictionary(ptr \(boxValue), ptr null)")
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_dictionary_release(ptr \(old))")
                out.emit("store ptr \(value), ptr \(slot)")
            case .closure:
                let value = temp()
                out.emit("\(value) = call ptr @basic_rt_value_closure(ptr \(boxValue), ptr null)")
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_closure_release(ptr \(old))")
                out.emit("store ptr \(value), ptr \(slot)")
            case .variant, .system, .array:
                let value = temp()
                out.emit("\(value) = call ptr @basic_rt_value_copy(ptr \(boxValue))")
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_value_release(ptr \(old))")
                out.emit("store ptr \(value), ptr \(slot)")
            }
        }

        // globals.capture
        out.raw("define ptr @\"globals.capture\"() {")
        out.label("entry")
        let snap = temp()
        out.emit("\(snap) = call ptr @basic_rt_snapshot_new(i64 \(module.globals.count))")
        for (index, global) in module.globals.enumerated() {
            let value = temp()
            out.emit("\(value) = load \(FunctionEmitter.llvmType(of: global)), ptr @\"G.\(global.name)\"")
            let boxed = box(value, global.type, rank: global.rank)
            out.emit("call void @basic_rt_snapshot_set(ptr \(snap), i64 \(index), ptr \(boxed))")
            out.emit("call void @basic_rt_value_release(ptr \(boxed))")
        }
        out.emit("ret ptr \(snap)")
        out.raw("}")
        out.raw("")

        // globals.restore
        out.raw("define void @\"globals.restore\"(ptr %snap) {")
        out.label("entry")
        for (index, global) in module.globals.enumerated() {
            let boxed = temp()
            out.emit("\(boxed) = call ptr @basic_rt_snapshot_get(ptr %snap, i64 \(index))")
            unboxInto(boxed, global.type, rank: global.rank, slot: "@\"G.\(global.name)\"")
            out.emit("call void @basic_rt_value_release(ptr \(boxed))")
        }
        out.emit("ret void")
        out.raw("}")
        out.raw("")

        // trampolines
        for function in module.functions where function.isAsync {
            out.raw("define ptr @\"A.\(function.name)\"(ptr %args) {")
            out.label("entry")
            out.emit("%jmpbuf = alloca [64 x i64]")
            out.emit("call void @basic_rt_task_boundary_push(ptr %jmpbuf)")
            out.emit("%landed = call i32 @setjmp(ptr %jmpbuf)")
            out.emit("%failed = icmp ne i32 %landed, 0")
            out.emit("br i1 %failed, label %fail, label %run")
            out.label("run")
            var arguments: [String] = []
            var owned: [(String, String)] = []
            for (index, parameter) in function.parameters.enumerated() {
                let boxed = temp()
                out.emit("\(boxed) = call ptr @basic_rt_array_load_value(ptr %args, i64 \(index))")
                owned.append((boxed, "basic_rt_value_release"))
                let value = temp()
                switch parameter.type {
                case .number, .void: out.emit("\(value) = call double @basic_rt_value_number(ptr \(boxed), ptr null)")
                case .boolean: out.emit("\(value) = call i1 @basic_rt_value_boolean(ptr \(boxed), ptr null)")
                case .string: out.emit("\(value) = call ptr @basic_rt_value_string(ptr \(boxed), ptr null)"); owned.append((value, "basic_rt_string_release"))
                case .composite(let name): out.emit("\(value) = call ptr @\(objectModel.symbols.unbox)(ptr \(boxed), i64 \(module.typeIndex(of: name) ?? -1), ptr null)"); owned.append((value, objectModel.symbols.release))
                case .dictionary: out.emit("\(value) = call ptr @basic_rt_value_dictionary(ptr \(boxed), ptr null)"); owned.append((value, "basic_rt_dictionary_release"))
                case .closure: out.emit("\(value) = call ptr @basic_rt_value_closure(ptr \(boxed), ptr null)"); owned.append((value, "basic_rt_closure_release"))
                case .variant, .system, .array: out.emit("\(value) = call ptr @basic_rt_value_copy(ptr \(boxed))"); owned.append((value, "basic_rt_value_release"))
                }
                arguments.append("\(FunctionEmitter.llvmType(of: parameter)) \(value)")
            }
            let call = "call \(FunctionEmitter.llvmType(function.returnType)) @\"F.\(function.name)\"(\(arguments.joined(separator: ", ")))"
            var resultBox: String
            if function.returnType == .void {
                out.emit(call)
                resultBox = temp()
                out.emit("\(resultBox) = call ptr @basic_rt_value_empty()")
            } else {
                let result = temp()
                out.emit("\(result) = \(call)")
                resultBox = box(result, function.returnType, rank: nil)
                if FunctionEmitter.isManaged(function.returnType) {
                    out.emit("call void @\(FunctionEmitter.releaseFunction(function.returnType))(ptr \(result))")
                }
            }
            for (value, release) in owned { out.emit("call void @\(release)(ptr \(value))") }
            out.emit("call void @basic_rt_task_boundary_pop()")
            out.emit("ret ptr \(resultBox)")
            out.label("fail")
            out.emit("call void @basic_rt_task_boundary_pop()")
            out.emit("ret ptr null")
            out.raw("}")
            out.raw("")
        }
        return out.lines.joined(separator: "\n")
    }

    /// The DATA items as three parallel constant tables.
    private func renderDataTables() -> String {
        let count = max(module.data.count, 1)
        var kinds: [String] = []
        var numbers: [String] = []
        var strings: [String] = []
        for item in module.data {
            switch item {
            case .number(let value):
                kinds.append("i8 0"); numbers.append("double \(FunctionEmitter.double(value))"); strings.append("ptr null")
            case .string(let value):
                kinds.append("i8 1"); numbers.append("double 0.0"); strings.append("ptr \(constants.constant(value))")
            }
        }
        if module.data.isEmpty {
            kinds.append("i8 0"); numbers.append("double 0.0"); strings.append("ptr null")
        }
        return """
        @data.kinds = private constant [\(count) x i8] [\(kinds.joined(separator: ", "))]
        @data.numbers = private constant [\(count) x double] [\(numbers.joined(separator: ", "))]
        @data.strings = private constant [\(count) x ptr] [\(strings.joined(separator: ", "))]
        """
    }

    /// The JSON descriptor the runtime registers a type from.
    static func typeDescriptor(_ type: BIRCompositeType, module: BIRModule) -> String {
        func typeObject(_ type: BIRType, dimensions: [Int?], isInteger: Bool = false) -> [String: Any] {
            switch type {
            case .number, .void: return ["k": isInteger ? "integer" : "number"]
            case .string: return ["k": "string"]
            case .boolean: return ["k": "boolean"]
            case .variant: return ["k": "variant"]
            case .dictionary: return ["k": "dictionary"]
            case .closure: return ["k": "closure"]
            case .system: return ["k": "variant"]
            case .composite(let name): return ["k": "composite", "i": module.typeIndex(of: name) ?? -1]
            case .array(let element, _):
                return ["k": "array", "elem": typeObject(element, dimensions: [], isInteger: isInteger), "dims": dimensions.map { $0.map { $0 as Any } ?? NSNull() }]
            }
        }
        var fields: [[String: Any]] = []
        for field in type.fields {
            var object: [String: Any] = ["name": field.name, "display": field.displayName, "type": typeObject(field.type, dimensions: field.dimensions, isInteger: field.isInteger)]
            if let json = field.jsonName { object["json"] = json }
            func literal(_ value: BIRDefault) -> [String: Any] {
                switch value {
                case .number(let value): return ["n": value]
                case .string(let value): return ["s": value]
                case .boolean(let value): return ["b": value]
                case .null: return ["null": true]
                case .empty: return ["empty": true]
                }
            }
            if let value = field.defaultValue { object["default"] = literal(value) }
            if !field.metadata.isEmpty { object["meta"] = field.metadata.mapValues(literal) }
            fields.append(object)
        }
        var object: [String: Any] = ["name": type.displayName, "kind": type.isClass ? "class" : "record", "fields": fields]
        if let base = type.base { object["base"] = base }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static let runtimeDeclarations = """
    declare void @basic_rt_start()
    declare void @basic_rt_finish()
    declare void @basic_rt_fail(ptr)
    declare void @basic_rt_fail_type(ptr)
    declare void @basic_rt_fail_missing(ptr)
    declare void @basic_rt_gosub_push(i64)
    declare i64 @basic_rt_gosub_pop()
    declare i64 @basic_rt_gosub_depth()
    declare void @basic_rt_randomize(double)
    declare void @basic_rt_randomize_time()
    declare double @basic_rt_rnd()
    declare void @basic_rt_print_text(ptr)
    declare void @basic_rt_print_number(double)
    declare void @basic_rt_print_boolean(i1)
    declare void @basic_rt_print_comma()
    declare void @basic_rt_print_tab(double)
    declare void @basic_rt_print_spc(double)
    declare void @basic_rt_print_newline()
    declare double @basic_rt_input_number(ptr, ptr)
    declare ptr @basic_rt_input_string(ptr, ptr)
    declare i1 @basic_rt_input_boolean(ptr, ptr)
    declare i1 @basic_rt_file_input_boolean(double)
    declare ptr @basic_rt_line_input(ptr)
    declare ptr @basic_rt_number_text(double)
    declare void @basic_rt_using_begin(ptr)
    declare void @basic_rt_using_number(double)
    declare void @basic_rt_using_string(ptr)
    declare void @basic_rt_using_end(i1)
    declare ptr @basic_rt_using_render()
    declare ptr @basic_rt_string_literal(ptr, i64)
    declare void @basic_rt_string_retain(ptr)
    declare void @basic_rt_string_release(ptr)
    declare ptr @basic_rt_string_concat(ptr, ptr)
    declare i1 @basic_rt_string_equal(ptr, ptr)
    declare i1 @basic_rt_string_less(ptr, ptr)
    declare i1 @basic_rt_string_truthy(ptr)
    declare double @basic_rt_string_length(ptr)
    declare double @basic_rt_string_asc(ptr)
    declare double @basic_rt_string_val(ptr)
    declare double @basic_rt_string_instr(double, ptr, ptr)
    declare ptr @basic_rt_number_str(double)
    declare ptr @basic_rt_chr(double)
    declare ptr @basic_rt_string_left(ptr, double)
    declare ptr @basic_rt_string_right(ptr, double)
    declare ptr @basic_rt_string_mid(ptr, double, double)
    declare ptr @basic_rt_space(double)
    declare ptr @basic_rt_string_repeat(double, ptr)
    declare ptr @basic_rt_write_quote(ptr)
    declare ptr @basic_rt_array_dim(i64, ptr, i64, i64)
    declare ptr @basic_rt_array_load_composite(ptr, i64)
    declare void @basic_rt_array_store_composite(ptr, i64, ptr)
    declare void @basic_rt_type_register(i64, ptr)
    declare i1 @basic_rt_composite_get_boolean(ptr, i64)
    declare void @basic_rt_composite_set_boolean(ptr, i64, i1)
    declare ptr @basic_rt_composite_get_array(ptr, i64)
    declare void @basic_rt_composite_set_array(ptr, i64, ptr, ptr)
    declare ptr @basic_rt_composite_get_value(ptr, i64)
    declare void @basic_rt_composite_set_value(ptr, i64, ptr, ptr)
    declare ptr @basic_rt_composite_get_dictionary(ptr, i64)
    declare double @basic_rt_array_count(ptr, ptr)
    declare void @basic_rt_array_assign(ptr, ptr, ptr)
    declare i1 @basic_rt_array_load_boolean(ptr, i64)
    declare void @basic_rt_array_store_boolean(ptr, i64, i1)
    declare ptr @basic_rt_array_load_value(ptr, i64)
    declare void @basic_rt_array_store_value(ptr, i64, ptr, ptr)
    declare ptr @basic_rt_array_load_dictionary(ptr, i64)
    declare void @basic_rt_print_array(ptr, ptr)
    declare ptr @basic_rt_array_text(ptr, ptr)
    declare void @basic_rt_value_release(ptr)
    declare ptr @basic_rt_value_copy(ptr)
    declare ptr @basic_rt_value_store(ptr, ptr, ptr)
    declare ptr @basic_rt_value_empty()
    declare ptr @basic_rt_value_null()
    declare ptr @basic_rt_value_from_number(double)
    declare ptr @basic_rt_value_from_string(ptr)
    declare ptr @basic_rt_value_from_boolean(i1)
    declare ptr @basic_rt_value_from_composite(ptr)
    declare ptr @basic_rt_value_from_array(ptr)
    declare ptr @basic_rt_value_from_dictionary(ptr)
    declare ptr @basic_rt_value_from_closure(ptr)
    declare double @basic_rt_value_number(ptr, ptr)
    declare ptr @basic_rt_value_string(ptr, ptr)
    declare i1 @basic_rt_value_boolean(ptr, ptr)
    declare ptr @basic_rt_value_composite(ptr, i64, ptr)
    declare ptr @basic_rt_value_dictionary(ptr, ptr)
    declare ptr @basic_rt_value_closure(ptr, ptr)
    declare i1 @basic_rt_value_truthy(ptr)
    declare i1 @basic_rt_value_equal(ptr, ptr)
    declare ptr @basic_rt_value_add(ptr, ptr)
    declare double @basic_rt_value_len(ptr)
    declare ptr @basic_rt_value_index(ptr, i64, ptr, ptr)
    declare void @basic_rt_value_set_index(ptr, i64, ptr, ptr, ptr)
    declare ptr @basic_rt_value_field(ptr, ptr, ptr)
    declare void @basic_rt_print_value(ptr)
    declare ptr @basic_rt_value_text(ptr)
    declare ptr @basic_rt_json_encode(ptr, i1)
    declare ptr @basic_rt_json_decode(ptr, i1)
    declare ptr @basic_rt_dictionary_new()
    declare ptr @basic_rt_dictionary_copy(ptr)
    declare void @basic_rt_dictionary_release(ptr)
    declare ptr @basic_rt_dictionary_get(ptr, ptr, ptr)
    declare void @basic_rt_dictionary_set(ptr, ptr, ptr, ptr)
    declare void @basic_rt_print_dictionary(ptr)
    declare ptr @basic_rt_dictionary_text(ptr)
    declare ptr @basic_rt_composite_new(i64)
    declare ptr @basic_rt_composite_copy(ptr)
    declare void @basic_rt_composite_assign(ptr, ptr)
    declare void @basic_rt_composite_release(ptr)
    declare i64 @basic_rt_composite_type(ptr)
    declare double @basic_rt_composite_get_number(ptr, i64)
    declare void @basic_rt_composite_set_number(ptr, i64, double)
    declare ptr @basic_rt_composite_get_string(ptr, i64)
    declare void @basic_rt_composite_set_string(ptr, i64, ptr)
    declare ptr @basic_rt_composite_get_composite(ptr, i64)
    declare void @basic_rt_composite_set_composite(ptr, i64, ptr)
    declare void @basic_rt_print_composite(ptr)
    declare ptr @basic_rt_composite_text(ptr)
    declare ptr @basic_rt_closure_new(ptr, ptr)
    declare void @basic_rt_closure_retain(ptr)
    declare void @basic_rt_closure_release(ptr)
    declare ptr @basic_rt_closure_function(ptr)
    declare ptr @basic_rt_closure_environment(ptr)
    declare void @basic_rt_array_release(ptr)
    declare i64 @basic_rt_array_offset(ptr, ptr, i64, ptr)
    declare double @basic_rt_array_load_number(ptr, i64)
    declare void @basic_rt_array_store_number(ptr, i64, double)
    declare ptr @basic_rt_array_load_string(ptr, i64)
    declare void @basic_rt_array_store_string(ptr, i64, ptr)
    declare void @basic_rt_data_register(i64, ptr, ptr, ptr)
    declare void @basic_rt_restore()
    declare double @basic_rt_read_number(ptr)
    declare ptr @basic_rt_read_string(ptr)
    declare i32 @setjmp(ptr) returns_twice
    declare void @basic_rt_error_install(ptr)
    declare void @basic_rt_statement(i64, i64)
    declare void @basic_rt_on_error(i64)
    declare void @basic_rt_raise(double)
    declare i64 @basic_rt_error_handler()
    declare i64 @basic_rt_resume_next()
    declare double @basic_rt_err()
    declare double @basic_rt_erl()
    declare void @basic_rt_cls()
    declare void @basic_rt_capture_begin()
    declare ptr @basic_rt_capture_end()
    declare void @basic_rt_file_open(ptr, i64, double, double)
    declare void @basic_rt_file_reset(double)
    declare ptr @basic_rt_file_input_chars(double, double)
    declare double @basic_rt_file_seek_position(double)
    declare void @basic_rt_file_seek(double, double)
    declare void @basic_rt_file_field_begin(double)
    declare ptr @basic_rt_file_field(double, double, ptr)
    declare void @basic_rt_field_mirror(ptr, ptr)
    declare ptr @basic_rt_field_set(ptr, ptr, i1)
    declare void @basic_rt_file_put(double, double, i1)
    declare void @basic_rt_file_get(double, double, i1)
    declare ptr @basic_rt_field_value_or(ptr, ptr)
    declare ptr @basic_rt_mki(double, double, ptr)
    declare ptr @basic_rt_mks(double, ptr)
    declare ptr @basic_rt_mkd(double, ptr)
    declare double @basic_rt_cvi(ptr, double, ptr)
    declare double @basic_rt_cvs(ptr, ptr)
    declare double @basic_rt_cvd(ptr, ptr)
    declare ptr @basic_rt_file_read_bytes(ptr)
    declare void @basic_rt_file_write_bytes(ptr, ptr)
    declare void @basic_rt_file_append_bytes(ptr, ptr)
    declare ptr @basic_rt_file_read_json(ptr, i1)
    declare void @basic_rt_file_write_json(ptr, ptr, i1)
    declare ptr @basic_rt_file_files(ptr)
    declare ptr @basic_rt_system_new(ptr, i64, ptr)
    declare void @basic_rt_event_register(ptr, ptr, ptr, i64)
    declare void @basic_rt_handler_register(ptr, ptr)
    declare ptr @basic_rt_value_call(ptr, ptr, i64, ptr, ptr)
    declare void @basic_rt_event_post(ptr, ptr, ptr)
    declare void @basic_rt_events_drain(i64)
    declare void @basic_rt_timer_on(ptr, double, ptr, i64)
    declare void @basic_rt_system_set(ptr, ptr, ptr)
    declare ptr @basic_rt_snapshot_new(i64)
    declare void @basic_rt_snapshot_set(ptr, i64, ptr)
    declare ptr @basic_rt_snapshot_get(ptr, i64)
    declare void @basic_rt_snapshot_release(ptr)
    declare ptr @basic_rt_value_array_copy(ptr)
    declare void @basic_rt_tasks_install(ptr, ptr)
    declare ptr @basic_rt_task_launch(ptr, ptr, ptr)
    declare ptr @basic_rt_task_value(ptr)
    declare ptr @basic_rt_task_sleep(double)
    declare ptr @basic_rt_task_await(ptr)
    declare void @basic_rt_task_join(ptr)
    declare void @basic_rt_task_cancel(ptr)
    declare void @basic_rt_task_background(ptr)
    declare void @basic_rt_task_discard(ptr)
    declare ptr @basic_rt_task_status(ptr)
    declare ptr @basic_rt_task_error(ptr)
    declare void @basic_rt_task_boundary_push(ptr)
    declare void @basic_rt_task_boundary_pop()
    declare ptr @basic_rt_inkey()
    declare void @basic_rt_files_list()
    declare ptr @basic_rt_system(ptr)
    declare void @basic_rt_gfx_screen(double)
    declare void @basic_rt_gfx_color(ptr, ptr)
    declare void @basic_rt_gfx_pset(double, double, ptr)
    declare void @basic_rt_gfx_preset(double, double, ptr)
    declare void @basic_rt_gfx_line(double, double, double, double, ptr)
    declare void @basic_rt_gfx_circle(double, double, double, ptr, double, i1)
    declare void @basic_rt_gfx_paint(double, double, ptr, ptr)
    declare void @basic_rt_gfx_draw(ptr)
    declare double @basic_rt_gfx_point(double, double)
    declare double @basic_rt_field_count(ptr)
    declare ptr @basic_rt_field_name(ptr, ptr)
    declare ptr @basic_rt_field_meta(ptr, ptr)
    declare ptr @basic_rt_field_value(ptr, ptr)
    declare ptr @basic_rt_set_field(ptr, ptr, ptr)
    declare void @basic_rt_system_print(ptr)
    declare ptr @basic_rt_current_dir()
    declare void @basic_rt_key_mode(i64)
    declare double @basic_rt_screen_width()
    declare double @basic_rt_screen_height()
    declare void @basic_rt_locate(double, double)
    declare ptr @basic_rt_line_input_field(ptr, i1, double, double, ptr, i1)
    declare ptr @basic_rt_line_input_exit_key()
    declare ptr @basic_rt_system_call(ptr, ptr, i64, ptr)
    declare void @basic_rt_file_close(double)
    declare void @basic_rt_file_print(double, ptr)
    declare void @basic_rt_file_write_line(double, ptr)
    declare void @basic_rt_file_input_begin(double)
    declare double @basic_rt_file_input_number(double, ptr)
    declare ptr @basic_rt_file_input_string(double)
    declare ptr @basic_rt_file_line_input(double)
    declare i1 @basic_rt_file_eof(double)
    declare double @basic_rt_file_lof(double)
    declare double @basic_rt_file_loc(double)
    declare double @basic_rt_file_exists_number(ptr)
    declare ptr @basic_rt_date()
    declare ptr @basic_rt_time()
    declare double @basic_rt_sleep(double)
    declare ptr @basic_rt_input_chars(double)
    declare ptr @basic_rt_file_cwd()
    declare void @basic_rt_file_chdir(ptr)
    declare void @basic_rt_file_mkdir(ptr)
    declare void @basic_rt_file_rm(ptr)
    declare void @basic_rt_file_rename(ptr, ptr)
    declare i1 @basic_rt_file_exists(ptr)
    declare i1 @basic_rt_file_isdir(ptr)
    declare ptr @basic_rt_file_read_text(ptr)
    declare void @basic_rt_file_write_text(ptr, ptr)
    declare double @llvm.fabs.f64(double)
    declare double @llvm.floor.f64(double)
    declare double @llvm.trunc.f64(double)
    declare double @llvm.round.f64(double)
    declare double @llvm.sqrt.f64(double)
    declare double @llvm.sin.f64(double)
    declare double @llvm.cos.f64(double)
    declare double @llvm.exp.f64(double)
    declare double @llvm.log.f64(double)
    declare double @tan(double)
    declare double @atan(double)
    """
}

/// Module-wide string constants, shared by every function emitter.
final class ConstantPool {
    private(set) var definitions: [String] = []
    private var count = 0

    /// A private constant holding NUL-terminated text; returns its name.
    func constant(_ text: String) -> String {
        constant(text, returnCount: true).0
    }

    func constant(_ text: String, returnCount: Bool) -> (String, Int) {
        count += 1
        let name = "@.str.\(count)"
        let (body, byteCount) = LLVMText.cString(text)
        definitions.append("\(name) = private unnamed_addr constant [\(byteCount) x i8] c\"\(body)\"")
        return (name, byteCount)
    }
}

/// Lowers one BIR function.
struct FunctionEmitter {
    private let function: BIRFunction
    private let module: BIRModule
    private let constants: ConstantPool
    private let isMain: Bool
    private let objectModel: any ObjectModel
    /// Shorthand for the whole-object symbols.
    private var objects: ObjectSymbols { objectModel.symbols }
    private var out = LLVMText()
    /// Owned string temporaries produced by the current instruction.
    private var owned: [String] = []
    /// Which owned temporaries are records (released differently).
    private var ownedComposites: Set<String> = []
    /// Which owned temporaries are closures.
    private var ownedClosures: Set<String> = []
    /// Which owned temporaries are VARIANT boxes.
    private var ownedValues: Set<String> = []
    /// Which owned temporaries are dictionaries.
    private var ownedDictionaries: Set<String> = []
    /// Slots for boxed arguments and indexes handed to the runtime. Wide
    /// enough for every call the language allows — a TUI control takes a
    /// dozen arguments, a `rect` twelve — and a call that wanted more is
    /// refused rather than written past the end of it and over the stack.
    private let scratchValues = 32
    private var gosubResumes: [BIRBlockID] = []
    private var usesGosub = false
    private var usesErrorHandling: Bool { isMain && !function.statementResumeBlocks.isEmpty }
    /// The largest number of indexes any DIM or element access uses.
    private var scratchRank = 1

    init(function: BIRFunction, module: BIRModule, constants: ConstantPool, isMain: Bool, objectModel: any ObjectModel = RuntimeObjectModel()) {
        self.function = function
        self.module = module
        self.constants = constants
        self.isMain = isMain
        self.objectModel = objectModel
    }

    /// The static class of a field's base, when that class is a Swift
    /// object — the one case field access does not go through the runtime.
    private func swiftClass(of base: BIRExpression) -> String? {
        guard case .composite(let name) = base.type, objectModel.isSwiftObject(name) else { return nil }
        return name
    }

    private func swiftClass(of place: BIRPlace) -> String? {
        guard case .composite(let name) = place.type, objectModel.isSwiftObject(name) else { return nil }
        return name
    }

    mutating func render() -> String {
        for block in function.blocks {
            if case .gosub(_, let resume) = block.terminator { gosubResumes.append(resume); usesGosub = true }
            if case .returnFromGosub = block.terminator { usesGosub = true }
        }
        scratchRank = max(1, (function.locals + module.globals).compactMap(\.rank).max() ?? 1)
        lowerBody()

        let signature: String
        if isMain {
            signature = "define i32 @main(i32 %argc, ptr %argv)"
        } else {
            let parameters = function.parameters.enumerated()
                .map { "\(Self.llvmType(of: $0.element)) %p\($0.offset)" }
                .joined(separator: ", ")
            signature = "define \(Self.llvmType(function.returnType)) @\"F.\(function.name)\"(\(parameters))"
        }
        return signature + " {\n" + out.lines.joined(separator: "\n") + "\n}"
    }

    // MARK: - Function

    private mutating func lowerBody() {
        out.label("prologue")
        out.emit("%\"scratch.indexes\" = alloca [\(scratchRank) x double]")
        out.emit("%\"scratch.values\" = alloca [\(scratchValues) x ptr]")
        for local in function.locals {
            out.emit("%\"L.\(local.name)\" = alloca \(Self.llvmType(of: local))")
            out.emit("store \(Self.llvmType(of: local)) \(Self.zero(of: local)), ptr %\"L.\(local.name)\"")
        }
        for (index, parameter) in function.parameters.enumerated() {
            var value = "%p\(index)"
            if parameter.type == .string {
                out.emit("call void @basic_rt_string_retain(ptr %p\(index))")
            } else if parameter.type.isClosure {
                out.emit("call void @basic_rt_closure_retain(ptr %p\(index))")
            } else if parameter.type.isComposite, parameter.rank == nil, parameter.name != "ME", parameter.name != "$ENV" {
                // Records and objects pass by value: the callee works on a copy.
                // ME is the caller's copy already, borrowed and written back.
                let copy = out.temp()
                out.emit("\(copy) = call ptr @\(objects.copy)(ptr %p\(index))")
                value = copy
            } else if parameter.type == .variant || parameter.type.isSystem {
                let copy = out.temp()
                out.emit("\(copy) = call ptr @basic_rt_value_copy(ptr %p\(index))")
                value = copy
            } else if parameter.type == .dictionary {
                let copy = out.temp()
                out.emit("\(copy) = call ptr @basic_rt_dictionary_copy(ptr %p\(index))")
                value = copy
            }
            out.emit("store \(Self.llvmType(of: parameter)) \(value), ptr %\"L.\(parameter.name)\"")
        }
        if isMain {
            out.emit("call void @basic_rt_start()")
            for type in module.types {
                out.emit("call void @basic_rt_type_register(i64 \(type.index), ptr \(constants.constant(LLVMLowering.typeDescriptor(type, module: module))))")
            }
            out.emit("call void @basic_rt_data_register(i64 \(module.data.count), ptr @data.kinds, ptr @data.numbers, ptr @data.strings)")
            if module.functions.contains(where: \.isAsync) {
                out.emit("call void @basic_rt_tasks_install(ptr @\"globals.capture\", ptr @\"globals.restore\")")
            }
            for handler in module.namedHandlers {
                out.emit("call void @basic_rt_handler_register(ptr \(constants.constant(handler.name)), ptr @\"E.\(handler.function)\")")
            }
        }
        if usesGosub {
            out.emit("%\"gosub.base\" = call i64 @basic_rt_gosub_depth()")
        }
        if usesErrorHandling {
            // A runtime error longjmps back here; the runtime then says which
            // handler to enter.
            out.emit("%\"error.jmpbuf\" = alloca [64 x i64]")
            out.emit("call void @basic_rt_error_install(ptr %\"error.jmpbuf\")")
            out.emit("%\"error.landed\" = call i32 @setjmp(ptr %\"error.jmpbuf\")")
            out.emit("%\"error.flag\" = icmp ne i32 %\"error.landed\", 0")
            out.emit("br i1 %\"error.flag\", label %\"error.dispatch\", label %\"b.\(function.blocks[0].label)\"")
        } else {
            out.emit("br label %\"b.\(function.blocks[0].label)\"")
        }

        for block in function.blocks {
            out.label("b.\(block.label)")
            for instruction in block.instructions {
                lower(instruction.operation)
                releaseOwned()
            }
            lower(block.terminator)
            releaseOwned()
        }

        if usesErrorHandling {
            out.label("error.dispatch")
            let handler = out.temp()
            out.emit("\(handler) = call i64 @basic_rt_error_handler()")
            let handlers = function.errorHandlerBlocks.enumerated()
                .map { "i64 \($0.offset), label %\"b.\(function.blocks[$0.element].label)\"" }
                .joined(separator: " ")
            out.emit("switch i64 \(handler), label %\"error.bad\" [ \(handlers) ]")
            out.label("error.bad")
            out.emit("unreachable")
            out.label("resume.dispatch")
            let statement = out.temp()
            out.emit("\(statement) = call i64 @basic_rt_resume_next()")
            let resumes = function.statementResumeBlocks.enumerated()
                .map { "i64 \($0.offset), label %\"b.\(function.blocks[$0.element].label)\"" }
                .joined(separator: " ")
            out.emit("switch i64 \(statement), label %\"resume.bad\" [ \(resumes) ]")
            out.label("resume.bad")
            out.emit("unreachable")
        }
        if usesGosub {
            out.label("gosub.dispatch")
            let index = out.temp()
            out.emit("\(index) = call i64 @basic_rt_gosub_pop()")
            let cases = gosubResumes.enumerated()
                .map { "i64 \($0.offset), label %\"b.\(function.blocks[$0.element].label)\"" }
                .joined(separator: " ")
            out.emit("switch i64 \(index), label %\"gosub.bad\" [ \(cases) ]")
            out.label("gosub.bad")
            out.emit("unreachable")
        }
    }

    // MARK: - Instructions

    private mutating func lower(_ operation: BIROperation) {
        switch operation {
        case .store(let variable, let value):
            let (result, isOwned) = lowerValue(value)
            if variable.type == .variant, variable.rank == nil {
                // The interpreter's assign: a VARIANT holding an array keeps
                // its shape, coercing what is assigned into it.
                let old = out.temp(), stored = out.temp()
                out.emit("\(old) = load ptr, ptr \(slotName(variable))")
                out.emit("\(stored) = call ptr @basic_rt_value_store(ptr \(old), ptr \(result), ptr \(constants.constant(variable.name)))")
                out.emit("call void @basic_rt_value_release(ptr \(old))")
                out.emit("store ptr \(stored), ptr \(slotName(variable))")
                break
            }
            storeManaged(result, owned: isOwned, into: slotName(variable), type: variable.type)
            if !Self.isManaged(variable.type) {
                out.emit("store \(Self.llvmType(of: variable)) \(result), ptr \(slotName(variable))")
            }
            if variable.type == .string, module.fieldVariables.contains(variable.name) {
                out.emit("call void @basic_rt_field_mirror(ptr \(constants.constant(variable.name)), ptr \(result))")
            }

        case .storeElement(let variable, let indexes, let value):
            let (result, _) = lowerValue(value)
            let (array, offset) = elementOffset(variable, indexes)
            storeElement(array, offset, result, value: value, elementType: variable.type, name: variable.name)

        case .storeField(let place, let value):
            guard case .field(let base, let index, let type) = place else { break }
            let (result, _) = lowerValue(value)
            let target = placePointer(base)
            let fieldName = constants.constant(fieldDisplayName(of: place))
            switch type {
            case .number where swiftClass(of: base) != nil:
                out.emit("call void @\"\(objectModel.fieldSetSymbol(for: swiftClass(of: base)!, field: index)!)\"(ptr \(target), double \(result))")
            case .boolean where swiftClass(of: base) != nil:
                out.emit("call void @\"\(objectModel.fieldSetSymbol(for: swiftClass(of: base)!, field: index)!)\"(ptr \(target), i1 \(result))")
            case .string where swiftClass(of: base) != nil, .composite where swiftClass(of: base) != nil:
                out.emit("call void @\"\(objectModel.fieldSetSymbol(for: swiftClass(of: base)!, field: index)!)\"(ptr \(target), ptr \(result))")
            case .number: out.emit("call void @basic_rt_composite_set_number(ptr \(target), i64 \(index), double \(result))")
            case .boolean: out.emit("call void @basic_rt_composite_set_boolean(ptr \(target), i64 \(index), i1 \(result))")
            case .string: out.emit("call void @basic_rt_composite_set_string(ptr \(target), i64 \(index), ptr \(result))")
            case .composite, .void, .closure: out.emit("call void @basic_rt_composite_set_composite(ptr \(target), i64 \(index), ptr \(result))")
            case .variant, .dictionary, .system: out.emit("call void @basic_rt_composite_set_value(ptr \(target), i64 \(index), ptr \(boxedPointer(result, value.type)), ptr \(fieldName))")
            case .array: out.emit("call void @basic_rt_composite_set_array(ptr \(target), i64 \(index), ptr \(boxedPointer(result, value.type)), ptr \(fieldName))")
            }

        case .storePlace(let place, let value):
            let (result, _) = lowerValue(value)
            switch place {
            case .arrayElement(let base, let indexes, let name):
                let (array, offset) = elementOffset(arrayPointer(base), name, indexes)
                storeElement(array, offset, result, value: value, elementType: place.type, name: name)
            case .dictionaryEntry(let base, let key, let name):
                let dictionary = dictionaryPointer(base)
                let (keyValue, _) = lowerValue(key)
                out.emit("call void @basic_rt_dictionary_set(ptr \(dictionary), ptr \(boxedPointer(keyValue, key.type)), ptr \(boxedPointer(result, value.type)), ptr \(constants.constant(name)))")
            case .valueEntry(let base, let indexes, let name):
                let box = valuePointer(base)
                let list = boxedIndexes(indexes)
                out.emit("call void @basic_rt_value_set_index(ptr \(box), i64 \(indexes.count), ptr \(list), ptr \(boxedPointer(result, value.type)), ptr \(constants.constant(name)))")
            case .valueField:
                fail("Assigning a field through a VARIANT is not supported")
            case .variable, .element, .field:
                break
            }

        case .assignArray(let place, let value):
            let (result, _) = lowerValue(value)
            let box = boxedPointer(result, value.type)
            switch place {
            case .variable(let variable):
                let array = out.temp()
                out.emit("\(array) = load ptr, ptr \(slotName(variable))")
                out.emit("call void @basic_rt_array_assign(ptr \(array), ptr \(box), ptr \(constants.constant(variable.name)))")
            case .field(let base, let index, _):
                let target = placePointer(base)
                out.emit("call void @basic_rt_composite_set_array(ptr \(target), i64 \(index), ptr \(box), ptr \(constants.constant(fieldDisplayName(of: place))))")
            default:
                fail("Cannot assign an array here")
            }

        case .callMethod(let receiver, let candidates, let arguments, let result):
            let callee = module.functions.first { $0.name == candidates[0].function }!
            let value = lowerMethodCall(receiver, candidates, arguments)
            if callee.returnType != .void, let value {
                if let result {
                    if Self.isManaged(callee.returnType) {
                        storeManaged(value, owned: true, into: slotName(result), type: callee.returnType)
                    } else {
                        out.emit("store \(Self.llvmType(callee.returnType)) \(value), ptr \(slotName(result))")
                    }
                } else if Self.isManaged(callee.returnType) {
                    owned.append(value)
                    if callee.returnType.isComposite { ownedComposites.insert(value) }
                    if callee.returnType.isClosure { ownedClosures.insert(value) }
                }
            }

        case .dim(let variable, let bounds):
            let values = bounds.map { $0.map { lowerValue($0).0 } ?? "-1.0" }
            for (index, value) in values.enumerated() {
                let slot = out.temp()
                out.emit("\(slot) = getelementptr [\(scratchRank) x double], ptr %\"scratch.indexes\", i64 0, i64 \(index)")
                out.emit("store double \(value), ptr \(slot)")
            }
            let array = out.temp()
            var kind = 0, elementType = -1
            switch variable.type {
            case .string: kind = 1
            case .boolean: kind = 2
            case .composite(let name): kind = 3; elementType = module.typeIndex(of: name) ?? -1
            case .variant: kind = 4
            case .dictionary: kind = 5
            case .number where variable.isInteger: kind = 6
            default: break
            }
            out.emit("\(array) = call ptr @basic_rt_array_dim(i64 \(values.count), ptr %\"scratch.indexes\", i64 \(kind), i64 \(elementType))")
            let old = out.temp()
            out.emit("\(old) = load ptr, ptr \(slotName(variable))")
            out.emit("call void @basic_rt_array_release(ptr \(old))")
            out.emit("store ptr \(array), ptr \(slotName(variable))")

        case .call(let name, let arguments):
            let values = arguments.map { lowerValue($0).0 }
            let callee = module.functions.first { $0.name == name }!
            let argumentList = zip(callee.parameters, values).map { "\(Self.llvmType(of: $0)) \($1)" }.joined(separator: ", ")
            if callee.returnType == .void {
                out.emit("call void @\"F.\(name)\"(\(argumentList))")
            } else {
                let result = out.temp()
                out.emit("\(result) = call \(Self.llvmType(callee.returnType)) @\"F.\(name)\"(\(argumentList))")
                if Self.isManaged(callee.returnType) { own(result, as: callee.returnType) }
            }

        case .read(let targets):
            for target in targets {
                switch target {
                case .variable(let variable):
                    let value = readValue(variable)
                    storeManaged(value, owned: true, into: slotName(variable), type: variable.type)
                    if !Self.isManaged(variable.type) {
                        out.emit("store double \(value), ptr \(slotName(variable))")
                    }
                case .element(let variable, let indexes):
                    let value = readValue(variable)
                    let (array, offset) = elementOffset(variable, indexes)
                    if variable.type == .string {
                        out.emit("call void @basic_rt_array_store_string(ptr \(array), i64 \(offset), ptr \(value))")
                        owned.append(value)
                    } else {
                        out.emit("call void @basic_rt_array_store_number(ptr \(array), i64 \(offset), double \(value))")
                    }
                }
            }
        case .restore:
            out.emit("call void @basic_rt_restore()")
        case .cls:
            out.emit("call void @basic_rt_cls()")
        case .fileService(let method, let arguments):
            _ = lowerFileService(method, arguments)
        case .callClosure(let closure, let arguments):
            _ = lowerClosureCall(closure, arguments, .void)
        case .openFile(let path, let mode, let number, let recordLength):
            let pathValue = lowerValue(path).0
            let numberValue = lowerValue(number).0
            let lengthValue = recordLength.map { lowerValue($0).0 } ?? "-1.0"
            out.emit("call void @basic_rt_file_open(ptr \(pathValue), i64 \(mode), double \(numberValue), double \(lengthValue))")
        case .fieldFile(let number, let fields):
            let numberValue = lowerValue(number).0
            out.emit("call void @basic_rt_file_field_begin(double \(numberValue))")
            for field in fields {
                let width = lowerValue(field.width).0
                let value = out.temp()
                out.emit("\(value) = call ptr @basic_rt_file_field(double \(numberValue), double \(width), ptr \(constants.constant(field.variable.name)))")
                storeManaged(value, owned: true, into: slotName(field.variable), type: .string)
            }
        case .setFieldString(let variable, let value, let rightAligned):
            let (text, _) = lowerValue(value)
            let fitted = out.temp()
            out.emit("\(fitted) = call ptr @basic_rt_field_set(ptr \(constants.constant(variable.name)), ptr \(text), i1 \(rightAligned ? "true" : "false"))")
            storeManaged(fitted, owned: true, into: slotName(variable), type: .string)
        case .putRecord(let number, let record):
            let numberValue = lowerValue(number).0
            let recordValue = record.map { lowerValue($0).0 } ?? "0.0"
            out.emit("call void @basic_rt_file_put(double \(numberValue), double \(recordValue), i1 \(record == nil ? "false" : "true"))")
        case .getRecord(let number, let record):
            let numberValue = lowerValue(number).0
            let recordValue = record.map { lowerValue($0).0 } ?? "0.0"
            out.emit("call void @basic_rt_file_get(double \(numberValue), double \(recordValue), i1 \(record == nil ? "false" : "true"))")
            // Refresh every FIELD variable from the runtime's mirror.
            for name in module.fieldVariables {
                guard let variable = (module.globals + function.locals).first(where: { $0.name == name && $0.type == .string }) else { continue }
                let old = out.temp(), fresh = out.temp()
                out.emit("\(old) = load ptr, ptr \(slotName(variable))")
                out.emit("\(fresh) = call ptr @basic_rt_field_value_or(ptr \(constants.constant(name)), ptr \(old))")
                out.emit("call void @basic_rt_string_release(ptr \(old))")
                out.emit("store ptr \(fresh), ptr \(slotName(variable))")
            }
        case .seekFile(let number, let position):
            let numberValue = lowerValue(number).0
            let positionValue = lowerValue(position).0
            out.emit("call void @basic_rt_file_seek(double \(numberValue), double \(positionValue))")
        case .resetFile(let number):
            out.emit("call void @basic_rt_file_reset(double \(lowerValue(number).0))")
        case .discard(let value):
            _ = lowerValue(value)
        case .locate(let row, let column):
            let rowValue = lowerValue(row).0
            let columnValue = lowerValue(column).0
            out.emit("call void @basic_rt_locate(double \(rowValue), double \(columnValue))")
        case .keyMode(let mode):
            out.emit("call void @basic_rt_key_mode(i64 \(mode))")
        case .filesList:
            out.emit("call void @basic_rt_files_list()")
        case .onEvent(let type, let subtype, let handler, let payloadType):
            out.emit("call void @basic_rt_event_register(ptr \(constants.constant(type)), ptr \(constants.constant(subtype)), ptr @\"E.\(handler)\", i64 \(payloadType))")
        case .onTimer(let timer, let ticks, let handler, let payloadType):
            let object = lowerValue(timer).0
            let count = lowerValue(ticks).0
            out.emit("call void @basic_rt_timer_on(ptr \(object), double \(count), ptr @\"E.\(handler)\", i64 \(payloadType))")
        case .systemSet(let object, let property, let value):
            let receiver = lowerValue(object).0
            let boxed = lowerValue(value).0
            out.emit("call void @basic_rt_system_set(ptr \(receiver), ptr \(constants.constant(property)), ptr \(boxed))")
        case .drainEvents(let limit):
            out.emit("call void @basic_rt_events_drain(i64 \(limit))")
        case .systemCommand(let command):
            out.emit("call void @basic_rt_system_print(ptr \(lowerValue(command).0))")
        case .screen(let mode):
            out.emit("call void @basic_rt_gfx_screen(double \(lowerValue(mode).0))")
        case .color(let foreground, let background):
            let fg = lowerValue(foreground).0
            let bg = background.map { lowerValue($0).0 } ?? "null"
            out.emit("call void @basic_rt_gfx_color(ptr \(fg), ptr \(bg))")
        case .pset(let x, let y, let color, let reset):
            let xv = lowerValue(x).0, yv = lowerValue(y).0
            let cv = color.map { lowerValue($0).0 } ?? "null"
            out.emit("call void @basic_rt_gfx_\(reset ? "preset" : "pset")(double \(xv), double \(yv), ptr \(cv))")
        case .gline(let x1, let y1, let x2, let y2, let color):
            let a = lowerValue(x1).0, b = lowerValue(y1).0, c = lowerValue(x2).0, d = lowerValue(y2).0
            let cv = color.map { lowerValue($0).0 } ?? "null"
            out.emit("call void @basic_rt_gfx_line(double \(a), double \(b), double \(c), double \(d), ptr \(cv))")
        case .circle(let x, let y, let radius, let color, let aspect):
            let xv = lowerValue(x).0, yv = lowerValue(y).0, rv = lowerValue(radius).0
            let cv = color.map { lowerValue($0).0 } ?? "null"
            let av = aspect.map { lowerValue($0).0 } ?? "0.0"
            out.emit("call void @basic_rt_gfx_circle(double \(xv), double \(yv), double \(rv), ptr \(cv), double \(av), i1 \(aspect == nil ? "false" : "true"))")
        case .paint(let x, let y, let color, let border):
            let xv = lowerValue(x).0, yv = lowerValue(y).0, cv = lowerValue(color).0
            let bv = border.map { lowerValue($0).0 } ?? "null"
            out.emit("call void @basic_rt_gfx_paint(double \(xv), double \(yv), ptr \(cv), ptr \(bv))")
        case .draw(let program):
            out.emit("call void @basic_rt_gfx_draw(ptr \(lowerValue(program).0))")
        case .lineInputField(let prompt, let into, let exitInto, let length, let maximum, let defaultText):
            let promptValue = prompt.map { lowerValue($0).0 } ?? "null"
            let lengthValue = length.map { lowerValue($0).0 } ?? "-1.0"
            let maxValue = maximum.map { lowerValue($0).0 } ?? "-1.0"
            let defaultValue = defaultText.map { lowerValue($0).0 } ?? "null"
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_line_input_field(ptr \(promptValue), i1 \(exitInto == nil ? "false" : "true"), double \(lengthValue), double \(maxValue), ptr \(defaultValue), i1 \(defaultText == nil ? "false" : "true"))")
            storeManaged(result, owned: true, into: slotName(into), type: .string)
            if let exitInto {
                let key = out.temp()
                out.emit("\(key) = call ptr @basic_rt_line_input_exit_key()")
                storeManaged(key, owned: true, into: slotName(exitInto), type: .string)
            }
        case .closeFile(let number):
            out.emit("call void @basic_rt_file_close(double \(number.map { lowerValue($0).0 } ?? "0.0"))")
        case .printFile(let number, let items, let newline):
            let numberValue = lowerValue(number).0
            out.emit("call void @basic_rt_capture_begin()")
            lower(.print(items, newline: newline))
            let text = out.temp()
            out.emit("\(text) = call ptr @basic_rt_capture_end()")
            owned.append(text)
            out.emit("call void @basic_rt_file_print(double \(numberValue), ptr \(text))")
        case .writeFile(let number, let values):
            let numberValue = lowerValue(number).0
            // WRITE quotes strings, doubles their quotes, and renders the rest as PRINT does.
            var line: String? = nil
            for value in values {
                let (result, _) = lowerValue(value)
                let piece = out.temp()
                switch value.type {
                case .string: out.emit("\(piece) = call ptr @basic_rt_write_quote(ptr \(result))")
                case .number: out.emit("\(piece) = call ptr @basic_rt_number_text(double \(result))")
                case .boolean:
                    let text = out.temp()
                    out.emit("\(text) = select i1 \(result), ptr \(constants.constant("TRUE")), ptr \(constants.constant("FALSE"))")
                    let length = out.temp()
                    out.emit("\(length) = select i1 \(result), i64 4, i64 5")
                    out.emit("\(piece) = call ptr @basic_rt_string_literal(ptr \(text), i64 \(length))")
                case .composite, .void, .closure: out.emit("\(piece) = call ptr @\(objects.text)(ptr \(result))")
                case .variant, .system: out.emit("\(piece) = call ptr @basic_rt_value_text(ptr \(result))")
                case .dictionary: out.emit("\(piece) = call ptr @basic_rt_dictionary_text(ptr \(result))")
                case .array: out.emit("\(piece) = call ptr @basic_rt_array_text(ptr \(result), ptr \(constants.constant("array")))")
                }
                owned.append(piece)
                if let previous = line {
                    let comma = out.temp()
                    out.emit("\(comma) = call ptr @basic_rt_string_literal(ptr \(constants.constant(",")), i64 1)")
                    owned.append(comma)
                    let joined = out.temp(), joined2 = out.temp()
                    out.emit("\(joined) = call ptr @basic_rt_string_concat(ptr \(previous), ptr \(comma))")
                    out.emit("\(joined2) = call ptr @basic_rt_string_concat(ptr \(joined), ptr \(piece))")
                    owned.append(joined); owned.append(joined2)
                    line = joined2
                } else {
                    line = piece
                }
            }
            out.emit("call void @basic_rt_file_write_line(double \(numberValue), ptr \(line ?? "null"))")
        case .inputFile(let number, let targets):
            let numberValue = lowerValue(number).0
            out.emit("call void @basic_rt_file_input_begin(double \(numberValue))")
            for target in targets {
                switch target {
                case .variable(let variable):
                    let value = out.temp()
                    switch variable.type {
                    case .string:
                        out.emit("\(value) = call ptr @basic_rt_file_input_string(double \(numberValue))")
                        storeManaged(value, owned: true, into: slotName(variable), type: .string)
                    case .boolean:
                        out.emit("\(value) = call i1 @basic_rt_file_input_boolean(double \(numberValue))")
                        out.emit("store i1 \(value), ptr \(slotName(variable))")
                    default:
                        out.emit("\(value) = call double @basic_rt_file_input_number(double \(numberValue), ptr \(constants.constant(variable.name)))")
                        out.emit("store double \(value), ptr \(slotName(variable))")
                    }
                case .element(let variable, let indexes):
                    let value = out.temp()
                    if variable.type == .string {
                        out.emit("\(value) = call ptr @basic_rt_file_input_string(double \(numberValue))")
                        owned.append(value)
                        let (array, offset) = elementOffset(variable, indexes)
                        out.emit("call void @basic_rt_array_store_string(ptr \(array), i64 \(offset), ptr \(value))")
                    } else {
                        out.emit("\(value) = call double @basic_rt_file_input_number(double \(numberValue), ptr \(constants.constant(variable.name)))")
                        let (array, offset) = elementOffset(variable, indexes)
                        out.emit("call void @basic_rt_array_store_number(ptr \(array), i64 \(offset), double \(value))")
                    }
                }
            }
        case .lineInputFile(let number, let variable):
            let numberValue = lowerValue(number).0
            let value = out.temp()
            out.emit("\(value) = call ptr @basic_rt_file_line_input(double \(numberValue))")
            storeManaged(value, owned: true, into: slotName(variable), type: .string)
        case .markStatement(let id, let line):
            out.emit("call void @basic_rt_statement(i64 \(id), i64 \(line))")
        case .onError(let handler):
            out.emit("call void @basic_rt_on_error(i64 \(handler ?? -1))")
        case .raise(let number):
            out.emit("call void @basic_rt_raise(double \(lowerValue(number).0))")
            out.emit("unreachable")
            out.label(out.freshLabel("raise.cont"))

        case .print(let items, let newline):
            for item in items {
                switch item {
                case .value(let value):
                    let (result, _) = lowerValue(value)
                    switch value.type {
                    case .number: out.emit("call void @basic_rt_print_number(double \(result))")
                    case .string: out.emit("call void @basic_rt_print_text(ptr \(result))")
                    case .boolean: out.emit("call void @basic_rt_print_boolean(i1 \(result))")
                    case .composite: out.emit("call void @\(objects.print)(ptr \(result))")
                    case .variant, .system: out.emit("call void @basic_rt_print_value(ptr \(result))")
                    case .dictionary: out.emit("call void @basic_rt_print_dictionary(ptr \(result))")
                    case .array: out.emit("call void @basic_rt_print_array(ptr \(result), ptr \(constants.constant("array")))")
                    case .closure:
                        let text = out.temp()
                        out.emit("\(text) = call ptr @basic_rt_string_literal(ptr \(constants.constant("<FUNCTION>")), i64 10)")
                        owned.append(text)
                        out.emit("call void @basic_rt_print_text(ptr \(text))")
                    case .void: break
                    }
                case .comma:
                    out.emit("call void @basic_rt_print_comma()")
                case .tab(let value):
                    out.emit("call void @basic_rt_print_tab(double \(lowerValue(value).0))")
                case .spc(let value):
                    out.emit("call void @basic_rt_print_spc(double \(lowerValue(value).0))")
                }
            }
            if newline {
                out.emit("call void @basic_rt_print_newline()")
            }

        case .input(let prompt, let variable, let displayName):
            let promptValue = prompt.map { lowerValue($0).0 } ?? "null"
            // The interpreter names the variable as the program wrote it.
            let name = constants.constant(displayName)
            switch variable.type {
            case .number:
                let result = out.temp()
                out.emit("\(result) = call double @basic_rt_input_number(ptr \(promptValue), ptr \(name))")
                out.emit("store double \(result), ptr \(slotName(variable))")
            case .string:
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_input_string(ptr \(promptValue), ptr \(name))")
                storeManaged(result, owned: true, into: slotName(variable), type: .string)
            case .boolean:
                let result = out.temp()
                out.emit("\(result) = call i1 @basic_rt_input_boolean(ptr \(promptValue), ptr \(name))")
                out.emit("store i1 \(result), ptr \(slotName(variable))")
            case .void, .composite, .closure, .variant, .dictionary, .array, .system:
                fail("INPUT into a record or closure is not supported")
            }

        case .lineInput(let prompt, let variable):
            let promptValue = prompt.map { lowerValue($0).0 } ?? "null"
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_line_input(ptr \(promptValue))")
            storeManaged(result, owned: true, into: slotName(variable), type: .string)

        case .printFileUsing(let number, let format, let values, let newline):
            let numberValue = lowerValue(number).0
            out.emit("call void @basic_rt_capture_begin()")
            lower(.printUsing(format: format, values: values, newline: newline))
            let text = out.temp()
            out.emit("\(text) = call ptr @basic_rt_capture_end()")
            owned.append(text)
            out.emit("call void @basic_rt_file_print(double \(numberValue), ptr \(text))")

        case .printUsing(let format, let values, let newline):
            out.emit("call void @basic_rt_using_begin(ptr \(lowerValue(format).0))")
            feedUsingValues(values)
            out.emit("call void @basic_rt_using_end(i1 \(newline ? "true" : "false"))")

        case .randomize(let seed):
            if let seed {
                out.emit("call void @basic_rt_randomize(double \(lowerValue(seed).0))")
            } else {
                out.emit("call void @basic_rt_randomize_time()")
            }

        case .fail(let message):
            fail(message)
        case .failMissing(let message):
            out.emit("call void @basic_rt_fail_missing(ptr \(constants.constant(message)))")
            out.emit("unreachable")
            out.label(out.freshLabel("fail.cont"))
        case .failType(let message):
            out.emit("call void @basic_rt_fail_type(ptr \(constants.constant(message)))")
            out.emit("unreachable")
            out.label(out.freshLabel("fail.cont"))
        }
    }

    /// Hands PRINT USING's values to the runtime, one call per value.
    private mutating func feedUsingValues(_ values: [BIRExpression]) {
        do {
            for value in values {
                let (result, _) = lowerValue(value)
                switch value.type {
                case .number: out.emit("call void @basic_rt_using_number(double \(result))")
                case .string: out.emit("call void @basic_rt_using_string(ptr \(result))")
                case .composite:
                    let text = out.temp()
                    out.emit("\(text) = call ptr @\(objects.text)(ptr \(result))")
                    owned.append(text)
                    out.emit("call void @basic_rt_using_string(ptr \(text))")
                case .boolean:
                    let text = out.temp()
                    out.emit("\(text) = select i1 \(result), ptr \(constants.constant("TRUE")), ptr \(constants.constant("FALSE"))")
                    let string = out.temp()
                    out.emit("\(string) = call ptr @basic_rt_string_literal(ptr \(text), i64 5)")
                    owned.append(string)
                    out.emit("call void @basic_rt_using_string(ptr \(string))")
                case .variant, .dictionary, .array, .system:
                    let text = out.temp()
                    out.emit("\(text) = call ptr @basic_rt_value_text(ptr \(boxedPointer(result, value.type)))")
                    owned.append(text)
                    out.emit("call void @basic_rt_using_string(ptr \(text))")
                case .void, .closure: break
                }
            }
        }
    }


    /// `READ` one item for a variable; strings come back owned.
    private mutating func readValue(_ variable: BIRVariable) -> String {
        let result = out.temp()
        let name = constants.constant(variable.name)
        if variable.type == .string {
            out.emit("\(result) = call ptr @basic_rt_read_string(ptr \(name))")
        } else {
            out.emit("\(result) = call double @basic_rt_read_number(ptr \(name))")
        }
        return result
    }

    /// Types whose values are runtime objects with ownership.
    static func isManaged(_ type: BIRType) -> Bool {
        type == .string || type.isComposite || type.isClosure || type == .variant || type == .dictionary || type.isSystem
    }

    /// The runtime call that drops one reference of a managed value.
    static func releaseFunction(_ type: BIRType) -> String {
        releaseFunction(type, objects: .runtime)
    }

    static func releaseFunction(_ type: BIRType, objects: ObjectSymbols) -> String {
        switch type {
        case .string: return "basic_rt_string_release"
        case .closure: return "basic_rt_closure_release"
        case .variant, .system: return "basic_rt_value_release"
        case .dictionary: return "basic_rt_dictionary_release"
        default: return objects.release
        }
    }

    /// Records an owned temporary of a managed type so the instruction
    /// releases it.
    private mutating func own(_ value: String, as type: BIRType) {
        owned.append(value)
        if type.isComposite { ownedComposites.insert(value) }
        if type.isClosure { ownedClosures.insert(value) }
        if type == .variant || type.isSystem { ownedValues.insert(value) }
        if type == .dictionary { ownedDictionaries.insert(value) }
    }

    /// A value as a VARIANT box pointer: itself for a VARIANT, else boxed
    /// (an owned temporary).
    private mutating func boxedPointer(_ value: String, _ type: BIRType) -> String {
        if type == .variant || type.isSystem {
            // A VARIANT and a system object are already boxed values, so
            // there is nothing to wrap — but the caller takes what comes back
            // as its own, and this one belongs to whoever it was loaded from.
            let copy = out.temp()
            out.emit("\(copy) = call ptr @basic_rt_value_copy(ptr \(value))")
            own(copy, as: .variant)
            return copy
        }
        let box = out.temp()
        switch type {
        case .number: out.emit("\(box) = call ptr @basic_rt_value_from_number(double \(value))")
        case .string: out.emit("\(box) = call ptr @basic_rt_value_from_string(ptr \(value))")
        case .boolean: out.emit("\(box) = call ptr @basic_rt_value_from_boolean(i1 \(value))")
        case .composite: out.emit("\(box) = call ptr @\(objects.box)(ptr \(value))")
        case .array: out.emit("\(box) = call ptr @basic_rt_value_from_array(ptr \(value))")
        case .dictionary: out.emit("\(box) = call ptr @basic_rt_value_from_dictionary(ptr \(value))")
        case .closure: out.emit("\(box) = call ptr @basic_rt_value_from_closure(ptr \(value))")
        case .void, .variant, .system: out.emit("\(box) = call ptr @basic_rt_value_empty()")
        }
        own(box, as: .variant)
        return box
    }

    /// Boxes each index into the scratch slots and returns the slot array.
    private mutating func boxedIndexes(_ indexes: [BIRExpression]) -> String {
        guard indexes.count <= scratchValues else {
            fail("a call with more than \(scratchValues) arguments is not supported by basicc yet")
            return "%\"scratch.values\""
        }
        for (position, index) in indexes.enumerated() {
            let (value, _) = lowerValue(index)
            let box = boxedPointer(value, index.type)
            let slot = out.temp()
            out.emit("\(slot) = getelementptr [\(scratchValues) x ptr], ptr %\"scratch.values\", i64 0, i64 \(position)")
            out.emit("store ptr \(box), ptr \(slot)")
        }
        return "%\"scratch.values\""
    }

    /// Stores a lowered value into an array element by element type.
    private mutating func storeElement(_ array: String, _ offset: String, _ result: String, value: BIRExpression, elementType: BIRType, name: String) {
        switch elementType {
        case .string: out.emit("call void @basic_rt_array_store_string(ptr \(array), i64 \(offset), ptr \(result))")
        case .composite: out.emit("call void @basic_rt_array_store_composite(ptr \(array), i64 \(offset), ptr \(result))")
        case .boolean: out.emit("call void @basic_rt_array_store_boolean(ptr \(array), i64 \(offset), i1 \(result))")
        case .variant, .dictionary, .array, .closure, .system:
            out.emit("call void @basic_rt_array_store_value(ptr \(array), i64 \(offset), ptr \(boxedPointer(result, value.type)), ptr \(constants.constant(name)))")
        case .number, .void: out.emit("call void @basic_rt_array_store_number(ptr \(array), i64 \(offset), double \(Self.asNumber(result, value.type, &out)))")
        }
    }

    /// The display name of the field a `.field` place names, for messages.
    private func fieldDisplayName(of place: BIRPlace) -> String {
        guard case .field(let base, let index, _) = place, case .composite(let typeName) = base.type,
              let type = module.types.first(where: { $0.name == typeName }), index < type.fields.count else { return "field" }
        return type.fields[index].displayName
    }

    /// The array behind an array-typed place, borrowed.
    private mutating func arrayPointer(_ place: BIRPlace) -> String {
        switch place {
        case .variable(let variable):
            let result = out.temp()
            out.emit("\(result) = load ptr, ptr \(slotName(variable))")
            return result
        case .field(let base, let index, _):
            let parent = placePointer(base)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_composite_get_array(ptr \(parent), i64 \(index))")
            return result
        default:
            fail("Not an array")
            return "null"
        }
    }

    /// The dictionary behind a dictionary-typed place, borrowed.
    private mutating func dictionaryPointer(_ place: BIRPlace) -> String {
        switch place {
        case .variable(let variable):
            let result = out.temp()
            out.emit("\(result) = load ptr, ptr \(slotName(variable))")
            return result
        case .field(let base, let index, _):
            let parent = placePointer(base)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_composite_get_dictionary(ptr \(parent), i64 \(index))")
            return result
        case .element(let variable, let indexes):
            let (array, offset) = elementOffset(variable, indexes)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_array_load_dictionary(ptr \(array), i64 \(offset))")
            return result
        default:
            fail("Not a dictionary")
            return "null"
        }
    }

    /// The VARIANT box a place holds, borrowed (its own storage, so an
    /// in-place mutation lands in the variable).
    private mutating func valuePointer(_ place: BIRPlace) -> String {
        switch place {
        case .variable(let variable):
            let result = out.temp()
            out.emit("\(result) = load ptr, ptr \(slotName(variable))")
            return result
        default:
            let (value, _) = lowerValue(loadExpression(place))
            return value
        }
    }

    /// The value a place holds, as an expression.
    private func loadExpression(_ place: BIRPlace) -> BIRExpression {
        switch place {
        case .variable(let variable): return variable.rank == nil ? .load(variable) : .loadArray(variable)
        case .element(let variable, let indexes): return .element(variable, indexes)
        case .field(let base, let index, let type): return .field(loadExpression(base), index: index, type: type)
        case .arrayElement(let base, let indexes, let name): return .elementOf(loadExpression(base), indexes, name: name)
        case .dictionaryEntry(let base, let key, let name): return .dictionaryGet(loadExpression(base), key: key, name: name)
        case .valueEntry(let base, let indexes, let name): return .valueIndex(loadExpression(base), indexes, name: name)
        case .valueField(let base, let field, let name): return .valueField(loadExpression(base), field: field, name: name)
        }
    }

    /// Stores a string or record into a slot with the ownership dance: a
    /// string is transferred or retained; a record is transferred or copied
    /// (value semantics). The slot's old value is released. A no-op for
    /// other types (the caller stores those).
    private mutating func storeManaged(_ value: String, owned isOwned: Bool, into slot: String, type: BIRType) {
        guard Self.isManaged(type) else { return }
        var stored = value
        if isOwned {
            owned.removeAll { $0 == value }
        } else if type == .string {
            out.emit("call void @basic_rt_string_retain(ptr \(value))")
        } else if type.isClosure {
            out.emit("call void @basic_rt_closure_retain(ptr \(value))")
        } else if type == .variant || type.isSystem {
            let copy = out.temp()
            out.emit("\(copy) = call ptr @basic_rt_value_copy(ptr \(value))")
            stored = copy
        } else if type == .dictionary {
            let copy = out.temp()
            out.emit("\(copy) = call ptr @basic_rt_dictionary_copy(ptr \(value))")
            stored = copy
        } else {
            let copy = out.temp()
            out.emit("\(copy) = call ptr @\(objects.copy)(ptr \(value))")
            stored = copy
        }
        let old = out.temp()
        out.emit("\(old) = load ptr, ptr \(slot)")
        out.emit("call void @\(Self.releaseFunction(type, objects: objects))(ptr \(old))")
        out.emit("store ptr \(stored), ptr \(slot)")
    }

    /// The record a place holds, borrowed and in place — so a store through
    /// it mutates the original.
    private mutating func placePointer(_ place: BIRPlace) -> String {
        switch place {
        case .variable(let variable):
            let result = out.temp()
            out.emit("\(result) = load ptr, ptr \(slotName(variable))")
            return result
        case .element(let variable, let indexes):
            let (array, offset) = elementOffset(variable, indexes)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_array_load_composite(ptr \(array), i64 \(offset))")
            return result
        case .field(let base, let index, _):
            let parent = placePointer(base)
            let result = out.temp()
            if let owner = swiftClass(of: base), let getter = objectModel.fieldGetSymbol(for: owner, field: index) {
                out.emit("\(result) = call ptr @\"\(getter)\"(ptr \(parent))")
            } else {
                out.emit("\(result) = call ptr @basic_rt_composite_get_composite(ptr \(parent), i64 \(index))")
            }
            return result
        case .arrayElement(let base, let indexes, let name):
            let (array, offset) = elementOffset(arrayPointer(base), name, indexes)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_array_load_composite(ptr \(array), i64 \(offset))")
            return result
        case .dictionaryEntry, .valueEntry, .valueField:
            fail("A record reached through a VARIANT or DICTIONARY cannot be mutated in place")
            return "null"
        }
    }

    /// Calls a method: copies the receiver in as ME, dispatches (statically or
    /// on the runtime type), writes ME back, and returns the raw result
    /// (owned when managed) or nil for VOID.
    private mutating func lowerMethodCall(_ receiver: BIRPlace, _ candidates: [BIRMethodCandidate], _ arguments: [BIRExpression]) -> String? {
        let callee = module.functions.first { $0.name == candidates[0].function }!
        let receiverPointer = placePointer(receiver)
        let me = out.temp()
        out.emit("\(me) = call ptr @\(objects.copy)(ptr \(receiverPointer))")
        let values = arguments.map { lowerValue($0).0 }
        let argumentList = ([("ptr", me)] + zip(callee.parameters.dropFirst(), values).map { (Self.llvmType(of: $0), $1) })
            .map { "\($0) \($1)" }.joined(separator: ", ")
        let returnType = Self.llvmType(callee.returnType)
        var value: String? = nil
        if candidates.count == 1 {
            if callee.returnType == .void {
                out.emit("call void @\"F.\(candidates[0].function)\"(\(argumentList))")
            } else {
                let result = out.temp()
                out.emit("\(result) = call \(returnType) @\"F.\(candidates[0].function)\"(\(argumentList))")
                value = result
            }
        } else {
            // Virtual: switch on the receiver's runtime type.
            let typeIndex = out.temp()
            out.emit("\(typeIndex) = call i64 @\(objects.typeIndex)(ptr \(me))")
            let join = out.freshLabel("dispatch.join")
            var incoming: [String] = []
            let cases = candidates.map { candidate -> (String, BIRMethodCandidate) in (out.freshLabel("dispatch.\(candidate.typeIndex)"), candidate) }
            out.emit("switch i64 \(typeIndex), label %\"\(cases[0].0)\" [ " + cases.map { "i64 \($0.1.typeIndex), label %\"\($0.0)\"" }.joined(separator: " ") + " ]")
            for (label, candidate) in cases {
                out.label(label)
                if callee.returnType == .void {
                    out.emit("call void @\"F.\(candidate.function)\"(\(argumentList))")
                } else {
                    let partial = out.temp()
                    out.emit("\(partial) = call \(returnType) @\"F.\(candidate.function)\"(\(argumentList))")
                    incoming.append("[ \(partial), %\"\(label)\" ]")
                }
                out.emit("br label %\"\(join)\"")
            }
            out.label(join)
            if callee.returnType != .void {
                let result = out.temp()
                out.emit("\(result) = phi \(returnType) " + incoming.joined(separator: ", "))
                value = result
            }
        }
        // Write the receiver back — a method's changes to ME are the
        // interpreter's, and so is the copy.
        writeBack(me, to: receiver)
        out.emit("call void @\(objects.release)(ptr \(me))")
        return value
    }

    /// Stores a copy of the record `value` (borrowed) into a place.
    private mutating func writeBack(_ value: String, to place: BIRPlace) {
        switch place {
        case .variable(let variable) where variable.name == "ME" && variable.scope == .local:
            // ME is borrowed from the caller: assign in place, never replace.
            let current = out.temp()
            out.emit("\(current) = load ptr, ptr \(slotName(variable))")
            out.emit("call void @\(objects.assign)(ptr \(current), ptr \(value))")
        case .variable(let variable):
            storeManaged(value, owned: false, into: slotName(variable), type: variable.type)
        case .element(let variable, let indexes):
            let (array, offset) = elementOffset(variable, indexes)
            out.emit("call void @basic_rt_array_store_composite(ptr \(array), i64 \(offset), ptr \(value))")
        case .field(let base, let index, _):
            let parent = placePointer(base)
            if let owner = swiftClass(of: base), let setter = objectModel.fieldSetSymbol(for: owner, field: index) {
                out.emit("call void @\"\(setter)\"(ptr \(parent), ptr \(value))")
            } else {
                out.emit("call void @basic_rt_composite_set_composite(ptr \(parent), i64 \(index), ptr \(value))")
            }
        case .arrayElement(let base, let indexes, let name):
            let (array, offset) = elementOffset(arrayPointer(base), name, indexes)
            out.emit("call void @basic_rt_array_store_composite(ptr \(array), i64 \(offset), ptr \(value))")
        case .dictionaryEntry, .valueEntry, .valueField:
            break
        }
    }

    /// A boolean as a number for storage in a numeric slot.
    static func asNumber(_ value: String, _ type: BIRType, _ out: inout LLVMText) -> String {
        guard type == .boolean else { return value }
        let number = out.temp()
        out.emit("\(number) = uitofp i1 \(value) to double")
        return number
    }

    /// Loads the array pointer and computes the bounds-checked element offset.
    private mutating func elementOffset(_ variable: BIRVariable, _ indexes: [BIRExpression]) -> (array: String, offset: String) {
        let array = out.temp()
        out.emit("\(array) = load ptr, ptr \(slotName(variable))")
        return elementOffset(array, variable.name, indexes)
    }

    /// The bounds-checked element offset into an array pointer.
    private mutating func elementOffset(_ array: String, _ name: String, _ indexes: [BIRExpression]) -> (array: String, offset: String) {
        let values = indexes.map { lowerValue($0).0 }
        for (index, value) in values.enumerated() {
            let slot = out.temp()
            out.emit("\(slot) = getelementptr [\(scratchRank) x double], ptr %\"scratch.indexes\", i64 0, i64 \(index)")
            out.emit("store double \(value), ptr \(slot)")
        }
        let offset = out.temp()
        out.emit("\(offset) = call i64 @basic_rt_array_offset(ptr \(array), ptr \(constants.constant(name)), i64 \(values.count), ptr %\"scratch.indexes\")")
        return (array, offset)
    }

    /// Calls the runtime's failure path and opens a fresh block for whatever
    /// follows, since `unreachable` must end its block.
    private mutating func fail(_ message: String) {
        out.emit("call void @basic_rt_fail(ptr \(constants.constant(message)))")
        out.emit("unreachable")
        out.label(out.freshLabel("fail.cont"))
    }

    private mutating func lower(_ terminator: BIRTerminator) {
        func label(_ id: BIRBlockID) -> String { "%\"b.\(function.blocks[id].label)\"" }
        switch terminator {
        case .jump(let target):
            out.emit("br label \(label(target))")
        case .branch(let condition, let then, let otherwise):
            let test = truthiness(of: condition)
            releaseOwned()
            out.emit("br i1 \(test), label \(label(then)), label \(label(otherwise))")
        case .gosub(let target, let resume):
            let index = gosubResumes.firstIndex(of: resume)!
            out.emit("call void @basic_rt_gosub_push(i64 \(index))")
            out.emit("br label \(label(target))")
        case .returnFromGosub:
            if isMain {
                out.emit("br label %\"gosub.dispatch\"")
            } else {
                // A pending GOSUB of this frame returns to it; otherwise this is
                // the function's own return, with the default value.
                let depth = out.temp(), pending = out.temp()
                let returnLabel = out.freshLabel("ret.default")
                out.emit("\(depth) = call i64 @basic_rt_gosub_depth()")
                out.emit("\(pending) = icmp ugt i64 \(depth), %\"gosub.base\"")
                out.emit("br i1 \(pending), label %\"gosub.dispatch\", label %\"\(returnLabel)\"")
                out.label(returnLabel)
                emitReturn(nil)
            }
        case .end:
            if isMain {
                out.emit("call void @basic_rt_finish()")
                out.emit("ret i32 0")
            } else {
                // The interpreter treats END inside a FUNCTION as that
                // function's return.
                emitReturn(nil)
            }
        case .ret(let value):
            emitReturn(value)
        case .resumeNext:
            out.emit("br label %\"resume.dispatch\"")
        case .unterminated:
            out.emit("unreachable")
        }
    }

    /// Returns from a function: evaluate the value, release string locals,
    /// and hand back an owned string or a plain value.
    private mutating func emitReturn(_ value: BIRExpression?) {
        var result: String? = nil
        if function.returnType != .void {
            if let value {
                let (lowered, isOwned) = lowerValue(value)
                if function.returnType == .string {
                    if isOwned { owned.removeAll { $0 == lowered } } else { out.emit("call void @basic_rt_string_retain(ptr \(lowered))") }
                    result = lowered
                } else if function.returnType.isComposite {
                    if isOwned { owned.removeAll { $0 == lowered }; result = lowered } else {
                        let copy = out.temp()
                        out.emit("\(copy) = call ptr @\(objects.copy)(ptr \(lowered))")
                        result = copy
                    }
                } else if function.returnType.isClosure {
                    if isOwned { owned.removeAll { $0 == lowered } } else { out.emit("call void @basic_rt_closure_retain(ptr \(lowered))") }
                    result = lowered
                } else if function.returnType == .variant || function.returnType == .dictionary || function.returnType.isSystem {
                    if isOwned { owned.removeAll { $0 == lowered }; result = lowered } else {
                        let copy = out.temp()
                        out.emit("\(copy) = call ptr @\(function.returnType == .dictionary ? "basic_rt_dictionary_copy" : "basic_rt_value_copy")(ptr \(lowered))")
                        result = copy
                    }
                } else {
                    result = lowered
                }
            } else if function.returnType.isComposite, case .composite(let name) = function.returnType {
                let fresh = out.temp()
                if let symbol = objectModel.newSymbol(for: name) {
                    out.emit("\(fresh) = call ptr @\"\(symbol)\"()")
                } else {
                    out.emit("\(fresh) = call ptr @basic_rt_composite_new(i64 \(module.typeIndex(of: name) ?? -1))")
                }
                result = fresh
            } else if function.returnType == .variant || function.returnType.isSystem {
                let fresh = out.temp()
                out.emit("\(fresh) = call ptr @basic_rt_value_empty()")
                result = fresh
            } else if function.returnType == .dictionary {
                let fresh = out.temp()
                out.emit("\(fresh) = call ptr @basic_rt_dictionary_new()")
                result = fresh
            } else {
                result = Self.zero(function.returnType)
            }
        }
        releaseOwned()
        for local in function.locals where local.type == .string && local.rank == nil {
            let old = out.temp()
            out.emit("\(old) = load ptr, ptr %\"L.\(local.name)\"")
            out.emit("call void @basic_rt_string_release(ptr \(old))")
        }
        for local in function.locals where local.type.isComposite && local.rank == nil && local.name != "ME" && local.name != "$ENV" {
            let old = out.temp()
            out.emit("\(old) = load ptr, ptr %\"L.\(local.name)\"")
            out.emit("call void @\(objects.release)(ptr \(old))")
        }
        for local in function.locals where local.type.isClosure && local.rank == nil {
            let old = out.temp()
            out.emit("\(old) = load ptr, ptr %\"L.\(local.name)\"")
            out.emit("call void @basic_rt_closure_release(ptr \(old))")
        }
        for local in function.locals where (local.type == .variant || local.type == .dictionary || local.type.isSystem) && local.rank == nil && local.name != "ME" {
            let old = out.temp()
            out.emit("\(old) = load ptr, ptr %\"L.\(local.name)\"")
            out.emit("call void @\(Self.releaseFunction(local.type))(ptr \(old))")
        }
        for local in function.locals where local.rank != nil {
            let old = out.temp()
            out.emit("\(old) = load ptr, ptr %\"L.\(local.name)\"")
            out.emit("call void @basic_rt_array_release(ptr \(old))")
        }
        if let result {
            out.emit("ret \(Self.llvmType(function.returnType)) \(result)")
        } else {
            out.emit("ret void")
        }
    }

    private mutating func releaseOwned() {
        for temporary in owned {
            let release = ownedComposites.contains(temporary) ? objects.release
                : ownedClosures.contains(temporary) ? "basic_rt_closure_release"
                : ownedValues.contains(temporary) ? "basic_rt_value_release"
                : ownedDictionaries.contains(temporary) ? "basic_rt_dictionary_release" : "basic_rt_string_release"
            out.emit("call void @\(release)(ptr \(temporary))")
        }
        owned.removeAll()
        ownedComposites.removeAll()
        ownedClosures.removeAll()
        ownedValues.removeAll()
        ownedDictionaries.removeAll()
    }

    // MARK: - Expressions

    /// Lowers an expression to an SSA value; the flag says whether a string
    /// result is owned (+1) by the current instruction.
    private mutating func lowerValue(_ expression: BIRExpression) -> (String, owned: Bool) {
        switch expression {
        case .number(let value):
            return (Self.double(value), false)
        case .boolean(let value):
            return (value ? "true" : "false", false)
        case .string(let value):
            let result = out.temp()
            let (name, count) = constants.constant(value, returnCount: true)
            out.emit("\(result) = call ptr @basic_rt_string_literal(ptr \(name), i64 \(count - 1))")
            owned.append(result)
            return (result, true)
        case .load(let variable):
            let result = out.temp()
            out.emit("\(result) = load \(Self.llvmType(of: variable)), ptr \(slotName(variable))")
            return (result, false)
        case .element(let variable, let indexes):
            let (array, offset) = elementOffset(variable, indexes)
            return lowerValue(.element(variable, indexes), fromArray: array, offset: offset)
        case .intrinsic(let intrinsic, let arguments):
            return lowerIntrinsic(intrinsic, arguments)
        default:
            return lowerValueRest(expression)
        }
    }

    /// Loads an element of `variable`'s element type from a computed slot.
    private mutating func lowerValue(_ expression: BIRExpression, fromArray array: String, offset: String) -> (String, owned: Bool) {
        guard case .element(let variable, _) = expression else { return ("", false) }
        do {
            let result = out.temp()
            switch variable.type {
            case .string:
                out.emit("\(result) = call ptr @basic_rt_array_load_string(ptr \(array), i64 \(offset))")
                owned.append(result)
                return (result, true)
            case .composite:
                out.emit("\(result) = call ptr @basic_rt_array_load_composite(ptr \(array), i64 \(offset))")
                return (result, false)
            case .boolean:
                out.emit("\(result) = call i1 @basic_rt_array_load_boolean(ptr \(array), i64 \(offset))")
                return (result, false)
            case .variant, .array, .closure, .system:
                out.emit("\(result) = call ptr @basic_rt_array_load_value(ptr \(array), i64 \(offset))")
                own(result, as: .variant)
                return (result, true)
            case .dictionary:
                out.emit("\(result) = call ptr @basic_rt_array_load_dictionary(ptr \(array), i64 \(offset))")
                return (result, false)
            default:
                out.emit("\(result) = call double @basic_rt_array_load_number(ptr \(array), i64 \(offset))")
                return (result, false)
            }
        }
    }

    /// The remaining expression forms.
    private mutating func lowerValueRest(_ expression: BIRExpression) -> (String, owned: Bool) {
        switch expression {
        case .elementOf(let arrayExpression, let indexes, let name):
            let (arrayPointer, _) = lowerValue(arrayExpression)
            let (array, offset) = elementOffset(arrayPointer, name, indexes)
            let elementType = arrayExpression.type.elementType ?? .number
            return lowerValue(.element(BIRVariable(name: name, type: elementType, scope: .local, storage: .array(rank: indexes.count)), indexes), fromArray: array, offset: offset)
        case .field(let base, let index, let type):
            let (parent, _) = lowerValue(base)
            let result = out.temp()
            if let owner = swiftClass(of: base), let getter = objectModel.fieldGetSymbol(for: owner, field: index) {
                switch type {
                case .number:
                    out.emit("\(result) = call double @\"\(getter)\"(ptr \(parent))")
                    return (result, false)
                case .boolean:
                    out.emit("\(result) = call i1 @\"\(getter)\"(ptr \(parent))")
                    return (result, false)
                case .string:
                    out.emit("\(result) = call ptr @\"\(getter)\"(ptr \(parent))")
                    owned.append(result)
                    return (result, true)
                default:
                    // An object field: borrowed, like the runtime's.
                    out.emit("\(result) = call ptr @\"\(getter)\"(ptr \(parent))")
                    return (result, false)
                }
            }
            switch type {
            case .number:
                out.emit("\(result) = call double @basic_rt_composite_get_number(ptr \(parent), i64 \(index))")
                return (result, false)
            case .boolean:
                out.emit("\(result) = call i1 @basic_rt_composite_get_boolean(ptr \(parent), i64 \(index))")
                return (result, false)
            case .string:
                out.emit("\(result) = call ptr @basic_rt_composite_get_string(ptr \(parent), i64 \(index))")
                owned.append(result)
                return (result, true)
            case .composite, .void, .closure:
                out.emit("\(result) = call ptr @basic_rt_composite_get_composite(ptr \(parent), i64 \(index))")
                return (result, false)
            case .array:
                out.emit("\(result) = call ptr @basic_rt_composite_get_array(ptr \(parent), i64 \(index))")
                return (result, false)
            case .variant, .system:
                out.emit("\(result) = call ptr @basic_rt_composite_get_value(ptr \(parent), i64 \(index))")
                own(result, as: .variant)
                return (result, true)
            case .dictionary:
                out.emit("\(result) = call ptr @basic_rt_composite_get_dictionary(ptr \(parent), i64 \(index))")
                return (result, false)
            }
        case .loadArray(let variable):
            let result = out.temp()
            out.emit("\(result) = load ptr, ptr \(slotName(variable))")
            return (result, false)
        case .box(let inner):
            let (value, _) = lowerValue(inner)
            return (boxedPointer(value, inner.type), true)
        case .unbox(let inner, let type, let name):
            let (box, _) = lowerValue(inner)
            let nameArgument = name.map { constants.constant($0) } ?? "null"
            let result = out.temp()
            switch type {
            case .number, .void:
                out.emit("\(result) = call double @basic_rt_value_number(ptr \(box), ptr \(nameArgument))")
                return (result, false)
            case .string:
                out.emit("\(result) = call ptr @basic_rt_value_string(ptr \(box), ptr \(nameArgument))")
                owned.append(result)
                return (result, true)
            case .boolean:
                out.emit("\(result) = call i1 @basic_rt_value_boolean(ptr \(box), ptr \(nameArgument))")
                return (result, false)
            case .composite(let typeName):
                out.emit("\(result) = call ptr @\(objects.unbox)(ptr \(box), i64 \(module.typeIndex(of: typeName) ?? -1), ptr \(nameArgument))")
                own(result, as: type)
                return (result, true)
            case .dictionary:
                out.emit("\(result) = call ptr @basic_rt_value_dictionary(ptr \(box), ptr \(nameArgument))")
                own(result, as: .dictionary)
                return (result, true)
            case .closure:
                out.emit("\(result) = call ptr @basic_rt_value_closure(ptr \(box), ptr \(nameArgument))")
                own(result, as: type)
                return (result, true)
            case .variant, .array, .system:
                return (box, false)
            }
        case .dictionaryGet(let dictionary, let key, let name):
            let (pointer, _) = lowerValue(dictionary)
            let (keyValue, _) = lowerValue(key)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_dictionary_get(ptr \(pointer), ptr \(boxedPointer(keyValue, key.type)), ptr \(constants.constant(name)))")
            own(result, as: .variant)
            return (result, true)
        case .valueIndex(let value, let indexes, let name):
            let (box, _) = lowerValue(value)
            let list = boxedIndexes(indexes)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_value_index(ptr \(box), i64 \(indexes.count), ptr \(list), ptr \(constants.constant(name)))")
            own(result, as: .variant)
            return (result, true)
        case .valueField(let value, let field, let name):
            let (box, _) = lowerValue(value)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_value_field(ptr \(box), ptr \(constants.constant(field)), ptr \(constants.constant(name)))")
            own(result, as: .variant)
            return (result, true)
        case .valueAdd(let left, let right):
            let l = lowerValue(left).0
            let r = lowerValue(right).0
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_value_add(ptr \(l), ptr \(r))")
            own(result, as: .variant)
            return (result, true)
        case .valueEqual(let left, let right):
            let l = lowerValue(left).0
            let r = lowerValue(right).0
            let flag = out.temp()
            out.emit("\(flag) = call i1 @basic_rt_value_equal(ptr \(l), ptr \(r))")
            let result = out.temp()
            out.emit("\(result) = uitofp i1 \(flag) to double")
            return (result, false)
        case .valueLen(let value):
            let (box, _) = lowerValue(value)
            let result = out.temp()
            out.emit("\(result) = call double @basic_rt_value_len(ptr \(box))")
            return (result, false)
        case .arrayLen(let array, let name):
            let (pointer, _) = lowerValue(array)
            let result = out.temp()
            out.emit("\(result) = call double @basic_rt_array_count(ptr \(pointer), ptr \(constants.constant(name)))")
            return (result, false)
        case .jsonEncode(let value, let pretty):
            let (box, _) = lowerValue(value)
            let flag = truthiness(of: pretty)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_json_encode(ptr \(box), i1 \(flag))")
            owned.append(result)
            return (result, true)
        case .jsonDecode(let source, let permissive):
            let (text, _) = lowerValue(source)
            let flag = truthiness(of: permissive)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_json_decode(ptr \(text), i1 \(flag))")
            own(result, as: .variant)
            return (result, true)
        case .emptyValue:
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_value_empty()")
            own(result, as: .variant)
            return (result, true)
        case .nullValue:
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_value_null()")
            own(result, as: .variant)
            return (result, true)
        case .newDictionary:
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_dictionary_new()")
            own(result, as: .dictionary)
            return (result, true)
        case .hostCall(let name, let arguments, let returns):
            let values = arguments.map { argument in "\(Self.llvmType(argument.type)) \(lowerValue(argument).0)" }
            if returns == .void {
                out.emit("call void @\(name)(\(values.joined(separator: ", ")))")
                return ("", false)
            }
            let result = out.temp()
            out.emit("\(result) = call \(Self.llvmType(returns)) @\(name)(\(values.joined(separator: ", ")))")
            if Self.isManaged(returns) { own(result, as: returns); return (result, true) }
            return (result, false)
        case .valueCall(let receiver, let method, let arguments, let name):
            let (value, _) = lowerValue(receiver)
            let list = boxedIndexes(arguments)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_value_call(ptr \(value), ptr \(constants.constant(method)), i64 \(arguments.count), ptr \(list), ptr \(constants.constant(name)))")
            own(result, as: .variant)
            return (result, true)
        case .asyncLaunch(let name, let arguments):
            let args = out.temp()
            out.emit("\(args) = call ptr @basic_rt_snapshot_new(i64 \(arguments.count))")
            for (index, argument) in arguments.enumerated() {
                let (value, _) = lowerValue(argument)
                let box = boxedPointer(value, argument.type)
                out.emit("call void @basic_rt_snapshot_set(ptr \(args), i64 \(index), ptr \(box))")
            }
            let displayName = name.split(separator: ".").last.map(String.init) ?? name
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_task_launch(ptr \(constants.constant(module.asyncDisplayName(of: name) ?? displayName)), ptr @\"A.\(name)\", ptr \(args))")
            out.emit("call void @basic_rt_snapshot_release(ptr \(args))")
            own(result, as: .variant)
            return (result, true)
        case .systemNew(let name, let arguments, _):
            let list = boxedIndexes(arguments)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_system_new(ptr \(constants.constant(name)), i64 \(arguments.count), ptr \(list))")
            own(result, as: .variant)
            return (result, true)
        case .systemCall(let receiver, let method, let arguments, let returns):
            let (box, _) = lowerValue(receiver)
            let list = boxedIndexes(arguments)
            let raw = out.temp()
            out.emit("\(raw) = call ptr @basic_rt_system_call(ptr \(box), ptr \(constants.constant(method)), i64 \(arguments.count), ptr \(list))")
            own(raw, as: .variant)
            let result = out.temp()
            switch returns {
            case .void:
                return ("", false)
            case .number:
                out.emit("\(result) = call double @basic_rt_value_number(ptr \(raw), ptr null)")
                return (result, false)
            case .string:
                out.emit("\(result) = call ptr @basic_rt_value_string(ptr \(raw), ptr null)")
                owned.append(result)
                return (result, true)
            case .boolean:
                out.emit("\(result) = call i1 @basic_rt_value_boolean(ptr \(raw), ptr null)")
                return (result, false)
            default:
                return (raw, false)
            }
        case .fileService(let method, let arguments, _):
            return lowerFileService(method, arguments)
        case .makeClosure(let functionName, let environment, let captures, _):
            var env = "null"
            if let environment, let type = module.types.first(where: { $0.name == environment }) {
                let created = out.temp()
                out.emit("\(created) = call ptr @basic_rt_composite_new(i64 \(type.index))")
                for (index, capture) in captures.enumerated() {
                    let (value, _) = lowerValue(capture)
                    switch capture.type {
                    case .number: out.emit("call void @basic_rt_composite_set_number(ptr \(created), i64 \(index), double \(value))")
                    case .boolean:
                        let number = out.temp()
                        out.emit("\(number) = uitofp i1 \(value) to double")
                        out.emit("call void @basic_rt_composite_set_number(ptr \(created), i64 \(index), double \(number))")
                    case .string: out.emit("call void @basic_rt_composite_set_string(ptr \(created), i64 \(index), ptr \(value))")
                    case .variant, .dictionary, .system:
                        out.emit("call void @basic_rt_composite_set_value(ptr \(created), i64 \(index), ptr \(boxedPointer(value, capture.type)), ptr \(constants.constant("capture")))")
                    default: out.emit("call void @basic_rt_composite_set_composite(ptr \(created), i64 \(index), ptr \(value))")
                    }
                }
                env = created
                owned.append(created)
                ownedComposites.insert(created)
            }
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_closure_new(ptr @\"F.\(functionName)\", ptr \(env))")
            owned.append(result)
            ownedClosures.insert(result)
            return (result, true)
        case .callClosure(let closure, let arguments, let returns):
            return lowerClosureCall(closure, arguments, returns)
        case .callMethod(let receiver, let candidates, let arguments, let returns):
            let result = lowerMethodCall(receiver, candidates, arguments)!
            if Self.isManaged(returns) {
                owned.append(result)
                if returns.isComposite { ownedComposites.insert(result) }
                if returns.isClosure { ownedClosures.insert(result) }
            }
            return (result, Self.isManaged(returns))
        case .usingString(let format, let values):
            out.emit("call void @basic_rt_using_begin(ptr \(lowerValue(format).0))")
            feedUsingValues(values)
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_using_render()")
            owned.append(result)
            return (result, true)
        case .constructWith(let name, let arguments):
            let values = arguments.map { (lowerValue($0).0, $0.type) }
            let result = out.temp()
            guard let symbol = objectModel.constructSymbol(for: name, arguments: arguments.map(\.type)) else {
                fail("CLASS \(name) cannot be constructed with arguments in this dialect")
                return ("null", false)
            }
            let list = values.map { "\(Self.llvmType($0.1)) \($0.0)" }.joined(separator: ", ")
            out.emit("\(result) = call ptr @\"\(symbol)\"(\(list))")
            owned.append(result)
            ownedComposites.insert(result)
            return (result, true)
        case .construct(let name):
            let result = out.temp()
            if let symbol = objectModel.newSymbol(for: name) {
                out.emit("\(result) = call ptr @\"\(symbol)\"()")
            } else {
                out.emit("\(result) = call ptr @basic_rt_composite_new(i64 \(module.typeIndex(of: name) ?? -1))")
            }
            owned.append(result)
            return (result, true)
        case .call(let name, let arguments, let returns):
            let values = arguments.map { lowerValue($0).0 }
            let callee = module.functions.first { $0.name == name }!
            let argumentList = zip(callee.parameters, values).map { "\(Self.llvmType(of: $0)) \($1)" }.joined(separator: ", ")
            let result = out.temp()
            out.emit("\(result) = call \(Self.llvmType(returns)) @\"F.\(name)\"(\(argumentList))")
            if Self.isManaged(returns) {
                owned.append(result)
                if returns.isComposite { ownedComposites.insert(result) }
                if returns.isClosure { ownedClosures.insert(result) }
                return (result, true)
            }
            return (result, false)
        case .negate(let inner):
            let result = out.temp()
            out.emit("\(result) = fneg double \(lowerValue(inner).0)")
            return (result, false)
        case .text(let inner):
            let (value, isOwned) = lowerValue(inner)
            switch inner.type {
            case .string:
                return (value, isOwned)
            case .number:
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_number_text(double \(value))")
                owned.append(result)
                return (result, true)
            case .composite:
                let result = out.temp()
                out.emit("\(result) = call ptr @\(objects.text)(ptr \(value))")
                owned.append(result)
                return (result, true)
            case .closure:
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_string_literal(ptr \(constants.constant("<FUNCTION>")), i64 10)")
                owned.append(result)
                return (result, true)
            case .variant, .dictionary, .array, .system:
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_value_text(ptr \(boxedPointer(value, inner.type)))")
                owned.append(result)
                return (result, true)
            case .boolean, .void:
                let text = out.temp()
                out.emit("\(text) = select i1 \(value), ptr \(constants.constant("TRUE")), ptr \(constants.constant("FALSE"))")
                let length = out.temp()
                out.emit("\(length) = select i1 \(value), i64 4, i64 5")
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_string_literal(ptr \(text), i64 \(length))")
                owned.append(result)
                return (result, true)
            }
        case .arithmetic(let op, let left, let right):
            let l = lowerValue(left).0
            let r = lowerValue(right).0
            let result = out.temp()
            switch op {
            case .add: out.emit("\(result) = fadd double \(l), \(r)")
            case .subtract: out.emit("\(result) = fsub double \(l), \(r)")
            case .multiply: out.emit("\(result) = fmul double \(l), \(r)")
            case .divide:
                let isZero = out.temp()
                let failLabel = out.freshLabel("div.zero")
                let okLabel = out.freshLabel("div.ok")
                out.emit("\(isZero) = fcmp oeq double \(r), 0.0")
                out.emit("br i1 \(isZero), label %\"\(failLabel)\", label %\"\(okLabel)\"")
                out.label(failLabel)
                out.emit("call void @basic_rt_fail(ptr \(constants.constant("Division by zero")))")
                out.emit("unreachable")
                out.label(okLabel)
                out.emit("\(result) = fdiv double \(l), \(r)")
            }
            return (result, false)
        case .concat(let left, let right):
            let l = lowerValue(left).0
            let r = lowerValue(right).0
            let result = out.temp()
            out.emit("\(result) = call ptr @basic_rt_string_concat(ptr \(l), ptr \(r))")
            owned.append(result)
            return (result, true)
        case .compare(let op, let left, let right):
            let flag = compareFlag(op, left, right)
            let result = out.temp()
            out.emit("\(result) = uitofp i1 \(flag) to double")
            return (result, false)
        case .logicalNot(let inner):
            let flag = out.temp()
            out.emit("\(flag) = xor i1 \(truthiness(of: inner)), true")
            let result = out.temp()
            out.emit("\(result) = uitofp i1 \(flag) to double")
            return (result, false)
        case .logical(let op, let left, let right):
            let l = truthiness(of: left)
            let r = truthiness(of: right)
            let flag = out.temp()
            switch op {
            case .and: out.emit("\(flag) = and i1 \(l), \(r)")
            case .or: out.emit("\(flag) = or i1 \(l), \(r)")
            case .xor: out.emit("\(flag) = xor i1 \(l), \(r)")
            case .eqv:
                // The sides agree: exclusive-or, inverted.
                let differ = out.temp()
                out.emit("\(differ) = xor i1 \(l), \(r)")
                out.emit("\(flag) = xor i1 \(differ), true")
            case .imp:
                // False only when the left holds and the right does not.
                let notLeft = out.temp()
                out.emit("\(notLeft) = xor i1 \(l), true")
                out.emit("\(flag) = or i1 \(notLeft), \(r)")
            }
            let result = out.temp()
            out.emit("\(result) = uitofp i1 \(flag) to double")
            return (result, false)
        default:
            return ("", false)
        }
    }

    /// Calls a closure value: its body with its environment first.
    private mutating func lowerClosureCall(_ closure: BIRExpression, _ arguments: [BIRExpression], _ returns: BIRType) -> (String, owned: Bool) {
        let (value, _) = lowerValue(closure)
        let function = out.temp(), environment = out.temp()
        out.emit("\(function) = call ptr @basic_rt_closure_function(ptr \(value))")
        out.emit("\(environment) = call ptr @basic_rt_closure_environment(ptr \(value))")
        let values = arguments.map { argument in "\(Self.llvmType(argument.type)) \(lowerValue(argument).0)" }
        let argumentList = (["ptr \(environment)"] + values).joined(separator: ", ")
        if returns == .void {
            out.emit("call void \(function)(\(argumentList))")
            return ("", false)
        }
        let result = out.temp()
        out.emit("\(result) = call \(Self.llvmType(returns)) \(function)(\(argumentList))")
        if Self.isManaged(returns) {
            owned.append(result)
            if returns.isComposite { ownedComposites.insert(result) }
            if returns.isClosure { ownedClosures.insert(result) }
            return (result, true)
        }
        return (result, false)
    }

    /// Calls one `File.*` runtime entry; strings come back owned.
    private mutating func lowerFileService(_ method: String, _ arguments: [BIRExpression]) -> (String, owned: Bool) {
        let values = arguments.map { lowerValue($0).0 }
        let a = values.first ?? "null"
        let result = out.temp()
        switch method {
        case "CWD":
            out.emit("\(result) = call ptr @basic_rt_file_cwd()")
            owned.append(result); return (result, true)
        case "READTEXT":
            out.emit("\(result) = call ptr @basic_rt_file_read_text(ptr \(a))")
            owned.append(result); return (result, true)
        case "EXISTS":
            out.emit("\(result) = call i1 @basic_rt_file_exists(ptr \(a))"); return (result, false)
        case "ISDIR":
            out.emit("\(result) = call i1 @basic_rt_file_isdir(ptr \(a))"); return (result, false)
        case "CHDIR": out.emit("call void @basic_rt_file_chdir(ptr \(a))")
        case "MKDIR": out.emit("call void @basic_rt_file_mkdir(ptr \(a))")
        case "RM": out.emit("call void @basic_rt_file_rm(ptr \(a))")
        case "RENAME": out.emit("call void @basic_rt_file_rename(ptr \(values[0]), ptr \(values[1]))")
        case "WRITETEXT": out.emit("call void @basic_rt_file_write_text(ptr \(values[0]), ptr \(values[1]))")
        case "READBYTES":
            out.emit("\(result) = call ptr @basic_rt_file_read_bytes(ptr \(a))")
            owned.append(result); return (result, true)
        case "WRITEBYTES": out.emit("call void @basic_rt_file_write_bytes(ptr \(values[0]), ptr \(values[1]))")
        case "APPENDBYTES": out.emit("call void @basic_rt_file_append_bytes(ptr \(values[0]), ptr \(values[1]))")
        case "READJSON":
            let permissive = truthiness(of: arguments[1])
            out.emit("\(result) = call ptr @basic_rt_file_read_json(ptr \(a), i1 \(permissive))")
            own(result, as: .variant); return (result, true)
        case "WRITEJSON":
            let box = boxedPointer(values[1], arguments[1].type)
            let pretty = truthiness(of: arguments[2])
            out.emit("call void @basic_rt_file_write_json(ptr \(values[0]), ptr \(box), i1 \(pretty))")
        case "FILES":
            out.emit("\(result) = call ptr @basic_rt_file_files(ptr \(values.first ?? "null"))")
            own(result, as: .variant); return (result, true)
        default: break
        }
        return ("", false)
    }

    /// An `i1` for a comparison of two operands of the same type.
    private mutating func compareFlag(_ op: BIRComparison, _ left: BIRExpression, _ right: BIRExpression) -> String {
        let l = lowerValue(left).0
        let r = lowerValue(right).0
        let flag = out.temp()
        switch left.type {
        case .number:
            // `une` for not-equal so NaN <> NaN is true, as Swift's != is.
            let predicate = ["equal": "oeq", "notEqual": "une", "less": "olt", "lessEqual": "ole", "greater": "ogt", "greaterEqual": "oge"][op.rawValue]!
            out.emit("\(flag) = fcmp \(predicate) double \(l), \(r)")
        case .boolean:
            out.emit("\(flag) = icmp \(op == .equal ? "eq" : "ne") i1 \(l), \(r)")
        case .composite, .closure:
            out.emit("\(flag) = icmp eq ptr \(l), \(r)")
        case .variant, .dictionary, .array, .system:
            let equal = out.temp()
            out.emit("\(equal) = call i1 @basic_rt_value_equal(ptr \(boxedPointer(l, left.type)), ptr \(boxedPointer(r, right.type)))")
            out.emit("\(flag) = \(op == .equal ? "and i1 \(equal), true" : "xor i1 \(equal), true")")
        case .string, .void:
            switch op {
            case .equal:
                out.emit("\(flag) = call i1 @basic_rt_string_equal(ptr \(l), ptr \(r))")
            case .notEqual:
                let equal = out.temp()
                out.emit("\(equal) = call i1 @basic_rt_string_equal(ptr \(l), ptr \(r))")
                out.emit("\(flag) = xor i1 \(equal), true")
            case .less:
                out.emit("\(flag) = call i1 @basic_rt_string_less(ptr \(l), ptr \(r))")
            case .greater:
                out.emit("\(flag) = call i1 @basic_rt_string_less(ptr \(r), ptr \(l))")
            case .lessEqual:
                let greater = out.temp()
                out.emit("\(greater) = call i1 @basic_rt_string_less(ptr \(r), ptr \(l))")
                out.emit("\(flag) = xor i1 \(greater), true")
            case .greaterEqual:
                let less = out.temp()
                out.emit("\(less) = call i1 @basic_rt_string_less(ptr \(l), ptr \(r))")
                out.emit("\(flag) = xor i1 \(less), true")
            }
        }
        return flag
    }

    /// The interpreter's `truthy` as an `i1`.
    private mutating func truthiness(of expression: BIRExpression) -> String {
        let (value, _) = lowerValue(expression)
        switch expression.type {
        case .boolean:
            return value
        case .number:
            let flag = out.temp()
            out.emit("\(flag) = fcmp une double \(value), 0.0")
            return flag
        case .string, .void:
            let flag = out.temp()
            out.emit("\(flag) = call i1 @basic_rt_string_truthy(ptr \(value))")
            return flag
        case .composite, .closure, .dictionary, .array, .system:
            return "true"
        case .variant:
            let flag = out.temp()
            out.emit("\(flag) = call i1 @basic_rt_value_truthy(ptr \(value))")
            return flag
        }
    }

    private mutating func lowerIntrinsic(_ intrinsic: BIRIntrinsic, _ arguments: [BIRExpression]) -> (String, owned: Bool) {
        let values = arguments.map { lowerValue($0).0 }
        let result = out.temp()
        func number(_ text: String) -> (String, owned: Bool) { out.emit("\(result) = \(text)"); return (result, false) }
        func string(_ text: String) -> (String, owned: Bool) { out.emit("\(result) = \(text)"); owned.append(result); return (result, true) }
        let a = values.first ?? ""
        switch intrinsic {
        case .abs: return number("call double @llvm.fabs.f64(double \(a))")
        case .int: return number("call double @llvm.floor.f64(double \(a))")
        case .fix: return number("call double @llvm.trunc.f64(double \(a))")
        case .cint: return number("call double @llvm.round.f64(double \(a))")
        case .sqr: return number("call double @llvm.sqrt.f64(double \(a))")
        case .sin: return number("call double @llvm.sin.f64(double \(a))")
        case .cos: return number("call double @llvm.cos.f64(double \(a))")
        case .exp: return number("call double @llvm.exp.f64(double \(a))")
        case .log: return number("call double @llvm.log.f64(double \(a))")
        case .tan: return number("call double @tan(double \(a))")
        case .atn: return number("call double @atan(double \(a))")
        case .sgn:
            let negative = out.temp(), positive = out.temp(), partial = out.temp()
            out.emit("\(negative) = fcmp olt double \(a), 0.0")
            out.emit("\(positive) = fcmp ogt double \(a), 0.0")
            out.emit("\(partial) = select i1 \(positive), double 1.0, double 0.0")
            return number("select i1 \(negative), double -1.0, double \(partial)")
        case .rnd: return number("call double @basic_rt_rnd()")
        case .err: return number("call double @basic_rt_err()")
        case .erl: return number("call double @basic_rt_erl()")
        case .lof: return number("call double @basic_rt_file_lof(double \(a))")
        case .fileExists: return number("call double @basic_rt_file_exists_number(ptr \(a))")
        case .date: return string("call ptr @basic_rt_date()")
        case .inputChars: return string("call ptr @basic_rt_input_chars(double \(a))")
        case .time: return string("call ptr @basic_rt_time()")
        case .loc: return number("call double @basic_rt_file_loc(double \(a))")
        case .eof:
            out.emit("\(result) = call i1 @basic_rt_file_eof(double \(a))")
            return (result, false)
        case .len: return number("call double @basic_rt_string_length(ptr \(a))")
        case .asc: return number("call double @basic_rt_string_asc(ptr \(a))")
        case .val: return number("call double @basic_rt_string_val(ptr \(a))")
        case .instr: return number("call double @basic_rt_string_instr(double \(values[0]), ptr \(values[1]), ptr \(values[2]))")
        case .str: return string("call ptr @basic_rt_number_str(double \(a))")
        case .chr: return string("call ptr @basic_rt_chr(double \(a))")
        case .left: return string("call ptr @basic_rt_string_left(ptr \(values[0]), double \(values[1]))")
        case .right: return string("call ptr @basic_rt_string_right(ptr \(values[0]), double \(values[1]))")
        case .mid: return string("call ptr @basic_rt_string_mid(ptr \(values[0]), double \(values[1]), double \(values[2]))")
        case .space: return string("call ptr @basic_rt_space(double \(a))")
        case .stringRepeat: return string("call ptr @basic_rt_string_repeat(double \(values[0]), ptr \(values[1]))")
        }
    }

    // MARK: - Names and types

    private func slotName(_ variable: BIRVariable) -> String {
        switch variable.scope {
        case .global: return "@\"G.\(variable.name)\""
        case .local: return "%\"L.\(variable.name)\""
        }
    }

    /// The LLVM type of a variable's slot: arrays are runtime pointers.
    static func llvmType(of variable: BIRVariable) -> String {
        variable.rank == nil ? llvmType(variable.type) : "ptr"
    }

    static func zero(of variable: BIRVariable) -> String {
        variable.rank == nil ? zero(variable.type) : "null"
    }

    static func llvmType(_ type: BIRType) -> String {
        switch type {
        case .number: return "double"
        case .string, .composite, .closure, .variant, .dictionary, .array, .system: return "ptr"
        case .boolean: return "i1"
        case .void: return "void"
        }
    }

    static func zero(_ type: BIRType) -> String {
        switch type {
        case .number: return "0.0"
        case .string, .composite, .closure, .variant, .dictionary, .array, .system: return "null"
        case .boolean: return "false"
        case .void: return ""
        }
    }

    /// A double literal LLVM will accept: hexadecimal bit pattern, so every
    /// value round-trips exactly.
    static func double(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(format: "0x%016llX", value.bitPattern)
    }
}
