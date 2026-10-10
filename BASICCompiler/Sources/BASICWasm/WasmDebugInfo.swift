import Foundation

// What a debugger needs from a module translated for debugging (BASIC-46).
//
// A debug build differs from a normal one in three ways, and basicc's LLVM IR
// in none:
//
// - The program's variables stay in linear memory, where the host can read
//   them, rather than becoming WebAssembly globals and locals.
// - Every function has a frame, so the address of a frame tells one call
//   from another, and an outer call from an inner one.
// - Each statement, where basicc records `basic.here`, calls the host's
//   `__debug(statement, function, frame)`: a breakpoint, a step or Pause
//   waits there.
//
// The IR it is translated from is compiled with debug info, whose metadata
// gives each variable's BASIC type; this table says where everything is.

/// Where a debug build's statements and variables are.
public struct WasmDebugInfo: Sendable {
    /// How a variable's value is held.
    public enum Storage: String, Sendable {
        case double, boolean, int32, int64, pointer
    }

    /// A variable: a global in memory, or a local in its function's frame.
    public struct Variable: Sendable, Equatable {
        /// As basicc stores it: uppercased.
        public let name: String
        /// Its BASIC type: DOUBLE, INTEGER, STRING, BOOLEAN, ARRAY, a record's
        /// or class's name.
        public let typeName: String
        public let storage: Storage
        /// A global's offset in memory; a local's from its frame.
        public let offset: Int
    }

    /// A function, by the number the hook passes.
    public struct Function: Sendable {
        /// Its BASIC name, uppercased; the program's own code is `main`.
        public let name: String
        /// Whether it is the program's own code rather than a FUNCTION or SUB.
        public let isProgram: Bool
        public let locals: [Variable]
    }

    /// A statement, by the index the hook passes.
    public struct Statement: Sendable, Equatable {
        /// Its line in its file, from 1.
        public let line: Int
        public let column: Int
        /// The text of its line.
        public let source: String
        /// Which statement of its line it is, from 0, as breakpoints count.
        public let indexOnLine: Int
    }

    public let globals: [Variable]
    public let functions: [Function]
    public let statements: [Statement]
}

/// The names and BASIC types in a debug build's metadata, as the traditional
/// dialect's DebugInfo writes them.
struct IRDebugNames {
    /// A global's BASIC type, by its name.
    var globalTypes: [String: String] = [:]
    /// A local's BASIC type, by its function's linkage name, then its name.
    var localTypes: [String: [String: String]] = [:]
    /// A function's BASIC name, by its linkage name.
    var functionNames: [String: String] = [:]

    init(llvmIR: String) {
        var nodes: [String: Substring] = [:]
        for line in llvmIR.split(separator: "\n") where line.hasPrefix("!") {
            guard let equals = line.range(of: " = ") else { continue }
            nodes[String(line[..<equals.lowerBound])] = line[equals.upperBound...]
        }
        func typeName(_ reference: String?) -> String? {
            guard let reference, let node = nodes[reference] else { return nil }
            guard node.contains("DW_TAG_typedef") || node.hasPrefix("!DIBasicType") else { return nil }
            return Self.field("name", in: node)
        }
        var linkage: [String: String] = [:]
        for (id, node) in nodes where node.contains("!DISubprogram(") {
            guard let name = Self.field("name", in: node) else { continue }
            let linkageName = Self.field("linkageName", in: node) ?? name
            linkage[id] = linkageName
            functionNames[linkageName] = name
        }
        for node in nodes.values {
            guard let name = Self.field("name", in: node) else { continue }
            if node.contains("!DIGlobalVariable(") {
                globalTypes[name] = typeName(Self.field("type", in: node))
            } else if node.contains("!DILocalVariable("), let scope = Self.field("scope", in: node),
                      let function = linkage[scope] {
                localTypes[function, default: [:]][name] = typeName(Self.field("type", in: node))
            }
        }
    }

    /// A node's field: `name: "TOTAL"` is TOTAL, `type: !16` is !16.
    static func field(_ name: String, in node: Substring) -> String? {
        for opener in ["(", ", "] {
            guard let range = node.range(of: opener + name + ": ") else { continue }
            let rest = node[range.upperBound...]
            if rest.hasPrefix("\"") {
                let text = rest.dropFirst()
                guard let close = text.firstIndex(of: "\"") else { return nil }
                return String(text[..<close])
            }
            let end = rest.firstIndex { $0 == "," || $0 == ")" } ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }
}
