#if canImport(JavaScriptCore)
import BASICRT
import BASICRTSwift
import BASICWasmHostC
import Foundation

// A framework map's entries, called by a host with no module (BASIC-45,
// slice 11e): the interpreter, when Studio's ▶ Run meets
// `IMPORT "ActiveUI"` or `IMPORT "TUIKit"`. It calls the very entries a
// module calls, through the same shims, so ▶ Run and ⚡ cannot disagree
// about what a member does.
//
// What a module's run sets up, this sets up for the interpreter's: the
// runtime in hosted mode (a shim's error unwinds to a protected call, it
// never exits the app), the bridges a shim converts strings, arrays and
// records through, and the framework's calls back routed to the host. The
// values the entries take — runtime strings, records, arrays and closures —
// are made and read here, so the host never touches the runtime itself.

public enum WasmHostedCalls {
    /// A value crossing in a runtime record or array.
    public enum Value: Equatable, Sendable {
        case number(Double)
        case string(String)
        case boolean(Bool)
    }

    /// The kind of a record's field, as registered.
    public enum Kind: Sendable {
        case number, string, boolean
    }

    /// Begins a host's run: hosted mode, the runtime started, and calls back
    /// routed to `callbacks`. `output` takes what the runtime writes — a
    /// shim's error message among it; `isStopRequested` is asked where the
    /// framework keeps the host waiting.
    public static func begin(callbacks: WasmCallbackHost, output: @escaping (String) -> Void,
                             isStopRequested: @escaping () -> Bool) {
        RTHosted.output = output
        RTHosted.unwind = { kind in basic_wasm_unwind(kind.rawValue) }
        RTHosted.checkStop = {
            WasmForward.service()
            if isStopRequested() { basic_wasm_unwind(WasmRunner.stopCode) }
        }
        RTHosted.isStopRequested = isStopRequested
        basic_rt_start()
        WasmCallbacks.clearQueued()
        WasmForward.clear()
        WasmCallbacks.host = callbacks
    }

    /// Ends the host's run, as a module's run ends.
    public static func end() {
        WasmCallbacks.host = nil
        WasmCallbacks.clearQueued()
        WasmForward.clear()
        RTHosted.output = nil
        RTHosted.unwind = nil
        RTHosted.checkStop = nil
        RTHosted.isStopRequested = nil
    }

    /// The code a protected call ends with: 0 when it returned.
    public static let stopCode = WasmRunner.stopCode

    /// Runs `body` protected: an error the runtime raises inside it comes back
    /// here as its unwind code (2 for an error, whose message went to
    /// `output`; 4 for Stop) instead of ending the app.
    ///
    /// Escaping, not `withoutActuallyEscaping`: an unwind skips the frames
    /// that would let go of `body`, which that checks for and traps on. What
    /// an unwind skips is left held, once per error or Stop.
    public static func protected(_ body: @escaping () -> Void) -> Int32 {
        let box = Body(body)
        return withExtendedLifetime(box) {
            basic_wasm_protected(runBody, Unmanaged.passUnretained(box).toOpaque())
        }
    }

    /// Calls `entry` with `arguments`, protected. The result, or 0 and the
    /// code the call unwound with.
    public static func call(_ entry: WasmEntryPoint, _ arguments: [Double]) -> (result: Double, code: Int32) {
        final class Answer { var value = 0.0 }
        let answer = Answer()
        let code = protected {
            answer.value = arguments.withUnsafeBufferPointer { entry.call($0.baseAddress ?? UnsafePointer(bitPattern: 8)!) }
        }
        return (answer.value, code)
    }

    /// Makes the calls back the framework has waiting — queued closures and
    /// overrides it waits for — on the calling thread, which must be the
    /// host's BASIC thread. Protected; answers the code as `call` does.
    public static func service() -> Int32 {
        protected {
            WasmForward.service()
            WasmCallbacks.runQueued()
        }
    }

    // MARK: Strings

    /// A runtime string holding `text`, owned by the caller (+1), as bits.
    public static func newString(_ text: String) -> Double {
        var utf8 = Array(text.utf8)
        if utf8.isEmpty { utf8 = [0] }
        let pointer = utf8.withUnsafeBufferPointer { basic_rt_string_literal($0.baseAddress!, text.utf8.count) }
        return Double(UInt(bitPattern: pointer))
    }

    /// The text of the runtime string at `bits`.
    public static func readString(_ bits: Double) -> String {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else { return "" }
        return rtString(pointer).rawString
    }

    public static func releaseString(_ bits: Double) {
        basic_rt_string_release(UnsafeMutableRawPointer(bitPattern: UInt(bits)))
    }

    // MARK: Records

    /// Registers a record type a shim may make, at `typeIndex`: a struct's
    /// leaves, or an ENUM's tag and fields. The runtime forgets every type at
    /// `begin`, so a run registers its own.
    public static func registerRecord(typeIndex: Int, name: String, fields: [(name: String, kind: Kind)]) {
        let described: [[String: Any]] = fields.map { field in
            let kind: String
            switch field.kind {
            case .number: kind = "number"
            case .string: kind = "string"
            case .boolean: kind = "boolean"
            }
            return ["name": field.name.uppercased(), "display": field.name, "type": ["k": kind]]
        }
        let object: [String: Any] = ["name": name, "kind": "record", "fields": described]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { basic_rt_type_register(typeIndex, $0) }
    }

    /// A new record of `typeIndex` holding `values` in order, owned (+1).
    public static func makeRecord(typeIndex: Int, values: [Value]) -> Double {
        let pointer = basic_rt_composite_new(typeIndex)
        for (slot, value) in values.enumerated() {
            switch value {
            case .number(let number): basic_rt_composite_set_number(pointer, slot, number)
            case .boolean(let flag): basic_rt_composite_set_boolean(pointer, slot, flag)
            case .string(let text):
                let made = newString(text)
                basic_rt_composite_set_string(pointer, slot, UnsafeMutableRawPointer(bitPattern: UInt(made)))
                releaseString(made)
            }
        }
        return Double(UInt(bitPattern: pointer))
    }

    /// The first `kinds.count` fields of the record at `bits`.
    public static func readRecord(_ bits: Double, kinds: [Kind]) -> [Value] {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else { return [] }
        return kinds.enumerated().map { slot, kind in
            switch kind {
            case .number: return .number(basic_rt_composite_get_number(pointer, slot))
            case .boolean: return .boolean(basic_rt_composite_get_boolean(pointer, slot))
            case .string:
                let text = basic_rt_composite_get_string(pointer, slot)
                defer { basic_rt_string_release(text) }
                return .string(text.map { rtString($0).rawString } ?? "")
            }
        }
    }

    public static func releaseRecord(_ bits: Double) {
        basic_rt_composite_release(UnsafeMutableRawPointer(bitPattern: UInt(bits)))
    }

    // MARK: Arrays

    /// The elements of the array a shim handed out (a VARIANT holding a
    /// 0-based array of `kind`), which is released.
    public static func takeArray(_ bits: Double, kind: Kind) -> [Value] {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else { return [] }
        defer { basic_rt_value_release(pointer) }
        return (0..<basicRTSwiftArrayCount(pointer)).map { index in
            switch kind {
            case .number: return .number(basicRTSwiftArrayNumber(pointer, index))
            case .boolean: return .boolean(basicRTSwiftArrayBoolean(pointer, index))
            case .string: return .string(basicRTSwiftArrayString(pointer, index))
            }
        }
    }

    /// An array to hand a shim, as a VARIANT holding a 0-based array of
    /// `kind`, owned (+1).
    public static func makeArray(_ elements: [Value], kind: Kind) -> Double {
        let pointer: UnsafeMutableRawPointer
        switch kind {
        case .number:
            pointer = basicRTSwiftArrayOutNumbers(elements.map { if case .number(let n) = $0 { return n }; return 0 })
        case .boolean:
            pointer = basicRTSwiftArrayOutBooleans(elements.map { if case .boolean(let b) = $0 { return b }; return false })
        case .string:
            pointer = basicRTSwiftArrayOutStrings(elements.map { if case .string(let t) = $0 { return t }; return "" })
        }
        return Double(UInt(bitPattern: pointer))
    }

    public static func releaseValue(_ bits: Double) {
        basic_rt_value_release(UnsafeMutableRawPointer(bitPattern: UInt(bits)))
    }

    // MARK: Closures

    /// A runtime closure standing for the host's callable `target` (never 0),
    /// owned (+1): what a `() -> Void` parameter's entry takes. When the
    /// framework calls it, the call reaches `callBASIC(target, …)`.
    public static func closure(target: Int) -> Double {
        let function = UnsafeRawPointer(bitPattern: UInt(target))!
        return Double(UInt(bitPattern: basic_rt_closure_new(function, nil)))
    }

    public static func releaseClosure(_ bits: Double) {
        basic_rt_closure_release(UnsafeMutableRawPointer(bitPattern: UInt(bits)))
    }

    final class Body {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}

private let runBody: basic_wasm_body = { context in
    Unmanaged<WasmHostedCalls.Body>.fromOpaque(context!).takeUnretainedValue().run()
}
#endif
