//
//  BASICAUICompiledBridge.swift
//  BASICCore
//
//  ActiveUI, reached from a compiled program (BASIC-45).
//

import Foundation

/// ActiveUI as a compiled program sees it.
///
/// A program compiled to WebAssembly runs inside BASICStudio, whose windows
/// answer the same ``BASICAUIRequest``s the interpreter sends. What each
/// control takes, what a table's column may be called and what `run` waits
/// for were settled in the interpreter's runtime; this calls that code
/// rather than repeating it, so the two engines cannot disagree. Only the
/// values crossing between the two runtimes are handled here; what the user
/// does comes back through ``BASICCompiledEvents``.
public enum BASICCompiledAUI {
    /// A value crossing between the two runtimes: the TUI binding's shapes.
    public typealias Value = BASICCompiledTUI.Value
    /// What went wrong, as the interpreter would have said it.
    public typealias Failure = BASICCompiledTUI.Failure

    /// The controls and their handlers, on the program's thread.
    nonisolated(unsafe) private static var runtime = BASICRuntime()

    /// A new run: no controls, no handlers.
    public static func reset() {
        runtime = BASICRuntime()
    }

    /// Makes control `typeName(arguments…)` on `host`'s windows; its id.
    public static func make(typeName: String, arguments: [Value], host: BASICAUIHost?) throws -> Int {
        guard let kind = BASICAUIKind(named: typeName) else {
            throw Failure(message: "Unknown CLASS \(typeName)")
        }
        do {
            guard case .systemObject(_, let id) = try runtime.auiObject(kind: kind, arguments: arguments.map(basicValue), host: host) else {
                throw Failure(message: "\(kind.rawValue) is not an ActiveUI control")
            }
            return id
        } catch let error as BASICError {
            throw Failure(message: bare(error))
        }
    }

    /// Calls `method` on control `id`. `pump` is how a window's `run` waits:
    /// the compiled program's Stop check and event drain.
    public static func call(
        typeName: String,
        id: Int,
        method: String,
        arguments: [Value],
        host: BASICAUIHost?,
        pump: () throws -> Void
    ) throws -> Value {
        do {
            let answer = try runtime.callAUIMethod(
                typeName: BASICAUIKind(named: typeName)?.rawValue ?? typeName,
                id: id, method: method,
                arguments: arguments.map(basicValue),
                host: host, pump: pump
            )
            return bridgeValue(answer)
        } catch let error as BASICError {
            throw Failure(message: bare(error))
        }
    }

    /// The handler control `id` named for `kind` (`onclick("Saved")`), if it
    /// named one.
    public static func handler(id: Int, kind: String) -> String? {
        runtime.auiHandler(id: id, kind: kind)
    }

    /// Queues what the user did, as ``BASICSession/postAUIEvent(kind:source:text:index:column:)``
    /// does for the interpreter. Safe from any thread.
    public static func post(kind: String, source: Int, text: String = "", index: Int = -1, column: Int = -1) {
        BASICCompiledEvents.post(type: "AUI", subtype: kind, fields: [
            "type": .string("AUI"),
            "subtype": .string(kind.uppercased()),
            "source": .number(Double(source)),
            "text": .string(text),
            "index": .number(Double(index)),
            "column": .number(Double(column)),
            "timestamp": .number(Date().timeIntervalSince1970),
        ])
    }

    // MARK: - The two value shapes

    private static func basicValue(_ value: Value) -> BASICValue {
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .string(BASICString(text))
        case .boolean(let flag): return .boolean(flag)
        case .handle(let id, let kind): return .systemObject(BASICAUIKind(named: kind)?.rawValue ?? kind, id)
        case .empty: return .empty
        }
    }

    private static func bridgeValue(_ value: BASICValue) -> Value {
        switch value {
        case .number(let number): return .number(number)
        case .boolean(let flag): return .boolean(flag)
        case .string(let text): return .string(text.description)
        case .systemObject(let kind, let id): return .handle(id: id, kind: kind)
        default: return .empty
        }
    }

    /// The message without the prefix the compiled runtime adds itself.
    private static func bare(_ error: BASICError) -> String {
        if case .runtime(let message) = error { return message }
        return error.description
    }
}
