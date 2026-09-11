#if canImport(BASICRTSwift)
import BASICRTSwift
#endif
import Foundation

// BASICRT control: program start and finish, runtime errors, the GOSUB
// return stack, and the random generator.

@_cdecl("basic_rt_start")
public func basic_rt_start() {
    // On a terminal, text is line-buffered as the Shell's is (VTG bytes go
    // straight to the descriptor, so they interleave the same way); the
    // reads flush first. On a pipe, buffer for speed.
    if isatty(STDOUT_FILENO) == 1 {
        setvbuf(stdout, nil, _IOLBF, 1 << 12)
    } else {
        setvbuf(stdout, nil, _IOFBF, 1 << 16)
    }
    RTSignals.install()
    // The two hooks BASICRTSwift needs to convert strings at a framework
    // boundary. They live here because only BASICRT knows what an RTString
    // is, and BASICRTSwift must not depend on it.
    //
    // Conditional because the runtime can also be compiled straight from
    // these sources, as one anonymous module with no BASICRTSwift in sight.
    // That path is Rev 1's only, and a Rev 1 program has no Swift objects to
    // bridge for — the Swift dialect refuses to build without the archive.
    #if canImport(BASICRTSwift)
    BASICRTSwiftBridge.install(
        readString: { rtString($0).rawString },
        makeString: { rtOwned($0) },
        fail: { basic_rt_fail($0) },
        // The array side (R4.7). An imported `[T]` is a BASIC array in a
        // VARIANT, which is what a BASIC function already hands back, so
        // `LEN(v)` and `v(i)` walk it and the language learns nothing new.
        arrayCount: { rtSwiftArray($0)?.values.count ?? 0 },
        arrayNumber: { rtSwiftArray($0)?.values[safe: $1]?.number ?? 0 },
        arrayBoolean: { rtSwiftArray($0)?.values[safe: $1]?.truthy ?? false },
        arrayString: { rtSwiftArray($0)?.values[safe: $1]?.string?.rawString ?? "" },
        // A Swift array arrives 0-based, which is where a BASIC `DIM` starts
        // too — so the bounds are `count - 1` and the indexes read the same
        // on both sides.
        makeNumberArray: { rtSwiftArrayOut($0.map { RTValue.number($0) }, element: .number) },
        makeBooleanArray: { rtSwiftArrayOut($0.map { RTValue.boolean($0) }, element: .boolean) },
        makeStringArray: { rtSwiftArrayOut($0.map { RTValue.string(RTText($0)) }, element: .string) }
    )
    // A BASIC error that crossed a Swift-facing boundary (R4.6), consumed as
    // Swift reads it.
    BASICRTSwiftBridge.installErrors(current: {
        let error = (number: RTTasks.boundaryNumber, message: RTTasks.boundaryError ?? "BASIC error")
        RTTasks.boundaryError = nil
        return error
    })
    // Records of an enum whose cases carry values (E4): the case at slot 0,
    // then each field name once — the layout the compiler gives the ENUM.
    BASICRTSwiftBridge.installEnums(
        make: { index, tag in
            let composite = RTComposite(typeIndex: index)
            composite.fields[0] = .number(Double(tag))
            return rtOwned(composite)
        },
        tag: { pointer in pointer.map { Int(rtComposite($0).fields[0].number ?? 0) } ?? 0 },
        number: { pointer, slot in pointer.map { rtComposite($0).fields[slot].number ?? 0 } ?? 0 },
        string: { pointer, slot in pointer.map { rtComposite($0).fields[slot].string?.rawString ?? "" } ?? "" },
        boolean: { pointer, slot in pointer.map { rtComposite($0).fields[slot].truthy } ?? false },
        setNumber: { pointer, slot, value in rtComposite(pointer).fields[slot] = .number(value) },
        setString: { pointer, slot, value in rtComposite(pointer).fields[slot] = .string(RTText(value)) },
        setBoolean: { pointer, slot, value in rtComposite(pointer).fields[slot] = .boolean(value) }
    )
    #endif
}

@_cdecl("basic_rt_finish")
public func basic_rt_finish() {
    RTGraphics.finish()
    RTTasks.finish()
    fflush(stdout)
}

/// Reports a runtime error the way the interpreter prints one and exits.
@_cdecl("basic_rt_fail")
public func basic_rt_fail(_ message: UnsafePointer<CChar>) -> Never {
    basic_rt_fail(String(cString: message))
}

package func basic_rt_fail(_ message: String) -> Never {
    basic_rt_fail(prefix: "Runtime error", message)
}

/// Reports a type error — the interpreter's other failure flavor.
@_cdecl("basic_rt_fail_type")
public func basic_rt_fail_type(_ message: UnsafePointer<CChar>) -> Never {
    basic_rt_fail_type(String(cString: message))
}

func basic_rt_fail_type(_ message: String) -> Never {
    basic_rt_fail(prefix: "Type error", message)
}

/// "Missing line N": the interpreter prints it bare, and numbers it 8.
@_cdecl("basic_rt_fail_missing")
public func basic_rt_fail_missing(_ message: UnsafePointer<CChar>) -> Never {
    RTError.raise(number: 8, message: String(cString: message), prefix: nil)
}

private func basic_rt_fail(prefix: String, _ message: String) -> Never {
    RTError.raise(number: RTError.number(for: message, isTypeError: prefix == "Type error"), message: message, prefix: prefix)
}

/// The GOSUB return stack: each entry is the index of the block to resume.
enum RTGosubStack {
    nonisolated(unsafe) static var entries: [Int] = []
}

@_cdecl("basic_rt_gosub_push")
public func basic_rt_gosub_push(_ resume: Int) {
    RTGosubStack.entries.append(resume)
}

/// How many GOSUBs are pending — a function compares this with the depth
/// at its entry to tell a subroutine RETURN from its own return.
@_cdecl("basic_rt_gosub_depth")
public func basic_rt_gosub_depth() -> Int {
    RTGosubStack.entries.count
}

@_cdecl("basic_rt_gosub_pop")
public func basic_rt_gosub_pop() -> Int {
    guard let resume = RTGosubStack.entries.popLast() else {
        basic_rt_fail("RETURN without GOSUB")
    }
    return resume
}

/// The interpreter's generator, bit for bit, so `RND` sequences match.
enum RTRandom {
    nonisolated(unsafe) static var state: UInt64 = 0x4d595df4d0f33173
    nonisolated(unsafe) static var lastValue: Double = 0

    static func randomize(seed: Double) {
        state = seed.bitPattern ^ 0x9e3779b97f4a7c15
        if state == 0 { state = 0x4d595df4d0f33173 }
        lastValue = 0
    }

    static func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        lastValue = Double(state >> 11) / Double(1 << 53)
        return lastValue
    }
}

@_cdecl("basic_rt_randomize")
public func basic_rt_randomize(_ seed: Double) {
    RTRandom.randomize(seed: seed)
}

/// `RANDOMIZE` with no seed: the clock, as the interpreter does.
@_cdecl("basic_rt_randomize_time")
public func basic_rt_randomize_time() {
    RTRandom.randomize(seed: Date().timeIntervalSince1970)
}

@_cdecl("basic_rt_rnd")
public func basic_rt_rnd() -> Double {
    RTRandom.next()
}

/// `DATE$`: `MM-dd-yyyy`, as the interpreter formats it.
@_cdecl("basic_rt_date")
public func basic_rt_date() -> UnsafeMutableRawPointer {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd-yyyy"
    return rtOwned(formatter.string(from: Date()))
}

/// `TIME$`: `HH:mm:ss`.
@_cdecl("basic_rt_time")
public func basic_rt_time() -> UnsafeMutableRawPointer {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return rtOwned(formatter.string(from: Date()))
}

/// `SLEEP(ms)`: pauses; the value is 0, as a statement-shaped builtin.
@_cdecl("basic_rt_sleep")
public func basic_rt_sleep(_ milliseconds: Double) -> Double {
    fflush(stdout)
    usleep(UInt32(max(0, milliseconds.rounded())) * 1000)
    return 0
}

/// `FILEEXISTS(path)`: 1 or 0.
@_cdecl("basic_rt_file_exists_number")
public func basic_rt_file_exists_number(_ pathPointer: UnsafeMutableRawPointer?) -> Double {
    FileManager.default.fileExists(atPath: (rtText(pathPointer) as NSString).expandingTildeInPath) ? 1 : 0
}


/// The BASIC array inside a boxed value, or nil when it holds something else.
///
/// Nil rather than a trap: an imported `[T]` parameter is declared VARIANT in
/// the generated unit, and BASIC will let a program pass a number to it. An
/// empty array is the harmless reading — the same thing the framework would
/// see if the program passed an array with nothing in it.
func rtSwiftArray(_ pointer: UnsafeMutableRawPointer?) -> RTArray? {
    guard case .array(let array) = rtValue(pointer) else { return nil }
    return array
}

/// An owned (+1) boxed value holding a one-dimensional BASIC array.
func rtSwiftArrayOut(_ values: [RTValue], element: RTTypeRef) -> UnsafeMutableRawPointer {
    rtOwned(.array(RTArray(
        upperBounds: [values.count - 1], isDynamic: true, element: element, values: values
    )))
}

extension Array {
    /// Out-of-range reads as nil: index arithmetic at a boundary should give
    /// a wrong answer no more readily than it gives a crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
