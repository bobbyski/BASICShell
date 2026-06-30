import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class BASICRuntime {
    private var globals: [String: VariableBinding] = [:]
    private var locals: [[String: VariableBinding]] = []
    var recordDefinitions: [String: BASICRecordDefinition] = [:]
    var interfaceDefinitions: [String: BASICInterfaceDefinition] = [:]
    var classDefinitions: [String: BASICClassDefinition] = [:]
    var functionTypeDefinitions: [String: BASICFunctionTypeDefinition] = [:]
    var letMode: LetMode = .global
    var keyMode: BASICKeyMode = .aibasic
    var mouseEventMode: BASICEventInputMode = .auto
    var gamepadEventMode: BASICEventInputMode = .auto
    var randomGenerator = BASICRandomGenerator()
    var lastErrorNumber = 0
    var lastErrorLine = 0
    var lastErrorMessage = ""
    private var fileObjects: [Int: BASICOpenFile] = [:]
    private var timerObjects: [Int: BASICSecondsTimer] = [:]
    private var eventHandlers: [BASICEventSelector: BASICEventHandlerRegistration] = [:]
    private var nextFileObjectID = 1
    private var nextVectorTerminalObjectID = 1
    private var nextTimerObjectID = 1

    func resetForRun() {
        globals.removeAll()
        locals.removeAll()
        fileObjects.removeAll()
        timerObjects.removeAll()
        eventHandlers.removeAll()
        nextFileObjectID = 1
        nextVectorTerminalObjectID = 1
        nextTimerObjectID = 1
        clearLastError()
    }

    func clearAll() {
        resetForRun()
        letMode = .global
        keyMode = .aibasic
        mouseEventMode = .auto
        gamepadEventMode = .auto
    }

    func clearLastError() {
        lastErrorNumber = 0
        lastErrorLine = 0
        lastErrorMessage = ""
    }

    func setLastError(number: Int, line: Int, message: String) {
        lastErrorNumber = number
        lastErrorLine = line
        lastErrorMessage = message
    }

    func snapshotForAsyncLaunch() -> BASICRuntimeSnapshot {
        BASICRuntimeSnapshot(globals: globals, letMode: letMode, keyMode: keyMode)
    }

    func restore(snapshot: BASICRuntimeSnapshot) {
        globals = snapshot.globals
        letMode = snapshot.letMode
        keyMode = snapshot.keyMode
    }

    var eventHandlerRegistrations: [BASICEventHandlerRegistration] {
        eventHandlers.values.sorted { $0.selector.description < $1.selector.description }
    }

    func setEventHandler(selector: BASICEventSelector, handler: VariableName) {
        eventHandlers[selector] = BASICEventHandlerRegistration(
            selector: selector,
            handlerName: handler.name,
            normalizedHandlerName: handler.normalized
        )
    }

    func clearEventHandler(selector: BASICEventSelector) {
        eventHandlers.removeValue(forKey: selector)
    }

    func eventHandler(for selector: BASICEventSelector) -> BASICEventHandlerRegistration? {
        eventHandlers[selector]
    }

    func isHostInputEnabled(for selector: BASICEventSelector) -> Bool {
        let mode: BASICEventInputMode
        switch selector.type {
        case "MOUSE":
            mode = mouseEventMode
        case "GAMEPAD":
            mode = gamepadEventMode
        default:
            return true
        }

        switch mode {
        case .on:
            return true
        case .off:
            return false
        case .auto:
            if selector.subtype != nil {
                return eventHandler(for: selector) != nil
                    || eventHandler(for: BASICEventSelector(type: selector.type)) != nil
            }
            return eventHandlers.keys.contains { $0.type == selector.type }
        }
    }

    func pushLocalContext() -> Int {
        locals.append([:])
        return locals.count - 1
    }

    func popLocalContext() {
        if !locals.isEmpty {
            _ = locals.removeLast()
        }
    }

    func value(for variable: VariableName) -> BASICValue {
        if let binding = binding(for: variable.normalized) {
            return binding.value
        }
        return defaultValue(for: inferredType(name: variable.name, value: nil))
    }

    func declaredType(for reference: VariableReference) -> BASICType? {
        binding(for: reference.base.normalized)?.type
    }

    func metadata(
        for reference: VariableReference,
        indexes: [BASICValue],
        fieldIndexes: [[BASICValue]] = [],
        accessClassName: String? = nil
    ) throws -> BASICValue {
        let binding = binding(for: reference.base.normalized)
        var displayName = binding?.displayName ?? reference.base.name
        var currentType = binding?.type ?? inferredType(name: reference.base.name, value: binding?.value)
        var currentValue = binding?.value ?? defaultValue(for: currentType)
        var metadata: BASICMetadata = [:]
        var path = displayName
        var parentPath: String?
        var indexDescription: String?

        if !indexes.isEmpty {
            let indexed = try reflectedIndexedValue(
                currentValue,
                indexes: indexes,
                name: displayName
            )
            currentValue = indexed.value
            currentType = indexed.type
            indexDescription = reflectionIndexDescription(indexes)
        }

        for (fieldIndex, fieldName) in reference.fields.enumerated() {
            guard let composite = currentValue.compositeFields else {
                throw BASICError.runtime("\(reference.base.name) has no field \(fieldName)")
            }
            let (recordName, fields) = composite
            let lookupTypeName = fieldIndex == 0 ? fieldSurfaceType(for: reference)?.name ?? recordName : recordName
            try validateFieldAccess(typeName: lookupTypeName, fieldName: fieldName, accessClassName: accessClassName)
            guard let field = compositeFieldDefinitions(for: lookupTypeName).first(where: { $0.normalizedName == fieldName.uppercased() }) else {
                throw BASICError.runtime("\(fieldLookupTypeName(fieldSurfaceType(for: reference), fallbackTypeName: recordName)) has no field \(fieldName)")
            }

            parentPath = path
            displayName = field.displayName
            metadata = field.metadata
            path = "\(path).\(displayName)"
            currentType = field.type
            currentValue = fields[field.normalizedName] ?? defaultValue(for: field)

            let indexes = fieldIndexes.indices.contains(fieldIndex) ? fieldIndexes[fieldIndex] : []
            if !indexes.isEmpty {
                let indexed = try reflectedIndexedValue(
                    currentValue,
                    indexes: indexes,
                    name: field.displayName
                )
                currentValue = indexed.value
                currentType = indexed.type
                indexDescription = reflectionIndexDescription(indexes)
            } else {
                indexDescription = nil
            }
        }

        return reflectionDictionary(
            metadata: metadata,
            name: displayName,
            typeName: reflectionTypeName(type: currentType, value: currentValue),
            path: path,
            parent: parentPath,
            index: indexDescription
        )
    }

    func reflectedFieldCount(for value: BASICValue) throws -> Int {
        try reflectedFields(for: value).count
    }

    func reflectedFieldName(for value: BASICValue, selector: BASICValue) throws -> String {
        try reflectedField(for: value, selector: selector).displayName
    }

    func reflectedFieldMetadata(for value: BASICValue, selector: BASICValue) throws -> BASICValue {
        let field = try reflectedField(for: value, selector: selector)
        return reflectionDictionary(
            metadata: field.metadata,
            name: field.displayName,
            typeName: field.type.name,
            path: field.displayName,
            parent: nil,
            index: nil
        )
    }

    func reflectedFieldValue(for value: BASICValue, selector: BASICValue) throws -> BASICValue {
        let composite = try reflectedComposite(for: value)
        let field = try reflectedField(for: value, selector: selector)
        return composite.fields[field.normalizedName] ?? defaultValue(for: field)
    }

    func settingReflectedField(value: BASICValue, selector: BASICValue, newValue: BASICValue) throws -> BASICValue {
        let composite = try reflectedComposite(for: value)
        let field = try reflectedField(for: value, selector: selector)
        var fields = composite.fields
        fields[field.normalizedName] = try coerceReflectedValue(newValue, to: field)
        switch value {
        case .record(let name, _):
            return .record(name, fields)
        case .object(let name, _):
            return .object(name, fields)
        default:
            throw BASICError.runtime("SETFIELD expects a record or object")
        }
    }

    private func reflectedComposite(for value: BASICValue) throws -> (name: String, fields: [String: BASICValue]) {
        guard let composite = value.compositeFields else {
            throw BASICError.runtime("Reflection expects a record or object")
        }
        return composite
    }

    private func reflectedFields(for value: BASICValue) throws -> [BASICClassField] {
        let composite = try reflectedComposite(for: value)
        return compositeFieldDefinitions(for: composite.name)
    }

    private func reflectedField(for value: BASICValue, selector: BASICValue) throws -> BASICClassField {
        let fields = try reflectedFields(for: value)
        if let number = selector.number {
            guard number.rounded() == number else {
                throw BASICError.runtime("Field index must be an integer")
            }
            let index = Int(number)
            guard fields.indices.contains(index) else {
                throw BASICError.runtime("Field index out of range")
            }
            return fields[index]
        }
        if let name = selector.string?.description {
            guard let field = fields.first(where: { $0.normalizedName == name.uppercased() }) else {
                throw BASICError.runtime("Unknown field \(name)")
            }
            return field
        }
        throw BASICError.runtime("Field selector must be a number or string")
    }

    private func coerceReflectedValue(_ value: BASICValue, to field: BASICClassField) throws -> BASICValue {
        if case .string(let string) = value {
            let text = string.description.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.type {
            case .scalar(.integer), .scalar(.double):
                if let number = Double(text) {
                    return try coerce(.number(number), to: field, variable: VariableName(name: field.displayName, column: 0))
                }
            case .scalar(.boolean):
                switch text.uppercased() {
                case "TRUE": return try coerce(.boolean(true), to: field, variable: VariableName(name: field.displayName, column: 0))
                case "FALSE": return try coerce(.boolean(false), to: field, variable: VariableName(name: field.displayName, column: 0))
                case "1": return try coerce(.number(1), to: field, variable: VariableName(name: field.displayName, column: 0))
                case "0": return try coerce(.number(0), to: field, variable: VariableName(name: field.displayName, column: 0))
                default: break
                }
            default:
                break
            }
        }
        return try coerce(value, to: field, variable: VariableName(name: field.displayName, column: 0))
    }

    static func isBuiltInClass(_ name: String) -> Bool {
        switch name.uppercased() {
        case "FILE", "VECTORTERMINAL", "VTG", "SECONDSTIMER",
            "BASICEVENT", "BASICRESIZEEVENT", "BASICMOUSEEVENT", "BASICTIMEREVENT", "BASICGAMEPADEVENT", "BASICFRAMEEVENT", "BASICROUTEEVENT", "BASICNETWORKEVENT":
            return true
        default:
            return false
        }
    }

    func fileObject(isOpen: Bool = false) -> BASICValue {
        let id = nextFileObjectID
        nextFileObjectID += 1
        fileObjects[id] = BASICOpenFile(isOpen: isOpen)
        return .systemObject("File", id)
    }

    func vectorTerminalObject() -> BASICValue {
        let id = nextVectorTerminalObjectID
        nextVectorTerminalObjectID += 1
        return .systemObject("VectorTerminal", id)
    }

    func secondsTimerObject(intervalSeconds: Double) -> BASICValue {
        let id = nextTimerObjectID
        nextTimerObjectID += 1
        timerObjects[id] = BASICSecondsTimer(intervalSeconds: intervalSeconds)
        return .systemObject("SecondsTimer", id)
    }

    func runningSecondsTimers() -> [(id: Int, intervalSeconds: Double, repeating: Bool)] {
        timerObjects.compactMap { id, timer in
            guard timer.isRunning else { return nil }
            return (id: id, intervalSeconds: timer.intervalSeconds, repeating: timer.repeating)
        }
    }

    func value(
        for reference: VariableReference,
        indexes: [BASICValue],
        fieldIndexes: [[BASICValue]] = [],
        accessClassName: String? = nil
    ) throws -> BASICValue {
        let declaredFieldType = fieldSurfaceType(for: reference)
        var value: BASICValue
        if !indexes.isEmpty, binding(for: reference.base.normalized) == nil {
            value = try createImplicitArray(for: reference.base, rank: indexes.count).value
        } else {
            value = self.value(for: reference.base)
        }
        if !indexes.isEmpty {
            switch value {
            case .array(let array):
                value = try arrayValue(array, at: indexes, name: reference.base.name)
            case .dictionary(let dictionary):
                value = try dictionaryValue(dictionary, at: indexes, name: reference.base.name)
            default:
                throw BASICError.runtime("\(reference.base.name) is not an array")
            }
        }
        for (fieldIndex, field) in reference.fields.enumerated() {
            if case .systemObject(let typeName, let id) = value {
                guard reference.fields.count == 1 else {
                    throw BASICError.runtime("\(typeName) has no field \(field)")
                }
                value = try systemObjectProperty(typeName: typeName, id: id, property: field)
                continue
            }
            guard let composite = value.compositeFields else {
                throw BASICError.runtime("\(reference.base.name) has no field \(field)")
            }
            let (recordName, fields) = composite
            let normalized = field.uppercased()
            let lookupTypeName = fieldIndex == 0 ? declaredFieldType?.name ?? recordName : recordName
            try validateFieldAccess(typeName: lookupTypeName, fieldName: field, accessClassName: accessClassName)
            guard fieldExists(typeName: lookupTypeName, fieldName: field) else {
                throw BASICError.runtime("\(fieldLookupTypeName(declaredFieldType, fallbackTypeName: recordName)) has no field \(field)")
            }
            guard let fieldValue = fields[normalized] else {
                throw BASICError.runtime("\(recordName) has no field \(field)")
            }
            value = fieldValue
            let indexes = fieldIndexes.indices.contains(fieldIndex) ? fieldIndexes[fieldIndex] : []
            if !indexes.isEmpty {
                switch value {
                case .array(let array):
                    value = try arrayValue(array, at: indexes, name: field)
                case .dictionary(let dictionary):
                    value = try dictionaryValue(dictionary, at: indexes, name: field)
                default:
                    throw BASICError.runtime("\(field) is not an array")
                }
            }
        }
        return value
    }

    func callSystemObjectMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue],
        fileHost: BASICFileHost? = nil,
        vectorTerminalHost: BASICVectorTerminalHost? = nil,
        timerHost: BASICTimerHost? = nil,
        jsonDecoder: ((String) throws -> BASICValue)? = nil,
        jsonEncoder: ((BASICValue, Bool) throws -> String)? = nil
    ) throws -> BASICValue {
        switch typeName.uppercased() {
        case "FILE":
            return try callFileMethod(id: id, method: method, arguments: arguments, fileHost: fileHost, jsonDecoder: jsonDecoder, jsonEncoder: jsonEncoder)
        case "VECTORTERMINAL", "VTG":
            return try callVectorTerminalMethod(method: method, arguments: arguments, host: vectorTerminalHost)
        case "SECONDSTIMER":
            return try callSecondsTimerMethod(id: id, method: method, arguments: arguments, host: timerHost)
        default:
            throw BASICError.runtime("\(typeName) has no method \(method)")
        }
    }

    func timerHandlerRegistrations(forTimerID id: Int) -> [(registration: BASICEventHandlerRegistration, ticks: Int)] {
        let prefix = "\(id):"
        return eventHandlerRegistrations.compactMap { registration in
            guard registration.selector.type == "TIMER",
                  let subtype = registration.selector.subtype,
                  subtype.hasPrefix(prefix),
                  let ticks = Int(subtype.dropFirst(prefix.count)) else {
                return nil
            }
            return (registration, max(1, ticks))
        }
    }

    func setTimerEventHandler(id: Int, ticks: Int, handler: VariableName) throws {
        guard timerObjects[id] != nil else {
            throw BASICError.runtime("Timer is not defined")
        }
        let tickCount = max(1, ticks)
        setEventHandler(
            selector: BASICEventSelector(type: "TIMER", subtype: "\(id):\(tickCount)"),
            handler: handler
        )
    }

    private func systemObjectProperty(typeName: String, id: Int, property: String) throws -> BASICValue {
        switch typeName.uppercased() {
        case "SECONDSTIMER":
            guard let timer = timerObjects[id] else {
                throw BASICError.runtime("Timer is not defined")
            }
            switch property.uppercased() {
            case "INTERVAL", "INTERVALSECONDS":
                return .number(timer.intervalSeconds)
            case "REPEATING":
                return .boolean(timer.repeating)
            case "RUNNING", "ISRUNNING":
                return .boolean(timer.isRunning)
            default:
                throw BASICError.runtime("\(typeName) has no property \(property)")
            }
        default:
            throw BASICError.runtime("\(typeName) has no property \(property)")
        }
    }

    private func assignSystemObjectProperty(typeName: String, id: Int, reference: VariableReference, value: BASICValue?) throws {
        guard reference.fields.count == 1, reference.indexes.isEmpty else {
            throw BASICError.runtime("\(typeName) has no writable field \(reference.fields.joined(separator: "."))")
        }
        switch typeName.uppercased() {
        case "SECONDSTIMER":
            guard var timer = timerObjects[id] else {
                throw BASICError.runtime("Timer is not defined")
            }
            let field = reference.fields[0].uppercased()
            switch field {
            case "INTERVAL", "INTERVALSECONDS":
                timer.intervalSeconds = try doubleValue(value ?? .empty)
            case "REPEATING":
                timer.repeating = try boolValue(value ?? .empty)
            case "RUNNING", "ISRUNNING":
                timer.isRunning = try boolValue(value ?? .empty)
            case "HANDLER":
                throw BASICError.runtime("Timer handler assignment is not implemented; use ON timer GOSUB handler")
            default:
                throw BASICError.runtime("\(typeName) has no property \(reference.fields[0])")
            }
            timerObjects[id] = timer
        default:
            throw BASICError.runtime("\(typeName) has no writable property \(reference.fields[0])")
        }
    }

    private func callSecondsTimerMethod(id: Int, method: String, arguments: [BASICValue], host: BASICTimerHost?) throws -> BASICValue {
        guard var timer = timerObjects[id] else {
            throw BASICError.runtime("Timer is not defined")
        }
        switch method.uppercased() {
        case "START":
            try requireArgumentCount(arguments, 0, method: "start")
            guard let host else {
                throw BASICError.runtime("Timers are not supported by this host")
            }
            guard timer.intervalSeconds > 0 else {
                throw BASICError.runtime("SecondsTimer interval must be greater than zero")
            }
            timer.isRunning = true
            timerObjects[id] = timer
            host.startTimer(id: id, intervalSeconds: timer.intervalSeconds, repeating: timer.repeating)
        case "STOP", "CANCEL":
            try requireArgumentCount(arguments, 0, method: "stop")
            timer.isRunning = false
            timerObjects[id] = timer
            host?.stopTimer(id: id)
        default:
            throw BASICError.runtime("SecondsTimer has no method \(method)")
        }
        return .empty
    }

    func localSnapshots() -> [BASICVariableSnapshot] {
        guard let local = locals.last else { return [] }
        return snapshots(from: local, scope: .local)
    }

    func localSnapshots(depthFromTop: Int) -> [BASICVariableSnapshot] {
        let index = locals.count - 1 - depthFromTop
        guard locals.indices.contains(index) else { return [] }
        return snapshots(from: locals[index], scope: .local)
    }

    func localSnapshots(contextIndex: Int) -> [BASICVariableSnapshot] {
        guard locals.indices.contains(contextIndex) else { return [] }
        return snapshots(from: locals[contextIndex], scope: .local)
    }

    func globalSnapshots() -> [BASICVariableSnapshot] {
        snapshots(from: globals, scope: .global)
    }

    func jsonString(for value: BASICValue, pretty: Bool) throws -> String {
        let object = try jsonObject(for: value, declaredType: inferredType(name: "", value: value))
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty {
            options.insert(.prettyPrinted)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    func valueFromJSONString(_ source: String, permissive: Bool) throws -> BASICValue {
        var options: JSONSerialization.ReadingOptions = []
        if permissive {
            options.insert(.fragmentsAllowed)
        }
        let data = Data(source.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: options)
        return try basicValue(fromJSONObject: object)
    }

    func assign(
        kind: AssignmentKind,
        variable: VariableName,
        declaredType: BASICType?,
        value: BASICValue?
    ) throws {
        try validateSuffix(variable: variable, declaredType: declaredType)
        let normalized = variable.normalized
        let target = targetContext(kind: kind, normalized: normalized)
        let existing = binding(in: target, normalized: normalized)
        let type = try resolvedType(variable: variable, declaredType: declaredType, value: value, existing: existing)
        if case .array(let existingArray) = existing?.value, let value {
            let coercedArray = try coerceArray(value, toMatch: existingArray, variable: variable)
            let binding = VariableBinding(displayName: variable.name, type: existingArray.type, value: .array(coercedArray))
            set(binding, in: target, normalized: normalized)
            return
        }
        let coerced = try coerce(value ?? defaultValue(for: type), to: type, variable: variable)
        let binding = VariableBinding(displayName: variable.name, type: type, value: coerced)
        set(binding, in: target, normalized: normalized)
    }

    func dim(kind: AssignmentKind, variable: VariableName, dimensions: [Int?], declaredType: BASICType?) throws {
        try validateSuffix(variable: variable, declaredType: declaredType)
        guard !dimensions.isEmpty else {
            let type = resolvedDeclaredType(declaredType ?? inferredType(name: variable.name, value: nil))
            let binding = VariableBinding(displayName: variable.name, type: type, value: defaultValue(for: type))
            set(binding, in: targetContext(kind: kind, normalized: variable.normalized), normalized: variable.normalized)
            return
        }
        guard dimensions.allSatisfy({ ($0 ?? 0) >= 0 }) else {
            throw BASICError.runtime("DIM bounds must be non-negative")
        }
        let type = resolvedDeclaredType(declaredType ?? inferredType(name: variable.name, value: nil))
        let resolvedDimensions = dimensions.map { $0 ?? -1 }
        let elementCount = resolvedDimensions.contains(-1) ? 0 : resolvedDimensions.reduce(1) { $0 * ($1 + 1) }
        let array = BASICArray(
            dimensions: resolvedDimensions,
            type: type,
            isDynamic: dimensions.contains(where: { $0 == nil }),
            values: Array(repeating: defaultValue(for: type), count: elementCount)
        )
        let binding = VariableBinding(displayName: variable.name, type: type, value: .array(array))
        set(binding, in: targetContext(kind: kind, normalized: variable.normalized), normalized: variable.normalized)
    }

    func assign(
        reference: VariableReference,
        indexes: [BASICValue],
        fieldIndexes: [[BASICValue]] = [],
        value: BASICValue?,
        accessClassName: String? = nil
    ) throws {
        guard !reference.isSimple else {
            try assign(kind: .bare, variable: reference.base, declaredType: nil, value: value)
            return
        }

        let normalized = reference.base.normalized
        let context = targetContext(kind: .bare, normalized: normalized)
        var binding: VariableBinding
        if let existing = self.binding(in: context, normalized: normalized) {
            binding = existing
        } else if !indexes.isEmpty {
            binding = try createImplicitArray(for: reference.base, rank: indexes.count, in: context)
        } else {
            throw BASICError.runtime("\(reference.base.name) is not defined")
        }

        if !indexes.isEmpty {
            switch binding.value {
            case .array(var array):
                let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: reference.base.name)
                if reference.fields.isEmpty {
                    array.values[offset] = try coerce(value ?? defaultValue(for: array.type), to: array.type, variable: reference.base)
                } else {
                    array.values[offset] = try assigningField(
                        reference.fields,
                        fieldIndexes: fieldIndexes,
                        in: array.values[offset],
                        value: value,
                        accessClassName: accessClassName,
                        declaredType: fieldSurfaceType(for: reference)
                    )
                }
                binding.value = .array(array)
                set(binding, in: context, normalized: normalized)
                return
            case .dictionary(var dictionary):
                let key = try dictionaryKey(from: indexes, name: reference.base.name)
                let currentValue = dictionary.values[key] ?? .empty
                if reference.fields.isEmpty {
                    dictionary.values[key] = value ?? .empty
                } else {
                    dictionary.values[key] = try assigningField(
                        reference.fields,
                        fieldIndexes: fieldIndexes,
                        in: currentValue,
                        value: value,
                        accessClassName: accessClassName,
                        declaredType: fieldSurfaceType(for: reference)
                    )
                }
                binding.value = .dictionary(dictionary)
                set(binding, in: context, normalized: normalized)
                return
            default:
                throw BASICError.runtime("\(reference.base.name) is not an array")
            }
        }

        if case .systemObject(let typeName, let id) = binding.value {
            try assignSystemObjectProperty(typeName: typeName, id: id, reference: reference, value: value)
        } else {
            binding.value = try assigningField(
                reference.fields,
                fieldIndexes: fieldIndexes,
                in: binding.value,
                value: value,
                accessClassName: accessClassName,
                declaredType: fieldSurfaceType(for: reference)
            )
        }
        set(binding, in: context, normalized: normalized)
    }

    private enum TargetContext {
        case global
        case local(Int)
    }

    private func targetContext(kind: AssignmentKind, normalized: String) -> TargetContext {
        switch kind {
        case .global:
            return .global
        case .local:
            return locals.indices.last.map(TargetContext.local) ?? .global
        case .letValue:
            switch letMode {
            case .global:
                return .global
            case .local:
                return locals.indices.last.map(TargetContext.local) ?? .global
            }
        case .bare:
            if let visible = visibleContext(for: normalized) {
                return visible
            }
            switch letMode {
            case .global:
                return .global
            case .local:
                return locals.indices.last.map(TargetContext.local) ?? .global
            }
        }
    }

    private func visibleContext(for normalized: String) -> TargetContext? {
        for index in locals.indices.reversed() {
            if locals[index][normalized] != nil {
                return .local(index)
            }
        }
        if globals[normalized] != nil {
            return .global
        }
        return nil
    }

    private func binding(for normalized: String) -> VariableBinding? {
        if let context = visibleContext(for: normalized) {
            return binding(in: context, normalized: normalized)
        }
        return nil
    }

    private func binding(in context: TargetContext, normalized: String) -> VariableBinding? {
        switch context {
        case .global: return globals[normalized]
        case .local(let index): return locals[index][normalized]
        }
    }

    private func set(_ binding: VariableBinding, in context: TargetContext, normalized: String) {
        switch context {
        case .global:
            globals[normalized] = binding
        case .local(let index):
            locals[index][normalized] = binding
        }
    }

    @discardableResult
    private func createImplicitArray(
        for variable: VariableName,
        rank: Int,
        in context: TargetContext? = nil
    ) throws -> VariableBinding {
        let target = context ?? targetContext(kind: .bare, normalized: variable.normalized)
        let type = resolvedDeclaredType(inferredType(name: variable.name, value: nil))
        try validateSuffix(variable: variable, declaredType: type)
        let dimensions = Array(repeating: 10, count: rank)
        let count = dimensions.reduce(1) { $0 * ($1 + 1) }
        let binding = VariableBinding(
            displayName: variable.name,
            type: type,
            value: .array(BASICArray(
                dimensions: dimensions,
                type: type,
                isDynamic: false,
                values: Array(repeating: defaultValue(for: type), count: count)
            ))
        )
        set(binding, in: target, normalized: variable.normalized)
        return binding
    }

    private func jsonObject(for value: BASICValue, declaredType: BASICType) throws -> Any {
        switch value {
        case .empty, .null:
            return NSNull()
        case .number(let number):
            return number
        case .string(let string):
            return string.rawString
        case .boolean(let boolean):
            return boolean
        case .systemObject, .closure:
            throw BASICError.runtime("System objects cannot be encoded as JSON")
        case .array(let array):
            return try jsonArrayObject(for: array)
        case .dictionary(let dictionary):
            var object: [String: Any] = [:]
            for key in dictionary.values.keys.sorted() {
                object[key] = try jsonObject(for: dictionary.values[key] ?? .empty, declaredType: inferredType(name: key, value: dictionary.values[key]))
            }
            return object
        case .record(let name, let fields):
            let definition = recordDefinitions[name.uppercased()]
            var object: [String: Any] = [:]
            for field in definition?.fields ?? [] {
                guard let json = field.json else { continue }
                let fieldValue = fields[field.normalizedName] ?? defaultValue(for: field)
                object[json.name] = try jsonObject(for: fieldValue, declaredType: field.type)
            }
            return object
        case .object(let name, let fields):
            guard let definition = classDefinitions[name.uppercased()] else { return [:] }
            var object: [String: Any] = [:]
            for field in inheritedFields(for: definition) {
                guard let json = field.json else { continue }
                let fieldValue = fields[field.normalizedName] ?? defaultValue(for: field)
                object[json.name] = try jsonObject(for: fieldValue, declaredType: field.type)
            }
            return object
        }
    }

    private func basicValue(fromJSONObject object: Any) throws -> BASICValue {
        if object is NSNull {
            return .null
        }
        if let string = object as? String {
            return .string(BASICString(string))
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let array = object as? [Any] {
            return .array(BASICArray(
                dimensions: [array.count - 1],
                type: .scalar(.variant),
                isDynamic: true,
                values: try array.map(basicValue(fromJSONObject:))
            ))
        }
        if let dictionary = object as? [String: Any] {
            var values: [String: BASICValue] = [:]
            for key in dictionary.keys.sorted() {
                values[key] = try basicValue(fromJSONObject: dictionary[key] as Any)
            }
            return .dictionary(BASICDictionary(values: values))
        }
        throw BASICError.runtime("Unsupported JSON value")
    }

    private func jsonArrayObject(for array: BASICArray) throws -> Any {
        guard array.dimensions.count > 1 else {
            return try array.values.map { try jsonObject(for: $0, declaredType: array.type) }
        }
        return try jsonArraySlice(for: array, dimension: 0, offset: 0).value
    }

    private func jsonArraySlice(for array: BASICArray, dimension: Int, offset: Int) throws -> (value: Any, nextOffset: Int) {
        let count = max(0, array.dimensions[dimension] + 1)
        var values: [Any] = []
        var cursor = offset
        if dimension == array.dimensions.count - 1 {
            for _ in 0..<count {
                values.append(try jsonObject(for: array.values[cursor], declaredType: array.type))
                cursor += 1
            }
            return (values, cursor)
        }
        for _ in 0..<count {
            let child = try jsonArraySlice(for: array, dimension: dimension + 1, offset: cursor)
            values.append(child.value)
            cursor = child.nextOffset
        }
        return (values, cursor)
    }

    private func resolvedType(
        variable: VariableName,
        declaredType: BASICType?,
        value: BASICValue?,
        existing: VariableBinding?
    ) throws -> BASICType {
        if let declaredType {
            let resolvedDeclaredType = resolvedDeclaredType(declaredType)
            if let existing, existing.type != resolvedDeclaredType {
                throw BASICError.type(message: "Cannot redeclare \(variable.name) as \(resolvedDeclaredType.name)")
            }
            return resolvedDeclaredType
        }
        if let existing {
            return existing.type
        }
        return inferredType(name: variable.name, value: value)
    }

    private func resolvedDeclaredType(_ type: BASICType) -> BASICType {
        if case .record(let name) = type, classDefinitions[name.uppercased()] != nil || Self.isBuiltInClass(name) {
            return .classType(name)
        }
        if case .record(let name) = type, interfaceDefinitions[name.uppercased()] != nil {
            return .interfaceType(name)
        }
        if case .record(let name) = type, functionTypeDefinitions[name.uppercased()] != nil {
            return .functionType(name)
        }
        return type
    }

    private func inferredType(name: String, value: BASICValue?) -> BASICType {
        if let suffixType = suffixType(for: name) {
            return suffixType
        }
        if let value {
            switch value {
            case .empty, .null: return .scalar(.variant)
            case .string: return .scalar(.string)
            case .boolean: return .scalar(.boolean)
            case .number(let number) where number.rounded() != number:
                return .scalar(.double)
            case .number:
                return .scalar(.double)
            case .record(let name, _):
                return .record(name)
            case .object(let name, _):
                return .classType(name)
            case .systemObject(let name, _):
                return .classType(name)
            case .closure:
                return .scalar(.variant)
            case .array(let array):
                return array.type
            case .dictionary:
                return .dictionary
            }
        }
        return .scalar(.double)
    }

    private func suffixType(for name: String) -> BASICType? {
        switch name.last {
        case "$": return .scalar(.string)
        case "%": return .scalar(.integer)
        case "#": return .scalar(.double)
        default: return nil
        }
    }

    private func validateSuffix(variable: VariableName, declaredType: BASICType?) throws {
        guard let declaredType, let suffixType = suffixType(for: variable.name), suffixType != declaredType else {
            return
        }
        throw BASICError.type(message: "suffix \(variable.name.last!) conflicts with AS \(declaredType.name)")
    }

    func coerce(_ value: BASICValue, to type: BASICType, variable: VariableName) throws -> BASICValue {
        if case .functionType(let name) = type {
            if case .empty = value {
                return .empty
            }
            guard let definition = functionTypeDefinitions[name.uppercased()] else {
                throw BASICError.type(message: "Type Mismatch")
            }
            guard case .closure(let closure) = value,
                  closure.matchesSignature(of: definition) else {
                throw BASICError.type(message: "Type Mismatch")
            }
            return value
        }
        if case .record(let name) = type {
            if case .record(let valueName, _) = value, valueName.uppercased() == name.uppercased() {
                return value
            }
            if case .dictionary(let dictionary) = value {
                return try decodeRecord(name: name, from: dictionary, variable: variable)
            }
            if case .object(let valueName, let fields) = value, valueName.uppercased() == name.uppercased() {
                return .record(valueName, fields)
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-\(name) value to \(variable.name)")
        }
        if case .classType(let name) = type {
            if let expected = Self.builtInEventClassName(name) {
                if case .null = value {
                    return .null
                }
                if case .empty = value {
                    return defaultValue(for: type)
                }
                if case .object(let valueName, _) = value,
                   valueName.uppercased() == expected || Self.isBuiltInEventClass(valueName, subclassOf: expected) {
                    return value
                }
                throw BASICError.type(message: "Type Mismatch")
            }
            if Self.isBuiltInClass(name), case .systemObject(let valueName, _) = value, valueName.uppercased() == name.uppercased() {
                return value
            }
            if case .null = value {
                return .null
            }
            if case .dictionary(let dictionary) = value {
                return try decodeObject(name: name, from: dictionary, variable: variable)
            }
            if case .object(let valueName, _) = value {
                if valueName.uppercased() == name.uppercased() || isClass(valueName, subclassOf: name) {
                    return value
                }
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-\(name) object to \(variable.name)")
        }
        if case .interfaceType(let name) = type {
            if case .null = value {
                return .null
            }
            if case .object(let valueName, _) = value,
               classConforms(valueName, toInterface: name) {
                return value
            }
            if case .empty = value {
                return .empty
            }
            throw BASICError.type(message: "Cannot assign non-\(name) object to \(variable.name)")
        }
        if case .dictionary = type {
            if case .dictionary = value {
                return value
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-dictionary value to \(variable.name)")
        }
        guard case .scalar(let scalar) = type else {
            throw BASICError.type(message: "Cannot assign aggregate type \(type.name) yet")
        }
        switch scalar {
        case .variant:
            return value
        case .string:
            guard let string = value.string else {
                throw BASICError.type(message: "Cannot assign non-string value to \(variable.name)")
            }
            return .string(string)
        case .double:
            guard let number = value.number else {
                throw BASICError.type(message: "Cannot assign non-numeric value to \(variable.name)")
            }
            return .number(number)
        case .integer:
            guard let number = value.number else {
                throw BASICError.type(message: "Cannot assign non-numeric value to \(variable.name)")
            }
            guard number.rounded() == number else {
                throw BASICError.type(message: "Cannot assign non-integer value to \(variable.name)")
            }
            return .number(number)
        case .boolean:
            if case .boolean = value {
                return value
            }
            guard let number = value.number, number == 0 || number == 1 else {
                throw BASICError.type(message: "Boolean \(variable.name) must be FALSE, TRUE, 0, or 1")
            }
            return .boolean(number == 1)
        }
    }

    private func decodeRecord(name: String, from dictionary: BASICDictionary, variable: VariableName) throws -> BASICValue {
        guard let definition = recordDefinitions[name.uppercased()] else {
            throw BASICError.runtime("Type Mismatch")
        }
        var fields = defaultValue(for: .record(name)).compositeFields?.fields ?? [:]
        for field in definition.fields {
            guard let json = field.json, let sourceValue = dictionary.values[json.name] else { continue }
            do {
                fields[field.normalizedName] = try coerce(sourceValue, to: field, variable: VariableName(name: field.displayName, column: variable.column))
            } catch {
                throw BASICError.runtime("Type Mismatch")
            }
        }
        return .record(definition.displayName, fields)
    }

    private func decodeObject(name: String, from dictionary: BASICDictionary, variable: VariableName) throws -> BASICValue {
        guard let definition = classDefinitions[name.uppercased()] else {
            throw BASICError.runtime("Type Mismatch")
        }
        var fields = defaultValue(for: .classType(name)).compositeFields?.fields ?? [:]
        for field in inheritedFields(for: definition) {
            guard let json = field.json, let sourceValue = dictionary.values[json.name] else { continue }
            do {
                fields[field.normalizedName] = try coerce(sourceValue, to: field, variable: VariableName(name: field.displayName, column: variable.column))
            } catch {
                throw BASICError.runtime("Type Mismatch")
            }
        }
        return .object(definition.displayName, fields)
    }

    private func coerceArray(_ value: BASICValue, toMatch existingArray: BASICArray, variable: VariableName) throws -> BASICArray {
        guard case .array(let sourceArray) = value else {
            throw BASICError.runtime("Type Mismatch")
        }
        do {
            let shape = try arrayShape(from: sourceArray, rank: existingArray.dimensions.count)
            let dimensions: [Int]
            if existingArray.isDynamic {
                dimensions = try zip(existingArray.dimensions, shape).map { existing, decoded in
                    if existing >= 0, existing != decoded {
                        throw BASICError.runtime("Type Mismatch")
                    }
                    return existing >= 0 ? existing : decoded
                }
            } else {
                guard shape == existingArray.dimensions else {
                    throw BASICError.runtime("Type Mismatch")
                }
                dimensions = existingArray.dimensions
            }
            let sourceValues = try flattenedArrayValues(from: sourceArray, rank: existingArray.dimensions.count)
            return BASICArray(
                dimensions: dimensions,
                type: existingArray.type,
                isDynamic: existingArray.isDynamic,
                values: try sourceValues.map {
                    try coerce($0, to: existingArray.type, variable: variable)
                }
            )
        } catch {
            throw BASICError.runtime("Type Mismatch")
        }
    }

    private func arrayShape(from array: BASICArray, rank: Int) throws -> [Int] {
        guard rank > 0 else { throw BASICError.runtime("Type Mismatch") }
        if rank == 1 {
            return [array.values.count - 1]
        }
        guard let first = array.values.first else {
            return Array(repeating: -1, count: rank)
        }
        guard case .array(let firstArray) = first else {
            throw BASICError.runtime("Type Mismatch")
        }
        let childShape = try arrayShape(from: firstArray, rank: rank - 1)
        for value in array.values.dropFirst() {
            guard case .array(let childArray) = value,
                  try arrayShape(from: childArray, rank: rank - 1) == childShape else {
                throw BASICError.runtime("Type Mismatch")
            }
        }
        return [array.values.count - 1] + childShape
    }

    private func flattenedArrayValues(from array: BASICArray, rank: Int) throws -> [BASICValue] {
        guard rank > 0 else { throw BASICError.runtime("Type Mismatch") }
        if rank == 1 {
            return array.values
        }
        var values: [BASICValue] = []
        for value in array.values {
            guard case .array(let childArray) = value else {
                throw BASICError.runtime("Type Mismatch")
            }
            values.append(contentsOf: try flattenedArrayValues(from: childArray, rank: rank - 1))
        }
        return values
    }

    private func coerce(_ value: BASICValue, to field: BASICRecordField, variable: VariableName) throws -> BASICValue {
        if !field.arrayDimensions.isEmpty {
            guard case .array(let defaultArray) = defaultValue(for: field) else {
                throw BASICError.runtime("Type Mismatch")
            }
            return .array(try coerceArray(value, toMatch: defaultArray, variable: variable))
        }
        return try coerce(value, to: field.type, variable: variable)
    }

    private func coerce(_ value: BASICValue, to field: BASICClassField, variable: VariableName) throws -> BASICValue {
        if !field.arrayDimensions.isEmpty {
            guard case .array(let defaultArray) = defaultValue(for: field) else {
                throw BASICError.runtime("Type Mismatch")
            }
            return .array(try coerceArray(value, toMatch: defaultArray, variable: variable))
        }
        return try coerce(value, to: field.type, variable: variable)
    }

    private func callFileMethod(id: Int, method: String, arguments: [BASICValue], fileHost: BASICFileHost?, jsonDecoder: ((String) throws -> BASICValue)?, jsonEncoder: ((BASICValue, Bool) throws -> String)?) throws -> BASICValue {
        let normalized = method.uppercased()
        guard var file = fileObjects[id] else {
            throw BASICError.runtime("Bad file object")
        }

        func requireHost() throws -> BASICFileHost {
            guard let fileHost else { throw BASICError.runtime("File I/O is not supported by this host") }
            return fileHost
        }

        func requireOpen() throws {
            guard file.isOpen else { throw BASICError.runtime("File is not open") }
        }

        func requireAccess(_ allowed: Set<BASICFileAccess>) throws {
            guard let access = file.access, allowed.contains(access) else {
                throw BASICError.runtime("Bad file mode")
            }
        }

        switch normalized {
        case "OPEN":
            guard arguments.count == 4 else { throw BASICError.runtime("open expects 4 arguments") }
            guard !file.isOpen else { throw BASICError.runtime("File Already Open") }
            let path = try filePath(from: arguments[0])
            let access = try fileAccess(from: arguments[1])
            let contentType = try fileContentType(from: arguments[2])
            let requireNew = try fileBoolean(from: arguments[3])
            let host = try requireHost()
            let exists = try host.fileExists(path: path)
            if requireNew && exists {
                throw BASICError.runtime("File Already Exists")
            }
            if access == .read && !exists {
                throw BASICError.runtime("File Not Found")
            }
            let initialContent: BASICString
            if exists, access != .write || contentType == .json && access == .read {
                initialContent = BASICString(try host.loadTextFile(path: path))
            } else {
                initialContent = BASICString("")
                if access == .write || access == .both {
                    try host.saveTextFile(path: path, text: "")
                }
            }
            file = BASICOpenFile(path: path, access: access, contentType: contentType, isOpen: true, content: initialContent, position: 0)
            fileObjects[id] = file
            return .empty
        case "READ":
            try requireOpen()
            try requireAccess([.read, .both])
            guard file.contentType != .json else { throw BASICError.runtime("Bad file mode") }
            let raw = file.content.rawString
            let remaining = String(raw.dropFirst(file.position))
            let result: String
            if arguments.isEmpty {
                result = remaining
                file.position = raw.count
            } else {
                guard arguments.count == 1 else { throw BASICError.runtime("read expects 0 or 1 arguments") }
                let maxCount = max(0, try fileInteger(from: arguments[0]))
                result = String(remaining.prefix(maxCount))
                file.position += result.count
            }
            fileObjects[id] = file
            return .string(BASICString(result))
        case "JSON":
            try requireOpen()
            try requireAccess([.read, .both])
            guard file.contentType == .json else { throw BASICError.runtime("Bad file mode") }
            guard arguments.isEmpty else { throw BASICError.runtime("json expects 0 arguments") }
            guard let jsonDecoder else { throw BASICError.runtime("JSON is not available") }
            return try jsonDecoder(file.content.rawString)
        case "WRITE":
            try requireOpen()
            try requireAccess([.write, .both])
            guard file.contentType != .json else { throw BASICError.runtime("Bad file mode") }
            guard arguments.count == 1, let text = arguments[0].string else {
                throw BASICError.runtime("write expects a string")
            }
            let path = try openPath(file)
            file.content = file.content.concatenating(text)
            file.position = file.content.rawString.count
            try requireHost().saveTextFile(path: path, text: file.content.rawString)
            fileObjects[id] = file
            return .empty
        case "WRITEJSON":
            try requireOpen()
            try requireAccess([.write, .both])
            guard file.contentType == .json else { throw BASICError.runtime("Bad file mode") }
            guard arguments.count == 2 else { throw BASICError.runtime("writeJson expects 2 arguments") }
            guard let jsonEncoder else { throw BASICError.runtime("JSON is not available") }
            let pretty = try fileBoolean(from: arguments[1])
            let text = try jsonEncoder(arguments[0], pretty)
            let path = try openPath(file)
            try requireHost().saveTextFile(path: path, text: text)
            file.content = BASICString(text)
            file.position = text.count
            fileObjects[id] = file
            return .empty
        case "SIZE":
            try requireOpen()
            guard arguments.isEmpty else { throw BASICError.runtime("size expects 0 arguments") }
            return .number(Double(file.content.byteCount))
        case "CLOSE":
            guard arguments.isEmpty else { throw BASICError.runtime("close expects 0 arguments") }
            file.isOpen = false
            fileObjects[id] = file
            return .empty
        default:
            throw BASICError.runtime("File has no method \(method)")
        }
    }

    private func openPath(_ file: BASICOpenFile) throws -> String {
        guard let path = file.path else { throw BASICError.runtime("File is not open") }
        return path
    }

    private func filePath(from value: BASICValue) throws -> String {
        guard let string = value.string else { throw BASICError.runtime("Expected a string") }
        return string.description
    }

    private func fileInteger(from value: BASICValue) throws -> Int {
        guard let number = value.number, number.rounded() == number else { throw BASICError.runtime("Expected an integer") }
        return Int(number)
    }

    private func fileBoolean(from value: BASICValue) throws -> Bool {
        switch value {
        case .boolean(let boolean): return boolean
        case .number(let number) where number == 0: return false
        case .number(let number) where number == 1: return true
        default: throw BASICError.runtime("Expected a boolean")
        }
    }

    private func fileAccess(from value: BASICValue) throws -> BASICFileAccess {
        guard let string = value.string else { throw BASICError.runtime("Expected file access") }
        guard let access = BASICFileAccess(rawValue: string.description.uppercased()) else {
            throw BASICError.runtime("Expected READ, WRITE, or BOTH")
        }
        return access
    }

    private func fileContentType(from value: BASICValue) throws -> BASICFileContentType {
        guard let string = value.string else { throw BASICError.runtime("Expected file type") }
        guard let type = BASICFileContentType(rawValue: string.description.uppercased()) else {
            throw BASICError.runtime("Expected RAW, TEXT, or JSON")
        }
        return type
    }

    private func callVectorTerminalMethod(method: String, arguments: [BASICValue], host: BASICVectorTerminalHost?) throws -> BASICValue {
        guard let host, host.isVectorTerminalAvailable else {
            throw BASICError.runtime("VectorTerminal graphics are not supported by this host")
        }

        let normalized = method.uppercased()
        switch normalized {
        case "CLEAR":
            try requireArgumentCount(arguments, 0, method: "clear")
            try host.vectorTerminalClear()
        case "PRESENT":
            try requireArgumentCount(arguments, 0, method: "present")
            try host.vectorTerminalPresent()
        case "DELETE":
            try requireArgumentCount(arguments, 1, method: "delete")
            try host.vectorTerminalDelete(id: try stringValue(arguments[0]))
        case "CLEARRECT":
            guard (5...6).contains(arguments.count) else { throw BASICError.runtime("clearRect expects 5 or 6 arguments") }
            try host.vectorTerminalClearRect(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                width: try integerValue(arguments[3]),
                height: try integerValue(arguments[4]),
                layer: try optionalInteger(arguments, at: 5)
            )
        case "PIXEL":
            guard (4...5).contains(arguments.count) else { throw BASICError.runtime("pixel expects 4 or 5 arguments") }
            try host.vectorTerminalPixel(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                color: try stringValue(arguments[3]),
                layer: try optionalInteger(arguments, at: 4)
            )
        case "LINE":
            guard (6...9).contains(arguments.count) else { throw BASICError.runtime("line expects 6 to 9 arguments") }
            let lineStyle = try vectorTerminalLineStyleArguments(arguments)
            try host.vectorTerminalLine(
                id: try stringValue(arguments[0]),
                x1: try integerValue(arguments[1]),
                y1: try integerValue(arguments[2]),
                x2: try integerValue(arguments[3]),
                y2: try integerValue(arguments[4]),
                stroke: try stringValue(arguments[5]),
                width: try optionalInteger(arguments, at: 6) ?? 1,
                lineCap: lineStyle.lineCap,
                layer: lineStyle.layer
            )
        case "DRAW":
            guard (3...7).contains(arguments.count) else { throw BASICError.runtime("draw expects 3 to 7 arguments") }
            try host.vectorTerminalDraw(
                id: try stringValue(arguments[0]),
                points: try vtgPoints(from: arguments[1]),
                stroke: try stringValue(arguments[2]),
                width: try optionalInteger(arguments, at: 3) ?? 1,
                lineCap: try optionalString(arguments, at: 4),
                lineJoin: try optionalString(arguments, at: 5),
                layer: try optionalInteger(arguments, at: 6)
            )
        case "QUADRATICCURVE":
            guard (8...12).contains(arguments.count) else { throw BASICError.runtime("quadraticCurve expects 8 to 12 arguments") }
            try host.vectorTerminalQuadraticCurve(
                id: try stringValue(arguments[0]),
                x1: try integerValue(arguments[1]),
                y1: try integerValue(arguments[2]),
                cx: try integerValue(arguments[3]),
                cy: try integerValue(arguments[4]),
                x2: try integerValue(arguments[5]),
                y2: try integerValue(arguments[6]),
                stroke: try stringValue(arguments[7]),
                width: try optionalInteger(arguments, at: 8) ?? 1,
                lineCap: try optionalString(arguments, at: 9),
                lineJoin: try optionalString(arguments, at: 10),
                layer: try optionalInteger(arguments, at: 11)
            )
        case "CUBICCURVE":
            guard (10...14).contains(arguments.count) else { throw BASICError.runtime("cubicCurve expects 10 to 14 arguments") }
            try host.vectorTerminalCubicCurve(
                id: try stringValue(arguments[0]),
                x1: try integerValue(arguments[1]),
                y1: try integerValue(arguments[2]),
                c1x: try integerValue(arguments[3]),
                c1y: try integerValue(arguments[4]),
                c2x: try integerValue(arguments[5]),
                c2y: try integerValue(arguments[6]),
                x2: try integerValue(arguments[7]),
                y2: try integerValue(arguments[8]),
                stroke: try stringValue(arguments[9]),
                width: try optionalInteger(arguments, at: 10) ?? 1,
                lineCap: try optionalString(arguments, at: 11),
                lineJoin: try optionalString(arguments, at: 12),
                layer: try optionalInteger(arguments, at: 13)
            )
        case "PATH":
            guard (2...8).contains(arguments.count) else { throw BASICError.runtime("path expects 2 to 8 arguments") }
            try host.vectorTerminalPath(
                id: try stringValue(arguments[0]),
                payload: try stringValue(arguments[1]),
                stroke: try optionalString(arguments, at: 2) ?? "#f8fafc",
                fill: try optionalString(arguments, at: 3),
                lineWidth: try optionalInteger(arguments, at: 4) ?? 1,
                lineCap: try optionalString(arguments, at: 5),
                lineJoin: try optionalString(arguments, at: 6),
                layer: try optionalInteger(arguments, at: 7)
            )
        case "TRIANGLE":
            guard (7...13).contains(arguments.count) else { throw BASICError.runtime("triangle expects 7 to 13 arguments") }
            try host.vectorTerminalTriangle(
                id: try stringValue(arguments[0]),
                x1: try integerValue(arguments[1]),
                y1: try integerValue(arguments[2]),
                x2: try integerValue(arguments[3]),
                y2: try integerValue(arguments[4]),
                x3: try integerValue(arguments[5]),
                y3: try integerValue(arguments[6]),
                stroke: try optionalString(arguments, at: 7) ?? "#f8fafc",
                fill: try optionalString(arguments, at: 8),
                lineWidth: try optionalInteger(arguments, at: 9) ?? 1,
                radius: try optionalInteger(arguments, at: 10) ?? 0,
                lineJoin: try optionalString(arguments, at: 11),
                layer: try optionalInteger(arguments, at: 12)
            )
        case "RECT":
            guard (5...12).contains(arguments.count) else { throw BASICError.runtime("rect expects 5 to 12 arguments") }
            let rectStyle = try vectorTerminalRectStyleArguments(arguments)
            try host.vectorTerminalRect(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                width: try integerValue(arguments[3]),
                height: try integerValue(arguments[4]),
                stroke: try optionalString(arguments, at: 5),
                fill: try optionalString(arguments, at: 6),
                lineWidth: try optionalInteger(arguments, at: 7) ?? 1,
                radius: try optionalInteger(arguments, at: 8) ?? 0,
                corners: rectStyle.corners,
                lineJoin: rectStyle.lineJoin,
                layer: rectStyle.layer
            )
        case "CIRCLE":
            guard (4...8).contains(arguments.count) else { throw BASICError.runtime("circle expects 4 to 8 arguments") }
            try host.vectorTerminalCircle(
                id: try stringValue(arguments[0]),
                cx: try integerValue(arguments[1]),
                cy: try integerValue(arguments[2]),
                radius: try integerValue(arguments[3]),
                stroke: try optionalString(arguments, at: 4),
                fill: try optionalString(arguments, at: 5),
                lineWidth: try optionalInteger(arguments, at: 6) ?? 1,
                layer: try optionalInteger(arguments, at: 7)
            )
        case "ELLIPSE":
            guard (5...9).contains(arguments.count) else { throw BASICError.runtime("ellipse expects 5 to 9 arguments") }
            try host.vectorTerminalEllipse(
                id: try stringValue(arguments[0]),
                cx: try integerValue(arguments[1]),
                cy: try integerValue(arguments[2]),
                rx: try integerValue(arguments[3]),
                ry: try integerValue(arguments[4]),
                stroke: try optionalString(arguments, at: 5),
                fill: try optionalString(arguments, at: 6),
                lineWidth: try optionalInteger(arguments, at: 7) ?? 1,
                layer: try optionalInteger(arguments, at: 8)
            )
        case "TEXT":
            guard (5...7).contains(arguments.count) else { throw BASICError.runtime("text expects 5 to 7 arguments") }
            try host.vectorTerminalText(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                value: try stringValue(arguments[3]),
                color: try stringValue(arguments[4]),
                size: try optionalInteger(arguments, at: 5) ?? 14,
                layer: try optionalInteger(arguments, at: 6)
            )
        case "VECTORPRINT":
            guard (5...8).contains(arguments.count) else { throw BASICError.runtime("vectorPrint expects 5 to 8 arguments") }
            try host.vectorTerminalVectorPrint(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                height: try integerValue(arguments[3]),
                value: try stringValue(arguments[4]),
                stroke: try optionalString(arguments, at: 5) ?? "#f8fafc",
                width: try optionalInteger(arguments, at: 6) ?? 1,
                layer: try optionalInteger(arguments, at: 7)
            )
        case "VECTORTEXTSIZE":
            guard arguments.count == 2 else { throw BASICError.runtime("vectorTextSize expects 2 arguments") }
            return vtgCanvasValue(try host.vectorTerminalVectorTextSize(
                height: try integerValue(arguments[0]),
                value: try stringValue(arguments[1])
            ))
        case "PILLBUTTON":
            guard (2...8).contains(arguments.count) else { throw BASICError.runtime("pillButton expects 2 to 8 arguments") }
            return vtgLayoutValue(try host.vectorTerminalPillButton(
                id: try stringValue(arguments[0]),
                text: try stringValue(arguments[1]),
                fill: try optionalString(arguments, at: 2) ?? "#0f766eFF",
                stroke: try optionalString(arguments, at: 3),
                lineWidth: try optionalInteger(arguments, at: 4) ?? 1,
                layer: try optionalInteger(arguments, at: 5),
                target: try optionalString(arguments, at: 6),
                timeoutMilliseconds: try optionalInteger(arguments, at: 7) ?? 750
            ))
        case "IMAGEPNG":
            guard (6...8).contains(arguments.count) else { throw BASICError.runtime("imagePng expects 6 to 8 arguments") }
            try host.vectorTerminalImagePNG(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                width: try integerValue(arguments[3]),
                height: try integerValue(arguments[4]),
                data: try dataValue(arguments[5]),
                filter: try optionalString(arguments, at: 6) ?? "smooth",
                layer: try optionalInteger(arguments, at: 7)
            )
        case "IMAGEJPEG":
            guard (6...8).contains(arguments.count) else { throw BASICError.runtime("imageJpeg expects 6 to 8 arguments") }
            try host.vectorTerminalImageJPEG(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                width: try integerValue(arguments[3]),
                height: try integerValue(arguments[4]),
                data: try dataValue(arguments[5]),
                filter: try optionalString(arguments, at: 6) ?? "smooth",
                layer: try optionalInteger(arguments, at: 7)
            )
        case "UPLOADSPRITEPNG":
            guard (4...5).contains(arguments.count) else { throw BASICError.runtime("uploadSpritePng expects 4 or 5 arguments") }
            try host.vectorTerminalUploadSpritePNG(
                id: try stringValue(arguments[0]),
                width: try integerValue(arguments[1]),
                height: try integerValue(arguments[2]),
                data: try dataValue(arguments[3]),
                filter: try optionalString(arguments, at: 4) ?? "smooth"
            )
        case "UPLOADSPRITEJPEG":
            guard (4...5).contains(arguments.count) else { throw BASICError.runtime("uploadSpriteJpeg expects 4 or 5 arguments") }
            try host.vectorTerminalUploadSpriteJPEG(
                id: try stringValue(arguments[0]),
                width: try integerValue(arguments[1]),
                height: try integerValue(arguments[2]),
                data: try dataValue(arguments[3]),
                filter: try optionalString(arguments, at: 4) ?? "smooth"
            )
        case "UPLOADVECTORSPRITE":
            guard (4...7).contains(arguments.count) else { throw BASICError.runtime("uploadVectorSprite expects 4 to 7 arguments") }
            try host.vectorTerminalUploadVectorSprite(
                id: try stringValue(arguments[0]),
                width: try integerValue(arguments[1]),
                height: try integerValue(arguments[2]),
                path: try stringValue(arguments[3]),
                stroke: try optionalString(arguments, at: 4),
                fill: try optionalString(arguments, at: 5),
                lineWidth: try optionalDouble(arguments, at: 6) ?? 1
            )
        case "UPLOADSPRITE":
            guard (5...7).contains(arguments.count) else { throw BASICError.runtime("uploadSprite expects 5 to 7 arguments") }
            try host.vectorTerminalUploadIndexedSprite(
                id: try stringValue(arguments[0]),
                width: try integerValue(arguments[1]),
                height: try integerValue(arguments[2]),
                pixels: try integerList(arguments[3]),
                palette: try stringList(arguments[4]),
                transparentIndex: try optionalInteger(arguments, at: 5),
                filter: try optionalString(arguments, at: 6) ?? "nearest"
            )
        case "UPLOADINDEXEDSPRITE":
            guard (5...7).contains(arguments.count) else { throw BASICError.runtime("uploadIndexedSprite expects 5 to 7 arguments") }
            try host.vectorTerminalUploadIndexedSprite(
                id: try stringValue(arguments[0]),
                width: try integerValue(arguments[1]),
                height: try integerValue(arguments[2]),
                pixels: try integerList(arguments[3]),
                palette: try stringList(arguments[4]),
                transparentIndex: try optionalInteger(arguments, at: 5),
                filter: try optionalString(arguments, at: 6) ?? "nearest"
            )
        case "SPRITE":
            guard (4...9).contains(arguments.count) else { throw BASICError.runtime("sprite expects 4 to 9 arguments") }
            try host.vectorTerminalSprite(
                id: try stringValue(arguments[0]),
                imageID: try stringValue(arguments[1]),
                x: try integerValue(arguments[2]),
                y: try integerValue(arguments[3]),
                rotation: try optionalDouble(arguments, at: 4) ?? 0,
                scale: try optionalDouble(arguments, at: 5) ?? 1,
                anchorX: try optionalDouble(arguments, at: 6) ?? 0.5,
                anchorY: try optionalDouble(arguments, at: 7) ?? 0.5,
                layer: try optionalInteger(arguments, at: 8)
            )
        case "MOVESPRITE":
            try requireArgumentCount(arguments, 3, method: "moveSprite")
            try host.vectorTerminalMoveSprite(id: try stringValue(arguments[0]), x: try integerValue(arguments[1]), y: try integerValue(arguments[2]))
        case "ROTATESPRITE":
            try requireArgumentCount(arguments, 2, method: "rotateSprite")
            try host.vectorTerminalRotateSprite(id: try stringValue(arguments[0]), rotation: try doubleValue(arguments[1]))
        case "ANCHORSPRITE":
            try requireArgumentCount(arguments, 3, method: "anchorSprite")
            try host.vectorTerminalAnchorSprite(id: try stringValue(arguments[0]), anchorX: try doubleValue(arguments[1]), anchorY: try doubleValue(arguments[2]))
        case "TRANSFORMSPRITE":
            guard (5...7).contains(arguments.count) else { throw BASICError.runtime("transformSprite expects 5 to 7 arguments") }
            try host.vectorTerminalTransformSprite(
                id: try stringValue(arguments[0]),
                x: try integerValue(arguments[1]),
                y: try integerValue(arguments[2]),
                rotation: try doubleValue(arguments[3]),
                scale: try doubleValue(arguments[4]),
                anchorX: try optionalDouble(arguments, at: 5),
                anchorY: try optionalDouble(arguments, at: 6)
            )
        case "REMOVESPRITE":
            try requireArgumentCount(arguments, 1, method: "removeSprite")
            try host.vectorTerminalRemoveSprite(id: try stringValue(arguments[0]))
        case "CLEARSPRITES":
            try requireArgumentCount(arguments, 0, method: "clearSprites")
            try host.vectorTerminalClearSprites()
        case "SETDEFAULTLAYER":
            try requireArgumentCount(arguments, 1, method: "setDefaultLayer")
            try host.vectorTerminalSetDefaultLayer(try integerValue(arguments[0]))
        case "SETLAYER":
            try requireArgumentCount(arguments, 2, method: "setLayer")
            try host.vectorTerminalSetLayer(id: try stringValue(arguments[0]), layer: try integerValue(arguments[1]))
        case "SCROLLLAYER":
            try requireArgumentCount(arguments, 3, method: "scrollLayer")
            try host.vectorTerminalScrollLayer(try integerValue(arguments[0]), x: try integerValue(arguments[1]), y: try integerValue(arguments[2]))
        case "SETLAYERALPHA":
            try requireArgumentCount(arguments, 2, method: "setLayerAlpha")
            try host.vectorTerminalSetLayerAlpha(try integerValue(arguments[0]), alpha: try doubleValue(arguments[1]))
        case "CLIPLAYER":
            try requireArgumentCount(arguments, 5, method: "clipLayer")
            try host.vectorTerminalClipLayer(try integerValue(arguments[0]), x: try integerValue(arguments[1]), y: try integerValue(arguments[2]), width: try integerValue(arguments[3]), height: try integerValue(arguments[4]))
        case "CLEARLAYERCLIP":
            try requireArgumentCount(arguments, 1, method: "clearLayerClip")
            try host.vectorTerminalClearLayerClip(try integerValue(arguments[0]))
        case "SETVIEWPORTMODE":
            guard (3...4).contains(arguments.count) else { throw BASICError.runtime("setViewportMode expects 3 or 4 arguments") }
            try host.vectorTerminalSetViewportMode(
                layer: try integerValue(arguments[0]),
                width: try integerValue(arguments[1]),
                height: try integerValue(arguments[2]),
                scale: try optionalString(arguments, at: 3) ?? "fit"
            )
        case "CLEARVIEWPORTMODE":
            try requireArgumentCount(arguments, 1, method: "clearViewportMode")
            try host.vectorTerminalClearViewportMode(layer: try integerValue(arguments[0]))
        case "SETVIEWPORTSCALE":
            try requireArgumentCount(arguments, 4, method: "setViewportScale")
            try host.vectorTerminalSetViewportScale(layer: try integerValue(arguments[0]), scale: try doubleValue(arguments[1]), x: try integerValue(arguments[2]), y: try integerValue(arguments[3]))
        case "HITREGION":
            guard (5...7).contains(arguments.count) else { throw BASICError.runtime("hitRegion expects 5 to 7 arguments") }
            try host.vectorTerminalHitRegion(id: try stringValue(arguments[0]), x: try integerValue(arguments[1]), y: try integerValue(arguments[2]), width: try integerValue(arguments[3]), height: try integerValue(arguments[4]), layer: try optionalInteger(arguments, at: 5), target: try optionalString(arguments, at: 6))
        case "CLEARHITREGIONS":
            guard arguments.count <= 2 else { throw BASICError.runtime("clearHitRegions expects 0 to 2 arguments") }
            try host.vectorTerminalClearHitRegions(id: try optionalString(arguments, at: 0), layer: try optionalInteger(arguments, at: 1))
        case "STARTFRAME":
            guard (1...2).contains(arguments.count) else { throw BASICError.runtime("startFrame expects 1 or 2 arguments") }
            try host.vectorTerminalStartFrame(id: try stringValue(arguments[0]), timeoutMilliseconds: try optionalInteger(arguments, at: 1) ?? 250)
        case "ENDFRAME":
            try requireArgumentCount(arguments, 1, method: "endFrame")
            try host.vectorTerminalEndFrame(id: try stringValue(arguments[0]))
        case "CANCELFRAME":
            try requireArgumentCount(arguments, 1, method: "cancelFrame")
            try host.vectorTerminalCancelFrame(id: try stringValue(arguments[0]))
        case "QUERYCAPABILITIES":
            guard arguments.count <= 1 else { throw BASICError.runtime("queryCapabilities expects 0 or 1 arguments") }
            return .string(BASICString(try host.vectorTerminalQueryCapabilities(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750) ?? ""))
        case "QUERYCAPABILITYINFO":
            guard arguments.count <= 1 else { throw BASICError.runtime("queryCapabilityInfo expects 0 or 1 arguments") }
            return .string(BASICString(try host.vectorTerminalQueryCapabilityInfo(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750) ?? ""))
        case "QUERYCANVAS":
            guard arguments.count <= 1 else { throw BASICError.runtime("queryCanvas expects 0 or 1 arguments") }
            return vtgCanvasValue(try host.vectorTerminalQueryCanvas(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750))
        case "QUERYSIZE":
            guard arguments.count <= 1 else { throw BASICError.runtime("querySize expects 0 or 1 arguments") }
            return vtgCanvasValue(try host.vectorTerminalQuerySize(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750))
        case "QUERYCURRENTCANVAS":
            guard arguments.count <= 1 else { throw BASICError.runtime("queryCurrentCanvas expects 0 or 1 arguments") }
            return vtgCanvasValue(try host.vectorTerminalQueryCurrentCanvas(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750))
        case "CANVASWIDTH":
            guard arguments.count <= 1 else { throw BASICError.runtime("canvasWidth expects 0 or 1 arguments") }
            return .number(Double(try host.vectorTerminalQueryCurrentCanvas(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750)?.width ?? 0))
        case "CANVASHEIGHT":
            guard arguments.count <= 1 else { throw BASICError.runtime("canvasHeight expects 0 or 1 arguments") }
            return .number(Double(try host.vectorTerminalQueryCurrentCanvas(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 750)?.height ?? 0))
        case "QUERYTERMINALCELLSIZE":
            try requireArgumentCount(arguments, 0, method: "queryTerminalCellSize")
            return vtgCellValue(try host.vectorTerminalQueryTerminalCellSize())
        case "QUERYTERMINALWSIZE":
            try requireArgumentCount(arguments, 0, method: "queryTerminalWSize")
            return vtgCellValue(try host.vectorTerminalQueryTerminalCellSize())
        case "ENABLERESIZEEVENTS":
            try requireArgumentCount(arguments, 0, method: "enableResizeEvents")
            try host.vectorTerminalEnableResizeEvents()
        case "DISABLERESIZEEVENTS":
            try requireArgumentCount(arguments, 0, method: "disableResizeEvents")
            try host.vectorTerminalDisableResizeEvents()
        case "ENABLEMOUSEREPORTING":
            guard arguments.count <= 1 else { throw BASICError.runtime("enableMouseReporting expects 0 or 1 arguments") }
            try host.vectorTerminalEnableMouseReporting(mode: try optionalString(arguments, at: 0))
        case "DISABLEMOUSEREPORTING":
            try requireArgumentCount(arguments, 0, method: "disableMouseReporting")
            try host.vectorTerminalDisableMouseReporting()
        case "READEVENT":
            guard arguments.count <= 1 else { throw BASICError.runtime("readEvent expects 0 or 1 arguments") }
            return .string(BASICString(try host.vectorTerminalReadEvent(timeoutMilliseconds: try optionalInteger(arguments, at: 0) ?? 0) ?? ""))
        case "ENTERALTERNATESCREEN":
            try requireArgumentCount(arguments, 0, method: "enterAlternateScreen")
            try host.vectorTerminalEnterAlternateScreen()
        case "LEAVEALTERNATESCREEN":
            try requireArgumentCount(arguments, 0, method: "leaveAlternateScreen")
            try host.vectorTerminalLeaveAlternateScreen()
        case "ENABLEBRACKETEDPASTE":
            try requireArgumentCount(arguments, 0, method: "enableBracketedPaste")
            try host.vectorTerminalEnableBracketedPaste()
        case "DISABLEBRACKETEDPASTE":
            try requireArgumentCount(arguments, 0, method: "disableBracketedPaste")
            try host.vectorTerminalDisableBracketedPaste()
        case "ENABLEFOCUSREPORTING":
            try requireArgumentCount(arguments, 0, method: "enableFocusReporting")
            try host.vectorTerminalEnableFocusReporting()
        case "DISABLEFOCUSREPORTING":
            try requireArgumentCount(arguments, 0, method: "disableFocusReporting")
            try host.vectorTerminalDisableFocusReporting()
        case "CLEARSCREEN":
            try requireArgumentCount(arguments, 0, method: "clearScreen")
            try host.vectorTerminalClearScreen()
        case "CLEARSCROLLBACKANDSCREEN":
            try requireArgumentCount(arguments, 0, method: "clearScrollbackAndScreen")
            try host.vectorTerminalClearScrollbackAndScreen()
        case "CLEARLINE":
            try requireArgumentCount(arguments, 0, method: "clearLine")
            try host.vectorTerminalClearLine()
        case "CLEARTOENDOFLINE":
            try requireArgumentCount(arguments, 0, method: "clearToEndOfLine")
            try host.vectorTerminalClearToEndOfLine()
        case "WRITETEXT":
            try requireArgumentCount(arguments, 1, method: "writeText")
            try host.vectorTerminalWriteText(try stringValue(arguments[0]))
        case "MOVECURSOR":
            try requireArgumentCount(arguments, 2, method: "moveCursor")
            try host.vectorTerminalMoveCursor(row: try integerValue(arguments[0]), column: try integerValue(arguments[1]))
        case "SETCURSOR":
            try requireArgumentCount(arguments, 2, method: "setCursor")
            try host.vectorTerminalSetCursor(row: try integerValue(arguments[0]), column: try integerValue(arguments[1]))
        case "MOVECURSORUP":
            guard arguments.count <= 1 else { throw BASICError.runtime("moveCursorUp expects 0 or 1 arguments") }
            try host.vectorTerminalMoveCursorUp(try optionalInteger(arguments, at: 0) ?? 1)
        case "MOVECURSORDOWN":
            guard arguments.count <= 1 else { throw BASICError.runtime("moveCursorDown expects 0 or 1 arguments") }
            try host.vectorTerminalMoveCursorDown(try optionalInteger(arguments, at: 0) ?? 1)
        case "MOVECURSORFORWARD":
            guard arguments.count <= 1 else { throw BASICError.runtime("moveCursorForward expects 0 or 1 arguments") }
            try host.vectorTerminalMoveCursorForward(try optionalInteger(arguments, at: 0) ?? 1)
        case "MOVECURSORBACKWARD":
            guard arguments.count <= 1 else { throw BASICError.runtime("moveCursorBackward expects 0 or 1 arguments") }
            try host.vectorTerminalMoveCursorBackward(try optionalInteger(arguments, at: 0) ?? 1)
        case "SAVECURSOR":
            try requireArgumentCount(arguments, 0, method: "saveCursor")
            try host.vectorTerminalSaveCursor()
        case "RESTORECURSOR":
            try requireArgumentCount(arguments, 0, method: "restoreCursor")
            try host.vectorTerminalRestoreCursor()
        case "HIDECURSOR":
            try requireArgumentCount(arguments, 0, method: "hideCursor")
            try host.vectorTerminalHideCursor()
        case "SHOWCURSOR":
            try requireArgumentCount(arguments, 0, method: "showCursor")
            try host.vectorTerminalShowCursor()
        case "RESETTEXTATTRIBUTES":
            try requireArgumentCount(arguments, 0, method: "resetTextAttributes")
            try host.vectorTerminalResetTextAttributes()
        case "BOLD":
            guard arguments.count <= 1 else { throw BASICError.runtime("bold expects 0 or 1 arguments") }
            try host.vectorTerminalBold(try optionalBoolean(arguments, at: 0) ?? true)
        case "UNDERLINE":
            guard arguments.count <= 1 else { throw BASICError.runtime("underline expects 0 or 1 arguments") }
            try host.vectorTerminalUnderline(try optionalBoolean(arguments, at: 0) ?? true)
        case "INVERSE":
            guard arguments.count <= 1 else { throw BASICError.runtime("inverse expects 0 or 1 arguments") }
            try host.vectorTerminalInverse(try optionalBoolean(arguments, at: 0) ?? true)
        case "SETFOREGROUND":
            guard (1...2).contains(arguments.count) else { throw BASICError.runtime("setForeground expects 1 or 2 arguments") }
            try host.vectorTerminalSetForeground(try stringValue(arguments[0]), bright: try optionalBoolean(arguments, at: 1) ?? false)
        case "SETBACKGROUND":
            guard (1...2).contains(arguments.count) else { throw BASICError.runtime("setBackground expects 1 or 2 arguments") }
            try host.vectorTerminalSetBackground(try stringValue(arguments[0]), bright: try optionalBoolean(arguments, at: 1) ?? false)
        case "SETFOREGROUNDRGB":
            try requireArgumentCount(arguments, 3, method: "setForegroundRGB")
            try host.vectorTerminalSetForegroundRGB(red: try integerValue(arguments[0]), green: try integerValue(arguments[1]), blue: try integerValue(arguments[2]))
        case "SETBACKGROUNDRGB":
            try requireArgumentCount(arguments, 3, method: "setBackgroundRGB")
            try host.vectorTerminalSetBackgroundRGB(red: try integerValue(arguments[0]), green: try integerValue(arguments[1]), blue: try integerValue(arguments[2]))
        case "BELL":
            try requireArgumentCount(arguments, 0, method: "bell")
            try host.vectorTerminalBell()
        default:
            throw BASICError.runtime("VectorTerminal has no method \(method)")
        }
        return .empty
    }

    private func requireArgumentCount(_ arguments: [BASICValue], _ expected: Int, method: String) throws {
        guard arguments.count == expected else {
            throw BASICError.runtime("\(method) expects \(expected) arguments")
        }
    }

    private func stringValue(_ value: BASICValue) throws -> String {
        guard let string = value.string else { throw BASICError.runtime("Expected a string") }
        return string.description
    }

    private func optionalString(_ arguments: [BASICValue], at index: Int) throws -> String? {
        guard arguments.indices.contains(index), arguments[index] != .empty, arguments[index] != .null else {
            return nil
        }
        return try stringValue(arguments[index])
    }

    private func vectorTerminalLineStyleArguments(_ arguments: [BASICValue]) throws -> (lineCap: String?, layer: Int?) {
        var lineCap: String?
        var layer: Int?
        if arguments.indices.contains(7), arguments[7] != .empty, arguments[7] != .null {
            if arguments[7].string != nil {
                lineCap = try stringValue(arguments[7])
            } else {
                layer = try integerValue(arguments[7])
            }
        }
        if arguments.indices.contains(8), arguments[8] != .empty, arguments[8] != .null {
            layer = try integerValue(arguments[8])
        }
        return (lineCap, layer)
    }

    private func vectorTerminalRectStyleArguments(_ arguments: [BASICValue]) throws -> (corners: String?, lineJoin: String?, layer: Int?) {
        var corners: String?
        var lineJoin: String?
        var layer: Int?
        if arguments.indices.contains(9), arguments[9] != .empty, arguments[9] != .null {
            if arguments[9].string != nil {
                corners = try stringValue(arguments[9])
            } else {
                layer = try integerValue(arguments[9])
            }
        }
        if arguments.indices.contains(10), arguments[10] != .empty, arguments[10] != .null {
            if arguments[10].string != nil {
                lineJoin = try stringValue(arguments[10])
            } else {
                guard layer == nil else { throw BASICError.runtime("rect layer must be the final argument") }
                layer = try integerValue(arguments[10])
            }
        }
        if arguments.indices.contains(11), arguments[11] != .empty, arguments[11] != .null {
            layer = try integerValue(arguments[11])
        }
        return (corners, lineJoin, layer)
    }

    private func integerValue(_ value: BASICValue) throws -> Int {
        guard let number = value.number, number.rounded() == number else {
            throw BASICError.runtime("Expected an integer")
        }
        return Int(number)
    }

    private func doubleValue(_ value: BASICValue) throws -> Double {
        guard let number = value.number else {
            throw BASICError.runtime("Expected a number")
        }
        return number
    }

    private func boolValue(_ value: BASICValue) throws -> Bool {
        switch value {
        case .boolean(let boolean):
            return boolean
        case .number(let number):
            return number != 0
        default:
            throw BASICError.runtime("Expected a boolean")
        }
    }

    private func dataValue(_ value: BASICValue) throws -> Data {
        guard let string = value.string else { throw BASICError.runtime("Expected a string") }
        let raw = string.rawString
        if raw.lowercased().hasPrefix("base64:") {
            let payload = String(raw.dropFirst("base64:".count))
            guard let decoded = Data(base64Encoded: payload) else {
                throw BASICError.runtime("Invalid base64 data")
            }
            return decoded
        }
        return string.rawData
    }

    private func optionalInteger(_ arguments: [BASICValue], at index: Int) throws -> Int? {
        guard arguments.indices.contains(index), arguments[index] != .empty, arguments[index] != .null else {
            return nil
        }
        return try integerValue(arguments[index])
    }

    private func optionalDouble(_ arguments: [BASICValue], at index: Int) throws -> Double? {
        guard arguments.indices.contains(index), arguments[index] != .empty, arguments[index] != .null else {
            return nil
        }
        return try doubleValue(arguments[index])
    }

    private func optionalBoolean(_ arguments: [BASICValue], at index: Int) throws -> Bool? {
        guard arguments.indices.contains(index), arguments[index] != .empty, arguments[index] != .null else {
            return nil
        }
        switch arguments[index] {
        case .boolean(let value):
            return value
        case .number(let value):
            return value != 0
        default:
            throw BASICError.runtime("Expected a boolean")
        }
    }

    private func vtgPoints(from value: BASICValue) throws -> [(x: Int, y: Int)] {
        if case .array(let array) = value {
            guard array.values.count >= 4, array.values.count.isMultiple(of: 2) else {
                throw BASICError.runtime("draw points array must contain x,y pairs")
            }
            var points: [(x: Int, y: Int)] = []
            var index = 0
            while index < array.values.count {
                points.append((x: try integerValue(array.values[index]), y: try integerValue(array.values[index + 1])))
                index += 2
            }
            return points
        }
        if case .string(let string) = value {
            let numbers = string.description
                .split { $0 == "," || $0 == " " || $0 == ";" }
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard numbers.count >= 4, numbers.count.isMultiple(of: 2) else {
                throw BASICError.runtime("draw points string must contain x,y pairs")
            }
            var points: [(x: Int, y: Int)] = []
            var index = 0
            while index < numbers.count {
                points.append((x: numbers[index], y: numbers[index + 1]))
                index += 2
            }
            return points
        }
        throw BASICError.runtime("draw points must be an array or x,y string")
    }

    private func integerList(_ value: BASICValue) throws -> [Int] {
        if case .array(let array) = value {
            return try array.values.map { try integerValue($0) }
        }
        if case .string(let string) = value {
            return try string.description
                .split { $0 == "," || $0 == " " || $0 == ";" }
                .map {
                    guard let value = Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw BASICError.runtime("Expected an integer list")
                    }
                    return value
                }
        }
        throw BASICError.runtime("Expected an integer array or list")
    }

    private func stringList(_ value: BASICValue) throws -> [String] {
        if case .array(let array) = value {
            return try array.values.map { try stringValue($0) }
        }
        if case .string(let string) = value {
            return string.description
                .split { $0 == "," || $0 == ";" }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        throw BASICError.runtime("Expected a string array or list")
    }

    private func dictionaryMember(_ value: BASICValue, key: String) throws -> BASICValue {
        guard case .dictionary(let dictionary) = value else {
            throw BASICError.runtime("Expected a dictionary")
        }
        return dictionary.values[key] ?? .empty
    }

    private func vtgCanvasValue(_ canvas: BASICVectorTerminalCanvasSnapshot?) -> BASICValue {
        guard let canvas else { return .empty }
        var values: [String: BASICValue] = [
            "width": .number(Double(canvas.width)),
            "height": .number(Double(canvas.height))
        ]
        if let source = canvas.source {
            values["source"] = .string(BASICString(source))
        }
        if let rawResponse = canvas.rawResponse {
            values["rawResponse"] = .string(BASICString(rawResponse))
        }
        return .dictionary(BASICDictionary(values: values))
    }

    private func vtgCellValue(_ cell: BASICVectorTerminalCellSnapshot?) -> BASICValue {
        guard let cell else { return .empty }
        var values: [String: BASICValue] = [
            "columns": .number(Double(cell.columns)),
            "rows": .number(Double(cell.rows))
        ]
        if let width = cell.width {
            values["width"] = .number(width)
        }
        if let height = cell.height {
            values["height"] = .number(height)
        }
        return .dictionary(BASICDictionary(values: values))
    }

    private func vtgLayoutValue(_ layout: BASICVectorTerminalLayoutSnapshot?) -> BASICValue {
        guard let layout else { return .empty }
        var values: [String: BASICValue] = [
            "x": .number(Double(layout.x)),
            "y": .number(Double(layout.y)),
            "width": .number(Double(layout.width)),
            "height": .number(Double(layout.height))
        ]
        if let row = layout.row {
            values["row"] = .number(Double(row))
        }
        if let column = layout.column {
            values["column"] = .number(Double(column))
        }
        return .dictionary(BASICDictionary(values: values))
    }

    func defaultValue(for type: BASICType) -> BASICValue {
        switch type {
        case .void: return .empty
        case .scalar(.string): return .string(BASICString(""))
        case .scalar(.boolean): return .boolean(false)
        case .scalar(.variant): return .empty
        case .scalar: return .number(0)
        case .record(let name):
            guard let definition = recordDefinitions[name.uppercased()] else {
                return .record(name, [:])
            }
            let fields = Dictionary(uniqueKeysWithValues: definition.fields.map {
                ($0.normalizedName, defaultValue(for: $0))
            })
            return .record(definition.displayName, fields)
        case .classType(let name):
            if Self.isBuiltInClass(name) {
                switch name.uppercased() {
                case "VECTORTERMINAL", "VTG":
                    return vectorTerminalObject()
                case "BASICEVENT", "BASICRESIZEEVENT", "BASICMOUSEEVENT", "BASICTIMEREVENT", "BASICGAMEPADEVENT", "BASICFRAMEEVENT", "BASICROUTEEVENT", "BASICNETWORKEVENT":
                    return Self.builtInEventObject(typeName: name, fields: [:])
                case "SECONDSTIMER":
                    return secondsTimerObject(intervalSeconds: 0)
                default:
                    return fileObject()
                }
            }
            guard let definition = classDefinitions[name.uppercased()] else {
                return .object(name, [:])
            }
            let fields = Dictionary(uniqueKeysWithValues: inheritedFields(for: definition).map {
                ($0.normalizedName, defaultValue(for: $0))
            })
            return .object(definition.displayName, fields)
        case .interfaceType:
            return .empty
        case .functionType:
            return .empty
        case .dictionary:
            return .dictionary(BASICDictionary())
        }
    }

    private func defaultValue(for field: BASICRecordField) -> BASICValue {
        defaultValue(type: field.type, arrayDimensions: field.arrayDimensions, explicitDefault: field.defaultValue)
    }

    private func defaultValue(for field: BASICClassField) -> BASICValue {
        defaultValue(type: field.type, arrayDimensions: field.arrayDimensions, explicitDefault: field.defaultValue)
    }

    private func defaultValue(type: BASICType, arrayDimensions: [Int?], explicitDefault: BASICValue?) -> BASICValue {
        guard !arrayDimensions.isEmpty else {
            return explicitDefault ?? defaultValue(for: type)
        }
        let dimensions = arrayDimensions.map { $0 ?? -1 }
        let count = dimensions.contains(-1) ? 0 : dimensions.reduce(1) { $0 * ($1 + 1) }
        return .array(BASICArray(
            dimensions: dimensions,
            type: type,
            isDynamic: arrayDimensions.contains(where: { $0 == nil }),
            values: Array(repeating: defaultValue(for: type), count: count)
        ))
    }

    private func arrayValue(_ array: BASICArray, at indexes: [BASICValue], name: String) throws -> BASICValue {
        try array.values[arrayOffset(dimensions: array.dimensions, indexes: indexes, name: name)]
    }

    private func dictionaryValue(_ dictionary: BASICDictionary, at indexes: [BASICValue], name: String) throws -> BASICValue {
        dictionary.values[try dictionaryKey(from: indexes, name: name)] ?? .empty
    }

    private func reflectedIndexedValue(_ value: BASICValue, indexes: [BASICValue], name: String) throws -> (value: BASICValue, type: BASICType) {
        switch value {
        case .array(let array):
            return (try arrayValue(array, at: indexes, name: name), array.type)
        case .dictionary(let dictionary):
            let element = try dictionaryValue(dictionary, at: indexes, name: name)
            return (element, inferredType(name: name, value: element))
        default:
            throw BASICError.runtime("\(name) is not an array")
        }
    }

    private func reflectionDictionary(
        metadata: BASICMetadata,
        name: String,
        typeName: String,
        path: String,
        parent: String?,
        index: String?
    ) -> BASICValue {
        var values = metadata
        values["name"] = .string(BASICString(name))
        values["type"] = .string(BASICString(typeName))
        values["path"] = .string(BASICString(path))
        if let parent {
            values["parent"] = .string(BASICString(parent))
        }
        if let index {
            values["index"] = .string(BASICString(index))
        }
        return .dictionary(BASICDictionary(values: values))
    }

    private func reflectionTypeName(type: BASICType, value: BASICValue) -> String {
        if case .array(let array) = value {
            return "ARRAY OF \(array.type.name)"
        }
        return type.name
    }

    private func reflectionIndexDescription(_ indexes: [BASICValue]) -> String {
        let rendered = indexes.map { value in
            if let string = value.string {
                return "\"\(string.description)\""
            }
            return value.description
        }
        return "(\(rendered.joined(separator: ",")))"
    }

    private func arrayOffset(dimensions: [Int], indexes: [BASICValue], name: String) throws -> Int {
        guard indexes.count == dimensions.count else {
            throw BASICError.runtime("\(name) expects \(dimensions.count) indexes")
        }
        var multiplier = 1
        var offset = 0
        for (indexValue, upperBound) in zip(indexes.reversed(), dimensions.reversed()) {
            let index = try arrayIndex(from: indexValue, name: name)
            guard (0...upperBound).contains(index) else {
                throw BASICError.runtime("\(name) subscript out of range")
            }
            offset += index * multiplier
            multiplier *= upperBound + 1
        }
        return offset
    }

    private func arrayIndex(from value: BASICValue, name: String) throws -> Int {
        guard let number = value.number, number.rounded() == number else {
            throw BASICError.runtime("\(name) array index must be numeric")
        }
        return Int(number)
    }

    private func dictionaryKey(from indexes: [BASICValue], name: String) throws -> String {
        guard indexes.count == 1 else {
            throw BASICError.runtime("\(name) expects 1 key")
        }
        if let string = indexes[0].string {
            return string.description
        }
        if let number = indexes[0].number {
            return BASICValue.number(number).description
        }
        throw BASICError.runtime("\(name) dictionary key must be a string or number")
    }

    private func assigningField(
        _ fields: [String],
        fieldIndexes: [[BASICValue]] = [],
        in recordValue: BASICValue,
        value: BASICValue?,
        accessClassName: String?,
        declaredType: BASICType? = nil
    ) throws -> BASICValue {
        guard let first = fields.first else {
            return value ?? recordValue
        }
        guard let composite = recordValue.compositeFields else {
            throw BASICError.runtime("Cannot assign field \(first) on non-record value")
        }
        let recordName = composite.name
        var recordFields = composite.fields
        let surfaceTypeName = declaredType?.name ?? recordName
        let fieldDefinitions = compositeFieldDefinitions(for: surfaceTypeName)
        guard !fieldDefinitions.isEmpty else { throw BASICError.runtime("Unknown TYPE or CLASS \(recordName)") }
        let normalized = first.uppercased()
        guard let field = fieldDefinitions.first(where: { $0.normalizedName == normalized }) else {
            throw BASICError.runtime("\(fieldLookupTypeName(declaredType, fallbackTypeName: recordName)) has no field \(first)")
        }
        try validateAccess(to: field, from: accessClassName)
        let current = recordFields[normalized] ?? defaultValue(for: field)
        let indexes = fieldIndexes.first ?? []
        if fields.count == 1 {
            if indexes.isEmpty {
                recordFields[normalized] = try coerce(value ?? defaultValue(for: field), to: field, variable: VariableName(name: field.displayName, column: 0))
            } else {
                recordFields[normalized] = try assigningIndexedValue(
                    in: current,
                    indexes: indexes,
                    value: value,
                    field: field
                )
            }
        } else if indexes.isEmpty {
            recordFields[normalized] = try assigningField(
                Array(fields.dropFirst()),
                fieldIndexes: Array(fieldIndexes.dropFirst()),
                in: current,
                value: value,
                accessClassName: accessClassName
            )
        } else {
            recordFields[normalized] = try assigningIndexedField(
                Array(fields.dropFirst()),
                fieldIndexes: Array(fieldIndexes.dropFirst()),
                in: current,
                indexes: indexes,
                value: value,
                accessClassName: accessClassName,
                field: field
            )
        }
        switch recordValue {
        case .object:
            return .object(recordName, recordFields)
        default:
            return .record(recordName, recordFields)
        }
    }

    private func assigningIndexedValue(
        in current: BASICValue,
        indexes: [BASICValue],
        value: BASICValue?,
        field: any BASICFieldDefinition
    ) throws -> BASICValue {
        switch current {
        case .array(var array):
            let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: field.displayName)
            array.values[offset] = try coerce(value ?? defaultValue(for: array.type), to: array.type, variable: VariableName(name: field.displayName, column: 0))
            return .array(array)
        case .dictionary(var dictionary):
            let key = try dictionaryKey(from: indexes, name: field.displayName)
            dictionary.values[key] = value ?? .empty
            return .dictionary(dictionary)
        default:
            throw BASICError.runtime("\(field.displayName) is not an array")
        }
    }

    private func assigningIndexedField(
        _ fields: [String],
        fieldIndexes: [[BASICValue]],
        in current: BASICValue,
        indexes: [BASICValue],
        value: BASICValue?,
        accessClassName: String?,
        field: any BASICFieldDefinition
    ) throws -> BASICValue {
        switch current {
        case .array(var array):
            let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: field.displayName)
            array.values[offset] = try assigningField(
                fields,
                fieldIndexes: fieldIndexes,
                in: array.values[offset],
                value: value,
                accessClassName: accessClassName
            )
            return .array(array)
        case .dictionary(var dictionary):
            let key = try dictionaryKey(from: indexes, name: field.displayName)
            dictionary.values[key] = try assigningField(
                fields,
                fieldIndexes: fieldIndexes,
                in: dictionary.values[key] ?? .empty,
                value: value,
                accessClassName: accessClassName
            )
            return .dictionary(dictionary)
        default:
            throw BASICError.runtime("\(field.displayName) is not an array")
        }
    }

    private func fieldSurfaceType(for reference: VariableReference) -> BASICType? {
        guard !reference.fields.isEmpty else { return nil }
        switch declaredType(for: reference) {
        case .classType(let name):
            return .classType(name)
        case .interfaceType(let name):
            return .interfaceType(name)
        default:
            return nil
        }
    }

    private func snapshots(from bindings: [String: VariableBinding], scope: BASICVariableScope) -> [BASICVariableSnapshot] {
        bindings.values
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map {
                snapshot(
                    name: $0.displayName,
                    type: $0.type,
                    value: $0.value,
                    scope: scope,
                    path: "\(scope.rawValue):\($0.displayName)"
                )
            }
    }

    private func snapshot(
        name: String,
        type: BASICType,
        value: BASICValue,
        scope: BASICVariableScope,
        path: String
    ) -> BASICVariableSnapshot {
        switch value {
        case .array(let array):
            let children = array.values.enumerated().map { offset, element in
                let elementName = elementName(for: offset, dimensions: array.dimensions)
                return snapshot(
                    name: elementName,
                    type: array.type,
                    value: element,
                    scope: scope,
                    path: "\(path)\(elementName)"
                )
            }
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: "ARRAY OF \(array.type.name)",
                value: arraySummary(array),
                scope: scope,
                children: children
            )
        case .dictionary(let dictionary):
            let children = dictionary.values.keys.sorted().map { key in
                let value = dictionary.values[key] ?? .empty
                return snapshot(
                    name: "\"\(key)\"",
                    type: inferredType(name: key, value: value),
                    value: value,
                    scope: scope,
                    path: "\(path)(\"\(key)\")"
                )
            }
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: "DICTIONARY",
                value: "\(dictionary.values.count) entries",
                scope: scope,
                children: children
            )
        case .record(let recordName, let fields):
            let children = compositeFieldSnapshots(typeName: recordName, fields: fields, scope: scope, parentPath: path)
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: recordName,
                value: "\(children.count) fields",
                scope: scope,
                children: children
            )
        case .object(let className, let fields):
            let fieldCount = compositeFieldDefinitions(for: className).count
            let children = objectFieldSnapshots(typeName: className, fields: fields, scope: scope, parentPath: path)
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: className,
                value: "\(fieldCount > 0 ? fieldCount : children.count) fields",
                scope: scope,
                children: children
            )
        case .systemObject(let typeName, _):
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: typeName,
                value: value.description,
                scope: scope,
                children: []
            )
        case .closure(let closure):
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: value.debugTypeName,
                value: "\(closure.capturedSnapshots.count) captures",
                scope: scope,
                children: closureSnapshotChildren(closure, scope: scope, parentPath: path)
            )
        default:
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: type.name,
                value: value.description,
                scope: scope,
                children: []
            )
        }
    }

    private func closureSnapshotChildren(
        _ closure: BASICCapturedClosure,
        scope: BASICVariableScope,
        parentPath: String
    ) -> [BASICVariableSnapshot] {
        var children = [
            BASICVariableSnapshot(
                path: "\(parentPath).Signature",
                name: "Signature",
                typeName: "FUNCTION",
                value: closure.signatureDescription,
                scope: scope,
                children: []
            )
        ]
        let captures = closure.capturedSnapshots
        guard !captures.isEmpty else { return children }
        children.append(
            BASICVariableSnapshot(
                path: "\(parentPath).Captured Values",
                name: "Captured Values",
                typeName: "CAPTURES",
                value: "\(captures.count) captures",
                scope: scope,
                children: captures.map {
                    BASICVariableSnapshot(
                        path: "\(parentPath).Captured Values.\($0.name)",
                        name: $0.name,
                        typeName: $0.typeName,
                        value: "\($0.value) [\($0.access.rawValue), rev \($0.revision)]",
                        scope: scope,
                        children: []
                    )
                }
            )
        )
        return children
    }

    private func objectFieldSnapshots(
        typeName: String,
        fields: [String: BASICValue],
        scope: BASICVariableScope,
        parentPath: String
    ) -> [BASICVariableSnapshot] {
        guard let classDefinition = classDefinitions[typeName.uppercased()] else {
            return compositeFieldSnapshots(typeName: typeName, fields: fields, scope: scope, parentPath: parentPath)
        }

        let chain = inheritanceChain(for: classDefinition)
        guard chain.count > 1 else {
            return compositeFieldSnapshots(typeName: typeName, fields: fields, scope: scope, parentPath: parentPath)
        }

        return chain.compactMap { definition in
            let classFields = definition.fields
            guard !classFields.isEmpty else { return nil }
            let children = classFields.map { field in
                let value = fields[field.normalizedName] ?? defaultValue(for: field)
                return snapshot(
                    name: field.displayName,
                    type: field.type,
                    value: value,
                    scope: scope,
                    path: "\(parentPath).\(definition.displayName).\(field.displayName)"
                )
            }
            return BASICVariableSnapshot(
                path: "\(parentPath).\(definition.displayName)",
                name: definition.displayName,
                typeName: "CLASS",
                value: "\(children.count) fields",
                scope: scope,
                children: children
            )
        }
    }

    private func compositeFieldSnapshots(
        typeName: String,
        fields: [String: BASICValue],
        scope: BASICVariableScope,
        parentPath: String
    ) -> [BASICVariableSnapshot] {
        let definitions = compositeFieldDefinitions(for: typeName)
        if !definitions.isEmpty {
            return definitions.map { field in
                let value = fields[field.normalizedName] ?? defaultValue(for: field)
                return snapshot(
                    name: field.displayName,
                    type: field.type,
                    value: value,
                    scope: scope,
                    path: "\(parentPath).\(field.displayName)"
                )
            }
        }

        return fields.keys.sorted().map { key in
            let value = fields[key] ?? .empty
            return snapshot(
                name: key,
                type: inferredType(name: key, value: value),
                value: value,
                scope: scope,
                path: "\(parentPath).\(key)"
            )
        }
    }

    private func compositeFieldDefinitions(for typeName: String) -> [BASICClassField] {
        if let fields = Self.builtInEventFields(for: typeName) {
            return fields
        }
        if let classDefinition = classDefinitions[typeName.uppercased()] {
            return inheritedFields(for: classDefinition)
        }
        if let recordDefinition = recordDefinitions[typeName.uppercased()] {
            return recordDefinition.fields.map {
                BASICClassField(
                    displayName: $0.displayName,
                    normalizedName: $0.normalizedName,
                    type: $0.type,
                    arrayDimensions: $0.arrayDimensions,
                    visibility: .public,
                    declaringClassName: recordDefinition.normalizedName,
                    json: $0.json,
                    metadata: $0.metadata,
                    defaultValue: $0.defaultValue
                )
            }
        }
        return []
    }

    private func inheritedFields(for classDefinition: BASICClassDefinition) -> [BASICClassField] {
        var fields: [BASICClassField] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            fields.append(contentsOf: inheritedFields(for: baseDefinition))
        }
        fields.append(contentsOf: classDefinition.fields)
        return fields
    }

    private func inheritanceChain(for classDefinition: BASICClassDefinition) -> [BASICClassDefinition] {
        var chain: [BASICClassDefinition] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            chain.append(contentsOf: inheritanceChain(for: baseDefinition))
        }
        chain.append(classDefinition)
        return chain
    }

    private func validateFieldAccess(typeName: String, fieldName: String, accessClassName: String?) throws {
        guard let field = compositeFieldDefinitions(for: typeName).first(where: { $0.normalizedName == fieldName.uppercased() }) else {
            return
        }
        try validateAccess(to: field, from: accessClassName)
    }

    private func fieldExists(typeName: String, fieldName: String) -> Bool {
        compositeFieldDefinitions(for: typeName).contains {
            $0.normalizedName == fieldName.uppercased()
        }
    }

    private func fieldLookupTypeName(_ declaredType: BASICType?, fallbackTypeName: String) -> String {
        switch declaredType {
        case .interfaceType(let name):
            return "INTERFACE \(name)"
        case .classType(let name):
            return "CLASS \(name)"
        default:
            return fallbackTypeName
        }
    }

    private func validateAccess(to field: BASICClassField, from accessClassName: String?) throws {
        switch field.visibility {
        case .public:
            return
        case .private:
            guard accessClassName?.uppercased() == field.declaringClassName.uppercased() else {
                throw BASICError.runtime("\(field.displayName) is PRIVATE")
            }
        case .protected:
            guard let accessClassName,
                  accessClassName.uppercased() == field.declaringClassName.uppercased()
                    || isClass(accessClassName, subclassOf: field.declaringClassName) else {
                throw BASICError.runtime("\(field.displayName) is PROTECTED")
            }
        }
    }

    private func isClass(_ className: String, subclassOf baseName: String) -> Bool {
        if Self.isBuiltInEventClass(className, subclassOf: baseName) {
            return true
        }
        var current = classDefinitions[className.uppercased()]?.baseClassName
        while let currentName = current {
            if currentName.uppercased() == baseName.uppercased() {
                return true
            }
            current = classDefinitions[currentName.uppercased()]?.baseClassName
        }
        return false
    }

    static func builtInEventObject(typeName: String, fields: [String: BASICValue]) -> BASICValue {
        let normalizedTypeName = builtInEventClassName(typeName) ?? typeName.uppercased()
        let displayName = builtInEventDisplayName(normalizedTypeName)
        let defaults = Dictionary(uniqueKeysWithValues: (builtInEventFields(for: normalizedTypeName) ?? []).map {
            ($0.normalizedName, eventDefaultValue(for: $0))
        })
        return .object(displayName, defaults.merging(fields) { _, new in new })
    }

    static func builtInEventClassName(_ name: String) -> String? {
        switch name.uppercased() {
        case "BASICEVENT", "BASICRESIZEEVENT", "BASICMOUSEEVENT", "BASICTIMEREVENT", "BASICGAMEPADEVENT", "BASICFRAMEEVENT", "BASICROUTEEVENT", "BASICNETWORKEVENT":
            return name.uppercased()
        default:
            return nil
        }
    }

    static func isBuiltInEventClass(_ className: String, subclassOf baseName: String) -> Bool {
        var current = builtInEventClassName(className)
        let expected = baseName.uppercased()
        while let currentName = current {
            if currentName == expected {
                return true
            }
            current = builtInEventBaseClassName(currentName)
        }
        return false
    }

    private static func builtInEventFields(for typeName: String) -> [BASICClassField]? {
        guard let normalized = builtInEventClassName(typeName) else { return nil }
        let baseFields = builtInEventBaseClassName(normalized).flatMap { builtInEventFields(for: $0) } ?? []
        let ownFields: [BASICClassField]
        switch normalized {
        case "BASICEVENT":
            ownFields = [
                eventField("Type", .scalar(.string), declaringClassName: normalized),
                eventField("Subtype", .scalar(.string), declaringClassName: normalized),
                eventField("Timestamp", .scalar(.double), declaringClassName: normalized),
                eventField("Target", .scalar(.string), declaringClassName: normalized),
                eventField("Handled", .scalar(.boolean), declaringClassName: normalized)
            ]
        case "BASICRESIZEEVENT":
            ownFields = [
                eventField("Width", .scalar(.integer), declaringClassName: normalized),
                eventField("Height", .scalar(.integer), declaringClassName: normalized)
            ]
        case "BASICMOUSEEVENT":
            ownFields = [
                eventField("X", .scalar(.integer), declaringClassName: normalized),
                eventField("Y", .scalar(.integer), declaringClassName: normalized),
                eventField("Button", .scalar(.integer), declaringClassName: normalized),
                eventField("Buttons", .scalar(.integer), declaringClassName: normalized),
                eventField("ButtonFlags", .scalar(.integer), declaringClassName: normalized),
                eventField("Duration", .scalar(.double), declaringClassName: normalized),
                eventField("DeltaX", .scalar(.double), declaringClassName: normalized),
                eventField("DeltaY", .scalar(.double), declaringClassName: normalized),
                eventField("HitId", .scalar(.string), declaringClassName: normalized)
            ]
        case "BASICTIMEREVENT":
            ownFields = [
                eventField("TimerID", .scalar(.integer), declaringClassName: normalized),
                eventField("Sequence", .scalar(.integer), declaringClassName: normalized),
                eventField("Tick", .scalar(.integer), declaringClassName: normalized),
                eventField("Ticks", .scalar(.integer), declaringClassName: normalized),
                eventField("Interval", .scalar(.integer), declaringClassName: normalized),
                eventField("BaseInterval", .scalar(.integer), declaringClassName: normalized),
                eventField("Elapsed", .scalar(.double), declaringClassName: normalized)
            ]
        case "BASICGAMEPADEVENT":
            ownFields = [
                eventField("Controller", .scalar(.integer), declaringClassName: normalized),
                eventField("Control", .scalar(.string), declaringClassName: normalized),
                eventField("Value", .scalar(.double), declaringClassName: normalized)
            ]
        case "BASICFRAMEEVENT":
            ownFields = [
                eventField("FrameID", .scalar(.string), declaringClassName: normalized),
                eventField("FrameType", .scalar(.string), declaringClassName: normalized),
                eventField("Reason", .scalar(.string), declaringClassName: normalized),
                eventField("Timeout", .scalar(.integer), declaringClassName: normalized),
                eventField("Raw", .scalar(.string), declaringClassName: normalized)
            ]
        case "BASICROUTEEVENT":
            ownFields = [
                eventField("RequestID", .scalar(.string), declaringClassName: normalized),
                eventField("Method", .scalar(.string), declaringClassName: normalized),
                eventField("Path", .scalar(.string), declaringClassName: normalized),
                eventField("Route", .scalar(.string), declaringClassName: normalized),
                eventField("Query", .scalar(.string), declaringClassName: normalized),
                eventField("Body", .scalar(.string), declaringClassName: normalized),
                eventField("Status", .scalar(.integer), declaringClassName: normalized)
            ]
        case "BASICNETWORKEVENT":
            ownFields = [
                eventField("Operation", .scalar(.string), declaringClassName: normalized),
                eventField("Url", .scalar(.string), declaringClassName: normalized),
                eventField("Status", .scalar(.integer), declaringClassName: normalized),
                eventField("Bytes", .scalar(.integer), declaringClassName: normalized),
                eventField("Error", .scalar(.string), declaringClassName: normalized),
                eventField("RequestID", .scalar(.string), declaringClassName: normalized)
            ]
        default:
            ownFields = []
        }
        return baseFields + ownFields
    }

    private static func builtInEventBaseClassName(_ normalizedName: String) -> String? {
        switch normalizedName {
        case "BASICRESIZEEVENT", "BASICMOUSEEVENT", "BASICTIMEREVENT", "BASICGAMEPADEVENT", "BASICFRAMEEVENT", "BASICROUTEEVENT", "BASICNETWORKEVENT":
            return "BASICEVENT"
        default:
            return nil
        }
    }

    private static func builtInEventDisplayName(_ normalizedName: String) -> String {
        switch normalizedName {
        case "BASICEVENT": return "BASICEvent"
        case "BASICRESIZEEVENT": return "BASICResizeEvent"
        case "BASICMOUSEEVENT": return "BASICMouseEvent"
        case "BASICTIMEREVENT": return "BASICTimerEvent"
        case "BASICGAMEPADEVENT": return "BASICGamepadEvent"
        case "BASICFRAMEEVENT": return "BASICFrameEvent"
        case "BASICROUTEEVENT": return "BASICRouteEvent"
        case "BASICNETWORKEVENT": return "BASICNetworkEvent"
        default: return normalizedName
        }
    }

    private static func eventField(
        _ name: String,
        _ type: BASICType,
        declaringClassName: String
    ) -> BASICClassField {
        BASICClassField(
            displayName: name,
            normalizedName: name.uppercased(),
            type: type,
            arrayDimensions: [],
            visibility: .public,
            declaringClassName: declaringClassName,
            json: nil,
            metadata: [:],
            defaultValue: nil
        )
    }

    private static func eventDefaultValue(for field: BASICClassField) -> BASICValue {
        switch field.type {
        case .scalar(.string):
            return .string(BASICString(""))
        case .scalar(.boolean):
            return .boolean(false)
        case .scalar(.variant):
            return .empty
        case .scalar:
            return .number(0)
        case .void:
            return .empty
        case .record(let name):
            return .record(name, [:])
        case .classType(let name):
            return builtInEventObject(typeName: name, fields: [:])
        case .interfaceType, .functionType:
            return .empty
        case .dictionary:
            return .dictionary(BASICDictionary())
        }
    }

    private func classConforms(_ className: String, toInterface interfaceName: String) -> Bool {
        guard let classDefinition = classDefinitions[className.uppercased()] else { return false }
        return inheritedInterfaceNames(for: classDefinition).contains {
            $0.uppercased() == interfaceName.uppercased()
        }
    }

    private func inheritedInterfaceNames(for classDefinition: BASICClassDefinition) -> [String] {
        var names: [String] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            names.append(contentsOf: inheritedInterfaceNames(for: baseDefinition))
        }
        for interfaceName in classDefinition.implementedInterfaces {
            names.append(interfaceName)
            if let interfaceDefinition = interfaceDefinitions[interfaceName.uppercased()] {
                names.append(contentsOf: inheritedInterfaceNames(for: interfaceDefinition))
            }
        }
        return names
    }

    private func inheritedInterfaceNames(for interfaceDefinition: BASICInterfaceDefinition) -> [String] {
        var names: [String] = []
        for interfaceName in interfaceDefinition.inheritedInterfaces {
            names.append(interfaceName)
            if let inheritedDefinition = interfaceDefinitions[interfaceName.uppercased()] {
                names.append(contentsOf: inheritedInterfaceNames(for: inheritedDefinition))
            }
        }
        return names
    }

    private func arraySummary(_ array: BASICArray) -> String {
        let bounds = array.dimensions.map { "0...\($0)" }.joined(separator: " x ")
        return "\(array.values.count) elements (\(bounds))"
    }

    private func elementName(for offset: Int, dimensions: [Int]) -> String {
        guard !dimensions.isEmpty else { return "(0)" }
        var remainder = offset
        var indexes = Array(repeating: 0, count: dimensions.count)
        for dimensionIndex in stride(from: dimensions.count - 1, through: 0, by: -1) {
            let size = dimensions[dimensionIndex] + 1
            indexes[dimensionIndex] = remainder % size
            remainder /= size
        }
        return "(\(indexes.map(String.init).joined(separator: ",")))"
    }
}
