//
//  BASICRichCompiledBridge.swift
//  BASICCore
//
//  The RichSwift binding, reached from a compiled program.
//

import Foundation

/// The Rich* binding as a compiled program sees it.
///
/// The same arrangement as ``BASICCompiledTUI``, for the same reason: how a
/// panel takes its title, why a renderer hands RichSwift a bare `String`
/// rather than a `Text`, what a short table row does — all settled here, and
/// a second copy in the compiler's runtime would drift from it the first
/// time either changed.
///
/// One difference from the TUI bridge, and it is the whole reason this file
/// exists rather than three lines in that one: a Rich object's state lives
/// on a `BASICRuntime`, not in a shared registry. So this holds one runtime
/// for the life of the process. A fresh one per call would hand back a
/// handle whose width, columns and rows were forgotten before the next
/// statement.
public enum BASICCompiledRich {

    /// A value crossing between the two runtimes.
    public enum Value: Sendable, Equatable {
        case number(Double)
        case string(String)
        case boolean(Bool)
        /// A handle to a Rich object, with what it is.
        case handle(id: Int, kind: String)
        case empty
    }

    /// What went wrong, as the interpreter would have said it.
    public struct Failure: Error {
        public let message: String
    }

    /// The one runtime the objects live on, reached under a lock: a
    /// compiled program is single-threaded through here, and the lock says
    /// so rather than leaving it to be assumed.
    nonisolated(unsafe) private static let runtime = BASICRuntime()
    private static let lock = NSLock()

    /// Builds a Rich* handle: the id it was made as.
    public static func make(typeName: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard case .systemObject(_, let id) = runtime.richObject(typeName: typeName) else {
            throw Failure(message: "\(typeName) is not a Rich object")
        }
        return id
    }

    /// Calls a method on a handle.
    public static func call(typeName: String, id: Int, method: String, arguments: [Value]) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        do {
            let answer = try runtime.callRichMethod(
                typeName: typeName, id: id, method: method,
                arguments: arguments.map(basicValue)
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
