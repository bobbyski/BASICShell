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
            lines.append("global " + render(variable))
        }
        if !module.data.isEmpty {
            lines.append("data " + module.data.map { item -> String in
                switch item {
                case .number(let value): return render(.number(value))
                case .string(let value): return render(.string(value))
                }
            }.joined(separator: ", "))
        }
        lines.append(contentsOf: render(module.main))
        for function in module.functions {
            lines.append(contentsOf: render(function))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func render(_ variable: BIRVariable) -> String {
        let suffix = variable.rank.map { "(\($0))" } ?? ""
        return "\(variable.name)\(suffix) : \(variable.type.rawValue)"
    }

    private func render(_ function: BIRFunction) -> [String] {
        let parameters = function.parameters.map(render).joined(separator: ", ")
        var lines = ["function \(function.name)(\(parameters)) : \(function.returnType.rawValue)"]
        for variable in function.locals where !function.parameters.contains(variable) {
            lines.append("  local " + render(variable))
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
        case .storeElement(let variable, let indexes, let value):
            return "store \(variable.name)(\(indexes.map(render).joined(separator: ", "))) <- \(render(value))"
        case .dim(let variable, let bounds):
            return "dim \(variable.name)(\(bounds.map(render).joined(separator: ", ")))"
        case .call(let name, let arguments):
            return "call \(name)(\(arguments.map(render).joined(separator: ", ")))"
        case .read(let targets):
            return "read " + targets.map { target -> String in
                switch target {
                case .variable(let variable): return variable.name
                case .element(let variable, let indexes): return "\(variable.name)(\(indexes.map(render).joined(separator: ", ")))"
                }
            }.joined(separator: ", ")
        case .restore:
            return "restore"
        case .markStatement(let id, let line):
            return "statement \(id) line \(line)"
        case .onError(let handler):
            return "on error " + (handler.map { "handler \($0)" } ?? "off")
        case .raise(let number):
            return "raise \(render(number))"
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
        case .ret(let value): return "ret" + (value.map { " " + render($0) } ?? "")
        case .resumeNext: return "resume next"
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
        case .call(let name, let arguments, _):
            return "\(name)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .element(let variable, let indexes):
            return "\(variable.name)(" + indexes.map(render).joined(separator: ", ") + ")"
        }
    }
}
