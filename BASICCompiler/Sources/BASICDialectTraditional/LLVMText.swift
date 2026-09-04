import Foundation

/// Accumulates one function's textual LLVM IR and hands out fresh names.
///
/// Labels and globals are always quoted (`%"b.if.then"`, `@"G.A$"`) so BASIC
/// names never need sanitizing.
struct LLVMText {
    private(set) var lines: [String] = []
    private var temporaries = 0
    private var labels = 0

    /// Appends one instruction, indented.
    mutating func emit(_ line: String) {
        lines.append("  " + line)
    }

    /// Appends a block label.
    mutating func label(_ name: String) {
        lines.append("\"\(name)\":")
    }

    /// A fresh `%tN`.
    mutating func temp() -> String {
        temporaries += 1
        return "%t\(temporaries)"
    }

    /// A fresh label name with the given stem, for blocks the lowering
    /// invents (division checks, fail continuations).
    mutating func freshLabel(_ stem: String) -> String {
        labels += 1
        return "\(stem).\(labels)"
    }

    /// Escapes text for a `c"..."` constant, NUL terminator included.
    static func cString(_ text: String) -> (body: String, byteCount: Int) {
        var body = ""
        var count = 0
        for byte in text.utf8 {
            count += 1
            if byte >= 0x20 && byte < 0x7f && byte != 0x22 && byte != 0x5c {
                body.append(Character(UnicodeScalar(byte)))
            } else {
                body += String(format: "\\%02X", byte)
            }
        }
        return (body + "\\00", count + 1)
    }
}
