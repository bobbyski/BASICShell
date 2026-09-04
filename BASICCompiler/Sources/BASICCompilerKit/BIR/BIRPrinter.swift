import Foundation

/// Renders BIR as text, for `--emit-bir` and the golden tests.
///
/// The format is meant to be read, not parsed:
///
/// ```text
/// module hello
/// global A$ : string
/// function main
///   entry:
///     store A$ <- "hi"
///     print A$ newline
///     jump L100
///   L100:
///     end
/// ```
public struct BIRPrinter {
    /// Creates a printer.
    public init() {}

    /// The module as text.
    public func render(_ module: BIRModule) -> String {
        var lines: [String] = ["module \(module.name)"]
        for variable in module.globals {
            lines.append("global \(variable.name) : \(variable.type.rawValue)")
        }
        lines.append(contentsOf: render(module.main))
        return lines.joined(separator: "\n") + "\n"
    }

    private func render(_ function: BIRFunction) -> [String] {
        var lines = ["function \(function.name)"]
        for variable in function.locals {
            lines.append("  local \(variable.name) : \(variable.type.rawValue)")
        }
        for block in function.blocks {
            lines.append("  \(block.label):")
            for instruction in block.instructions {
                lines.append("    " + render(instruction.operation))
            }
            lines.append("    " + render(block.terminator, in: function))
        }
        return lines
    }

    private func render(_ operation: BIROperation) -> String {
        switch operation {
        case .store(let variable, let value):
            return "store \(variable.name) <- \(render(value))"
        case .print(let items, let newline):
            let rendered = items.map { item -> String in
                switch item {
                case .value(let value): return render(value)
                case .comma: return ","
                case .tab(let value): return "tab(\(render(value)))"
                case .spc(let value): return "spc(\(render(value)))"
                }
            }
            return "print " + rendered.joined(separator: " ") + (newline ? " newline" : "")
        case .input(let prompt, let variable):
            return "input " + (prompt.map { render($0) + " " } ?? "") + "-> \(variable.name)"
        case .randomize(let seed):
            return "randomize" + (seed.map { " " + render($0) } ?? "")
        case .fail(let message):
            return "fail \"\(message)\""
        }
    }

    private func render(_ terminator: BIRTerminator, in function: BIRFunction) -> String {
        func label(_ id: BIRBlockID) -> String { function.blocks[id].label }
        switch terminator {
        case .jump(let target): return "jump \(label(target))"
        case .branch(let condition, let then, let otherwise):
            return "branch \(render(condition)) ? \(label(then)) : \(label(otherwise))"
        case .gosub(let target, let resume): return "gosub \(label(target)) resume \(label(resume))"
        case .returnFromGosub: return "return"
        case .end: return "end"
        case .unterminated: return "<unterminated>"
        }
    }

    /// An expression, fully parenthesized so precedence is never in doubt.
    public func render(_ expression: BIRExpression) -> String {
        switch expression {
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .string(let value):
            return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .boolean(let value):
            return value ? "TRUE" : "FALSE"
        case .load(let variable):
            return variable.name
        case .negate(let value):
            return "-(\(render(value)))"
        case .arithmetic(let op, let left, let right):
            let symbol = ["add": "+", "subtract": "-", "multiply": "*", "divide": "/"][op.rawValue]!
            return "(\(render(left)) \(symbol) \(render(right)))"
        case .concat(let left, let right):
            return "(\(render(left)) & \(render(right)))"
        case .compare(let op, let left, let right):
            let symbol = ["equal": "=", "notEqual": "<>", "less": "<", "lessEqual": "<=", "greater": ">", "greaterEqual": ">="][op.rawValue]!
            return "(\(render(left)) \(symbol) \(render(right)))"
        case .logical(let op, let left, let right):
            return "(\(render(left)) \(op.rawValue.uppercased()) \(render(right)))"
        case .intrinsic(let intrinsic, let arguments):
            return "\(intrinsic.rawValue)(" + arguments.map(render).joined(separator: ", ") + ")"
        }
    }
}
