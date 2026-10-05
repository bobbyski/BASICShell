import Foundation

// BASICRT error handling — ON ERROR GOTO, ERR, ERL, RESUME NEXT.
//
// The compiled program marks each statement of the program body (`ERL`, and
// where RESUME NEXT continues) and installs a jump buffer in main. When a
// runtime error fires with a handler set, the runtime longjmps to main's
// dispatch, which enters the handler block. The rules are the interpreter's:
// one handler active at a time; an error while handling is fatal; RESUME
// NEXT continues after the statement that failed, even when the failure
// happened inside a called function.

@_silgen_name("longjmp")
private func rt_longjmp(_ env: UnsafeMutableRawPointer, _ value: Int32) -> Never

enum RTError {
    nonisolated(unsafe) static var jumpBuffer: UnsafeMutableRawPointer?
    /// Handler index, or -1 for none (`ON ERROR GOTO 0`).
    nonisolated(unsafe) static var handler = -1
    nonisolated(unsafe) static var isHandling = false
    /// The statement being executed, and its display line.
    nonisolated(unsafe) static var statement = 0
    nonisolated(unsafe) static var line = 0
    nonisolated(unsafe) static var lastNumber = 0
    nonisolated(unsafe) static var lastLine = 0
    /// The statement that failed — captured at the fault, because the
    /// handler's own statements keep updating `statement`.
    nonisolated(unsafe) static var faultStatement = 0

    /// The interpreter's error-number table.
    static func number(for message: String, isTypeError: Bool) -> Int {
        if isTypeError { return 13 }
        if message.localizedCaseInsensitiveContains("division by zero") { return 11 }
        if message.localizedCaseInsensitiveContains("type mismatch") { return 13 }
        if message == "Overflow" { return 6 }
        return 5
    }

    /// Records the error and, when a handler can take it, jumps there.
    /// `prefix` nil prints the message bare (the interpreter's "Missing line").
    static func raise(number: Int, message: String, prefix: String?) -> Never {
        // Inside an async body, a failure is the task's, not the program's.
        if let boundary = RTTasks.boundaries.last {
            RTTasks.boundaryError = (prefix.map { "\($0): " } ?? "") + message
            RTTasks.boundaryNumber = number
            rt_longjmp(boundary, 1)
        }
        lastNumber = number
        // ERL is the statement that failed, inside whatever function: the
        // interpreter's, since BASIC-9.
        let here = RTLocations.current()
        lastLine = here?.line ?? line
        if let jumpBuffer, handler >= 0, !isHandling {
            isHandling = true
            faultStatement = statement
            rt_longjmp(jumpBuffer, 1)
        }
        // A program that dies mid-draw owes the terminal the same tidy-up
        // as one that reaches END, or the message is printed under a canvas
        // that is still there.
        RTGraphics.finish()
        fflush(stdout)
        let text = (prefix.map { "\($0): " } ?? "") + message
        if prefix != nil, let here {
            // The interpreter's BASICError.located: the statement's line, a
            // caret under where it starts, and the message with its line.
            let marker = String(here.source.prefix(max(0, here.column)).map { $0 == "\t" ? "\t" : " " }) + "^"
            fputs("\(here.source)\n\(marker)\n\(text) at \(here.line)\n", stdout)
        } else {
            fputs(text + "\n", stdout)
        }
        fflush(stdout)
        exit(1)
    }
}

/// The program's statement table, from `main`: where `@"basic.here"` says
/// the program is, and each statement's line, column and source text.
enum RTLocations {
    nonisolated(unsafe) static var here: UnsafeMutablePointer<Int64>?
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var lines: UnsafePointer<Int64>?
    nonisolated(unsafe) static var columns: UnsafePointer<Int64>?
    nonisolated(unsafe) static var sources: UnsafePointer<UnsafePointer<CChar>?>?

    /// Where the program is: saved around a task body, which a failure
    /// leaves by a jump that skips the restore every return does.
    static var position: Int64 {
        get { here?.pointee ?? -1 }
        set { here?.pointee = newValue }
    }

    /// The statement running now, or nil before the first one.
    static func current() -> (line: Int, column: Int, source: String)? {
        guard let here, let lines, let columns, let sources else { return nil }
        let index = Int(here.pointee)
        guard index >= 0, index < count, let text = sources[index] else { return nil }
        return (Int(lines[index]), Int(columns[index]), String(cString: text))
    }
}

@_cdecl("basic_rt_locations")
public func basic_rt_locations(_ here: UnsafeMutablePointer<Int64>, _ count: Int, _ lines: UnsafePointer<Int64>, _ columns: UnsafePointer<Int64>, _ sources: UnsafePointer<UnsafePointer<CChar>?>) {
    RTLocations.here = here
    RTLocations.count = count
    RTLocations.lines = lines
    RTLocations.columns = columns
    RTLocations.sources = sources
}

@_cdecl("basic_rt_error_install")
public func basic_rt_error_install(_ jumpBuffer: UnsafeMutableRawPointer) {
    RTError.jumpBuffer = jumpBuffer
}

@_cdecl("basic_rt_statement")
public func basic_rt_statement(_ id: Int, _ line: Int) {
    RTError.statement = id
    RTError.line = line
}

/// `ON ERROR GOTO`: handler index, or -1 to disable. Entering a new handler
/// also ends any handling in progress, as the interpreter does.
@_cdecl("basic_rt_on_error")
public func basic_rt_on_error(_ handler: Int) {
    RTError.handler = handler
    RTError.isHandling = false
}

/// `ERROR n`.
@_cdecl("basic_rt_raise")
public func basic_rt_raise(_ number: Double) -> Never {
    let code = Int(number.rounded())
    RTError.raise(number: code, message: "Error \(code)", prefix: "Runtime error")
}

/// The handler to enter after a longjmp.
@_cdecl("basic_rt_error_handler")
public func basic_rt_error_handler() -> Int {
    RTError.handler
}

/// `RESUME NEXT`: the statement to continue at.
@_cdecl("basic_rt_resume_next")
public func basic_rt_resume_next() -> Int {
    guard RTError.isHandling else {
        basic_rt_fail("RESUME without error")
    }
    RTError.isHandling = false
    return RTError.faultStatement
}

@_cdecl("basic_rt_err")
public func basic_rt_err() -> Double {
    Double(RTError.lastNumber)
}

@_cdecl("basic_rt_erl")
public func basic_rt_erl() -> Double {
    Double(RTError.lastLine)
}
