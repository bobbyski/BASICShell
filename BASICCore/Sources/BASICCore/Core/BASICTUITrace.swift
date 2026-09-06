import Foundation

/// Env-gated trace for the TUI binding's handler dispatch.
///
/// A control event reaches BASIC in two hops — TUIKit calls back with the
/// view's id, and the id is looked up in a registry to find the handler's
/// name. When nothing happens on a click, the question is which hop was
/// missing, and the two look identical from outside.
///
/// Set `BASIC_TUI_TRACE` to a path to find out.
enum BASICTUITrace {
    static func log(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["BASIC_TUI_TRACE"] else { return }
        let line = Data("tui: \(message)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }
}
