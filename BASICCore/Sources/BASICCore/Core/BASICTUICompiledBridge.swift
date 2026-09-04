//
//  BASICTUICompiledBridge.swift
//  BASICCore
//
//  The TUI binding, reached from a compiled program.
//

import Foundation
import TUIKit

/// The TUIKit binding as a compiled program sees it.
///
/// `basicc` has its own runtime and no interpreter, but a control's
/// behaviour was settled here control by control — which word a table
/// answers, what a short row does, where a menu bar goes. A second copy of
/// that in the compiler's runtime would drift from this one the first time
/// either changed, and a difference between the two is exactly what the
/// compiler exists not to have. So a compiled program calls this binding
/// instead, across an ABI of the only shapes that cross it: numbers,
/// strings, booleans, and handles to the objects this module holds.
public enum BASICCompiledTUI {

    /// A value crossing between the two runtimes.
    public enum Value: Sendable, Equatable {
        case number(Double)
        case string(String)
        case boolean(Bool)
        /// A handle to a TUI object, with what it is.
        case handle(id: Int, kind: String)
        case empty
    }

    /// What went wrong, as the interpreter would have said it.
    public struct Failure: Error {
        public let message: String
    }

    /// Builds a pseudo-class handle: the id, and the kind it was made as.
    public static func make(typeName: String, arguments: [Value]) throws -> Int {
        let runtime = BASICRuntime()
        do {
            let handle = try runtime.tuiObject(typeName: typeName, arguments: arguments.map(basicValue))
            guard case .systemObject(_, let id) = handle else {
                throw Failure(message: "\(typeName) is not a TUI object")
            }
            return id
        } catch let error as BASICError {
            throw Failure(message: bare(error))
        }
    }

    /// Calls a method on a handle. `RUN` blocks until the application stops;
    /// everything a control does in the meantime reaches the program through
    /// `invokeHandler`, which is how a BASIC function wired to a button is
    /// called from inside a frame.
    public static func call(
        typeName: String,
        id: Int,
        method: String,
        arguments: [Value],
        invokeHandler: @escaping (String, [Value]) -> Void
    ) throws -> Value {
        let bridge = BASICTUIRuntimeBridge.shared
        let wrapped: (String, [BASICValue]) throws -> Void = { name, values in
            invokeHandler(name, values.map(bridgeValue))
        }
        do {
            if method.uppercased() == "RUN" {
                guard case .handle(let windowID, _)? = arguments.first else {
                    throw Failure(message: "\(typeName).run expects a window")
                }
                bridge.invokeHandler = wrapped
                defer { bridge.invokeHandler = nil }
                // A compiled program is its own host: an ANSIDriver and
                // nothing else a `BASICHost` would answer.
                try BASICTUIRuntimeBridge.runBlocking(appID: id, windowID: windowID, driver: ANSIDriver())
                if let failure = bridge.takeFailure() {
                    throw failure
                }
                return .empty
            }
            let runtime = BASICRuntime()
            bridge.invokeHandler = wrapped
            defer { bridge.invokeHandler = nil }
            let answer = try runtime.callTUIMethod(
                typeName: typeName, id: id, method: method,
                arguments: arguments.map(basicValue),
                presentationHost: nil,
                invokeHandler: wrapped
            )
            return bridgeValue(answer)
        } catch let error as BASICError {
            throw Failure(message: bare(error))
        }
    }

    /// The message without the prefix the compiled runtime adds itself.
    private static func bare(_ error: BASICError) -> String {
        if case .runtime(let message) = error { return message }
        return error.description
    }

    /// The kind a handle was made as, for naming it in an error.
    public static func kind(of id: Int) -> String {
        (try? withTUIRegistry { $0.kinds[id] ?? "" }) ?? ""
    }

    // MARK: - The two value shapes

    private static func basicValue(_ value: Value) -> BASICValue {
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .string(BASICString(text))
        case .boolean(let flag): return .boolean(flag)
        case .handle(let id, let kind): return .systemObject(kind, id)
        case .empty: return .empty
        }
    }

    private static func bridgeValue(_ value: BASICValue) -> Value {
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .string(text.description)
        case .boolean(let flag): return .boolean(flag)
        case .systemObject(let kind, let id): return .handle(id: id, kind: kind)
        default: return .empty
        }
    }
}
