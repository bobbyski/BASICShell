import Foundation

// The WebAssembly binary format, as much of it as the translator writes:
// LEB128 numbers, sections, function types, and a function body builder with
// one method per instruction used. Exception handling is the original
// proposal's `try`/`catch`, which JavaScriptCore has had since Safari 15.2.

/// A WebAssembly value type.
enum WasmValueType: UInt8, Hashable {
    case i32 = 0x7F
    case i64 = 0x7E
    case f64 = 0x7C
}

/// A function type: parameters, and zero or one result.
struct WasmFunctionType: Hashable {
    var parameters: [WasmValueType]
    var results: [WasmValueType]

    var encoded: [UInt8] {
        var out = WasmBuffer()
        out.byte(0x60)
        out.unsigned(UInt64(parameters.count))
        parameters.forEach { out.byte($0.rawValue) }
        out.unsigned(UInt64(results.count))
        results.forEach { out.byte($0.rawValue) }
        return out.bytes
    }
}

/// Bytes, appended to.
struct WasmBuffer {
    var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) { bytes.append(value) }
    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }

    mutating func unsigned(_ value: UInt64) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
    }

    mutating func signed(_ value: Int64) {
        var value = value
        while true {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            let signBit = byte & 0x40
            if (value == 0 && signBit == 0) || (value == -1 && signBit != 0) {
                bytes.append(byte)
                return
            }
            bytes.append(byte | 0x80)
        }
    }

    mutating func name(_ text: String) {
        let utf8 = Array(text.utf8)
        unsigned(UInt64(utf8.count))
        append(utf8)
    }

    mutating func float64(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// A vector: the count, then each item.
    mutating func vector(_ items: [[UInt8]]) {
        unsigned(UInt64(items.count))
        items.forEach { append($0) }
    }

    /// A section: its id, its size, its content.
    mutating func section(_ id: UInt8, _ content: [UInt8]) {
        guard !content.isEmpty else { return }
        byte(id)
        unsigned(UInt64(content.count))
        append(content)
    }
}

/// One function body, written instruction by instruction.
struct WasmCode {
    private(set) var buffer = WasmBuffer()

    // Control.
    mutating func unreachable() { buffer.byte(0x00) }
    mutating func block() { buffer.byte(0x02); buffer.byte(0x40) }
    mutating func loop() { buffer.byte(0x03); buffer.byte(0x40) }
    mutating func ifThen() { buffer.byte(0x04); buffer.byte(0x40) }
    mutating func elseBranch() { buffer.byte(0x05) }
    mutating func tryBlock() { buffer.byte(0x06); buffer.byte(0x40) }
    mutating func catchTag(_ tag: UInt32) { buffer.byte(0x07); buffer.unsigned(UInt64(tag)) }
    mutating func end() { buffer.byte(0x0B) }
    mutating func br(_ depth: Int) { buffer.byte(0x0C); buffer.unsigned(UInt64(depth)) }
    mutating func brIf(_ depth: Int) { buffer.byte(0x0D); buffer.unsigned(UInt64(depth)) }
    mutating func brTable(_ depths: [Int], default fallback: Int) {
        buffer.byte(0x0E)
        buffer.unsigned(UInt64(depths.count))
        depths.forEach { buffer.unsigned(UInt64($0)) }
        buffer.unsigned(UInt64(fallback))
    }
    mutating func returnFromFunction() { buffer.byte(0x0F) }
    mutating func call(_ function: UInt32) { buffer.byte(0x10); buffer.unsigned(UInt64(function)) }
    mutating func callIndirect(type: UInt32) {
        buffer.byte(0x11)
        buffer.unsigned(UInt64(type))
        buffer.byte(0x00)
    }
    mutating func drop() { buffer.byte(0x1A) }
    mutating func select() { buffer.byte(0x1B) }

    // Variables.
    mutating func localGet(_ index: UInt32) { buffer.byte(0x20); buffer.unsigned(UInt64(index)) }
    mutating func localSet(_ index: UInt32) { buffer.byte(0x21); buffer.unsigned(UInt64(index)) }
    mutating func localTee(_ index: UInt32) { buffer.byte(0x22); buffer.unsigned(UInt64(index)) }
    mutating func globalGet(_ index: UInt32) { buffer.byte(0x23); buffer.unsigned(UInt64(index)) }
    mutating func globalSet(_ index: UInt32) { buffer.byte(0x24); buffer.unsigned(UInt64(index)) }

    // Memory: alignment as a power of two, then the offset.
    private mutating func memory(_ opcode: UInt8, align: UInt32, offset: UInt32) {
        buffer.byte(opcode)
        buffer.unsigned(UInt64(align))
        buffer.unsigned(UInt64(offset))
    }
    mutating func i32Load(offset: UInt32 = 0) { memory(0x28, align: 2, offset: offset) }
    mutating func i64Load(offset: UInt32 = 0) { memory(0x29, align: 3, offset: offset) }
    mutating func f64Load(offset: UInt32 = 0) { memory(0x2B, align: 3, offset: offset) }
    mutating func i32Load8U(offset: UInt32 = 0) { memory(0x2D, align: 0, offset: offset) }
    mutating func i32Store(offset: UInt32 = 0) { memory(0x36, align: 2, offset: offset) }
    mutating func i64Store(offset: UInt32 = 0) { memory(0x37, align: 3, offset: offset) }
    mutating func f64Store(offset: UInt32 = 0) { memory(0x39, align: 3, offset: offset) }
    mutating func i32Store8(offset: UInt32 = 0) { memory(0x3A, align: 0, offset: offset) }

    // Constants.
    mutating func i32Const(_ value: Int32) { buffer.byte(0x41); buffer.signed(Int64(value)) }
    mutating func i64Const(_ value: Int64) { buffer.byte(0x42); buffer.signed(value) }
    mutating func f64Const(_ value: Double) { buffer.byte(0x44); buffer.float64(value) }

    /// Any opcode without immediates.
    mutating func op(_ opcode: UInt8) { buffer.byte(opcode) }
    /// A 0xFC-prefixed opcode (the saturating truncations).
    mutating func prefixed(_ opcode: UInt32) { buffer.byte(0xFC); buffer.unsigned(UInt64(opcode)) }

    var bytes: [UInt8] { buffer.bytes }
}

/// Opcodes without immediates, by name.
enum WasmOp {
    static let i32Eqz: UInt8 = 0x45, i32Eq: UInt8 = 0x46, i32Ne: UInt8 = 0x47
    static let i32LtS: UInt8 = 0x48, i32LtU: UInt8 = 0x49, i32GtS: UInt8 = 0x4A, i32GtU: UInt8 = 0x4B
    static let i32LeS: UInt8 = 0x4C, i32LeU: UInt8 = 0x4D, i32GeS: UInt8 = 0x4E, i32GeU: UInt8 = 0x4F
    static let i64Eqz: UInt8 = 0x50, i64Eq: UInt8 = 0x51, i64Ne: UInt8 = 0x52
    static let i64LtS: UInt8 = 0x53, i64LtU: UInt8 = 0x54, i64GtS: UInt8 = 0x55, i64GtU: UInt8 = 0x56
    static let i64LeS: UInt8 = 0x57, i64LeU: UInt8 = 0x58, i64GeS: UInt8 = 0x59, i64GeU: UInt8 = 0x5A
    static let f64Eq: UInt8 = 0x61, f64Ne: UInt8 = 0x62, f64Lt: UInt8 = 0x63, f64Gt: UInt8 = 0x64
    static let f64Le: UInt8 = 0x65, f64Ge: UInt8 = 0x66
    static let i32Add: UInt8 = 0x6A, i32Sub: UInt8 = 0x6B, i32Mul: UInt8 = 0x6C
    static let i32And: UInt8 = 0x71, i32Or: UInt8 = 0x72, i32Xor: UInt8 = 0x73
    static let i64Add: UInt8 = 0x7C, i64Sub: UInt8 = 0x7D, i64Mul: UInt8 = 0x7E
    static let i64And: UInt8 = 0x83, i64Or: UInt8 = 0x84, i64Xor: UInt8 = 0x85
    static let f64Abs: UInt8 = 0x99, f64Neg: UInt8 = 0x9A, f64Ceil: UInt8 = 0x9B, f64Floor: UInt8 = 0x9C
    static let f64Trunc: UInt8 = 0x9D, f64Nearest: UInt8 = 0x9E, f64Sqrt: UInt8 = 0x9F
    static let f64Add: UInt8 = 0xA0, f64Sub: UInt8 = 0xA1, f64Mul: UInt8 = 0xA2, f64Div: UInt8 = 0xA3
    static let f64Copysign: UInt8 = 0xA6
    static let i32WrapI64: UInt8 = 0xA7
    static let i64TruncF64S: UInt8 = 0xB0
    static let i64ExtendI32S: UInt8 = 0xAC, i64ExtendI32U: UInt8 = 0xAD
    static let f64ConvertI32S: UInt8 = 0xB7, f64ConvertI32U: UInt8 = 0xB8
    static let f64ConvertI64S: UInt8 = 0xB9, f64ConvertI64U: UInt8 = 0xBA
    /// 0xFC-prefixed.
    static let i64TruncSatF64S: UInt32 = 6, i64TruncSatF64U: UInt32 = 7
}
