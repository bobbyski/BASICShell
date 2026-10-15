import Foundation

// What a debugger shows for a value a compiled program holds (BASIC-46), in
// the words the interpreter's variables pane uses: a number as PRINT shows
// it, TRUE or FALSE, a string's text, an array's size and bounds with its
// elements under it, a record's fields, a dictionary's entries.
//
// A pointer variable is described by the runtime object it actually points
// to, not only by its declared type, so a wrong guess about the type can
// never read one kind of object as another.

/// A value as the interpreter's variables pane shows one.
public struct RTDebugValue: Sendable, Equatable {
    public let name: String
    public let typeName: String
    public let value: String
    public let children: [RTDebugValue]

    public init(name: String, typeName: String, value: String, children: [RTDebugValue] = []) {
        self.name = name
        self.typeName = typeName
        self.value = value
        self.children = children
    }
}

public enum RTDebug {
    /// The most elements of an array, or entries of a dictionary, listed
    /// under it; the rest are counted in a last line.
    public static let childLimit = 1000

    /// A number variable's value, as PRINT shows it without its spaces.
    public static func number(_ value: Double) -> String { rtNumberText(value) }

    /// What a pointer variable holds. `typeName` is its declared type (STRING,
    /// ARRAY, a record's name…), named when nothing better is known.
    public static func describe(name: String, typeName: String, pointer: UnsafeMutableRawPointer?) -> RTDebugValue {
        guard let pointer else {
            return RTDebugValue(name: name, typeName: typeName, value: typeName == "STRING" ? "" : "NULL")
        }
        // Only an object the runtime allocated is read as one: anything else
        // a debugger finds in a pointer's place is shown, never followed
        // (BASIC-53).
        guard isHeapObject(pointer) else {
            return RTDebugValue(name: name, typeName: typeName, value: "<unreadable>")
        }
        switch Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() {
        case let string as RTString: return describe(name: name, typeName: typeName, value: .string(string.value))
        case let array as RTArray: return describe(name: name, typeName: typeName, value: .array(array))
        case let composite as RTComposite: return describe(name: name, typeName: typeName, value: .composite(composite))
        case let dictionary as RTDictionary: return describe(name: name, typeName: typeName, value: .dictionary(dictionary))
        case let box as RTBox: return describe(name: name, typeName: typeName, value: box.value)
        case let closure as RTClosure: return describe(name: name, typeName: typeName, value: .closure(closure))
        case let task as RTTask: return describe(name: name, typeName: typeName, value: .task(task))
        case let object as RTSystemObject: return describe(name: name, typeName: typeName, value: .system(object))
        default: return RTDebugValue(name: name, typeName: typeName, value: "<\(typeName)>")
        }
    }

    static func describe(name: String, typeName declared: String, value: RTValue) -> RTDebugValue {
        func typed(_ actual: String) -> String { declared.isEmpty || declared == "VARIANT" ? actual : declared }
        switch value {
        case .empty: return RTDebugValue(name: name, typeName: typed("VARIANT"), value: "")
        case .null: return RTDebugValue(name: name, typeName: typed("VARIANT"), value: "NULL")
        case .number(let number): return RTDebugValue(name: name, typeName: typed("DOUBLE"), value: rtNumberText(number))
        case .string(let text): return RTDebugValue(name: name, typeName: typed("STRING"), value: text.description)
        case .boolean(let truth): return RTDebugValue(name: name, typeName: typed("BOOLEAN"), value: truth ? "TRUE" : "FALSE")
        case .date(let text), .time(let text), .datetime(let text):
            return RTDebugValue(name: name, typeName: typed("DATE"), value: text)
        case .decimal(let decimal): return RTDebugValue(name: name, typeName: typed("DECIMAL"), value: "\(decimal)")
        case .closure: return RTDebugValue(name: name, typeName: typed("FUNCTION"), value: "<FUNCTION>")
        case .task(let task): return RTDebugValue(name: name, typeName: typed("TASK"), value: "<TASK \(task.name)>")
        case .system(let object): return RTDebugValue(name: name, typeName: object.typeName, value: "<\(object.typeName)>")
        case .cell: return RTDebugValue(name: name, typeName: typed("VARIANT"), value: "<shared>")
        case .composite(let composite):
            guard composite.typeIndex >= 0, composite.typeIndex < RTTypes.registry.count,
                  let type = RTTypes.registry[composite.typeIndex] else {
                return RTDebugValue(name: name, typeName: declared, value: "<\(declared)>")
            }
            let children = zip(type.fields, composite.fields).map { field, value in
                describe(name: field.displayName, typeName: typeName(field.type), value: value)
            }
            return RTDebugValue(name: name, typeName: type.name, value: "\(children.count) fields", children: children)
        case .array(let array):
            let bounds = array.upperBounds.map { "0...\($0)" }.joined(separator: " x ")
            let elementType = typeName(array.element)
            var children = array.values.prefix(childLimit).enumerated().map { offset, element in
                describe(name: elementName(offset, upperBounds: array.upperBounds), typeName: elementType, value: element)
            }
            if array.values.count > childLimit {
                children.append(RTDebugValue(name: "…", typeName: "", value: "\(array.values.count - childLimit) more"))
            }
            return RTDebugValue(name: name, typeName: "ARRAY OF \(elementType)",
                                value: "\(array.values.count) elements (\(bounds))", children: children)
        case .dictionary(let dictionary):
            let keys = dictionary.values.keys.sorted()
            var children = keys.prefix(childLimit).map { key in
                describe(name: "\"\(key)\"", typeName: "", value: dictionary.values[key] ?? .empty)
            }
            if keys.count > childLimit {
                children.append(RTDebugValue(name: "…", typeName: "", value: "\(keys.count - childLimit) more"))
            }
            return RTDebugValue(name: name, typeName: "DICTIONARY", value: "\(keys.count) entries", children: children)
        }
    }

    /// Whether `pointer` is the start of a live heap allocation, as every
    /// runtime object is: aligned, and known to malloc.
    static func isHeapObject(_ pointer: UnsafeMutableRawPointer) -> Bool {
        guard UInt(bitPattern: pointer) % 16 == 0 else { return false }
        #if canImport(Darwin)
        return malloc_size(pointer) > 0
        #else
        return true
        #endif
    }

    /// A declared type's BASIC name.
    static func typeName(_ type: RTTypeRef) -> String {
        switch type {
        case .number: return "DOUBLE"
        case .integer: return "INTEGER"
        case .string: return "STRING"
        case .boolean: return "BOOLEAN"
        case .variant: return "VARIANT"
        case .dictionary: return "DICTIONARY"
        case .closure: return "FUNCTION"
        case .composite(let index):
            guard index >= 0, index < RTTypes.registry.count, let type = RTTypes.registry[index] else { return "TYPE" }
            return type.name
        case .array(let element, _): return "ARRAY OF \(typeName(element))"
        }
    }

    /// An element's name: `(2)`, `(1,3)`; the interpreter's `elementName`.
    static func elementName(_ offset: Int, upperBounds: [Int]) -> String {
        guard !upperBounds.isEmpty else { return "(0)" }
        var remainder = offset
        var indexes = Array(repeating: 0, count: upperBounds.count)
        for dimension in stride(from: upperBounds.count - 1, through: 0, by: -1) {
            let size = upperBounds[dimension] + 1
            indexes[dimension] = remainder % max(1, size)
            remainder /= max(1, size)
        }
        return "(\(indexes.map(String.init).joined(separator: ",")))"
    }
}
