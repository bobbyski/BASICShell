import Foundation

// BASICRT console.
//
// `PRINT` is rendered item by item, and the runtime tracks the output column
// so `,` zones and `TAB` agree across statements the way the interpreter's
// `outputColumn` does. Output is buffered through stdio and flushed at exit
// and before any input.

/// Console state: the current output column.
enum RTConsole {
    /// The 14-column zone width `,` advances to.
    static let zoneWidth = 14
    nonisolated(unsafe) static var column = 0

    static func write(_ text: String) {
        if RTCapture.active {
            RTCapture.text += text
            if let lastNewline = text.lastIndex(of: "\n") {
                RTCapture.column = text.distance(from: text.index(after: lastNewline), to: text.endIndex)
            } else {
                RTCapture.column += text.count
            }
            return
        }
        fputs(text, stdout)
        if let lastNewline = text.lastIndex(of: "\n") {
            column = text.distance(from: text.index(after: lastNewline), to: text.endIndex)
        } else {
            column += text.count
        }
    }

    /// The column PRINT's `,` and TAB measure against: the capture's while
    /// rendering for a file, else the console's.
    static var effectiveColumn: Int { RTCapture.active ? RTCapture.column : column }
}

@_cdecl("basic_rt_print_text")
public func basic_rt_print_text(_ pointer: UnsafeMutableRawPointer?) {
    RTConsole.write(rtString(pointer).description)
}

@_cdecl("basic_rt_print_number")
public func basic_rt_print_number(_ value: Double) {
    RTConsole.write(rtNumberText(value))
}

@_cdecl("basic_rt_print_boolean")
public func basic_rt_print_boolean(_ value: Bool) {
    RTConsole.write(value ? "TRUE" : "FALSE")
}

/// `,` — pad to the next zone.
@_cdecl("basic_rt_print_comma")
public func basic_rt_print_comma() {
    let spaces = RTConsole.zoneWidth - (RTConsole.effectiveColumn % RTConsole.zoneWidth)
    RTConsole.write(String(repeating: " ", count: spaces))
}

/// `TAB(n)` — pad to column n (1-based); nothing when already past it.
@_cdecl("basic_rt_print_tab")
public func basic_rt_print_tab(_ target: Double) {
    let targetColumn = max(0, Int(target.rounded()) - 1)
    RTConsole.write(String(repeating: " ", count: max(0, targetColumn - RTConsole.effectiveColumn)))
}

/// `SPC(n)` — n spaces.
@_cdecl("basic_rt_print_spc")
public func basic_rt_print_spc(_ count: Double) {
    RTConsole.write(String(repeating: " ", count: max(0, Int(count.rounded()))))
}

@_cdecl("basic_rt_print_newline")
public func basic_rt_print_newline() {
    RTConsole.write("\n")
}

/// Shows the prompt and reads one line; nil at end of input.
private func readInputLine(prompt: UnsafeMutableRawPointer?, defaultPrompt: String) -> String? {
    RTConsole.write(prompt.map(rtText) ?? defaultPrompt)
    fflush(stdout)
    guard let line = readLine(strippingNewline: true) else { return nil }
    RTConsole.column = 0
    return line
}

/// `INPUT` into a numeric variable. `name` is the variable's name, for the
/// default prompt and the error.
@_cdecl("basic_rt_input_number")
public func basic_rt_input_number(_ prompt: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> Double {
    let variable = String(cString: name)
    let raw = readInputLine(prompt: prompt, defaultPrompt: "\(variable)? ") ?? ""
    guard let number = Double(raw.trimmingCharacters(in: .whitespaces)) else {
        basic_rt_fail("Expected numeric input for \(variable)")
    }
    return number
}

/// The interpreter's reading of a boolean from input text.
func rtParseBoolean(_ raw: String) -> Bool {
    switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
    case "TRUE", "1": return true
    case "FALSE", "0": return false
    default: basic_rt_fail("Type Mismatch")
    }
}

/// `INPUT` into a boolean variable.
@_cdecl("basic_rt_input_boolean")
public func basic_rt_input_boolean(_ prompt: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> Bool {
    let raw = readInputLine(prompt: prompt, defaultPrompt: "\(String(cString: name))? ") ?? ""
    return rtParseBoolean(raw)
}

/// `INPUT` into a string variable.
@_cdecl("basic_rt_input_string")
public func basic_rt_input_string(_ prompt: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let raw = readInputLine(prompt: prompt, defaultPrompt: "\(String(cString: name))? ") ?? ""
    return rtOwned(raw)
}

/// `LINE INPUT`: the prompt verbatim (default none), then the whole line.
@_cdecl("basic_rt_line_input")
public func basic_rt_line_input(_ prompt: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let raw = readInputLine(prompt: prompt, defaultPrompt: "") ?? ""
    RTConsole.column = 0
    return rtOwned(raw)
}

/// `CLS`: the ANSI clear the interpreter prints, then column 0.
@_cdecl("basic_rt_cls")
public func basic_rt_cls() {
    RTConsole.write("\u{001B}[2J\u{001B}[H\n")
    RTConsole.column = 0
}

/// Renders PRINT items into a string instead of the console, for PRINT #.
/// The compiler brackets the items with begin/end and the runtime collects.
enum RTCapture {
    nonisolated(unsafe) static var active = false
    nonisolated(unsafe) static var text = ""
    nonisolated(unsafe) static var column = 0
}

@_cdecl("basic_rt_capture_begin")
public func basic_rt_capture_begin() {
    RTCapture.active = true
    RTCapture.text = ""
    RTCapture.column = 0
}

/// Ends a capture and returns the text, owned.
@_cdecl("basic_rt_capture_end")
public func basic_rt_capture_end() -> UnsafeMutableRawPointer {
    RTCapture.active = false
    return rtOwned(RTCapture.text)
}

/// `INPUT$(n)`: the next n keys typed, without echo — the interpreter's
/// blocking keyboard read. Its keyboard host reads nothing when standard
/// input is not a terminal, and neither does this.
@_cdecl("basic_rt_input_chars")
public func basic_rt_input_chars(_ countValue: Double) -> UnsafeMutableRawPointer {
    let count = max(0, Int(countValue.rounded()))
    fflush(stdout)
    var original = termios()
    guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else { return rtOwned("") }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    var bytes: [UInt8] = []
    while bytes.count < count {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { break }
        bytes.append(byte)
    }
    return rtOwned(String(decoding: bytes, as: UTF8.self))
}
