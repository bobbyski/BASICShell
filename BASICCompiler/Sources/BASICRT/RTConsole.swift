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
        fputs(text, stdout)
        if let lastNewline = text.lastIndex(of: "\n") {
            column = text.distance(from: text.index(after: lastNewline), to: text.endIndex)
        } else {
            column += text.count
        }
    }
}

@_cdecl("basic_rt_print_text")
public func basic_rt_print_text(_ pointer: UnsafeMutableRawPointer?) {
    RTConsole.write(rtText(pointer))
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
    let spaces = RTConsole.zoneWidth - (RTConsole.column % RTConsole.zoneWidth)
    RTConsole.write(String(repeating: " ", count: spaces))
}

/// `TAB(n)` — pad to column n (1-based); nothing when already past it.
@_cdecl("basic_rt_print_tab")
public func basic_rt_print_tab(_ target: Double) {
    let targetColumn = max(0, Int(target.rounded()) - 1)
    RTConsole.write(String(repeating: " ", count: max(0, targetColumn - RTConsole.column)))
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
