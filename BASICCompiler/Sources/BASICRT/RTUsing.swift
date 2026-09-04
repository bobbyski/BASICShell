import Foundation

// BASICRT `PRINT USING`.
//
// The compiled program hands over the format and then each value, and the
// runtime renders the line with the interpreter's formatter, ported here
// field for field: `!` first character, `&` whole value, and numeric fields
// built from `# . , + $ - *`.

enum RTUsing {
    nonisolated(unsafe) static var format = ""
    nonisolated(unsafe) static var values: [Value] = []

    enum Value {
        case number(Double)
        case string(String)

        var description: String {
            switch self {
            case .number(let value): return rtNumberText(value)
            case .string(let value): return value
            }
        }
    }

    static func render(format: String, values: [Value]) -> String {
        guard !values.isEmpty else { return format }
        var rendered = ""
        var valueIndex = 0
        while valueIndex < values.count {
            let startIndex = valueIndex
            let pass = renderPass(format: format, values: values, valueIndex: &valueIndex)
            if pass.fieldCount == 0 {
                if rendered.isEmpty { rendered += format }
                break
            }
            rendered += pass.text
            if valueIndex == startIndex { break }
        }
        return rendered
    }

    private static func renderPass(format: String, values: [Value], valueIndex: inout Int) -> (text: String, fieldCount: Int) {
        var output = ""
        var fieldCount = 0
        var index = format.startIndex

        while index < format.endIndex {
            let character = format[index]
            if character == "!" {
                guard valueIndex < values.count else { break }
                output += String(values[valueIndex].description.prefix(1))
                valueIndex += 1
                fieldCount += 1
                index = format.index(after: index)
                continue
            }
            if character == "&" {
                guard valueIndex < values.count else { break }
                output += values[valueIndex].description
                valueIndex += 1
                fieldCount += 1
                index = format.index(after: index)
                continue
            }
            if isNumericCharacter(character) {
                let start = index
                while index < format.endIndex, isNumericCharacter(format[index]) {
                    index = format.index(after: index)
                }
                let field = String(format[start..<index])
                if field.contains("#") {
                    guard valueIndex < values.count else { break }
                    output += numericField(field, value: values[valueIndex])
                    valueIndex += 1
                    fieldCount += 1
                    continue
                }
                output += field
                continue
            }
            output.append(character)
            index = format.index(after: index)
        }
        return (output, fieldCount)
    }

    private static func isNumericCharacter(_ character: Character) -> Bool {
        "#.,+$-*".contains(character)
    }

    private static func numericField(_ field: String, value: Value) -> String {
        guard case .number(let number) = value else {
            basic_rt_fail("Expected a number")
        }
        let decimalIndex = field.firstIndex(of: ".")
        let integerPattern = decimalIndex.map { String(field[..<$0]) } ?? field
        let fractionalPattern = decimalIndex.map { String(field[field.index(after: $0)...]) } ?? ""
        let fractionalDigits = fractionalPattern.filter { $0 == "#" }.count
        let usesGrouping = integerPattern.contains(",")
        let usesDollar = field.contains("$")
        let usesPlus = field.contains("+")
        let padCharacter: Character = field.contains("*") ? "*" : " "

        let absolute = abs(number)
        let scale = pow(10.0, Double(fractionalDigits))
        let roundedAbsolute = (absolute * scale).rounded() / scale
        let fixed = String(format: "%.\(fractionalDigits)f", roundedAbsolute)
        let pieces = fixed.split(separator: ".", omittingEmptySubsequences: false)
        var integerPart = String(pieces.first ?? "0")
        let fractionalPart = pieces.count > 1 ? String(pieces[1]) : ""
        if usesGrouping {
            integerPart = groupedDigits(integerPart)
        }

        var prefix = ""
        if number < 0 {
            prefix += "-"
        } else if usesPlus {
            prefix += "+"
        }
        if usesDollar {
            prefix += "$"
        }
        var rendered = prefix + integerPart
        if fractionalDigits > 0 {
            rendered += "." + fractionalPart
        }
        let width = field.count
        guard rendered.count <= width else {
            return String(repeating: "%", count: width)
        }
        return String(repeating: String(padCharacter), count: width - rendered.count) + rendered
    }

    private static func groupedDigits(_ digits: String) -> String {
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}

@_cdecl("basic_rt_using_begin")
public func basic_rt_using_begin(_ format: UnsafeMutableRawPointer?) {
    RTUsing.format = rtText(format)
    RTUsing.values = []
}

@_cdecl("basic_rt_using_number")
public func basic_rt_using_number(_ value: Double) {
    RTUsing.values.append(.number(value))
}

@_cdecl("basic_rt_using_string")
public func basic_rt_using_string(_ value: UnsafeMutableRawPointer?) {
    RTUsing.values.append(.string(rtText(value)))
}

/// Renders the collected line; `newline` is false after a trailing separator.
@_cdecl("basic_rt_using_end")
public func basic_rt_using_end(_ newline: Bool) {
    RTConsole.write(RTUsing.render(format: RTUsing.format, values: RTUsing.values))
    if newline { RTConsole.write("\n") }
}

/// `USING$`: the rendered line as an owned string.
@_cdecl("basic_rt_using_render")
public func basic_rt_using_render() -> UnsafeMutableRawPointer {
    rtOwned(RTUsing.render(format: RTUsing.format, values: RTUsing.values))
}
