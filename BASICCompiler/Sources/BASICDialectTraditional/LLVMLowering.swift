import BASICCompilerKit
import Foundation

/// Lowers a ``BIRModule`` to textual LLVM IR for the traditional dialect.
///
/// ```text
///   BIR globals   ─► @"G.NAME" = global double 0.0 | ptr null | i1 false
///   BIR locals    ─► %"L.NAME" = alloca ...            (in the entry block)
///   BIR blocks    ─► "b.<label>": ... terminator
///   expressions   ─► SSA temporaries; strings are runtime pointers
///   GOSUB/RETURN  ─► basic_rt_gosub_push / a switch over resume blocks
/// ```
///
/// String ownership: a runtime call that yields a string yields it owned
/// (+1); a variable load is borrowed. A store transfers an owned value or
/// retains a borrowed one, and releases the slot's previous value. Every
/// owned temporary left at the end of an instruction is released there.
struct LLVMLowering {
    private let module: BIRModule
    private let options: CompileOptions
    private var out = LLVMText()
    private var constants: [String] = []
    private var constantCount = 0
    /// Owned string temporaries produced by the current instruction.
    private var owned: [String] = []
    private var gosubResumes: [BIRBlockID] = []
    private var usesGosub = false

    init(module: BIRModule, options: CompileOptions) {
        self.module = module
        self.options = options
    }

    /// The whole module as `.ll` text.
    mutating func render() -> String {
        for block in module.main.blocks {
            if case .gosub(_, let resume) = block.terminator { gosubResumes.append(resume) }
            if case .returnFromGosub = block.terminator { usesGosub = true }
            if case .gosub = block.terminator { usesGosub = true }
        }
        lowerMain()

        var text = "; basicc — \(module.name), traditional dialect\n"
        text += "target triple = \"\(options.target.rawValue)\"\n\n"
        text += Self.runtimeDeclarations + "\n"
        for variable in module.globals {
            text += "@\"G.\(variable.name)\" = global \(llvmType(variable.type)) \(zero(variable.type))\n"
        }
        text += "\n" + constants.joined(separator: "\n") + "\n\n"
        text += "define i32 @main(i32 %argc, ptr %argv) {\n"
        text += out.lines.joined(separator: "\n") + "\n"
        text += "}\n"
        return text
    }

    // MARK: - Function

    private mutating func lowerMain() {
        out.label("prologue")
        for local in module.main.locals {
            out.emit("%\"L.\(local.name)\" = alloca \(llvmType(local.type))")
            out.emit("store \(llvmType(local.type)) \(zero(local.type)), ptr %\"L.\(local.name)\"")
        }
        out.emit("call void @basic_rt_start()")
        out.emit("br label %\"b.\(module.main.blocks[0].label)\"")

        for block in module.main.blocks {
            out.label("b.\(block.label)")
            for instruction in block.instructions {
                lower(instruction.operation)
                releaseOwned()
            }
            lower(block.terminator)
            releaseOwned()
        }

        if usesGosub {
            out.label("gosub.dispatch")
            let index = out.temp()
            out.emit("\(index) = call i64 @basic_rt_gosub_pop()")
            let cases = gosubResumes.enumerated()
                .map { "i64 \($0.offset), label %\"b.\(module.main.blocks[$0.element].label)\"" }
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
            let slot = slotName(variable)
            if variable.type == .string {
                if isOwned {
                    owned.removeAll { $0 == result }
                } else {
                    out.emit("call void @basic_rt_string_retain(ptr \(result))")
                }
                let old = out.temp()
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_string_release(ptr \(old))")
            }
            out.emit("store \(llvmType(variable.type)) \(result), ptr \(slot)")

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
            let name = constant(variable.name)
            let slot = slotName(variable)
            switch variable.type {
            case .number:
                let result = out.temp()
                out.emit("\(result) = call double @basic_rt_input_number(ptr \(promptValue), ptr \(name))")
                out.emit("store double \(result), ptr \(slot)")
            case .string:
                let result = out.temp()
                out.emit("\(result) = call ptr @basic_rt_input_string(ptr \(promptValue), ptr \(name))")
                let old = out.temp()
                out.emit("\(old) = load ptr, ptr \(slot)")
                out.emit("call void @basic_rt_string_release(ptr \(old))")
                out.emit("store ptr \(result), ptr \(slot)")
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

    /// Calls the runtime's failure path and opens a fresh block for whatever
    /// follows, since `unreachable` must end its block.
    private mutating func fail(_ message: String) {
        out.emit("call void @basic_rt_fail(ptr \(constant(message)))")
        out.emit("unreachable")
        out.label(out.freshLabel("fail.cont"))
    }

    private mutating func lower(_ terminator: BIRTerminator) {
        func label(_ id: BIRBlockID) -> String { "%\"b.\(module.main.blocks[id].label)\"" }
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
            out.emit("br label %\"gosub.dispatch\"")
        case .end:
            out.emit("call void @basic_rt_finish()")
            out.emit("ret i32 0")
        case .unterminated:
            out.emit("unreachable")
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
            let (name, count) = constant(value, returnCount: true)
            out.emit("\(result) = call ptr @basic_rt_string_literal(ptr \(name), i64 \(count - 1))")
            owned.append(result)
            return (result, true)
        case .load(let variable):
            let result = out.temp()
            out.emit("\(result) = load \(llvmType(variable.type)), ptr \(slotName(variable))")
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
                out.emit("call void @basic_rt_fail(ptr \(constant("Division by zero")))")
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

    // MARK: - Names and constants

    private func slotName(_ variable: BIRVariable) -> String {
        switch variable.scope {
        case .global: return "@\"G.\(variable.name)\""
        case .local: return "%\"L.\(variable.name)\""
        }
    }

    private func llvmType(_ type: BIRType) -> String {
        switch type {
        case .number: return "double"
        case .string: return "ptr"
        case .boolean: return "i1"
        case .void: return "void"
        }
    }

    private func zero(_ type: BIRType) -> String {
        switch type {
        case .number: return "0.0"
        case .string: return "null"
        case .boolean: return "false"
        case .void: return ""
        }
    }

    /// A private constant holding NUL-terminated text; returns its name.
    private mutating func constant(_ text: String) -> String {
        constant(text, returnCount: true).0
    }

    private mutating func constant(_ text: String, returnCount: Bool) -> (String, Int) {
        constantCount += 1
        let name = "@.str.\(constantCount)"
        let (body, count) = LLVMText.cString(text)
        constants.append("\(name) = private unnamed_addr constant [\(count) x i8] c\"\(body)\"")
        return (name, count)
    }

    /// A double literal LLVM will accept: hexadecimal bit pattern, so every
    /// value round-trips exactly.
    static func double(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(format: "0x%016llX", value.bitPattern)
    }

    static let runtimeDeclarations = """
    declare void @basic_rt_start()
    declare void @basic_rt_finish()
    declare void @basic_rt_fail(ptr)
    declare void @basic_rt_gosub_push(i64)
    declare i64 @basic_rt_gosub_pop()
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
