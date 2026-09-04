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

    init(module: BIRModule, options: CompileOptions) {
        self.module = module
        self.options = options
    }

    /// The whole module as `.ll` text.
    func render() -> String {
        var functions: [String] = []
        var mainEmitter = FunctionEmitter(function: module.main, module: module, constants: constants, isMain: true)
        functions.append(mainEmitter.render())
        for function in module.functions {
            var emitter = FunctionEmitter(function: function, module: module, constants: constants, isMain: false)
            functions.append(emitter.render())
        }

        var text = "; basicc — \(module.name), traditional dialect\n"
        text += "target triple = \"\(options.target.rawValue)\"\n\n"
        text += Self.runtimeDeclarations + "\n\n"
        for variable in module.globals {
            text += "@\"G.\(variable.name)\" = global \(FunctionEmitter.llvmType(of: variable)) \(FunctionEmitter.zero(of: variable))\n"
        }
        text += "\n" + renderDataTables() + "\n"
        text += constants.definitions.joined(separator: "\n") + "\n\n"
        text += functions.joined(separator: "\n\n")
        return text
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

    static let runtimeDeclarations = """
    declare void @basic_rt_start()
    declare void @basic_rt_finish()
    declare void @basic_rt_fail(ptr)
    declare void @basic_rt_fail_type(ptr)
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
    declare ptr @basic_rt_array_dim(i64, ptr, i1)
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
    private var out = LLVMText()
    /// Owned string temporaries produced by the current instruction.
    private var owned: [String] = []
    private var gosubResumes: [BIRBlockID] = []
    private var usesGosub = false
    private var usesErrorHandling: Bool { isMain && !function.statementResumeBlocks.isEmpty }
    /// The largest number of indexes any DIM or element access uses.
    private var scratchRank = 1

    init(function: BIRFunction, module: BIRModule, constants: ConstantPool, isMain: Bool) {
        self.function = function
        self.module = module
        self.constants = constants
        self.isMain = isMain
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
        for local in function.locals {
            out.emit("%\"L.\(local.name)\" = alloca \(Self.llvmType(of: local))")
            out.emit("store \(Self.llvmType(of: local)) \(Self.zero(of: local)), ptr %\"L.\(local.name)\"")
        }
        for (index, parameter) in function.parameters.enumerated() {
            if parameter.type == .string {
                out.emit("call void @basic_rt_string_retain(ptr %p\(index))")
            }
            out.emit("store \(Self.llvmType(of: parameter)) %p\(index), ptr %\"L.\(parameter.name)\"")
        }
        if isMain {
            out.emit("call void @basic_rt_start()")
            out.emit("call void @basic_rt_data_register(i64 \(module.data.count), ptr @data.kinds, ptr @data.numbers, ptr @data.strings)")
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
            storeString(result, owned: isOwned, into: slotName(variable), isString: variable.type == .string)
            if variable.type != .string {
                out.emit("store \(Self.llvmType(of: variable)) \(result), ptr \(slotName(variable))")
            }

        case .storeElement(let variable, let indexes, let value):
            let (result, _) = lowerValue(value)
            let (array, offset) = elementOffset(variable, indexes)
            if variable.type == .string {
                out.emit("call void @basic_rt_array_store_string(ptr \(array), i64 \(offset), ptr \(result))")
            } else {
                out.emit("call void @basic_rt_array_store_number(ptr \(array), i64 \(offset), double \(result))")
            }

        case .dim(let variable, let bounds):
            let values = bounds.map { lowerValue($0).0 }
            for (index, value) in values.enumerated() {
                let slot = out.temp()
                out.emit("\(slot) = getelementptr [\(scratchRank) x double], ptr %\"scratch.indexes\", i64 0, i64 \(index)")
                out.emit("store double \(value), ptr \(slot)")
            }
            let array = out.temp()
            out.emit("\(array) = call ptr @basic_rt_array_dim(i64 \(values.count), ptr %\"scratch.indexes\", i1 \(variable.type == .string ? "true" : "false"))")
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
                if callee.returnType == .string { owned.append(result) }
            }

        case .read(let targets):
            for target in targets {
                switch target {
                case .variable(let variable):
                    let value = readValue(variable)
                    storeString(value, owned: true, into: slotName(variable), isString: variable.type == .string)
                    if variable.type != .string {
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

        case .input(let prompt, let variable):
            let promptValue = prompt.map { lowerValue($0).0 } ?? "null"
            let name = constants.constant(variable.name)
            switch variable.type {
            case .number:
                let result = out.temp()
                out.emit("\(result) = call double @basic_rt_input_number(ptr \(promptValue), ptr \(name))")
                out.emit("store double \(result), ptr \(slotName(variable))")
            case .string:
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_input_string(ptr \(promptValue), ptr \(name))")
                storeString(result, owned: true, into: slotName(variable), isString: true)
            case .boolean, .void:
                fail("INPUT into a boolean is not supported")
            }

        case .randomize(let seed):
            if let seed {
                out.emit("call void @basic_rt_randomize(double \(lowerValue(seed).0))")
            } else {
                out.emit("call void @basic_rt_randomize_time()")
            }

        case .fail(let message):
            fail(message)
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

    /// Stores a string into a slot with the ownership dance; a no-op for
    /// other types (the caller stores those).
    private mutating func storeString(_ value: String, owned isOwned: Bool, into slot: String, isString: Bool) {
        guard isString else { return }
        if isOwned {
            owned.removeAll { $0 == value }
        } else {
            out.emit("call void @basic_rt_string_retain(ptr \(value))")
        }
        let old = out.temp()
        out.emit("\(old) = load ptr, ptr \(slot)")
        out.emit("call void @basic_rt_string_release(ptr \(old))")
        out.emit("store ptr \(value), ptr \(slot)")
    }

    /// Loads the array pointer and computes the bounds-checked element offset.
    private mutating func elementOffset(_ variable: BIRVariable, _ indexes: [BIRExpression]) -> (array: String, offset: String) {
        let values = indexes.map { lowerValue($0).0 }
        for (index, value) in values.enumerated() {
            let slot = out.temp()
            out.emit("\(slot) = getelementptr [\(scratchRank) x double], ptr %\"scratch.indexes\", i64 0, i64 \(index)")
            out.emit("store double \(value), ptr \(slot)")
        }
        let array = out.temp()
        out.emit("\(array) = load ptr, ptr \(slotName(variable))")
        let offset = out.temp()
        out.emit("\(offset) = call i64 @basic_rt_array_offset(ptr \(array), ptr \(constants.constant(variable.name)), i64 \(values.count), ptr %\"scratch.indexes\")")
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
                }
                result = lowered
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
            out.emit("call void @basic_rt_string_release(ptr \(temporary))")
        }
        owned.removeAll()
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
            let result = out.temp()
            if variable.type == .string {
                out.emit("\(result) = call ptr @basic_rt_array_load_string(ptr \(array), i64 \(offset))")
                owned.append(result)
                return (result, true)
            }
            out.emit("\(result) = call double @basic_rt_array_load_number(ptr \(array), i64 \(offset))")
            return (result, false)
        case .call(let name, let arguments, let returns):
            let values = arguments.map { lowerValue($0).0 }
            let callee = module.functions.first { $0.name == name }!
            let argumentList = zip(callee.parameters, values).map { "\(Self.llvmType(of: $0)) \($1)" }.joined(separator: ", ")
            let result = out.temp()
            out.emit("\(result) = call \(Self.llvmType(returns)) @\"F.\(name)\"(\(argumentList))")
            if returns == .string { owned.append(result); return (result, true) }
            return (result, false)
        case .negate(let inner):
            let result = out.temp()
            out.emit("\(result) = fneg double \(lowerValue(inner).0)")
            return (result, false)
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
        case .logical(let op, let left, let right):
            let l = truthiness(of: left)
            let r = truthiness(of: right)
            let flag = out.temp()
            out.emit("\(flag) = \(op == .and ? "and" : "or") i1 \(l), \(r)")
            let result = out.temp()
            out.emit("\(result) = uitofp i1 \(flag) to double")
            return (result, false)
        case .intrinsic(let intrinsic, let arguments):
            return lowerIntrinsic(intrinsic, arguments)
        }
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
        case .string: return "ptr"
        case .boolean: return "i1"
        case .void: return "void"
        }
    }

    static func zero(_ type: BIRType) -> String {
        switch type {
        case .number: return "0.0"
        case .string: return "null"
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
