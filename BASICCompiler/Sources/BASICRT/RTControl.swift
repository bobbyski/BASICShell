import Foundation

// BASICRT control: program start and finish, runtime errors, the GOSUB
// return stack, and the random generator.

@_cdecl("basic_rt_start")
public func basic_rt_start() {
    setvbuf(stdout, nil, _IOFBF, 1 << 16)
}

@_cdecl("basic_rt_finish")
public func basic_rt_finish() {
    fflush(stdout)
}

/// Reports a runtime error the way the interpreter prints one and exits.
@_cdecl("basic_rt_fail")
public func basic_rt_fail(_ message: UnsafePointer<CChar>) -> Never {
    basic_rt_fail(String(cString: message))
}

func basic_rt_fail(_ message: String) -> Never {
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
