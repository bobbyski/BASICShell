import Foundation

// The LLVM IR basicc's traditional dialect emits, read back.
//
// Not a general LLVM parser: the subset `LLVMLowering` writes, which is small
// on purpose — about twenty instructions, scalar types, constant arrays and
// byte strings. Anything outside it is an error naming the line, never a
// guess, so a new instruction in the lowering shows up here as a clear
// failure rather than as a wrong program.

/// An IR type.
indirect enum IRType: Hashable, CustomStringConvertible {
    case void
    case int(Int)          // i1, i8, i32, i64
    case double
    case pointer
    case array(Int, IRType)

    /// Bytes in memory, as the native runtime lays them out.
    var size: Int {
        switch self {
        case .void: return 0
        case .int(let bits): return max(1, bits / 8)
        case .double, .pointer: return 8
        case .array(let count, let element): return count * element.size
        }
    }

    var alignment: Int {
        switch self {
        case .array(_, let element): return element.alignment
        default: return max(1, size)
        }
    }

    var description: String {
        switch self {
        case .void: return "void"
        case .int(let bits): return "i\(bits)"
        case .double: return "double"
        case .pointer: return "ptr"
        case .array(let count, let element): return "[\(count) x \(element)]"
        }
    }
}

/// An operand.
enum IRValue: Hashable {
    case register(String)
    case global(String)
    case integer(Int64)
    case float(Double)
    case null
}

/// One instruction, with its result register when it has one.
struct IRInstruction {
    var result: String?
    var kind: Kind
    var line: String

    enum Kind {
        case call(returns: IRType, callee: IRValue, arguments: [(IRType, IRValue)])
        case store(IRType, IRValue, address: IRValue)
        case load(IRType, address: IRValue)
        case alloca(IRType)
        case elementPointer(base: IRType, address: IRValue, indexes: [Int64])
        case floatCompare(String, IRValue, IRValue)
        case intCompare(String, IRType, IRValue, IRValue)
        case binary(String, IRType, IRValue, IRValue)
        case floatNegate(IRValue)
        case convert(String, from: IRType, IRValue, to: IRType)
        case select(IRValue, IRType, IRValue, IRValue)
        case phi(IRType, [(IRValue, String)])
        case branch(String)
        case conditionalBranch(IRValue, String, String)
        case switchOn(IRType, IRValue, defaultLabel: String, cases: [(Int64, String)])
        case returnValue(IRType, IRValue?)
        case unreachable
    }

    /// The result's type, when there is a result.
    var resultType: IRType? {
        switch kind {
        case .call(let type, _, _): return type == .void ? nil : type
        case .load(let type, _): return type
        case .alloca, .elementPointer: return .pointer
        case .floatCompare, .intCompare: return .int(1)
        case .binary(_, let type, _, _): return type
        case .floatNegate: return .double
        case .convert(_, _, _, let type): return type
        case .select(_, let type, _, _): return type
        case .phi(let type, _): return type
        default: return nil
        }
    }
}

struct IRBlock {
    var label: String
    var instructions: [IRInstruction]
}

struct IRFunction {
    var name: String
    var returns: IRType
    var parameters: [(IRType, String)]
    var blocks: [IRBlock]
}

struct IRDeclaration {
    var name: String
    var returns: IRType
    var parameters: [IRType]
}

/// A global's initial contents.
enum IRInitializer {
    case zero
    case bytes([UInt8])
    case scalar(IRValue)
    case array([IRValue])
}

struct IRGlobal {
    var name: String
    var type: IRType
    var initializer: IRInitializer
    var isConstant: Bool
}

struct IRModule {
    var globals: [IRGlobal] = []
    var declarations: [IRDeclaration] = []
    var functions: [IRFunction] = []
}

/// What went wrong reading IR, and where.
public struct IRParseError: Error, CustomStringConvertible {
    public let message: String
    public let line: String
    public var description: String { "\(message): \(line)" }
}

// MARK: - Tokens

private enum Token: Equatable {
    case word(String)
    case local(String)
    case global(String)
    case number(String)
    case bytes([UInt8])
    case punct(Character)
}

private func tokenize(_ line: String) throws -> [Token] {
    var tokens: [Token] = []
    let chars = Array(line.unicodeScalars)
    var i = 0
    func isNameChar(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." || c == "$" || c == "-"
    }
    func name(after start: Int) throws -> (String, Int) {
        var j = start
        if j < chars.count, chars[j] == "\"" {
            j += 1
            var text = ""
            while j < chars.count, chars[j] != "\"" { text.unicodeScalars.append(chars[j]); j += 1 }
            guard j < chars.count else { throw IRParseError(message: "an unterminated name", line: line) }
            return (text, j + 1)
        }
        var text = ""
        while j < chars.count, isNameChar(chars[j]) { text.unicodeScalars.append(chars[j]); j += 1 }
        return (text, j)
    }
    while i < chars.count {
        let c = chars[i]
        if c == " " || c == "\t" { i += 1; continue }
        if c == ";" { break }
        if c == "%" {
            let (text, next) = try name(after: i + 1)
            tokens.append(.local(text)); i = next; continue
        }
        if c == "@" {
            let (text, next) = try name(after: i + 1)
            tokens.append(.global(text)); i = next; continue
        }
        if c == "c", i + 1 < chars.count, chars[i + 1] == "\"" {
            var j = i + 2
            var bytes: [UInt8] = []
            while j < chars.count, chars[j] != "\"" {
                if chars[j] == "\\", j + 2 < chars.count,
                   let value = UInt8(String(String.UnicodeScalarView([chars[j + 1], chars[j + 2]])), radix: 16) {
                    bytes.append(value); j += 3
                } else {
                    bytes.append(contentsOf: Array(String(chars[j]).utf8)); j += 1
                }
            }
            guard j < chars.count else { throw IRParseError(message: "an unterminated string", line: line) }
            tokens.append(.bytes(bytes)); i = j + 1; continue
        }
        if c == "-" || CharacterSet.decimalDigits.contains(c) {
            var j = i + 1
            while j < chars.count, CharacterSet.alphanumerics.contains(chars[j]) || chars[j] == "." || chars[j] == "+"
                || (chars[j] == "-" && (chars[j - 1] == "e" || chars[j - 1] == "E")) {
                j += 1
            }
            tokens.append(.number(String(String.UnicodeScalarView(chars[i..<j])))); i = j; continue
        }
        if CharacterSet.letters.contains(c) || c == "_" {
            var j = i
            var text = ""
            while j < chars.count, isNameChar(chars[j]) { text.unicodeScalars.append(chars[j]); j += 1 }
            tokens.append(.word(text)); i = j; continue
        }
        tokens.append(.punct(Character(c))); i += 1
    }
    return tokens
}

// MARK: - Parser

private struct Cursor {
    var tokens: [Token]
    var position = 0
    let line: String

    var atEnd: Bool { position >= tokens.count }
    var peek: Token? { atEnd ? nil : tokens[position] }

    mutating func next() throws -> Token {
        guard !atEnd else { throw IRParseError(message: "the line ended early", line: line) }
        defer { position += 1 }
        return tokens[position]
    }

    func error(_ message: String) -> IRParseError { IRParseError(message: message, line: line) }

    mutating func expect(_ punct: Character) throws {
        guard try next() == .punct(punct) else { throw error("expected '\(punct)'") }
    }

    mutating func expectWord(_ word: String) throws {
        guard try next() == .word(word) else { throw error("expected '\(word)'") }
    }

    mutating func skip(_ punct: Character) -> Bool {
        if peek == .punct(punct) { position += 1; return true }
        return false
    }

    mutating func skipWord(_ word: String) -> Bool {
        if peek == .word(word) { position += 1; return true }
        return false
    }

    mutating func word() throws -> String {
        guard case .word(let text) = try next() else { throw error("expected a word") }
        return text
    }

    mutating func type() throws -> IRType {
        let token = try next()
        switch token {
        case .word("void"): return .void
        case .word("double"): return .double
        case .word("ptr"): return .pointer
        case .word(let text) where text.hasPrefix("i") && Int(text.dropFirst()) != nil:
            return .int(Int(text.dropFirst())!)
        case .punct("["):
            guard case .number(let count) = try next(), let n = Int(count) else { throw error("expected an array length") }
            try expectWord("x")
            let element = try type()
            try expect("]")
            return .array(n, element)
        default:
            throw error("expected a type")
        }
    }

    mutating func value() throws -> IRValue {
        switch try next() {
        case .local(let name): return .register(name)
        case .global(let name): return .global(name)
        case .word("true"): return .integer(1)
        case .word("false"): return .integer(0)
        case .word("null"): return .null
        case .number(let text):
            if text.hasPrefix("0x") || text.hasPrefix("0X"), let bits = UInt64(text.dropFirst(2), radix: 16) {
                return .float(Double(bitPattern: bits))
            }
            if let integer = Int64(text) { return .integer(integer) }
            if let float = Double(text) { return .float(float) }
            throw error("a number LLVM would not write")
        default:
            throw error("expected a value")
        }
    }

    mutating func label() throws -> String {
        try expectWord("label")
        guard case .local(let name) = try next() else { throw error("expected a label") }
        return name
    }

    mutating func typedValue() throws -> (IRType, IRValue) {
        let type = try type()
        return (type, try value())
    }
}

enum IRParser {
    static func parse(_ text: String) throws -> IRModule {
        var module = IRModule()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("target ")
                || trimmed.hasPrefix("source_filename") || trimmed.hasPrefix("!") || trimmed.hasPrefix("attributes ") {
                continue
            }
            if trimmed.hasPrefix("@") {
                module.globals.append(try global(trimmed))
            } else if trimmed.hasPrefix("declare ") {
                // Debug info's own intrinsic: a debug build's (BASIC-46).
                if trimmed.contains("@llvm.dbg.") { continue }
                module.declarations.append(try declaration(trimmed))
            } else if trimmed.hasPrefix("define ") {
                var body: [String] = []
                while let bodyLine = lines.popFirst() {
                    if bodyLine.hasPrefix("}") { break }
                    body.append(bodyLine)
                }
                module.functions.append(try function(header: trimmed, body: body))
            } else {
                throw IRParseError(message: "a line the translator does not know", line: line)
            }
        }
        return module
    }

    private static func global(_ line: String) throws -> IRGlobal {
        var cursor = Cursor(tokens: try tokenize(line), line: line)
        guard case .global(let name) = try cursor.next() else { throw cursor.error("expected a global name") }
        try cursor.expect("=")
        while cursor.skipWord("private") || cursor.skipWord("internal") || cursor.skipWord("unnamed_addr") {}
        let isConstant: Bool
        if cursor.skipWord("constant") {
            isConstant = true
        } else {
            try cursor.expectWord("global")
            isConstant = false
        }
        let type = try cursor.type()
        let initializer: IRInitializer
        switch cursor.peek {
        case .bytes(let bytes)?:
            _ = try cursor.next()
            initializer = .bytes(bytes)
        case .punct("[")?:
            _ = try cursor.next()
            var values: [IRValue] = []
            if !cursor.skip("]") {
                repeat {
                    _ = try cursor.type()
                    values.append(try cursor.value())
                } while cursor.skip(",")
                try cursor.expect("]")
            }
            initializer = .array(values)
        case .word("zeroinitializer")?:
            _ = try cursor.next()
            initializer = .zero
        default:
            initializer = .scalar(try cursor.value())
        }
        return IRGlobal(name: name, type: type, initializer: initializer, isConstant: isConstant)
    }

    private static func declaration(_ line: String) throws -> IRDeclaration {
        var cursor = Cursor(tokens: try tokenize(line), line: line)
        try cursor.expectWord("declare")
        let returns = try cursor.type()
        guard case .global(let name) = try cursor.next() else { throw cursor.error("expected a function name") }
        try cursor.expect("(")
        var parameters: [IRType] = []
        if !cursor.skip(")") {
            repeat { parameters.append(try cursor.type()) } while cursor.skip(",")
            try cursor.expect(")")
        }
        return IRDeclaration(name: name, returns: returns, parameters: parameters)
    }

    private static func function(header: String, body: [String]) throws -> IRFunction {
        var cursor = Cursor(tokens: try tokenize(header), line: header)
        try cursor.expectWord("define")
        let returns = try cursor.type()
        guard case .global(let name) = try cursor.next() else { throw cursor.error("expected a function name") }
        try cursor.expect("(")
        var parameters: [(IRType, String)] = []
        if !cursor.skip(")") {
            repeat {
                let type = try cursor.type()
                guard case .local(let parameter) = try cursor.next() else { throw cursor.error("expected a parameter") }
                parameters.append((type, parameter))
            } while cursor.skip(",")
            try cursor.expect(")")
        }
        var blocks: [IRBlock] = []
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }
            // Where a variable lives, for a native debugger: a debug build's
            // metadata says the same, and the translator reads it there.
            if trimmed.contains("@llvm.dbg.declare(") { continue }
            if !line.hasPrefix(" "), trimmed.hasSuffix(":") {
                var label = String(trimmed.dropLast())
                if label.hasPrefix("\""), label.hasSuffix("\""), label.count >= 2 { label = String(label.dropFirst().dropLast()) }
                blocks.append(IRBlock(label: label, instructions: []))
                continue
            }
            if blocks.isEmpty { blocks.append(IRBlock(label: "entry", instructions: [])) }
            blocks[blocks.count - 1].instructions.append(try instruction(trimmed))
        }
        return IRFunction(name: name, returns: returns, parameters: parameters, blocks: blocks)
    }

    private static func instruction(_ line: String) throws -> IRInstruction {
        // Debug locations ride at the end; the translator has no use for them.
        let text = line.range(of: ", !dbg").map { String(line[..<$0.lowerBound]) } ?? line
        var cursor = Cursor(tokens: try tokenize(text), line: line)
        var result: String?
        if case .local(let name)? = cursor.peek, cursor.tokens.count > 1, cursor.tokens[1] == .punct("=") {
            result = name
            cursor.position = 2
        }
        let opcode = try cursor.word()
        let kind: IRInstruction.Kind
        switch opcode {
        case "call":
            _ = cursor.skipWord("tail")
            let returns = try cursor.type()
            let callee = try cursor.value()
            try cursor.expect("(")
            var arguments: [(IRType, IRValue)] = []
            if !cursor.skip(")") {
                repeat { arguments.append(try cursor.typedValue()) } while cursor.skip(",")
                try cursor.expect(")")
            }
            kind = .call(returns: returns, callee: callee, arguments: arguments)
        case "store":
            let (type, value) = try cursor.typedValue()
            try cursor.expect(",")
            _ = try cursor.type()
            kind = .store(type, value, address: try cursor.value())
        case "load":
            let type = try cursor.type()
            try cursor.expect(",")
            _ = try cursor.type()
            kind = .load(type, address: try cursor.value())
        case "alloca":
            kind = .alloca(try cursor.type())
        case "getelementptr":
            _ = cursor.skipWord("inbounds")
            let base = try cursor.type()
            try cursor.expect(",")
            _ = try cursor.type()
            let address = try cursor.value()
            var indexes: [Int64] = []
            while cursor.skip(",") {
                _ = try cursor.type()
                guard case .integer(let index) = try cursor.value() else {
                    throw cursor.error("a getelementptr index that is not a constant")
                }
                indexes.append(index)
            }
            kind = .elementPointer(base: base, address: address, indexes: indexes)
        case "fcmp":
            let predicate = try cursor.word()
            _ = try cursor.type()
            let left = try cursor.value()
            try cursor.expect(",")
            kind = .floatCompare(predicate, left, try cursor.value())
        case "icmp":
            let predicate = try cursor.word()
            let type = try cursor.type()
            let left = try cursor.value()
            try cursor.expect(",")
            kind = .intCompare(predicate, type, left, try cursor.value())
        case "fadd", "fsub", "fmul", "fdiv", "and", "or", "xor", "add", "sub", "mul":
            let type = try cursor.type()
            let left = try cursor.value()
            try cursor.expect(",")
            kind = .binary(opcode, type, left, try cursor.value())
        case "fneg":
            _ = try cursor.type()
            kind = .floatNegate(try cursor.value())
        case "uitofp", "sitofp", "fptosi", "fptoui", "trunc", "zext", "sext":
            let (from, value) = try cursor.typedValue()
            try cursor.expectWord("to")
            kind = .convert(opcode, from: from, value, to: try cursor.type())
        case "select":
            _ = try cursor.type()
            let condition = try cursor.value()
            try cursor.expect(",")
            let (type, first) = try cursor.typedValue()
            try cursor.expect(",")
            _ = try cursor.type()
            kind = .select(condition, type, first, try cursor.value())
        case "phi":
            let type = try cursor.type()
            var incoming: [(IRValue, String)] = []
            repeat {
                try cursor.expect("[")
                let value = try cursor.value()
                try cursor.expect(",")
                guard case .local(let label) = try cursor.next() else { throw cursor.error("expected a label") }
                try cursor.expect("]")
                incoming.append((value, label))
            } while cursor.skip(",")
            kind = .phi(type, incoming)
        case "br":
            if cursor.peek == .word("label") {
                kind = .branch(try cursor.label())
            } else {
                _ = try cursor.type()
                let condition = try cursor.value()
                try cursor.expect(",")
                let yes = try cursor.label()
                try cursor.expect(",")
                kind = .conditionalBranch(condition, yes, try cursor.label())
            }
        case "switch":
            let (type, value) = try cursor.typedValue()
            try cursor.expect(",")
            let fallback = try cursor.label()
            try cursor.expect("[")
            var cases: [(Int64, String)] = []
            while !cursor.skip("]") {
                _ = try cursor.type()
                guard case .integer(let match) = try cursor.value() else { throw cursor.error("expected a case value") }
                try cursor.expect(",")
                cases.append((match, try cursor.label()))
            }
            kind = .switchOn(type, value, defaultLabel: fallback, cases: cases)
        case "ret":
            let type = try cursor.type()
            kind = .returnValue(type, type == .void ? nil : try cursor.value())
        case "unreachable":
            kind = .unreachable
        default:
            throw cursor.error("an instruction the translator does not know (\(opcode))")
        }
        return IRInstruction(result: result, kind: kind, line: line)
    }
}
