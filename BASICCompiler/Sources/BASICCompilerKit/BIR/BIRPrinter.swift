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
        for type in module.types {
            lines.append("type \(type.name) #\(type.index) " + type.fields.map { "\($0.name) : \($0.type.name)" }.joined(separator: ", "))
        }
        lines.append(contentsOf: render(module.main))
        for function in module.functions {
            lines.append(contentsOf: render(function))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func render(_ variable: BIRVariable) -> String {
        let suffix = variable.rank.map { "(\($0))" } ?? ""
        return "\(variable.name)\(suffix) : \(variable.type.name)"
    }

    private func render(_ function: BIRFunction) -> [String] {
        let parameters = function.parameters.map(render).joined(separator: ", ")
        var lines = ["function \(function.name)(\(parameters)) : \(function.returnType.name)"]
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
        case .storeField(let place, let value), .storePlace(let place, let value):
            return "store \(render(place)) <- \(render(value))"
        case .assignArray(let place, let value):
            return "assign array \(render(place)) <- \(render(value))"
        case .callMethod(let receiver, let candidates, let arguments, let result):
            let target = candidates.count == 1 ? candidates[0].function : "virtual[" + candidates.map(\.function).joined(separator: "|") + "]"
            let call = "call \(render(receiver)).\(target)(" + arguments.map(render).joined(separator: ", ") + ")"
            return result.map { "store \($0.name) <- " + call } ?? call
        case .dim(let variable, let bounds):
            return "dim \(variable.name)(\(bounds.map { $0.map(render) ?? "*" }.joined(separator: ", ")))"
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
        case .cls:
            return "cls"
        case .fileService(let method, let arguments):
            return "File.\(method)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .callClosure(let closure, let arguments):
            return "call \(render(closure))(" + arguments.map(render).joined(separator: ", ") + ")"
        case .openFile(let path, let mode, let number, let recordLength):
            return "open \(render(path)) mode \(mode) as \(render(number))" + (recordLength.map { " len \(render($0))" } ?? "")
        case .fieldFile(let number, let fields):
            return "field \(render(number)), " + fields.map { "\(render($0.width)) as \($0.variable.name)" }.joined(separator: ", ")
        case .setFieldString(let variable, let value, let rightAligned):
            return "\(rightAligned ? "rset" : "lset") \(variable.name) <- \(render(value))"
        case .putRecord(let number, let record):
            return "put \(render(number))" + (record.map { ", \(render($0))" } ?? "")
        case .getRecord(let number, let record):
            return "get \(render(number))" + (record.map { ", \(render($0))" } ?? "")
        case .seekFile(let number, let position):
            return "seek \(render(number)), \(render(position))"
        case .resetFile(let number):
            return "reset \(render(number))"
        case .discard(let value):
            return "discard \(render(value))"
        case .locate(let row, let column):
            return "locate \(render(row)), \(render(column))"
        case .keyMode(let mode):
            return "option \(mode == 1 ? "ibm" : "aibasic")-keys"
        case .filesList:
            return "files"
        case .onEvent(let type, let subtype, let handler, _):
            return "on \(type)\(subtype.isEmpty ? "" : "." + subtype) call \(handler)"
        case .onTimer(let timer, let ticks, let handler, _):
            return "on timer \(render(timer)) every \(render(ticks)) call \(handler)"
        case .systemSet(let object, let property, let value):
            return "\(render(object)).\(property) <- \(render(value))"
        case .drainEvents(let limit):
            return "drain events \(limit)"
        case .systemCommand(let command):
            return "system \(render(command))"
        case .screen(let mode):
            return "screen \(render(mode))"
        case .color(let foreground, let background):
            return "color \(render(foreground))" + (background.map { ", \(render($0))" } ?? "")
        case .pset(let x, let y, let color, let reset):
            return "\(reset ? "preset" : "pset") (\(render(x)), \(render(y)))" + (color.map { ", \(render($0))" } ?? "")
        case .gline(let x1, let y1, let x2, let y2, let color):
            return "line (\(render(x1)), \(render(y1)))-(\(render(x2)), \(render(y2)))" + (color.map { ", \(render($0))" } ?? "")
        case .circle(let x, let y, let radius, let color, let aspect):
            return "circle (\(render(x)), \(render(y))), \(render(radius))" + (color.map { ", \(render($0))" } ?? "") + (aspect.map { ", \(render($0))" } ?? "")
        case .paint(let x, let y, let color, let border):
            return "paint (\(render(x)), \(render(y))), \(render(color))" + (border.map { ", \(render($0))" } ?? "")
        case .draw(let program):
            return "draw \(render(program))"
        case .lineInputField(let prompt, let into, let exitInto, let length, let maximum, let defaultText):
            return "line input field " + (prompt.map { render($0) + ", " } ?? "") + into.name
                + (length.map { " length \(render($0))" } ?? "") + (maximum.map { " max \(render($0))" } ?? "")
                + (defaultText.map { " default \(render($0))" } ?? "") + (exitInto.map { " exitvar \($0.name)" } ?? "")
        case .closeFile(let number):
            return "close" + (number.map { " " + render($0) } ?? "")
        case .printFile(let number, let items, let newline):
            return "print #\(render(number)) " + items.map { item -> String in
                switch item {
                case .value(let value): return render(value)
                case .comma: return ","
                case .tab(let value): return "tab(\(render(value)))"
                case .spc(let value): return "spc(\(render(value)))"
                }
            }.joined(separator: " ") + (newline ? " newline" : "")
        case .printFileUsing(let number, let format, let values, let newline):
            return "print #\(render(number)) using \(render(format)); " + values.map(render).joined(separator: ", ") + (newline ? " newline" : "")
        case .writeFile(let number, let values):
            return "write #\(render(number)) " + values.map(render).joined(separator: ", ")
        case .inputFile(let number, let targets):
            return "input #\(render(number)) " + targets.map { target -> String in
                switch target {
                case .variable(let variable): return variable.name
                case .element(let variable, let indexes): return "\(variable.name)(\(indexes.map(render).joined(separator: ", ")))"
                }
            }.joined(separator: ", ")
        case .lineInputFile(let number, let variable):
            return "line input #\(render(number)) -> \(variable.name)"
        case .markStatement(let id, let line):
            return "statement \(id) line \(line)"
        case .onError(let handler):
            return "on error " + (handler.map { "handler \($0)" } ?? "off")
        case .raise(let number):
            return "raise \(render(number))"
        case .failMissing(let message):
            return "fail missing \"\(message)\""
        case .failType(let message):
            return "fail type \"\(message)\""
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
        case .input(let prompt, let variable, _):
            return "input " + (prompt.map { render($0) + " " } ?? "") + "-> \(variable.name)"
        case .lineInput(let prompt, let variable):
            return "line input " + (prompt.map { render($0) + " " } ?? "") + "-> \(variable.name)"
        case .printUsing(let format, let values, let newline):
            return "print using \(render(format)); " + values.map(render).joined(separator: ", ") + (newline ? " newline" : "")
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

    private func render(_ place: BIRPlace) -> String {
        switch place {
        case .variable(let variable): return variable.name
        case .element(let variable, let indexes): return "\(variable.name)(" + indexes.map(render).joined(separator: ", ") + ")"
        case .field(let base, let index, _): return "\(render(base)).#\(index)"
        case .arrayElement(let base, let indexes, _): return "\(render(base))(" + indexes.map(render).joined(separator: ", ") + ")"
        case .dictionaryEntry(let base, let key, _): return "\(render(base))(\(render(key)))"
        case .valueEntry(let base, let indexes, _): return "\(render(base))(" + indexes.map(render).joined(separator: ", ") + ")"
        case .valueField(let base, let field, _): return "\(render(base)).\(field)"
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
        case .text(let value):
            return "text(\(render(value)))"
        case .field(let base, let index, _):
            return "\(render(base)).#\(index)"
        case .construct(let name):
            return "new \(name)"
        case .usingString(let format, let values):
            return "USING$(" + ([format] + values).map(render).joined(separator: ", ") + ")"
        case .fileService(let method, let arguments, _):
            return "File.\(method)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .makeClosure(let function, _, let captures, _):
            return "closure \(function)[" + captures.map(render).joined(separator: ", ") + "]"
        case .callClosure(let closure, let arguments, _):
            return "\(render(closure))(" + arguments.map(render).joined(separator: ", ") + ")"
        case .callMethod(let receiver, let candidates, let arguments, _):
            let target = candidates.count == 1 ? candidates[0].function : "virtual[" + candidates.map(\.function).joined(separator: "|") + "]"
            return "\(render(receiver)).\(target)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .loadArray(let variable):
            return "\(variable.name)()"
        case .elementOf(let array, let indexes, _):
            return "\(render(array))(" + indexes.map(render).joined(separator: ", ") + ")"
        case .box(let value):
            return "box(\(render(value)))"
        case .unbox(let value, let type, _):
            return "unbox<\(type.name)>(\(render(value)))"
        case .dictionaryGet(let dictionary, let key, _):
            return "\(render(dictionary))(\(render(key)))"
        case .valueIndex(let value, let indexes, _):
            return "\(render(value))(" + indexes.map(render).joined(separator: ", ") + ")"
        case .valueField(let value, let field, _):
            return "\(render(value)).\(field)"
        case .valueAdd(let left, let right):
            return "(\(render(left)) + \(render(right)))"
        case .valueEqual(let left, let right):
            return "(\(render(left)) = \(render(right)))"
        case .valueLen(let value):
            return "LEN(\(render(value)))"
        case .arrayLen(let array, _):
            return "LEN(\(render(array)))"
        case .jsonEncode(let value, let pretty):
            return "TOJSONSTRING(\(render(value)), \(render(pretty)))"
        case .jsonDecode(let source, let permissive):
            return "FROMJSONSTRING(\(render(source)), \(render(permissive)))"
        case .emptyValue:
            return "EMPTY"
        case .nullValue:
            return "NULL"
        case .newDictionary:
            return "new DICTIONARY"
        case .hostCall(let name, let arguments, _):
            return "\(name)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .systemNew(let name, let arguments):
            return "new \(name)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .systemCall(let receiver, let method, let arguments, _):
            return "\(render(receiver)).\(method)(" + arguments.map(render).joined(separator: ", ") + ")"
        case .asyncLaunch(let name, let arguments):
            return "launch \(name)(" + arguments.map(render).joined(separator: ", ") + ")"
        }
    }
}
