import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class BASICInterpreter {
    private let program: BASICProgram
    private weak var host: BASICHost?
    /// Resolved once so the per-statement trace hook does not repeat a dynamic cast.
    private weak var loggingHost: (any BASICLoggingHost)?
    private let outputCoordinator: BASICHostOutputCoordinator
    let runtime: BASICRuntime
    private let fileState: BASICFileState
    private var executionControl: BASICExecutionControl?
    private let task: BASICTask?
    private weak var taskScheduler: BASICTaskScheduler?
    private weak var timerHost: BASICTimerHost?
    private let eventLoop: BASICEventLoop?
    private var gosubStack: [GosubFrame] = []
    private var forStack: [ForFrame] = []
    private var functionStack: [FunctionFrame] = []
    private var functionDefinitions: [String: FunctionDefinition] = [:]
    private var recordDefinitions: [String: BASICRecordDefinition] = [:]
    private var interfaceDefinitions: [String: BASICInterfaceDefinition] = [:]
    private var classDefinitions: [String: BASICClassDefinition] = [:]
    private var functionTypeDefinitions: [String: BASICFunctionTypeDefinition] = [:]
    private var legacyFiles: [Int: BASICOpenFile] = [:]
    private var lineIndexByNumber: [Int: Int] = [:]
    private var lineIndexByLabel: [String: Int] = [:]
    private var parsedLines: [ParsedLine] = []
    private var outputColumn = 0
    private var pausedDebugCallStack: [BASICCallStackFrame]?
    private var pausedDebugLocalVariables: [BASICVariableSnapshot]?
    private var pausedDebugFrameLocalVariables: [[BASICVariableSnapshot]]?
    private var pausedDebugGlobalVariables: [BASICVariableSnapshot]?
    private var pausedDebugCallDepth: Int?
    private var dataValues: [BASICValue] = []
    private var dataIndex = 0
    private var errorHandlerTarget: BranchTarget?
    private var isHandlingError = false
    private var errorResumePC: Int?
    private var errorResumeNextPC: Int?
    private var pc = 0
    private var isPrepared = false
    private var loggedMissingEventSelectors: Set<String> = []
    private var currentSourceFileName: String?
    private var currentLogModuleOverride: String?
    private var traceOverride: Bool?
    private var lastParseErrorLocation: (fileName: String?, lineNumber: Int)?
    private var currentGraphicsColor = BASICColor.legacy(1)
    private var currentTextForeground = BASICColor.legacy(7)
    private var currentTextBackground: BASICColor?
    private var currentGraphicsPoint = (x: 0, y: 0)

    /// Creates an interpreter with fresh runtime state.
    public convenience init(program: BASICProgram, host: BASICHost) {
        self.init(program: program, host: host, runtime: BASICRuntime(), fileState: BASICFileState(), executionControl: nil, task: nil, taskScheduler: nil, eventLoop: nil, outputCoordinator: nil)
    }

    init(
        program: BASICProgram,
        host: BASICHost,
        runtime: BASICRuntime,
        fileState: BASICFileState = BASICFileState(),
        executionControl: BASICExecutionControl? = nil,
        task: BASICTask? = nil,
        taskScheduler: BASICTaskScheduler? = nil,
        timerHost: BASICTimerHost? = nil,
        eventLoop: BASICEventLoop? = nil,
        outputCoordinator: BASICHostOutputCoordinator? = nil
    ) {
        self.program = program
        self.host = host
        self.loggingHost = host as? any BASICLoggingHost
        self.outputCoordinator = outputCoordinator ?? BASICHostOutputCoordinator(host: host)
        self.runtime = runtime
        self.fileState = fileState
        self.executionControl = executionControl
        self.task = task
        self.taskScheduler = taskScheduler
        self.timerHost = timerHost
        self.eventLoop = eventLoop
    }

    /// Starts execution, optionally from a numbered line.
    public func run(startLine: Int? = nil) throws {
        gosubStack.removeAll()
        forStack.removeAll()
        functionStack.removeAll()
        legacyFiles.removeAll()
        loggedMissingEventSelectors.removeAll()
        resetErrorTrap()
        outputColumn = 0
        try prepare(startLine: startLine)
        try continueExecution()
    }

    func setExecutionControl(_ executionControl: BASICExecutionControl?) {
        self.executionControl = executionControl
    }

    /// Parses and validates the interpreter program without running it.
    public func diagnostics() -> [BASICDiagnostic] {
        var diagnostics: [BASICDiagnostic] = []
        let rootLines = program.orderedLines

        for (index, line) in rootLines.enumerated() {
            do {
                var closureHeaderParser = try Parser(source: line.source)
                if try closureHeaderParser.parseClosureBlockAssignmentHeader() != nil {
                    continue
                }
                var parser = try Parser(source: line.source)
                _ = try parser.parseStatement()
            } catch let error as BASICError {
                diagnostics.append(
                    diagnostic(
                        for: error,
                        fileName: line.fileName,
                        sourceLineNumber: line.sourceLineNumber ?? index + 1,
                        fallbackColumn: 0
                    )
                )
            } catch {
                diagnostics.append(
                    BASICDiagnostic(
                        fileName: line.fileName,
                        lineNumber: line.sourceLineNumber ?? index + 1,
                        column: 0,
                        message: "Unexpected error: \(error)"
                    )
                )
            }
        }

        guard diagnostics.isEmpty else { return diagnostics }

        do {
            let sourceLines = try expandedProgramLines()
            let parsed: [ParsedLine]
            do {
                parsed = try parsedProgramLines(from: sourceLines)
            } catch let error as BASICError {
                let location = lastParseErrorLocation
                diagnostics.append(
                    diagnostic(
                        for: error,
                        fileName: location?.fileName,
                        sourceLineNumber: location?.lineNumber ?? 1,
                        fallbackColumn: 0
                    )
                )
                return diagnostics
            } catch {
                diagnostics.append(BASICDiagnostic(lineNumber: 1, column: 0, message: "Unexpected error: \(error)"))
                return diagnostics
            }
            guard diagnostics.isEmpty else { return diagnostics }

            do {
                recordDefinitions = try collectRecords(in: parsed)
                runtime.recordDefinitions = recordDefinitions
                interfaceDefinitions = try collectInterfaces(in: parsed)
                runtime.interfaceDefinitions = interfaceDefinitions
                functionTypeDefinitions = try collectFunctionTypes(in: parsed)
                runtime.functionTypeDefinitions = functionTypeDefinitions
                classDefinitions = try collectClasses(in: parsed)
                try validateInterfaceInheritance()
                try validateClassInheritance()
                try validateClassInterfaces()
                _ = try collectFunctions(in: parsed)
            } catch let error as BASICError {
                diagnostics.append(diagnostic(for: error, parsed: parsed))
            } catch {
                diagnostics.append(BASICDiagnostic(lineNumber: 1, column: 0, message: "Unexpected error: \(error)"))
            }

            return diagnostics
        } catch let error as BASICError {
            let location = lastParseErrorLocation
            return [
                diagnostic(
                    for: error,
                    fileName: location?.fileName,
                    sourceLineNumber: location?.lineNumber ?? 1,
                    fallbackColumn: 0
                )
            ]
        } catch {
            return [BASICDiagnostic(lineNumber: 1, column: 0, message: "Unexpected error: \(error)")]
        }
    }

    private func diagnostic(
        for error: BASICError,
        fileName: String? = nil,
        sourceLineNumber: Int,
        fallbackColumn: Int
    ) -> BASICDiagnostic {
        switch error {
        case .contextualSyntax(let message, _, let column):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: column, message: "Syntax error: \(message)")
        case .contextualType(let message, _, let column):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: column, message: "Type error: \(message)")
        case .syntax(let message):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: fallbackColumn, message: "Syntax error: \(message)")
        case .type(let message):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: fallbackColumn, message: "Type error: \(message)")
        default:
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: fallbackColumn, message: error.description)
        }
    }

    private func diagnostic(for error: BASICError, parsed: [ParsedLine]) -> BASICDiagnostic {
        let location = sourceLocation(for: error, parsed: parsed)
        return diagnostic(
            for: error,
            fileName: location?.fileName,
            sourceLineNumber: location?.lineNumber ?? 1,
            fallbackColumn: 0
        )
    }

    private func sourceLocation(for error: BASICError, parsed: [ParsedLine]) -> (fileName: String?, lineNumber: Int)? {
        let message = error.description
        var currentClassName: String?

        for line in parsed {
            switch line.statement {
            case .classDeclaration(let name):
                currentClassName = name
                if message.contains("CLASS \(name)") && !message.contains(" method ") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .endClass:
                currentClassName = nil
            case .interfaceDeclaration(let name):
                if message.contains("INTERFACE \(name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .functionTypeDeclaration(let name, _, _, _):
                if message.contains("FUNCTION TYPE \(name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .typeDeclaration(let name):
                if message.contains("TYPE \(name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .functionDeclaration(let name, _, _, _, _, _, _):
                let classMatches = currentClassName.map { message.contains("CLASS \($0)") } ?? true
                if classMatches && (message.contains("method \(name.name)") || message.contains("Function \(name.name)")) {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .classField(let name, _, _, _, _, _, _), .typeField(let name, _, _, _, _, _, _):
                if message.contains("field \(name)") || message.contains(" \(name) ") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .interfaceFunctionSignature(let name, _, _):
                if message.contains(".\(name.name)") || message.contains("member \(name.name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            default:
                continue
            }
        }

        if let rootLine = parsed.first(where: { !$0.isImported }) {
            return (rootLine.fileName, rootLine.sourceLineNumber)
        }
        return parsed.first.map { ($0.fileName, $0.sourceLineNumber) }
    }

    private func parsedProgramLines(from sourceLines: [ProgramLine]) throws -> [ParsedLine] {
        lastParseErrorLocation = nil
        var parsed: [ParsedLine] = []
        var index = 0
        while index < sourceLines.count {
            let line = sourceLines[index]
            var headerParser = try Parser(source: line.source)
            let header: (
                kind: AssignmentKind,
                variable: VariableName,
                declaredType: BASICType?,
                parameters: [FunctionParameter],
                returnType: BASICType,
                captures: [ClosureCaptureSpec]
            )?
            do {
                header = try headerParser.parseClosureBlockAssignmentHeader()
            } catch let error as BASICError {
                lastParseErrorLocation = (line.fileName, line.sourceLineNumber ?? index + 1)
                throw error
            }
            if let header {
                var body: [ClosureBodyLine] = []
                index += 1
                var foundEnd = false
                while index < sourceLines.count {
                    let bodyLine = sourceLines[index]
                    var parser = try Parser(source: bodyLine.source)
                    let statement: Statement
                    do {
                        statement = try parser.parseStatement()
                    } catch let error as BASICError {
                        lastParseErrorLocation = (bodyLine.fileName, bodyLine.sourceLineNumber ?? index + 1)
                        throw error
                    }
                    if case .endFunction = statement {
                        foundEnd = true
                        break
                    }
                    body.append(
                        ClosureBodyLine(
                            fileName: bodyLine.fileName,
                            sourceLineNumber: bodyLine.sourceLineNumber ?? index + 1,
                            statement: statement
                        )
                    )
                    index += 1
                }
                guard foundEnd else {
                    throw BASICError.runtime("FUNCTION closure without END FUNCTION")
                }
                parsed += ParsedLine.flatten(
                    number: line.number,
                    fileName: line.fileName,
                    sourceLineNumber: line.sourceLineNumber ?? parsed.count + 1,
                    isImported: line.isImported,
                    statement: .closureAssignment(
                        header.kind,
                        header.variable,
                        header.declaredType,
                        header.parameters,
                        header.returnType,
                        header.captures,
                        body
                    )
                )
                index += 1
                continue
            }

            var parser = try Parser(source: line.source)
            let statement: Statement
            do {
                statement = try parser.parseStatement()
            } catch let error as BASICError {
                lastParseErrorLocation = (line.fileName, line.sourceLineNumber ?? index + 1)
                throw error
            }
            parsed += ParsedLine.flatten(
                number: line.number,
                fileName: line.fileName,
                sourceLineNumber: line.sourceLineNumber ?? index + 1,
                isImported: line.isImported,
                statement: statement
            )
            index += 1
        }
        return parsed
    }

    func prepare(startLine: Int?) throws {
        let sourceLines = try expandedProgramLines()
        let parsed = try parsedProgramLines(from: sourceLines)
        parsedLines = parsed
        lineIndexByNumber = [:]
        lineIndexByLabel = [:]
        for (index, line) in parsed.enumerated() {
            if let number = line.number {
                lineIndexByNumber[number] = index
            }
            if let label = line.statement.label {
                lineIndexByLabel[label.uppercased()] = index
            }
        }
        recordDefinitions = try collectRecords(in: parsed)
        runtime.recordDefinitions = recordDefinitions
        interfaceDefinitions = try collectInterfaces(in: parsed)
        runtime.interfaceDefinitions = interfaceDefinitions
        functionTypeDefinitions = try collectFunctionTypes(in: parsed)
        runtime.functionTypeDefinitions = functionTypeDefinitions
        classDefinitions = try collectClasses(in: parsed)
        try validateInterfaceInheritance()
        try validateClassInheritance()
        try validateClassInterfaces()
        runtime.classDefinitions = classDefinitions
        functionDefinitions = try collectFunctions(in: parsed)
        dataValues = collectData(in: parsed)
        dataIndex = 0
        try seedHostVariables()

        pc = 0
        if let startLine {
            guard let index = lineIndexByNumber[startLine] else { throw BASICError.missingLine(startLine) }
            pc = index
        }
        isPrepared = true
    }

    private func seedHostVariables() throws {
        let currentDirectory = try (host as? BASICFileHost)?.currentDirectoryPath() ?? FileManager.default.currentDirectoryPath
        let columns = (host as? BASICConsoleHost)?.screenColumns() ?? 80
        let rows = (host as? BASICConsoleHost)?.screenRows() ?? 25
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "CURRENTDIR$", column: 0),
            declaredType: .scalar(.string),
            value: .string(BASICString(currentDirectory))
        )
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "SCREENWIDTH", column: 0),
            declaredType: .scalar(.double),
            value: .number(Double(columns))
        )
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "SCREENHEIGHT", column: 0),
            declaredType: .scalar(.double),
            value: .number(Double(rows))
        )
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "SCRIPT$", column: 0),
            declaredType: .scalar(.string),
            value: .string(BASICString(runtime.scriptPath))
        )
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "ARGC", column: 0),
            declaredType: .scalar(.double),
            value: .number(Double(runtime.scriptArguments.count))
        )
        try runtime.dim(
            kind: .global,
            variable: VariableName(name: "ARGV$", column: 0),
            dimensions: [max(0, runtime.scriptArguments.count - 1)],
            declaredType: .scalar(.string)
        )
        for (index, argument) in runtime.scriptArguments.enumerated() {
            try runtime.assign(
                reference: VariableReference(
                    base: VariableName(name: "ARGV$", column: 0),
                    indexes: [.number(Double(index))]
                ),
                indexes: [.number(Double(index))],
                value: .string(BASICString(argument))
            )
        }
    }

    private func expandedProgramLines() throws -> [ProgramLine] {
        var importedPaths: Set<String> = []
        var activeImportStack: [String] = []
        return try expandedProgramLines(from: program.orderedLines.map {
            ProgramLine(number: $0.number, source: $0.source, fileName: $0.fileName, sourceLineNumber: $0.sourceLineNumber, isImported: $0.isImported)
        }, importedPaths: &importedPaths, activeImportStack: &activeImportStack)
    }

    private func expandedProgramLines(
        from lines: [ProgramLine],
        importedPaths: inout Set<String>,
        activeImportStack: inout [String]
    ) throws -> [ProgramLine] {
        var expanded: [ProgramLine] = []
        for line in lines {
            let parsedStatement: Statement
            do {
                var closureHeaderParser = try Parser(source: line.source)
                if try closureHeaderParser.parseClosureBlockAssignmentHeader() != nil {
                    expanded.append(line)
                    continue
                }
                var parser = try Parser(source: line.source)
                parsedStatement = try parser.parseStatement()
            } catch let error as BASICError {
                if line.isImported {
                    lastParseErrorLocation = (line.fileName, line.sourceLineNumber ?? expanded.count + 1)
                }
                throw error
            } catch {
                if line.isImported {
                    lastParseErrorLocation = (line.fileName, line.sourceLineNumber ?? expanded.count + 1)
                }
                throw error
            }

            if case .importDirective(let path) = parsedStatement {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("IMPORT is not supported by this host")
                }
                let resolvedPath = Self.resolvedImportPath(path, relativeTo: line.fileName)
                if Self.isDirectoryImportPath(path) {
                    for importedFile in try Self.importedBasFiles(in: resolvedPath, using: fileHost) {
                        let normalizedImportedFile = Self.normalizedImportPath(importedFile)
                        try Self.validateImportCycle(for: normalizedImportedFile, activeImportStack: activeImportStack)
                        guard !importedPaths.contains(normalizedImportedFile) else { continue }
                        importedPaths.insert(normalizedImportedFile)
                        activeImportStack.append(normalizedImportedFile)
                        do {
                            let imported = BASICProgram.importedLines(from: try fileHost.loadTextFile(path: importedFile), fileName: importedFile)
                            expanded += try expandedProgramLines(
                                from: imported,
                                importedPaths: &importedPaths,
                                activeImportStack: &activeImportStack
                            )
                            _ = activeImportStack.popLast()
                        } catch {
                            _ = activeImportStack.popLast()
                            throw error
                        }
                    }
                } else {
                    try Self.validateImportCycle(for: resolvedPath, activeImportStack: activeImportStack)
                    guard !importedPaths.contains(resolvedPath) else { continue }
                    importedPaths.insert(resolvedPath)
                    activeImportStack.append(resolvedPath)
                    do {
                        let imported = BASICProgram.importedLines(from: try fileHost.loadTextFile(path: resolvedPath), fileName: resolvedPath)
                        expanded += try expandedProgramLines(
                            from: imported,
                            importedPaths: &importedPaths,
                            activeImportStack: &activeImportStack
                        )
                        _ = activeImportStack.popLast()
                    } catch {
                        _ = activeImportStack.popLast()
                        throw error
                    }
                }
            } else {
                expanded.append(line)
            }
        }
        return expanded
    }

    private static func validateImportCycle(for path: String, activeImportStack: [String]) throws {
        guard activeImportStack.contains(path) else { return }
        let cycle = (activeImportStack + [path]).joined(separator: " -> ")
        throw BASICError.runtime("Import cycle detected: \(cycle)")
    }

    private static func resolvedImportPath(_ path: String, relativeTo importer: String?) -> String {
        let normalizedPath = normalizedImportPath(path)
        guard !normalizedPath.hasPrefix("/"),
              let importer,
              let base = importDirectory(for: importer),
              !base.isEmpty
        else {
            return normalizedPath
        }
        return normalizedImportPath(base + "/" + normalizedPath)
    }

    private static func importDirectory(for fileName: String) -> String? {
        let normalized = normalizedImportPath(fileName)
        guard let separator = normalized.lastIndex(of: "/") else { return nil }
        return String(normalized[..<separator])
    }

    private static func normalizedImportPath(_ path: String) -> String {
        let usesTrailingSlash = path.hasSuffix("/") || path.hasSuffix("\\")
        let isAbsolute = path.hasPrefix("/") || path.hasPrefix("\\")
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var stack: [String] = []

        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(component)
                }
            default:
                stack.append(component)
            }
        }

        let prefix = isAbsolute ? "/" : ""
        let joined = prefix + stack.joined(separator: "/")
        guard usesTrailingSlash, !joined.isEmpty, !joined.hasSuffix("/") else { return joined }
        return joined + "/"
    }

    private static func isDirectoryImportPath(_ path: String) -> Bool {
        path.hasSuffix("/") || path.hasSuffix("\\")
    }

    private static func importedBasFiles(in path: String, using fileHost: BASICFileHost) throws -> [String] {
        var directory = path.replacingOccurrences(of: "\\", with: "/")
        while directory.hasSuffix("/") {
            directory.removeLast()
        }
        return try fileHost.listFiles(path: path)
            .filter { $0.lowercased().hasSuffix(".bas") }
            .map { joinImportPath(directory: directory, relativePath: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func joinImportPath(directory: String, relativePath: String) -> String {
        let cleanRelative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !directory.isEmpty else { return cleanRelative }
        return "\(directory)/\(cleanRelative)"
    }

    /// Continues execution after a breakpoint, step, or break request.
    public func continueExecution() throws {
        clearPausedDebugSnapshots()
        if !isPrepared {
            try prepare(startLine: nil)
        }
        if let task {
            taskScheduler?.markRunning(task)
        }

        defer {
            if let task, pc >= parsedLines.count, task.state == .running {
                taskScheduler?.markCompleted(task)
            }
        }

        while pc < parsedLines.count {
            if let task, task.isCancellationRequested {
                taskScheduler?.markCancelled(task)
                throw BASICError.breakRequested(parsedLines[safe: pc]?.displayLineNumber)
            }
            do {
                let current = parsedLines[pc]
                if current.isImported {
                    pc += 1
                    continue
                }
                updateExecutionLocation(current)
                try checkExecutionBreak()
                traceExecution(current)
                let next = try execute(current.statement, pc: pc, parsed: parsedLines)
                try apply(flow: next, currentPC: pc, parsed: parsedLines)
                try drainPendingEventsIfAllowed(limit: 16)
            } catch let error as BASICError {
                if error.isDebugPause {
                    snapshotPausedDebugState()
                    if let task {
                        if task.isCancellationRequested {
                            taskScheduler?.markCancelled(task)
                        } else {
                            taskScheduler?.markSuspended(task)
                        }
                    }
                    throw error
                }
                if try handleRuntimeError(error, faultPC: pc, parsed: parsedLines) {
                    continue
                }
                if let task {
                    taskScheduler?.markFailed(task, error: error)
                }
                throw error
            } catch {
                if let task {
                    taskScheduler?.markFailed(task, error: error)
                }
                throw error
            }

            if executionControl?.shouldPauseAfterStep(callDepth: debugCallDepth, taskID: task?.id) == true {
                if pc < parsedLines.count {
                    updateExecutionLocation(parsedLines[pc])
                    if let task {
                        taskScheduler?.markSuspended(task)
                    }
                    throw BASICError.stepComplete(parsedLines[pc].breakpointLocation)
                }
                return
            }
        }
    }

    private func apply(flow: Flow, currentPC: Int, parsed: [ParsedLine]) throws {
        switch flow {
        case .next:
            pc = currentPC + 1
        case .jump(let index):
            pc = index
        case .goto(let line):
            guard let index = lineIndexByNumber[line] else { throw BASICError.missingLine(line) }
            pc = index
        case .gotoLabel(let label):
            guard let index = lineIndexByLabel[label.uppercased()] else { throw BASICError.missingLabel(label) }
            pc = index
        case .returnTo(let index):
            pc = index
        case .end:
            pc = parsed.count
        case .exitSelect:
            guard let index = matchingEndSelect(after: currentPC, in: parsed) else {
                throw BASICError.runtime("EXIT SELECT without SELECT")
            }
            pc = index + 1
        case .functionReturn:
            throw BASICError.runtime("RETURN outside FUNCTION")
        }
    }

    private func resetErrorTrap() {
        errorHandlerTarget = nil
        isHandlingError = false
        errorResumePC = nil
        errorResumeNextPC = nil
    }

    @discardableResult
    private func handleRuntimeError(_ error: BASICError, faultPC: Int, parsed: [ParsedLine]) throws -> Bool {
        runtime.setLastError(
            number: errorNumber(for: error),
            line: parsed[safe: faultPC]?.displayLineNumber ?? 0,
            message: error.description
        )
        guard errorHandlerTarget != nil, !isHandlingError else {
            return false
        }
        errorResumePC = faultPC
        errorResumeNextPC = faultPC + 1
        isHandlingError = true
        try jumpToErrorHandler()
        return true
    }

    private func jumpToErrorHandler() throws {
        guard let target = errorHandlerTarget else {
            throw BASICError.runtime("No error handler")
        }
        switch target {
        case .line(let line):
            guard let index = lineIndexByNumber[line] else { throw BASICError.missingLine(line) }
            pc = index
        case .label(let label):
            guard let index = lineIndexByLabel[label.uppercased()] else { throw BASICError.missingLabel(label) }
            pc = index
        }
    }

    private func errorNumber(for error: BASICError) -> Int {
        switch error {
        case .numberedRuntime(let number):
            return number
        case .runtime(let message) where message.localizedCaseInsensitiveContains("division by zero"):
            return 11
        case .runtime(let message) where message.localizedCaseInsensitiveContains("type mismatch"):
            return 13
        case .type, .contextualType:
            return 13
        case .missingLine, .missingLabel:
            return 8
        default:
            return 5
        }
    }

    private func updateExecutionLocation(_ line: ParsedLine) {
        currentSourceFileName = line.fileName
        guard let executionControl else {
            task?.update(location: line.breakpointLocation)
            return
        }
        let location = executionControl.update(
            lineNumber: line.displayLineNumber,
            location: line.breakpointLocation,
            taskID: task?.id
        )
        if let location {
            task?.update(location: location)
        }
    }

    private func checkExecutionBreak() throws {
        try executionControl?.checkBreak(taskID: task?.id, location: task?.location)
    }

    private func throwPendingAsyncDebuggerPause() throws {
        guard task?.parentID == nil,
              let error = taskScheduler?.pendingDebuggerPause(excluding: task?.id) else {
            return
        }
        throw error
    }

    private func drainPendingEventsIfAllowed(limit: Int) throws {
        try throwPendingAsyncDebuggerPause()
        guard executionControl?.isStepping != true else { return }
        eventLoop?.runPending(limit: limit)
        try eventLoop?.throwPendingError()
        try throwPendingAsyncDebuggerPause()
    }

    private func defaultLogModuleName() -> String {
        guard let fileName = currentSourceFileName, !fileName.isEmpty else {
            return "Immediate"
        }
        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? fileName
    }

    var debugCallDepth: Int {
        pausedDebugCallDepth ?? gosubStack.count + functionStack.count
    }

    private var currentClassContext: String? {
        functionStack.last?.definition.ownerClassName
    }

    var debugLocalVariables: [BASICVariableSnapshot] {
        pausedDebugLocalVariables ?? runtime.localSnapshots()
    }

    var debugGlobalVariables: [BASICVariableSnapshot] {
        pausedDebugGlobalVariables ?? runtime.globalSnapshots()
    }

    var debugFiles: [BASICFileSnapshot] {
        let numbered = legacyFiles.keys.sorted().compactMap { handle -> BASICFileSnapshot? in
            guard let file = legacyFiles[handle] else { return nil }
            let logicalSize = file.contentType == .raw ? file.content.byteCount : file.content.characterCount
            return BASICFileSnapshot(
                id: "legacy:\(handle)",
                reference: "#\(handle)",
                path: file.path ?? "",
                access: file.access?.rawValue ?? "",
                type: file.legacyMode?.rawValue ?? file.contentType?.rawValue ?? "",
                position: file.position,
                size: file.content.byteCount,
                isAtEOF: file.position >= logicalSize,
                isOpen: file.isOpen,
                recordLength: file.recordLength,
                lastError: file.lastError
            )
        }
        return runtime.fileSnapshots + numbered
    }

    var debugCallStack: [BASICCallStackFrame] {
        pausedDebugCallStack ?? currentDebugCallStack()
    }

    var debugFrameLocalVariables: [[BASICVariableSnapshot]] {
        pausedDebugFrameLocalVariables ?? currentDebugFrameLocalVariables()
    }

    private func currentDebugCallStack() -> [BASICCallStackFrame] {
        var frames: [BASICCallStackFrame] = []

        for (offset, frame) in functionStack.reversed().enumerated() {
            frames.append(
                BASICCallStackFrame(
                    index: offset,
                    kind: debugFrameKind(for: frame.definition),
                    name: frame.definition.ownerClassName.map { "\($0).\((frame.definition.displayName))" } ?? frame.definition.displayName,
                    location: offset == 0
                        ? task?.location ?? parsedLines[safe: frame.definition.startIndex]?.breakpointLocation
                        : parsedLines[safe: frame.definition.startIndex]?.breakpointLocation,
                    declaringClassName: frame.definition.ownerClassName,
                    receiverClassName: frame.receiverClassName,
                    isOverride: frame.definition.isOverride
                )
            )
        }

        for (offset, frame) in gosubStack.reversed().enumerated() {
            frames.append(
                BASICCallStackFrame(
                    index: frames.count + offset,
                    kind: "GOSUB",
                    name: "Return",
                    location: parsedLines[safe: frame.returnIndex]?.breakpointLocation,
                    declaringClassName: nil,
                    receiverClassName: nil,
                    isOverride: false
                )
            )
        }

        frames.append(
            BASICCallStackFrame(
                index: frames.count,
                kind: "Program",
                name: "[main]",
                location: parsedLines[safe: pc]?.breakpointLocation,
                declaringClassName: nil,
                receiverClassName: nil,
                isOverride: false
            )
        )

        return frames
    }

    private func currentDebugFrameLocalVariables() -> [[BASICVariableSnapshot]] {
        var snapshots: [[BASICVariableSnapshot]] = []

        for frame in functionStack.reversed() {
            snapshots.append(runtime.localSnapshots(contextIndex: frame.localContextIndex))
        }

        for frame in gosubStack.reversed() {
            snapshots.append(runtime.localSnapshots(contextIndex: frame.localContextIndex))
        }

        snapshots.append([])
        return snapshots
    }

    private func currentSuspendedFrames(
        fallbackKind: String,
        fallbackName: String,
        fallbackLocation: BASICBreakpointLocation?
    ) -> [BASICSuspendedFrame] {
        let stack = currentDebugCallStack()
        let frameLocals = currentDebugFrameLocalVariables()
        guard !stack.isEmpty else {
            return [
                BASICSuspendedFrame(
                    kind: fallbackKind,
                    name: fallbackName,
                    resumeLocation: fallbackLocation,
                    localScopeDepth: functionStack.count,
                    localVariables: runtime.localSnapshots()
                )
            ]
        }

        return stack.enumerated().map { offset, frame in
            BASICSuspendedFrame(
                kind: frame.kind,
                name: frame.name,
                resumeLocation: frame.location ?? fallbackLocation,
                localScopeDepth: max(0, functionStack.count - offset),
                localVariables: frameLocals[safe: offset] ?? []
            )
        }
    }

    private func debugFrameKind(for definition: FunctionDefinition) -> String {
        guard definition.ownerClassName != nil else { return "Function" }
        if definition.normalizedName == "NEW" { return "Constructor" }
        return "Method"
    }

    private func snapshotPausedDebugState() {
        guard pausedDebugCallStack == nil else { return }
        pausedDebugCallStack = currentDebugCallStack()
        pausedDebugLocalVariables = runtime.localSnapshots()
        pausedDebugFrameLocalVariables = currentDebugFrameLocalVariables()
        pausedDebugGlobalVariables = runtime.globalSnapshots()
        pausedDebugCallDepth = gosubStack.count + functionStack.count
    }

    private func clearPausedDebugSnapshots() {
        pausedDebugCallStack = nil
        pausedDebugLocalVariables = nil
        pausedDebugFrameLocalVariables = nil
        pausedDebugGlobalVariables = nil
        pausedDebugCallDepth = nil
    }

    private func execute(_ statement: Statement, pc: Int, parsed: [ParsedLine] = []) throws -> Flow {
        do {
            let flow = try executeUnchecked(statement, pc: pc, parsed: parsed)
            clearLegacyFileError(for: statement)
            return flow
        } catch {
            recordLegacyFileError(error, for: statement)
            throw error
        }
    }

    private func executeUnchecked(_ statement: Statement, pc: Int, parsed: [ParsedLine] = []) throws -> Flow {
        switch statement {
        case .empty, .remark, .data, .defFunction, .functionTypeDeclaration:
            return .next
        case .typeDeclaration:
            guard let index = matchingEndType(after: pc, in: parsed) else {
                throw BASICError.runtime("TYPE without END TYPE")
            }
            return .jump(index + 1)
        case .typeField, .endType:
            return .next
        case .interfaceDeclaration:
            guard let index = matchingEndInterface(after: pc, in: parsed) else {
                throw BASICError.runtime("INTERFACE without END INTERFACE")
            }
            return .jump(index + 1)
        case .interfaceFunctionSignature, .endInterface:
            return .next
        case .classDeclaration:
            guard let index = matchingEndClass(after: pc, in: parsed) else {
                throw BASICError.runtime("CLASS without END CLASS")
            }
            return .jump(index + 1)
        case .classField, .implementsDeclaration, .inheritsDeclaration, .endClass:
            return .next
        case .importDirective:
            return .next
        case .label:
            return .next
        case .labeled(_, let statement):
            return try execute(statement, pc: pc, parsed: parsed)
        case .sequence(let statements):
            for statement in statements {
                let flow = try execute(statement, pc: pc, parsed: parsed)
                if flow != .next {
                    return flow
                }
            }
            return .next
        case .end:
            return .end
        case .functionDeclaration:
            guard let index = matchingEndFunction(after: pc, in: parsed) else {
                throw BASICError.runtime("FUNCTION without END FUNCTION")
            }
            return .jump(index + 1)
        case .endFunction:
            if !functionStack.isEmpty {
                return .functionReturn
            }
            return .next
        case .print(let parts):
            let rendered = try renderPrint(parts, startColumn: outputColumn)
            outputCoordinator.print(rendered.text, terminator: rendered.terminator)
            updateOutputColumn(rendered)
            return .next
        case .printUsing(let format, let values, let trailingSeparator):
            let rendered = try renderUsing(format: format, values: values, trailingSeparator: trailingSeparator, startColumn: outputColumn)
            outputCoordinator.print(rendered.text, terminator: rendered.terminator)
            updateOutputColumn(rendered)
            return .next
        case .log(let level, let parts):
            guard let loggingHost,
                  loggingHost.isBASICLoggingEnabled else {
                return .next
            }
            let rendered = try renderPrint(parts, startColumn: 0)
            outputCoordinator.log(
                level: try string(level),
                issuer: "U",
                module: currentLogModuleOverride ?? defaultLogModuleName(),
                text: rendered.text
            )
            return .next
        case .module(let name):
            currentLogModuleOverride = try string(name)
            return .next
        case .traceOn:
            traceOverride = true
            return .next
        case .traceOff:
            traceOverride = false
            return .next
        case .printFile(let number, let parts):
            try printLegacyFile(number: number, parts: parts)
            return .next
        case .printFileUsing(let number, let format, let values, let trailingSeparator):
            try printLegacyFileUsing(number: number, format: format, values: values, trailingSeparator: trailingSeparator)
            return .next
        case .screen(let expression):
            let modeNumber = try integer(expression)
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            graphicsHost.setScreenMode(nativeScreenMode(for: modeNumber))
            return .next
        case .color(let expressions):
            let (color, background) = try resolveColorStatement(expressions)
            currentTextForeground = color
            currentTextBackground = background
            outputCoordinator.print(ansiColorSequence(foreground: color, background: background), terminator: "")
            currentGraphicsColor = color
            if let graphicsHost = host as? BASICGraphicsHost, graphicsHost.isGraphicsAvailable {
                graphicsHost.setGraphicsColor(color)
            }
            return .next
        case .cls:
            outputCoordinator.printLine("\u{001B}[2J\u{001B}[H")
            if let graphicsHost = host as? BASICGraphicsHost, graphicsHost.isGraphicsAvailable {
                graphicsHost.clearGraphics(color: nil)
            }
            outputColumn = 0
            return .next
        case .locate(let rowExpression, let columnExpression):
            let row = try integer(rowExpression)
            let column = try integer(columnExpression)
            if let consoleHost = host as? BASICConsoleHost {
                try consoleHost.locate(row: row, column: column)
            } else {
                let safeRow = max(1, row)
                let safeColumn = max(1, column)
                outputCoordinator.print("\u{001B}[\(safeRow);\(safeColumn)H", terminator: "")
            }
            outputColumn = max(0, column - 1)
            return .next
        case .pset(let point, let color):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            let resolved = try resolve(point: point)
            let resolvedColor = try color.map(resolveColor) ?? currentGraphicsColor
            graphicsHost.setPixel(x: resolved.x, y: resolved.y, color: resolvedColor)
            currentGraphicsPoint = resolved
            return .next
        case .preset(let point, let color):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            let resolved = try resolve(point: point)
            let resolvedColor = try color.map(resolveColor) ?? BASICColor.legacy(0)
            graphicsHost.setPixel(x: resolved.x, y: resolved.y, color: resolvedColor)
            currentGraphicsPoint = resolved
            return .next
        case .line(let start, let end, let color):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            let resolvedStart = try resolve(point: start)
            let resolvedEnd = try resolve(point: end)
            let resolvedColor = try color.map(resolveColor) ?? currentGraphicsColor
            graphicsHost.drawLine(
                x1: resolvedStart.x,
                y1: resolvedStart.y,
                x2: resolvedEnd.x,
                y2: resolvedEnd.y,
                color: resolvedColor
            )
            currentGraphicsPoint = resolvedEnd
            return .next
        case .circle(let center, let radius, let color, let aspect):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            let resolvedCenter = try resolve(point: center)
            let resolvedRadius = try integer(radius)
            let resolvedColor = try color.map(resolveColor) ?? currentGraphicsColor
            if let aspect {
                let radii = try ellipseRadii(radius: resolvedRadius, aspect: aspect)
                graphicsHost.drawEllipse(
                    cx: resolvedCenter.x,
                    cy: resolvedCenter.y,
                    radiusX: radii.x,
                    radiusY: radii.y,
                    color: resolvedColor
                )
            } else {
                graphicsHost.drawCircle(
                    cx: resolvedCenter.x,
                    cy: resolvedCenter.y,
                    radius: resolvedRadius,
                    color: resolvedColor
                )
            }
            currentGraphicsPoint = resolvedCenter
            return .next
        case .paint(let point, let color, let borderColor):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            let resolvedPoint = try resolve(point: point)
            let resolvedColor = try resolveColor(color)
            let resolvedBorderColor = try borderColor.map(resolveColor)
            graphicsHost.paintFill(
                x: resolvedPoint.x,
                y: resolvedPoint.y,
                color: resolvedColor,
                borderColor: resolvedBorderColor
            )
            currentGraphicsPoint = resolvedPoint
            return .next
        case .draw(let expression):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            try drawGraphicsPath(try string(expression), graphicsHost: graphicsHost)
            return .next
        case .assignment(let kind, let variable, let declaredType, let expression):
            let value = try expression.map(evaluate)
            if try assignFunctionReturnIfNeeded(variable: variable, declaredType: declaredType, value: value) {
                return .next
            }
            try runtime.assign(kind: kind, variable: variable, declaredType: declaredType, value: value)
            return .next
        case .closureAssignment(let kind, let variable, let declaredType, let parameters, let returnType, let captures, let body):
            let environment = BASICCapturedEnvironment()
            let parameterNames = Set(parameters.map { $0.variable.normalized })
            let captureSpecs = captures.isEmpty
                ? capturedVariableNames(in: body)
                    .filter { !parameterNames.contains($0.normalized) }
                    .map { ClosureCaptureSpec(variable: $0, access: .readOnly) }
                : captures.filter { !parameterNames.contains($0.variable.normalized) }
            for capture in captureSpecs {
                _ = environment.capture(
                    name: capture.variable.name,
                    value: runtime.value(for: capture.variable),
                    access: capture.access
                )
            }
            try runtime.assign(
                kind: kind,
                variable: variable,
                declaredType: declaredType,
                value: .closure(BASICCapturedClosure(
                    name: variable.name,
                    parameters: parameters,
                    returnType: returnType,
                    bodyStatements: body,
                    environment: environment
                ))
            )
            return .next
        case .referenceAssignment(let reference, let expression):
            let value = try expression.map(evaluate)
            try runtime.assign(
                reference: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                value: value,
                accessClassName: currentClassContext
            )
            return .next
        case .expression(let expression):
            let value = try evaluateStandaloneExpression(expression)
            if case .task(let handle) = value {
                _ = taskScheduler?.requestCancellation(id: handle.id)
                throw BASICError.runtime("Task result was ignored; use AWAIT, assign it to a TASK variable, or launch it with BACKGROUND")
            }
            return .next
        case .dim(let kind, let variable, let dimensions, let declaredType):
            try runtime.dim(kind: kind, variable: variable, dimensions: try dimensions.map { try $0.map(integer) }, declaredType: declaredType)
            return .next
        case .optionLetMode(let mode):
            runtime.letMode = mode
            return .next
        case .optionKeyMode(let mode):
            runtime.keyMode = mode
            return .next
        case .optionEventInput(let type, let mode):
            switch type.uppercased() {
            case "MOUSE":
                runtime.mouseEventMode = mode
            case "GAMEPAD":
                runtime.gamepadEventMode = mode
            default:
                break
            }
            synchronizeHostInput(for: type)
            return .next
        case .optionShellMode(let enabled):
            runtime.shellModeEnabled = enabled
            return .next
        case .optionStringSubstitution(let enabled):
            runtime.stringSubstitutionEnabled = enabled
            return .next
        case .input(let prompt, let target):
            let promptText = try prompt.map(string) ?? "\(inputTargetName(target))? "
            let raw = host?.readLine(prompt: promptText) ?? ""
            try assignReadValue(try inputValue(from: raw, to: target), to: target)
            return .next
        case .lineInput(let prompt, let target, let exitTarget, let fieldLength, let maxLength, let defaultValue):
            let promptText = try prompt.map(string) ?? ""
            let length = try fieldLength.map(integer)
            let maximum = try maxLength.map(integer)
            let defaultText = try defaultValue.map(string)
            if let length, length <= 0 {
                throw BASICError.runtime("LINE INPUT LENGTH must be greater than zero")
            }
            if let maximum, maximum < 0 {
                throw BASICError.runtime("LINE INPUT MAX must be zero or greater")
            }
            let options = BASICLineInputOptions(fieldLength: length, maxLength: maximum, defaultText: defaultText)
            let result: BASICLineInputResult
            if let lineInputHost = host as? BASICConfiguredLineInputHost {
                result = lineInputHost.readLine(prompt: promptText, exitOnSpecialKey: exitTarget != nil, options: options) ?? BASICLineInputResult(text: defaultText ?? "")
            } else if exitTarget != nil, let lineInputHost = host as? BASICLineInputHost {
                result = lineInputHost.readLine(prompt: promptText, exitOnSpecialKey: true) ?? BASICLineInputResult(text: defaultText ?? "")
            } else {
                result = BASICLineInputResult(text: host?.readLine(prompt: promptText) ?? defaultText ?? "")
            }
            let text = maximum.map { String(result.text.prefix($0)) } ?? result.text
            try assignReadValue(.string(BASICString(text)), to: target)
            if let exitTarget {
                try assignReadValue(.string(BASICString(result.exitKey ?? "")), to: exitTarget)
            }
            outputColumn = 0
            return .next
        case .openFile(let path, let mode, let number, let recordLength):
            try openLegacyFile(path: path, mode: mode, number: number, recordLength: recordLength)
            return .next
        case .closeFile(let number):
            try closeLegacyFile(number: number)
            return .next
        case .putFile(let number, let parts):
            let handle = try legacyFileHandle(number)
            if legacyFiles[handle]?.legacyMode == .random {
                try putLegacyRecord(handle: handle, parts: parts)
            } else {
                try printLegacyFile(number: number, parts: parts)
            }
            return .next
        case .getFile(let number, let targets):
            try inputLegacyFile(number: number, targets: targets)
            return .next
        case .getRecordFile(let number, let record):
            try getLegacyRecord(handle: legacyFileHandle(number), record: record)
            return .next
        case .writeFile(let number, let values):
            try writeLegacyFile(number: number, values: values)
            return .next
        case .fieldFile(let number, let fields):
            try defineLegacyFields(number: number, fields: fields)
            return .next
        case .setFieldString(let target, let value, let rightAligned):
            try setLegacyFieldString(target: target, value: value, rightAligned: rightAligned)
            return .next
        case .seekFile(let number, let position):
            try seekLegacyFile(number: number, position: position)
            return .next
        case .resetFile(let number):
            try resetLegacyFile(number: number)
            return .next
        case .inputFile(let number, let targets):
            try inputLegacyFile(number: number, targets: targets)
            return .next
        case .lineInputFile(let number, let target):
            try lineInputLegacyFile(number: number, target: target)
            return .next
        case .read(let targets):
            try readData(into: targets)
            return .next
        case .restore:
            dataIndex = 0
            return .next
        case .load(let path):
            let resolvedPath = try string(path)
            try loadProgram(path: resolvedPath)
            return .next
        case .save(let path):
            let resolvedPath = try path.map(string) ?? fileState.lastFilePath
            guard let resolvedPath else { throw BASICError.syntax("Expected path after SAVE") }
            try saveProgram(path: resolvedPath)
            return .next
        case .cd(let path):
            try changeDirectory(path: path)
            return .next
        case .pwd:
            guard let fileHost = host as? BASICFileHost else {
                throw BASICError.runtime("PWD is not supported by this host")
            }
            outputCoordinator.printLine(try fileHost.currentDirectoryPath())
            return .next
        case .files:
            try listFiles()
            return .next
        case .setEnvironment(let name, let value):
            runtime.setEnvironmentValue(name: try string(name), value: try string(value))
            return .next
        case .unsetEnvironment(let name):
            runtime.unsetEnvironmentValue(name: try string(name))
            return .next
        case .exportEnvironment(let name, let value):
            let exportedValue = try value.map(evaluate) ?? runtime.value(for: VariableName(name: name, column: 0))
            try runtime.exportEnvironmentValue(name: environmentName(forExport: name), value: exportedValue)
            return .next
        case .which(let command):
            try printExecutablePath(command: try string(command))
            return .next
        case .typeCommand(let command):
            try printCommandType(command: try string(command))
            return .next
        case .pushDirectory(let path):
            try pushDirectory(path: path)
            return .next
        case .popDirectory:
            try popDirectory()
            return .next
        case .directoryStack:
            try printDirectoryStack()
            return .next
        case .system(let command):
            let output = try runSystemCommand(command)
            if !output.isEmpty {
                outputCoordinator.print(output, terminator: "")
                updateOutputColumn(text: output, terminator: "")
            }
            return .next
        case .exec(let command, let arguments, let stdout, let stderr, let tty, let timeout):
            let result = try runStructuredProcess(
                command: command,
                arguments: arguments,
                stdout: stdout,
                stderr: stderr,
                tty: tty,
                timeout: timeout
            )
            if let stdout {
                try assignReadValue(.string(BASICString(result.stdout)), to: stdout)
            }
            if let stderr {
                try assignReadValue(.string(BASICString(result.stderr)), to: stderr)
            }
            if stdout == nil && !result.stdout.isEmpty {
                outputCoordinator.print(result.stdout, terminator: "")
                updateOutputColumn(text: result.stdout, terminator: "")
            }
            if stderr == nil && !result.stderr.isEmpty {
                outputCoordinator.print(result.stderr, terminator: "")
                updateOutputColumn(text: result.stderr, terminator: "")
            }
            return .next
        case .pipe(let input, let stages):
            let result = try runStructuredPipeline(input: input, stages: stages)
            if !result.stdout.isEmpty {
                outputCoordinator.print(result.stdout, terminator: "")
                updateOutputColumn(text: result.stdout, terminator: "")
            }
            if !result.stderr.isEmpty {
                outputCoordinator.print(result.stderr, terminator: "")
                updateOutputColumn(text: result.stderr, terminator: "")
            }
            return .next
        case .background(let expression):
            let value = try evaluate(expression)
            guard case .task(let handle) = value,
                  taskScheduler?.markBackground(id: handle.id) == true else {
                throw BASICError.runtime("BACKGROUND requires an async task")
            }
            return .next
        case .join(let expression):
            try joinTask(try evaluate(expression))
            return .next
        case .cancelTask(let expression):
            guard let taskScheduler else {
                throw BASICError.runtime("CANCEL is not supported outside a running BASIC session")
            }
            let taskID = try taskHandleID(from: evaluate(expression), operation: "CANCEL")
            _ = taskScheduler.markObserved(id: taskID)
            guard taskScheduler.requestCancellation(id: taskID) else {
                throw BASICError.runtime("CANCEL requires a known task handle")
            }
            return .next
        case .yield:
            task?.recordYield()
            try drainPendingEventsIfAllowed(limit: 8)
            return .next
        case .randomize(let expression):
            let seed = try expression.map { try numeric(try evaluate($0)) } ?? Date().timeIntervalSince1970
            runtime.randomGenerator.randomize(seed: seed)
            return .next
        case .goto(let line):
            return .goto(line)
        case .gotoLabel(let label):
            return .gotoLabel(label)
        case .computedGoto(let targets, let selector):
            let selected = try integer(selector)
            guard selected >= 1, selected <= targets.count else {
                return .next
            }
            return targets[selected - 1].flow
        case .computedGosub(let targets, let selector):
            let selected = try integer(selector)
            guard selected >= 1, selected <= targets.count else {
                return .next
            }
            let localContextIndex = runtime.pushLocalContext()
            let target = targets[selected - 1]
            gosubStack.append(GosubFrame(
                returnIndex: pc + 1,
                localContextIndex: localContextIndex,
                functionDepth: functionStack.count,
                displayName: gosubDisplayName(for: target)
            ))
            return target.flow
        case .onErrorGoto(let target):
            errorHandlerTarget = target
            isHandlingError = false
            errorResumePC = nil
            errorResumeNextPC = nil
            return .next
        case .onEventCall(let selector, let handler):
            guard let definition = functionDefinitions[handler.normalized] else {
                throw BASICError.runtime("Function \(handler.name) is not defined")
            }
            guard !definition.isAsync else {
                throw BASICError.runtime("Event handler \(handler.name) must be synchronous")
            }
            runtime.setEventHandler(selector: selector, handler: handler)
            synchronizeHostInput(for: selector.type)
            return .next
        case .onTimerEvent(let timer, let ticksExpression, let handler):
            guard let definition = functionDefinitions[handler.normalized] else {
                throw BASICError.runtime("Timer handler \(handler.name) must be a FUNCTION")
            }
            guard !definition.isAsync else {
                throw BASICError.runtime("Timer handler \(handler.name) must be synchronous")
            }
            let timerValue = runtime.value(for: timer)
            guard case .systemObject(let typeName, let id) = timerValue,
                  typeName.uppercased() == "SECONDSTIMER" else {
                throw BASICError.runtime("\(timer.name) is not a SecondsTimer")
            }
            let ticks = try ticksExpression.map(integer) ?? 1
            guard ticks > 0 else {
                throw BASICError.runtime("Timer ticks must be greater than zero")
            }
            try runtime.setTimerEventHandler(id: id, ticks: ticks, handler: handler)
            return .next
        case .error(let expression):
            throw BASICError.numberedRuntime(try integer(expression))
        case .resumeNext:
            guard isHandlingError else {
                throw BASICError.runtime("RESUME without error")
            }
            guard let resumeNextPC = errorResumeNextPC else {
                throw BASICError.runtime("No error to resume")
            }
            isHandlingError = false
            errorResumePC = nil
            errorResumeNextPC = nil
            return .jump(resumeNextPC)
        case .gosub(let target):
            let localContextIndex = runtime.pushLocalContext()
            gosubStack.append(GosubFrame(
                returnIndex: pc + 1,
                localContextIndex: localContextIndex,
                functionDepth: functionStack.count,
                displayName: gosubDisplayName(for: target)
            ))
            return target.flow
        case .returnFromSubroutine:
            if let frame = gosubStack.last, frame.functionDepth == functionStack.count {
                _ = gosubStack.popLast()
                runtime.popLocalContext()
                return .returnTo(frame.returnIndex)
            }
            if !functionStack.isEmpty {
                try setFunctionReturn(nil)
                return .functionReturn
            }
            guard let frame = gosubStack.popLast() else {
                throw BASICError.runtime("RETURN without GOSUB")
            }
            runtime.popLocalContext()
            return .returnTo(frame.returnIndex)
        case .returnValue(let expression):
            guard !functionStack.isEmpty else {
                throw BASICError.runtime("RETURN value outside FUNCTION")
            }
            try setFunctionReturn(try evaluate(expression))
            return .functionReturn
        case .pause:
            if host?.readLine(prompt: "PAUSE") == nil {
                outputCoordinator.printLine("PAUSE")
                outputColumn = 0
            }
            return .next
        case .exitFunction:
            guard !functionStack.isEmpty else {
                throw BASICError.runtime("EXIT FUNCTION outside FUNCTION")
            }
            return .functionReturn
        case .ifThen(let condition, let thenAction, let elseAction):
            if try evaluate(condition).truthy {
                return try execute(thenAction, pc: pc, parsed: parsed)
            }
            guard let elseAction else { return .next }
            return try execute(elseAction, pc: pc, parsed: parsed)
        case .blockIf(let condition):
            return try blockIfFlow(condition, pc: pc, parsed: parsed)
        case .elseIf:
            guard let index = matchingEndIf(after: pc, in: parsed) else {
                throw BASICError.runtime("ELSEIF without END IF")
            }
            return .jump(index + 1)
        case .elseBlock:
            guard let index = matchingEndIf(after: pc, in: parsed) else {
                throw BASICError.runtime("ELSE without END IF")
            }
            return .jump(index + 1)
        case .endIf:
            return .next
        case .forLoop(let variable, let start, let end, let step):
            return try forLoopFlow(variable: variable, start: start, end: end, step: step, pc: pc, parsed: parsed)
        case .nextLoop(let variables):
            return try nextLoopFlow(variables: variables)
        case .selectCase(let expression):
            return try selectCaseFlow(expression, pc: pc, parsed: parsed)
        case .caseClause, .caseElse:
            guard let index = matchingEndSelect(after: pc, in: parsed) else {
                throw BASICError.runtime("CASE without SELECT")
            }
            return .jump(index + 1)
        case .endSelect:
            return .next
        case .exitSelect:
            return .exitSelect
        }
    }

    private func legacyFileNumber(in statement: Statement) -> Expression? {
        switch statement {
        case .closeFile(let number): return number
        case .putFile(let number, _), .getFile(let number, _), .getRecordFile(let number, _),
             .writeFile(let number, _), .fieldFile(let number, _), .seekFile(let number, _),
             .resetFile(let number), .printFile(let number, _), .printFileUsing(let number, _, _, _),
             .inputFile(let number, _), .lineInputFile(let number, _):
            return number
        default:
            return nil
        }
    }

    private func clearLegacyFileError(for statement: Statement) {
        guard let number = legacyFileNumber(in: statement),
              let handle = try? legacyFileHandle(number) else { return }
        legacyFiles[handle]?.lastError = nil
    }

    private func recordLegacyFileError(_ error: Error, for statement: Statement) {
        if case .setFieldString(let target, _, _) = statement {
            let variableName = inputTargetName(target).uppercased()
            for handle in legacyFiles.keys where legacyFiles[handle]?.fields.contains(where: { $0.variable.normalized == variableName }) == true {
                legacyFiles[handle]?.lastError = String(describing: error)
            }
            return
        }
        guard let number = legacyFileNumber(in: statement),
              let handle = try? legacyFileHandle(number) else { return }
        legacyFiles[handle]?.lastError = String(describing: error)
    }

    private func forLoopFlow(
        variable: VariableName,
        start: Expression,
        end: Expression,
        step: Expression?,
        pc: Int,
        parsed: [ParsedLine]
    ) throws -> Flow {
        let startValue = try numeric(try evaluate(start))
        let endValue = try numeric(try evaluate(end))
        let stepValue = try step.map { try numeric(try evaluate($0)) } ?? 1
        guard stepValue != 0 else {
            throw BASICError.runtime("FOR STEP cannot be 0")
        }

        try runtime.assign(kind: .bare, variable: variable, declaredType: nil, value: .number(startValue))
        let entersLoop = stepValue > 0 ? startValue <= endValue : startValue >= endValue
        guard entersLoop else {
            guard let index = matchingNext(after: pc, in: parsed) else {
                throw BASICError.runtime("FOR without NEXT")
            }
            return .jump(index + 1)
        }

        forStack.append(ForFrame(variable: variable, endValue: endValue, stepValue: stepValue, loopStartIndex: pc))
        return .next
    }

    private func nextLoopFlow(variables: [VariableName]) throws -> Flow {
        if variables.isEmpty {
            return try advanceNextLoop(variable: nil)
        }

        for variable in variables {
            let flow = try advanceNextLoop(variable: variable)
            if flow != .next {
                return flow
            }
        }
        return .next
    }

    private func collectFunctions(in parsed: [ParsedLine]) throws -> [String: FunctionDefinition] {
        var definitions: [String: FunctionDefinition] = [:]
        var index = 0
        while index < parsed.count {
            switch parsed[index].statement {
            case .interfaceDeclaration:
                guard let endIndex = matchingEndInterface(after: index, in: parsed) else {
                    throw BASICError.runtime("INTERFACE without END INTERFACE")
                }
                index = endIndex + 1
                continue
            case .classDeclaration:
                guard let endIndex = matchingEndClass(after: index, in: parsed) else {
                    throw BASICError.runtime("CLASS without END CLASS")
                }
                index = endIndex + 1
                continue
            case .functionDeclaration(let name, let parameters, let returnType, let isAsync, _, _, _):
                guard let endIndex = matchingEndFunction(after: index, in: parsed) else {
                    throw BASICError.runtime("FUNCTION without END FUNCTION")
                }
                let definition = FunctionDefinition(
                    displayName: name.name,
                    normalizedName: name.normalized,
                    parameters: parameters,
                    returnType: returnType,
                    isAsync: isAsync,
                    startIndex: index,
                    endIndex: endIndex
                )
                if definitions[name.normalized] != nil {
                    throw BASICError.runtime("Function \(name.name) is already defined")
                }
                definitions[name.normalized] = definition
                index = endIndex + 1
                continue
            case .defFunction(let name, let parameter, let returnType, let body):
                let definition = FunctionDefinition(
                    displayName: name.name,
                    normalizedName: name.normalized,
                    parameters: [parameter],
                    returnType: returnType,
                    startIndex: index,
                    endIndex: index,
                    bodyExpression: body
                )
                if definitions[name.normalized] != nil {
                    throw BASICError.runtime("Function \(name.name) is already defined")
                }
                definitions[name.normalized] = definition
            default:
                break
            }
            index += 1
        }
        return definitions
    }

    private func collectData(in parsed: [ParsedLine]) -> [BASICValue] {
        parsed
            .filter { !$0.isImported }
            .flatMap { line -> [BASICValue] in
                if case .data(let values) = line.statement {
                    return values
                }
                return []
            }
    }

    private func readData(into targets: [ReadTarget]) throws {
        for target in targets {
            guard dataIndex < dataValues.count else {
                throw BASICError.runtime("Out of DATA")
            }
            let value = dataValues[dataIndex]
            dataIndex += 1
            switch target {
            case .variable(let variable):
                try runtime.assign(kind: .bare, variable: variable, declaredType: nil, value: value)
            case .reference(let reference):
                try runtime.assign(
                    reference: reference,
                    indexes: try reference.indexes.map(evaluate),
                    fieldIndexes: try evaluatedFieldIndexes(for: reference),
                    value: value,
                    accessClassName: currentClassContext
                )
            }
        }
    }

    private func collectRecords(in parsed: [ParsedLine]) throws -> [String: BASICRecordDefinition] {
        var definitions: [String: BASICRecordDefinition] = [:]
        var index = 0
        while index < parsed.count {
            guard case .typeDeclaration(let name) = parsed[index].statement else {
                index += 1
                continue
            }

            let normalized = name.uppercased()
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("TYPE \(name) is already defined")
            }

            var fields: [BASICRecordField] = []
            index += 1
            while index < parsed.count {
                switch parsed[index].statement {
                case .typeField(let fieldName, let type, let fixedLength, let arrayDimensions, let json, let metadata, let defaultValue):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("TYPE \(name) field \(fieldName) is already defined")
                    }
                    fields.append(
                        BASICRecordField(
                            displayName: fieldName,
                            normalizedName: normalizedField,
                            type: type,
                            fixedLength: fixedLength,
                            arrayDimensions: arrayDimensions,
                            json: json,
                            metadata: metadata,
                            defaultValue: defaultValue
                        )
                    )
                case .endType:
                    definitions[normalized] = BASICRecordDefinition(
                        displayName: name,
                        normalizedName: normalized,
                        fields: fields
                    )
                    break
                default:
                    throw BASICError.runtime("Unexpected statement inside TYPE \(name)")
                }
                if case .endType = parsed[index].statement {
                    break
                }
                index += 1
            }
            guard index < parsed.count, case .endType = parsed[index].statement else {
                throw BASICError.runtime("TYPE without END TYPE")
            }
            index += 1
        }
        return definitions
    }

    private func collectFunctionTypes(in parsed: [ParsedLine]) throws -> [String: BASICFunctionTypeDefinition] {
        var definitions: [String: BASICFunctionTypeDefinition] = [:]
        for line in parsed {
            guard case .functionTypeDeclaration(let name, let parameters, let returnType, let isAsync) = line.statement else {
                continue
            }
            let normalized = name.uppercased()
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("FUNCTION TYPE \(name) is already defined")
            }
            definitions[normalized] = BASICFunctionTypeDefinition(
                displayName: name,
                normalizedName: normalized,
                parameters: parameters,
                returnType: returnType,
                isAsync: isAsync
            )
        }
        return definitions
    }

    private func collectInterfaces(in parsed: [ParsedLine]) throws -> [String: BASICInterfaceDefinition] {
        var definitions: [String: BASICInterfaceDefinition] = [:]
        var index = 0
        while index < parsed.count {
            guard case .interfaceDeclaration(let name) = parsed[index].statement else {
                index += 1
                continue
            }

            let normalized = name.uppercased()
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("INTERFACE \(name) is already defined")
            }

            var inheritedInterfaces: [String] = []
            var members: [BASICInterfaceMember] = []
            index += 1
            while index < parsed.count {
                switch parsed[index].statement {
                case .inheritsDeclaration(let interfaceName):
                    inheritedInterfaces.append(interfaceName)
                case .interfaceFunctionSignature(let memberName, let parameters, let returnType):
                    let normalizedMember = memberName.normalized
                    guard !members.contains(where: { $0.normalizedName == normalizedMember }) else {
                        throw BASICError.runtime("INTERFACE \(name) member \(memberName.name) is already defined")
                    }
                    members.append(
                        BASICInterfaceMember(
                            displayName: memberName.name,
                            normalizedName: normalizedMember,
                            parameters: parameters,
                            returnType: returnType
                        )
                    )
                case .functionDeclaration(let memberName, let parameters, let returnType, _, _, _, _):
                    let normalizedMember = memberName.normalized
                    guard !members.contains(where: { $0.normalizedName == normalizedMember }) else {
                        throw BASICError.runtime("INTERFACE \(name) member \(memberName.name) is already defined")
                    }
                    members.append(
                        BASICInterfaceMember(
                            displayName: memberName.name,
                            normalizedName: normalizedMember,
                            parameters: parameters,
                            returnType: returnType
                        )
                    )
                case .endInterface:
                    definitions[normalized] = BASICInterfaceDefinition(
                        displayName: name,
                        normalizedName: normalized,
                        inheritedInterfaces: inheritedInterfaces,
                        members: members
                    )
                    break
                default:
                    throw BASICError.runtime("Unexpected statement inside INTERFACE \(name)")
                }
                if case .endInterface = parsed[index].statement {
                    break
                }
                index += 1
            }
            guard index < parsed.count, case .endInterface = parsed[index].statement else {
                throw BASICError.runtime("INTERFACE without END INTERFACE")
            }
            index += 1
        }
        return definitions
    }

    private func collectClasses(in parsed: [ParsedLine]) throws -> [String: BASICClassDefinition] {
        var definitions: [String: BASICClassDefinition] = [:]
        var index = 0
        while index < parsed.count {
            guard case .classDeclaration(let name) = parsed[index].statement else {
                index += 1
                continue
            }

            let normalized = name.uppercased()
            guard !BASICRuntime.isBuiltInClass(name) else {
                throw BASICError.runtime("Cannot redefine built-in class \(normalized)")
            }
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("CLASS \(name) is already defined")
            }

            var fields: [BASICClassField] = []
            var interfaces: [String] = []
            var methods: [String: FunctionDefinition] = [:]
            var baseClass: String?
            index += 1
            while index < parsed.count {
                switch parsed[index].statement {
                case .classField(let fieldName, let type, let visibility, let arrayDimensions, let json, let metadata, let defaultValue):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("CLASS \(name) field \(fieldName) is already defined")
                    }
                    fields.append(BASICClassField(displayName: fieldName, normalizedName: normalizedField, type: type, arrayDimensions: arrayDimensions, visibility: visibility, declaringClassName: normalized, json: json, metadata: metadata, defaultValue: defaultValue))
                case .typeField(let fieldName, let type, _, let arrayDimensions, let json, let metadata, let defaultValue):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("CLASS \(name) field \(fieldName) is already defined")
                    }
                    fields.append(BASICClassField(displayName: fieldName, normalizedName: normalizedField, type: type, arrayDimensions: arrayDimensions, visibility: .public, declaringClassName: normalized, json: json, metadata: metadata, defaultValue: defaultValue))
                case .implementsDeclaration(let interfaceName):
                    interfaces.append(interfaceName)
                case .inheritsDeclaration(let baseClassName):
                    guard baseClassName.uppercased() != normalized else {
                        throw BASICError.runtime("CLASS \(name) cannot inherit itself")
                    }
                    baseClass = baseClassName
                case .functionDeclaration(let methodName, let parameters, let returnType, let isAsync, let visibility, let isOverride, let explicitInterfaceImplementations):
                    guard let endIndex = matchingEndFunction(after: index, in: parsed) else {
                        throw BASICError.runtime("FUNCTION without END FUNCTION")
                    }
                    guard methods[methodName.normalized] == nil else {
                        throw BASICError.runtime("CLASS \(name) method \(methodName.name) is already defined")
                    }
                    methods[methodName.normalized] = FunctionDefinition(
                        displayName: methodName.name,
                        normalizedName: methodName.normalized,
                        parameters: parameters,
                        returnType: returnType,
                        isAsync: isAsync,
                        startIndex: index,
                        endIndex: endIndex,
                        ownerClassName: name,
                        visibility: visibility,
                        isOverride: isOverride,
                        explicitInterfaceImplementations: explicitInterfaceImplementations
                    )
                    index = endIndex
                case .endClass:
                    definitions[normalized] = BASICClassDefinition(
                        displayName: name,
                        normalizedName: normalized,
                        baseClassName: baseClass,
                        fields: fields,
                        implementedInterfaces: interfaces,
                        methods: methods
                    )
                    break
                default:
                    throw BASICError.runtime("Unexpected statement inside CLASS \(name)")
                }
                if case .endClass = parsed[index].statement {
                    break
                }
                index += 1
            }
            guard index < parsed.count, case .endClass = parsed[index].statement else {
                throw BASICError.runtime("CLASS without END CLASS")
            }
            index += 1
        }
        return definitions
    }

    private func validateClassInterfaces() throws {
        for classDefinition in classDefinitions.values {
            for interfaceName in inheritedInterfaceNames(for: classDefinition) {
                guard let interfaceDefinition = interfaceDefinitions[interfaceName.uppercased()] else {
                    throw BASICError.runtime("CLASS \(classDefinition.displayName) implements unknown INTERFACE \(interfaceName)")
                }
                for member in interfaceMembers(for: interfaceDefinition) {
                    guard let method = method(for: member, interface: interfaceDefinition, in: classDefinition) else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) does not implement \(interfaceDefinition.displayName).\(member.displayName)")
                    }
                    guard method.parameters.map(\.type) == member.parameters.map(\.type),
                          method.returnType == member.returnType else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) does not match INTERFACE \(interfaceDefinition.displayName)")
                    }
                }
            }
        }
    }

    private func validateInterfaceInheritance() throws {
        for interfaceDefinition in interfaceDefinitions.values.sorted(by: { $0.displayName < $1.displayName }) {
            for inheritedName in interfaceDefinition.inheritedInterfaces {
                guard interfaceDefinitions[inheritedName.uppercased()] != nil else {
                    throw BASICError.runtime("INTERFACE \(interfaceDefinition.displayName) inherits unknown INTERFACE \(inheritedName)")
                }
            }
            try validateInterfaceCycle(interfaceDefinition, path: [])
        }
    }

    private func validateInterfaceCycle(_ interfaceDefinition: BASICInterfaceDefinition, path: [String]) throws {
        if path.contains(interfaceDefinition.normalizedName) {
            throw BASICError.runtime("INTERFACE \(interfaceDefinition.displayName) has an inheritance cycle")
        }
        let nextPath = path + [interfaceDefinition.normalizedName]
        for inheritedName in interfaceDefinition.inheritedInterfaces {
            guard let inherited = interfaceDefinitions[inheritedName.uppercased()] else { continue }
            try validateInterfaceCycle(inherited, path: nextPath)
        }
    }

    private func validateClassInheritance() throws {
        for classDefinition in classDefinitions.values {
            if let baseName = classDefinition.baseClassName,
               classDefinitions[baseName.uppercased()] == nil {
                throw BASICError.runtime("CLASS \(classDefinition.displayName) inherits unknown CLASS \(baseName)")
            }
            var seen: Set<String> = []
            var current = classDefinition.baseClassName
            while let currentName = current {
                let normalized = currentName.uppercased()
                guard seen.insert(normalized).inserted else {
                    throw BASICError.runtime("CLASS \(classDefinition.displayName) has an inheritance cycle")
                }
                current = classDefinitions[normalized]?.baseClassName
            }

            let inherited = inheritedFields(for: classDefinition).dropLast(classDefinition.fields.count)
            for field in classDefinition.fields where inherited.contains(where: { $0.normalizedName == field.normalizedName }) {
                throw BASICError.runtime("CLASS \(classDefinition.displayName) field \(field.displayName) shadows an inherited field")
            }

            for method in classDefinition.methods.values {
                let inheritedMethod = inheritedMethod(named: method.normalizedName, for: classDefinition)
                if method.isOverride {
                    guard let inheritedMethod else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) is OVERRIDES but no inherited method exists")
                    }
                    guard methodSignature(method, matches: inheritedMethod) else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) OVERRIDES signature does not match inherited method")
                    }
                } else if inheritedMethod != nil {
                    throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) overrides an inherited method; add OVERRIDES")
                }
            }
        }
    }

    private func methodSignature(_ method: FunctionDefinition, matches inheritedMethod: FunctionDefinition) -> Bool {
        method.parameters.map(\.type) == inheritedMethod.parameters.map(\.type)
            && method.returnType == inheritedMethod.returnType
    }

    private func inheritedInterfaceNames(for classDefinition: BASICClassDefinition) -> [String] {
        var names: [String] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            names.append(contentsOf: inheritedInterfaceNames(for: baseDefinition))
        }
        names.append(contentsOf: classDefinition.implementedInterfaces)
        return names
    }

    private func interfaceMembers(for interfaceDefinition: BASICInterfaceDefinition) -> [BASICInterfaceMember] {
        var members: [BASICInterfaceMember] = []
        for inheritedName in interfaceDefinition.inheritedInterfaces {
            if let inherited = interfaceDefinitions[inheritedName.uppercased()] {
                members.append(contentsOf: interfaceMembers(for: inherited))
            }
        }
        members.append(contentsOf: interfaceDefinition.members)
        return members
    }

    private func lookupMethod(named normalizedName: String, in classDefinition: BASICClassDefinition) -> FunctionDefinition? {
        if let method = classDefinition.methods[normalizedName] {
            return method
        }
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            return lookupMethod(named: normalizedName, in: baseDefinition)
        }
        return nil
    }

    private func method(
        for member: BASICInterfaceMember,
        interface: BASICInterfaceDefinition,
        in classDefinition: BASICClassDefinition
    ) -> FunctionDefinition? {
        if let direct = lookupMethod(named: member.normalizedName, in: classDefinition) {
            return direct
        }
        return allMethods(in: classDefinition).first { method in
            method.explicitInterfaceImplementations.contains {
                $0.normalizedInterfaceName == interface.normalizedName
                    && $0.normalizedMemberName == member.normalizedName
            }
        }
    }

    private func allMethods(in classDefinition: BASICClassDefinition) -> [FunctionDefinition] {
        var methods: [FunctionDefinition] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            methods.append(contentsOf: allMethods(in: baseDefinition))
        }
        methods.append(contentsOf: classDefinition.methods.values)
        return methods
    }

    private func inheritedMethod(named normalizedName: String, for classDefinition: BASICClassDefinition) -> FunctionDefinition? {
        guard let baseName = classDefinition.baseClassName,
              let baseDefinition = classDefinitions[baseName.uppercased()] else {
            return nil
        }
        return lookupMethod(named: normalizedName, in: baseDefinition)
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

    private func matchingEndFunction(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .functionDeclaration:
                depth += 1
            case .endFunction:
                if depth == 0 {
                    return index
                }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return nil
    }

    private func matchingEndType(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var index = pc + 1
        while index < parsed.count {
            if case .endType = parsed[index].statement {
                return index
            }
            index += 1
        }
        return nil
    }

    private func matchingEndInterface(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var index = pc + 1
        while index < parsed.count {
            if case .endInterface = parsed[index].statement {
                return index
            }
            index += 1
        }
        return nil
    }

    private func matchingEndClass(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var index = pc + 1
        while index < parsed.count {
            if case .endClass = parsed[index].statement {
                return index
            }
            index += 1
        }
        return nil
    }

    // Internal rather than private so ``BASICKeywords`` can *be* this set
    // rather than keep a copy of it — a builtin added here is highlighted and
    // completed without anyone touching a second list.
    static let intrinsicFunctionNames: Set<String> = [
        "ABS", "ACS", "ASC", "ASN", "ASYNCVALUE", "ATN", "BINARY$", "CINT", "COS", "COT", "CSC", "DATE$", "DEC",
        "EXP", "FIX", "HCS", "HEX$", "HSN", "HTN", "INKEY$", "INPUT$", "INSTR", "INT", "EOF", "LCT", "LEFT$", "LOF",
        "HTTPGETASYNC", "LOG", "LOC", "LTW", "MID$", "MKI$", "MKS$", "MKD$", "CVI", "CVS", "CVD", "RAD", "READFILEASYNC", "RIGHT$", "RND", "SCN", "SEC", "SEEK", "SGN", "SLEEP", "TASKERROR$", "TASKSTATUS$", "WRITEFILEASYNC",
        "FILEEXISTS", "SIN", "SPACE$", "SPC", "SQR", "STR$", "STRING$", "TAB", "TAN", "TIME$", "POS",
        "TOJSONSTRING", "VAL", "FROMJSONSTRING", "USING$", "REFLECT",
        "FIELDCOUNT", "FIELDNAME$", "FIELDMETA", "FIELDVALUE", "FIELDVALUE$", "SETFIELD"
    ]

    private func callIntrinsicFunction(name: VariableName, arguments: [Expression]) throws -> BASICValue {
        let normalized = name.normalized

        switch normalized {
        case "ABS":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            return .number(abs(value))
        case "ACS":
            return .number(acos(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "ASC":
            try requireArgumentCount(name.name, arguments, 1)
            guard let string = try evaluate(arguments[0]).string,
                  let byte = string.rawData.first else {
                throw BASICError.runtime("ASC requires a non-empty string")
            }
            return .number(Double(byte))
        case "ASN":
            return .number(asin(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "ASYNCVALUE":
            try requireArgumentCount(name.name, arguments, 1)
            let value = try evaluate(arguments[0])
            guard let taskScheduler else {
                throw BASICError.runtime("ASYNCVALUE is not supported outside a running BASIC session")
            }
            let parentID = task?.id ?? taskScheduler.currentTask?.id
            let handle = taskScheduler.startHostOperationTaskWithResult(
                name: "ASYNCVALUE",
                parentID: parentID,
                operation: "asyncvalue"
            ) {
                await Task.yield()
                return value
            }
            return .task(handle)
        case "ATN":
            return .number(atan(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "BINARY$":
            let value = try singleIntegerArgument(name: name.name, arguments: arguments)
            guard value >= 0 else {
                throw BASICError.runtime("BINARY$ requires a non-negative value")
            }
            return .string(BASICString(String(value, radix: 2)))
        case "CINT":
            return .number(try singleNumericArgument(name: name.name, arguments: arguments).rounded())
        case "COS":
            return .number(cos(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "COT":
            return .number(1 / tan(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "CSC":
            return .number(1 / sin(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "DATE$":
            try requireArgumentCount(name.name, arguments, 0)
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd-yyyy"
            return .string(BASICString(formatter.string(from: Date())))
        case "DEC":
            return .number(try singleNumericArgument(name: name.name, arguments: arguments) * 180 / Double.pi)
        case "EXP":
            return .number(exp(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "FILEEXISTS":
            try requireArgumentCount(name.name, arguments, 1)
            guard let fileHost = host as? BASICFileHost else {
                throw BASICError.runtime("FILEEXISTS is not supported by this host")
            }
            return .number(try fileHost.fileExists(path: string(arguments[0])) ? 1 : 0)
        case "EOF":
            try requireArgumentCount(name.name, arguments, 1)
            return try legacyEOF(arguments[0])
        case "FIX":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            return .number(value < 0 ? ceil(value) : floor(value))
        case "HCS":
            return .number(cosh(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "HEX$":
            let value = try singleIntegerArgument(name: name.name, arguments: arguments)
            guard value >= 0 else {
                throw BASICError.runtime("HEX$ requires a non-negative value")
            }
            return .string(BASICString(String(value, radix: 16, uppercase: true)))
        case "HSN":
            return .number(sinh(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "HTN":
            return .number(tanh(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "HTTPGETASYNC":
            try requireArgumentCount(name.name, arguments, 1)
            let url = try rawString(arguments[0])
            guard let taskScheduler else {
                throw BASICError.runtime("HTTPGETASYNC is not supported outside a running BASIC session")
            }
            guard let networkHost = host as? BASICNetworkHost else {
                throw BASICError.runtime("HTTPGETASYNC is not supported by this host")
            }
            let hostReference = BASICHostReference(host: networkHost)
            let parentID = task?.id ?? taskScheduler.currentTask?.id
            let handle = taskScheduler.startHostOperationTaskWithResult(
                name: "HTTPGETASYNC",
                parentID: parentID,
                operation: "http-get"
            ) {
                guard let host = hostReference.host as? BASICNetworkHost else {
                    throw BASICError.runtime("HTTPGETASYNC host became unavailable")
                }
                let response = try await host.httpGet(url: url)
                let headers = response.headers.reduce(into: [String: BASICValue]()) { result, entry in
                    result[entry.key] = .string(BASICString(entry.value))
                }
                return .dictionary(BASICDictionary(values: [
                    "BODY": .string(BASICString(response.body)),
                    "HEADERS": .dictionary(BASICDictionary(values: headers)),
                    "STATUS": .number(Double(response.statusCode)),
                    "URL": .string(BASICString(response.url))
                ]))
            }
            return .task(handle)
        case "INKEY$":
            try requireArgumentCount(name.name, arguments, 0)
            let rawKey = (host as? BASICKeyboardHost)?.readKey() ?? ""
            try checkExecutionBreak()
            let encoding: BASICKeyEncoding = runtime.keyMode == .ibm ? .ibm : .aibasic
            return .string(BASICString(BASICKeyNormalizer.normalize(rawKey, encoding: encoding)))
        case "INPUT$":
            return try intrinsicInputString(name: name.name, arguments: arguments)
        case "INSTR":
            return .number(Double(try intrinsicInstr(arguments: arguments)))
        case "INT":
            return .number(floor(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "LCT":
            return .number(log10(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "LEFT$":
            try requireArgumentCount(name.name, arguments, 2)
            let value = try rawString(arguments[0])
            let count = max(0, try integer(arguments[1]))
            return .string(BASICString(String(value.prefix(count))))
        case "LOF":
            try requireArgumentCount(name.name, arguments, 1)
            return .number(Double(try legacyFileLength(arguments[0])))
        case "LOC":
            try requireArgumentCount(name.name, arguments, 1)
            let value = try evaluate(arguments[0])
            if let number = value.number, number.rounded() == number,
               legacyFiles[Int(number)]?.isOpen == true {
                return .number(Double(try legacyFileLocation(handle: Int(number))))
            }
            return .number(log(try numeric(value)))
        case "LOG":
            return .number(log(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "LTW":
            return .number(log2(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "MID$":
            return try intrinsicMid(arguments: arguments)
        case "MKI$":
            let conversion = try integerEncodingArguments(name: name.name, arguments: arguments)
            return .string(BASICString(rawData: signedIntegerData(
                conversion.value,
                width: conversion.width,
                order: conversion.order
            )))
        case "MKS$":
            let conversion = try floatingEncodingArguments(name: name.name, arguments: arguments)
            let bits = Float(conversion.value).bitPattern
            return .string(BASICString(rawData: binaryData(UInt64(bits), byteCount: 4, order: conversion.order)))
        case "MKD$":
            let conversion = try floatingEncodingArguments(name: name.name, arguments: arguments)
            return .string(BASICString(rawData: binaryData(
                conversion.value.bitPattern,
                byteCount: 8,
                order: conversion.order
            )))
        case "CVI":
            let conversion = try integerDecodingArguments(name: name.name, arguments: arguments)
            let bits = binaryUInt(conversion.data, order: conversion.order)
            switch conversion.width {
            case 16:
                return .number(Double(Int16(bitPattern: UInt16(truncatingIfNeeded: bits))))
            case 32:
                return .number(Double(Int32(bitPattern: UInt32(truncatingIfNeeded: bits))))
            case 64:
                let signed = Int64(bitPattern: bits)
                let number = Double(signed)
                guard Int64(exactly: number) == signed else {
                    throw BASICError.runtime("CVI 64-bit value cannot be represented exactly")
                }
                return .number(number)
            default:
                throw BASICError.runtime("CVI width must be 16, 32, or 64")
            }
        case "CVS":
            let conversion = try floatingDecodingArguments(name: name.name, arguments: arguments, byteCount: 4)
            return .number(Double(Float(bitPattern: UInt32(truncatingIfNeeded: binaryUInt(
                conversion.data,
                order: conversion.order
            )))))
        case "CVD":
            let conversion = try floatingDecodingArguments(name: name.name, arguments: arguments, byteCount: 8)
            return .number(Double(bitPattern: binaryUInt(conversion.data, order: conversion.order)))
        case "POS":
            try requireArgumentCount(name.name, arguments, 1)
            return .number(Double(outputColumn + 1))
        case "RIGHT$":
            try requireArgumentCount(name.name, arguments, 2)
            let value = try rawString(arguments[0])
            let count = max(0, try integer(arguments[1]))
            return .string(BASICString(String(value.suffix(count))))
        case "REFLECT":
            try requireArgumentCount(name.name, arguments, 1)
            return try reflect(arguments[0])
        case "FIELDCOUNT":
            try requireArgumentCount(name.name, arguments, 1)
            return .number(Double(try runtime.reflectedFieldCount(for: evaluate(arguments[0]))))
        case "FIELDNAME$":
            try requireArgumentCount(name.name, arguments, 2)
            return .string(BASICString(try runtime.reflectedFieldName(for: evaluate(arguments[0]), selector: evaluate(arguments[1]))))
        case "FIELDMETA":
            try requireArgumentCount(name.name, arguments, 2)
            return try runtime.reflectedFieldMetadata(for: evaluate(arguments[0]), selector: evaluate(arguments[1]))
        case "FIELDVALUE":
            try requireArgumentCount(name.name, arguments, 2)
            return try runtime.reflectedFieldValue(for: evaluate(arguments[0]), selector: evaluate(arguments[1]))
        case "FIELDVALUE$":
            try requireArgumentCount(name.name, arguments, 2)
            return .string(BASICString(try runtime.reflectedFieldValue(for: evaluate(arguments[0]), selector: evaluate(arguments[1])).description))
        case "SETFIELD":
            try requireArgumentCount(name.name, arguments, 3)
            return try runtime.settingReflectedField(value: evaluate(arguments[0]), selector: evaluate(arguments[1]), newValue: evaluate(arguments[2]))
        case "RAD":
            return .number(try singleNumericArgument(name: name.name, arguments: arguments) * Double.pi / 180)
        case "READFILEASYNC":
            try requireArgumentCount(name.name, arguments, 1)
            let path = try rawString(arguments[0])
            guard let taskScheduler else {
                throw BASICError.runtime("READFILEASYNC is not supported outside a running BASIC session")
            }
            guard let fileHost = host as? BASICFileHost else {
                throw BASICError.runtime("READFILEASYNC is not supported by this host")
            }
            let hostReference = BASICHostReference(host: fileHost)
            let parentID = task?.id ?? taskScheduler.currentTask?.id
            let handle = taskScheduler.startHostOperationTaskWithResult(
                name: "READFILEASYNC",
                parentID: parentID,
                operation: "file-read"
            ) {
                guard let host = hostReference.host as? BASICFileHost else {
                    throw BASICError.runtime("READFILEASYNC host became unavailable")
                }
                return .string(BASICString(try host.loadTextFile(path: path)))
            }
            return .task(handle)
        case "RND":
            try requireArgumentRange(name.name, arguments, 0...1)
            let argument = try arguments.first.map { try numeric(try evaluate($0)) }
            return .number(runtime.randomGenerator.next(argument: argument))
        case "SCN", "SGN":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            return .number(value == 0 ? 0 : (value < 0 ? -1 : 1))
        case "SEC":
            return .number(1 / cos(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "SEEK":
            try requireArgumentCount(name.name, arguments, 1)
            let handle = try legacyFileHandle(arguments[0])
            return .number(Double(try legacyFileSeekPosition(handle: handle)))
        case "SLEEP":
            try requireArgumentCount(name.name, arguments, 1)
            let milliseconds = max(0, try integer(arguments[0]))
            guard let taskScheduler else {
                throw BASICError.runtime("SLEEP is not supported outside a running BASIC session")
            }
            let parentID = task?.id ?? taskScheduler.currentTask?.id
            let nanoseconds = UInt64(milliseconds) * 1_000_000
            let handle = taskScheduler.startHostOperationTaskWithResult(
                name: "SLEEP",
                parentID: parentID,
                operation: "timer"
            ) {
                if nanoseconds > 0 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
                return .number(Double(milliseconds))
            }
            return .task(handle)
        case "TASKERROR$":
            try requireArgumentCount(name.name, arguments, 1)
            let taskID = try taskHandleID(from: evaluate(arguments[0]), operation: "TASKERROR$")
            _ = taskScheduler?.markObserved(id: taskID)
            guard let snapshot = taskScheduler?.snapshot(for: taskID) else {
                throw BASICError.runtime("TASKERROR$ requires a known task handle")
            }
            return .string(BASICString(snapshot.errorDescription ?? ""))
        case "TASKSTATUS$":
            try requireArgumentCount(name.name, arguments, 1)
            let taskID = try taskHandleID(from: evaluate(arguments[0]), operation: "TASKSTATUS$")
            _ = taskScheduler?.markObserved(id: taskID)
            guard let snapshot = taskScheduler?.snapshot(for: taskID) else {
                throw BASICError.runtime("TASKSTATUS$ requires a known task handle")
            }
            let status = snapshot.isCancellationRequested ? BASICTaskState.cancelled : snapshot.state
            return .string(BASICString(status.rawValue.uppercased()))
        case "SIN":
            return .number(sin(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "SPACE$":
            let count = max(0, try singleIntegerArgument(name: name.name, arguments: arguments))
            return .string(BASICString(String(repeating: " ", count: count)))
        case "SPC":
            let count = max(0, try singleIntegerArgument(name: name.name, arguments: arguments))
            return .string(BASICString(String(repeating: " ", count: count)))
        case "SQR":
            return .number(sqrt(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "STR$":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            let rendered = BASICValue.number(value).description
            return .string(BASICString(value >= 0 ? " " + rendered : rendered))
        case "STRING$":
            return try intrinsicString(arguments: arguments)
        case "TAB":
            let target = max(1, try singleIntegerArgument(name: name.name, arguments: arguments))
            return .string(BASICString(String(repeating: " ", count: target - 1)))
        case "TAN":
            return .number(tan(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "TIME$":
            try requireArgumentCount(name.name, arguments, 0)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return .string(BASICString(formatter.string(from: Date())))
        case "WRITEFILEASYNC":
            try requireArgumentCount(name.name, arguments, 2)
            let path = try rawString(arguments[0])
            let text = try rawString(arguments[1])
            guard let taskScheduler else {
                throw BASICError.runtime("WRITEFILEASYNC is not supported outside a running BASIC session")
            }
            guard let fileHost = host as? BASICFileHost else {
                throw BASICError.runtime("WRITEFILEASYNC is not supported by this host")
            }
            let hostReference = BASICHostReference(host: fileHost)
            let parentID = task?.id ?? taskScheduler.currentTask?.id
            let handle = taskScheduler.startHostOperationTaskWithResult(
                name: "WRITEFILEASYNC",
                parentID: parentID,
                operation: "file-write"
            ) {
                guard let host = hostReference.host as? BASICFileHost else {
                    throw BASICError.runtime("WRITEFILEASYNC host became unavailable")
                }
                try host.saveTextFile(path: path, text: text)
                return .number(Double(text.utf8.count))
            }
            return .task(handle)
        case "TOJSONSTRING":
            try requireArgumentCount(name.name, arguments, 2)
            let value = try evaluate(arguments[0])
            let pretty = try boolean(try evaluate(arguments[1]))
            do {
                return .string(BASICString(try runtime.jsonString(for: value, pretty: pretty)))
            } catch let error as BASICError {
                throw error
            } catch {
                throw BASICError.runtime("JSON encode failed: \(error.localizedDescription)")
            }
        case "VAL":
            let value = try singleStringArgument(name: name.name, arguments: arguments)
            return .number(Self.leadingNumber(in: value) ?? 0)
        case "USING$":
            guard arguments.count >= 2 else {
                throw BASICError.runtime("USING$ expects at least 2 arguments")
            }
            let format = try string(arguments[0])
            let values = try arguments.dropFirst().map(evaluate)
            return .string(BASICString(try formatUsing(format: format, values: values)))
        case "FROMJSONSTRING":
            try requireArgumentCount(name.name, arguments, 2)
            let source = try string(arguments[0])
            let permissive = try boolean(try evaluate(arguments[1]))
            do {
                return try runtime.valueFromJSONString(source, permissive: permissive)
            } catch let error as BASICError {
                throw error
            } catch {
                throw BASICError.runtime("JSON parse failed: \(error.localizedDescription)")
            }
        default:
            throw BASICError.runtime("Unknown function \(name.name)")
        }
    }

    private func callFunction(name: VariableName, arguments: [Expression], allowVoid: Bool = false) throws -> BASICValue {
        if Self.intrinsicFunctionNames.contains(name.normalized) {
            return try callIntrinsicFunction(name: name, arguments: arguments)
        }
        guard let definition = functionDefinitions[name.normalized] else {
            throw BASICError.runtime("Unknown function \(name.name)")
        }
        return try callFunction(definition: definition, receiver: nil, receiverClassName: nil, arguments: arguments, allowVoid: allowVoid).value
    }

    private func singleNumericArgument(name: String, arguments: [Expression]) throws -> Double {
        try requireArgumentCount(name, arguments, 1)
        return try numeric(try evaluate(arguments[0]))
    }

    private func singleIntegerArgument(name: String, arguments: [Expression]) throws -> Int {
        try requireArgumentCount(name, arguments, 1)
        return try integer(arguments[0])
    }

    private func singleStringArgument(name: String, arguments: [Expression]) throws -> String {
        try requireArgumentCount(name, arguments, 1)
        return try string(arguments[0])
    }

    private func singleRawStringArgument(name: String, arguments: [Expression]) throws -> String {
        try requireArgumentCount(name, arguments, 1)
        return try rawString(arguments[0])
    }

    private func reflect(_ expression: Expression) throws -> BASICValue {
        switch expression {
        case .variable(let variable):
            return try runtime.metadata(
                for: VariableReference(base: variable),
                indexes: [],
                accessClassName: currentClassContext
            )
        case .variableReference(let reference):
            return try runtime.metadata(
                for: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                accessClassName: currentClassContext
            )
        case .callOrArray(let name, let arguments):
            return try runtime.metadata(
                for: VariableReference(base: name, indexes: arguments),
                indexes: try arguments.map(evaluate),
                accessClassName: currentClassContext
            )
        default:
            throw BASICError.runtime("REFLECT expects a variable")
        }
    }

    private func requireArgumentCount(_ name: String, _ arguments: [Expression], _ count: Int) throws {
        guard arguments.count == count else {
            throw BASICError.runtime("\(name) expects \(count) argument\(count == 1 ? "" : "s")")
        }
    }

    private func requireArgumentRange(_ name: String, _ arguments: [Expression], _ range: ClosedRange<Int>) throws {
        guard range.contains(arguments.count) else {
            throw BASICError.runtime("\(name) expects \(range.lowerBound) to \(range.upperBound) arguments")
        }
    }

    private func intrinsicInstr(arguments: [Expression]) throws -> Int {
        try requireArgumentRange("INSTR", arguments, 2...3)
        let start: Int
        let haystack: String
        let needle: String
        if arguments.count == 2 {
            start = 1
            haystack = try rawString(arguments[0])
            needle = try rawString(arguments[1])
        } else {
            start = max(1, try integer(arguments[0]))
            haystack = try rawString(arguments[1])
            needle = try rawString(arguments[2])
        }

        guard !needle.isEmpty else { return start }
        guard start <= haystack.count else { return 0 }
        let startIndex = haystack.index(haystack.startIndex, offsetBy: start - 1)
        guard let range = haystack[startIndex...].range(of: needle) else { return 0 }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound) + 1
    }

    private func intrinsicMid(arguments: [Expression]) throws -> BASICValue {
        try requireArgumentRange("MID$", arguments, 2...3)
        let value = try rawString(arguments[0])
        let start = max(1, try integer(arguments[1]))
        guard start <= value.count else { return .string(BASICString("")) }
        let startIndex = value.index(value.startIndex, offsetBy: start - 1)
        let suffix = value[startIndex...]
        if arguments.count == 2 {
            return .string(BASICString(String(suffix)))
        }
        let count = max(0, try integer(arguments[2]))
        return .string(BASICString(String(suffix.prefix(count))))
    }

    private func intrinsicString(arguments: [Expression]) throws -> BASICValue {
        try requireArgumentCount("STRING$", arguments, 2)
        let count = max(0, try integer(arguments[0]))
        let value = try evaluate(arguments[1])
        let character: String
        if let number = value.number {
            let code = Int(number.rounded())
            character = code == 0 ? "\0" : try BASICString.character(code: code).description
        } else if let string = value.string?.description, let first = string.first {
            character = String(first)
        } else {
            throw BASICError.runtime("STRING$ requires a character code or non-empty string")
        }
        return .string(BASICString(String(repeating: character, count: count)))
    }

    private static func leadingNumber(in value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var index = trimmed.startIndex
        if index < trimmed.endIndex, trimmed[index] == "+" || trimmed[index] == "-" {
            index = trimmed.index(after: index)
        }

        var hasDigits = false
        while index < trimmed.endIndex, trimmed[index].isNumber {
            hasDigits = true
            index = trimmed.index(after: index)
        }
        if index < trimmed.endIndex, trimmed[index] == "." {
            index = trimmed.index(after: index)
            while index < trimmed.endIndex, trimmed[index].isNumber {
                hasDigits = true
                index = trimmed.index(after: index)
            }
        }
        guard hasDigits else { return nil }
        if index < trimmed.endIndex, trimmed[index].uppercased() == "E" {
            var exponentIndex = trimmed.index(after: index)
            if exponentIndex < trimmed.endIndex, trimmed[exponentIndex] == "+" || trimmed[exponentIndex] == "-" {
                exponentIndex = trimmed.index(after: exponentIndex)
            }
            let exponentStart = exponentIndex
            while exponentIndex < trimmed.endIndex, trimmed[exponentIndex].isNumber {
                exponentIndex = trimmed.index(after: exponentIndex)
            }
            if exponentIndex > exponentStart {
                index = exponentIndex
            }
        }
        return Double(trimmed[..<index])
    }

    private func callMethod(receiver: VariableReference, method: VariableName, arguments: [Expression], allowVoid: Bool = false) throws -> BASICValue {
        if receiver.base.normalized == "FILE",
           receiver.indexes.isEmpty,
           receiver.fields.isEmpty,
           !runtime.hasVariable(receiver.base) {
            return try callSharedFileMethod(method: method, arguments: arguments)
        }
        let receiverDeclaredType = runtime.declaredType(for: receiver)
        let receiverValue = try runtime.value(
            for: receiver,
            indexes: try receiver.indexes.map(evaluate),
            fieldIndexes: try evaluatedFieldIndexes(for: receiver),
            accessClassName: currentClassContext
        )
        if case .systemObject(let typeName, let id) = receiverValue {
            if typeName.uppercased() == "HTTPCLIENT", method.normalized == "GET" {
                return try callHTTPClientGet(id: id, arguments: arguments)
            }
            return try runtime.callSystemObjectMethod(
                typeName: typeName,
                id: id,
                method: method.name,
                arguments: try arguments.map(evaluate),
                tuiPresentationHost: host as? BASICTUIPresentationHost,
                // How a control gets back into the program. The runtime has no
                // route to the interpreter, and calling a named function is the
                // entire purpose of a button.
                invokeHandler: { [weak self] handlerName in
                    guard let self else { return }
                    try self.callNamedHandler(handlerName)
                },
                fileHost: host as? BASICFileHost,
                vectorTerminalHost: host as? BASICVectorTerminalHost,
                timerHost: timerHost,
                jsonDecoder: { [runtime] source in try runtime.valueFromJSONString(source, permissive: true) },
                jsonEncoder: { [runtime] value, pretty in try runtime.jsonString(for: value, pretty: pretty) }
            )
        }
        var missingMethodError: BASICError?
        if case .object(let className, _) = receiverValue {
            guard let classDefinition = classDefinitions[className.uppercased()] else {
                throw BASICError.runtime("Unknown CLASS \(className)")
            }
            if let definition = lookupMethod(named: method.normalized, receiverDeclaredType: receiverDeclaredType, in: classDefinition) {
                try validateMethodAccess(definition, receiverClass: classDefinition.displayName)
                let result = try callFunction(
                    definition: definition,
                    receiver: receiverValue,
                    receiverClassName: classDefinition.displayName,
                    arguments: arguments,
                    allowVoid: allowVoid
                )
                if let updatedReceiver = result.receiver {
                    try runtime.assign(
                        reference: receiver,
                        indexes: try receiver.indexes.map(evaluate),
                        fieldIndexes: try evaluatedFieldIndexes(for: receiver),
                        value: updatedReceiver,
                        accessClassName: currentClassContext
                    )
                }
                return result.value
            }
            missingMethodError = BASICError.runtime("\(methodLookupTypeName(receiverDeclaredType, fallbackClassName: classDefinition.displayName)) has no method \(method.name)")
        }
        var fieldReference = receiver
        fieldReference.fields.append(method.name)
        fieldReference.fieldIndexes.append(arguments)
        do {
            return try runtime.value(
                for: fieldReference,
                indexes: try fieldReference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: fieldReference),
                accessClassName: currentClassContext
            )
        } catch {
            if let missingMethodError {
                throw missingMethodError
            }
            throw error
        }
    }

    private func callSharedFileMethod(method: VariableName, arguments: [Expression]) throws -> BASICValue {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("File I/O is not supported by this host")
        }
        func path(_ expression: Expression) throws -> String {
            try validatedBASICFilePath(string(expression))
        }
        switch method.normalized {
        case "CWD", "CWD$":
            try requireArgumentCount("File.Cwd$", arguments, 0)
            return .string(BASICString(try fileHost.currentDirectoryPath()))
        case "CHDIR":
            try requireArgumentCount("File.ChDir", arguments, 1)
            try fileHost.changeDirectory(path: path(arguments[0]))
            return .empty
        case "MKDIR":
            try requireArgumentCount("File.Mkdir", arguments, 1)
            try fileHost.createDirectory(path: path(arguments[0]))
            return .empty
        case "RM":
            try requireArgumentCount("File.Rm", arguments, 1)
            try fileHost.removePath(path: path(arguments[0]))
            return .empty
        case "RENAME":
            try requireArgumentCount("File.Rename", arguments, 2)
            try fileHost.renamePath(from: path(arguments[0]), to: path(arguments[1]))
            return .empty
        case "EXISTS":
            try requireArgumentCount("File.Exists", arguments, 1)
            return .boolean(try fileHost.fileExists(path: path(arguments[0])))
        case "ISDIR":
            try requireArgumentCount("File.IsDir", arguments, 1)
            return .boolean(try fileHost.isDirectory(path: path(arguments[0])))
        case "FILES", "FILES$":
            try requireArgumentRange("File.Files$", arguments, 0...1)
            let directoryPath = try arguments.first.map(path) ?? fileHost.currentDirectoryPath()
            let names = try fileHost.listDirectory(path: directoryPath)
            return .array(BASICArray(
                dimensions: [names.isEmpty ? -1 : names.count - 1],
                type: .scalar(.string),
                isDynamic: true,
                values: names.map { .string(BASICString($0)) }
            ))
        case "READTEXT", "READTEXT$":
            try requireArgumentCount("File.ReadText$", arguments, 1)
            return .string(BASICString(try fileHost.loadTextFile(path: path(arguments[0]))))
        case "WRITETEXT":
            try requireArgumentCount("File.WriteText", arguments, 2)
            try fileHost.saveTextFile(path: path(arguments[0]), text: string(arguments[1]))
            return .empty
        case "READBYTES", "READBYTES$":
            try requireArgumentCount("File.ReadBytes$", arguments, 1)
            return .string(BASICString(rawData: try fileHost.loadFileData(path: path(arguments[0]))))
        case "WRITEBYTES":
            try requireArgumentCount("File.WriteBytes", arguments, 2)
            guard let bytes = try evaluate(arguments[1]).string else {
                throw BASICError.runtime("File.WriteBytes expects a string")
            }
            try fileHost.saveFileData(path: path(arguments[0]), data: bytes.rawData)
            return .empty
        case "APPENDBYTES":
            try requireArgumentCount("File.AppendBytes", arguments, 2)
            let filePath = try path(arguments[0])
            guard let bytes = try evaluate(arguments[1]).string else {
                throw BASICError.runtime("File.AppendBytes expects a string")
            }
            var data = try fileHost.fileExists(path: filePath) ? fileHost.loadFileData(path: filePath) : Data()
            data.append(bytes.rawData)
            try fileHost.saveFileData(path: filePath, data: data)
            return .empty
        case "READJSON":
            try requireArgumentRange("File.ReadJson", arguments, 1...2)
            let permissive = try arguments.count == 2 ? boolean(evaluate(arguments[1])) : true
            return try runtime.valueFromJSONString(
                fileHost.loadTextFile(path: path(arguments[0])),
                permissive: permissive
            )
        case "WRITEJSON":
            try requireArgumentRange("File.WriteJson", arguments, 2...3)
            let pretty = try arguments.count == 3 ? boolean(evaluate(arguments[2])) : false
            let text = try runtime.jsonString(for: evaluate(arguments[1]), pretty: pretty)
            try fileHost.saveTextFile(path: path(arguments[0]), text: text)
            return .empty
        default:
            throw BASICError.runtime("File has no shared method \(method.name)")
        }
    }

    private func lookupMethod(
        named normalizedName: String,
        receiverDeclaredType: BASICType?,
        in classDefinition: BASICClassDefinition
    ) -> FunctionDefinition? {
        switch receiverDeclaredType {
        case .interfaceType(let interfaceName):
            return lookupInterfaceMethod(
                named: normalizedName,
                interfaceName: interfaceName,
                in: classDefinition
            )
        case .classType(let declaredClassName):
            guard let declaredClass = classDefinitions[declaredClassName.uppercased()],
                  lookupMethod(named: normalizedName, in: declaredClass) != nil else {
                return nil
            }
            return lookupMethod(named: normalizedName, in: classDefinition)
        default:
            if let direct = lookupMethod(named: normalizedName, in: classDefinition) {
                return direct
            }
            return nil
        }
    }

    private func methodLookupTypeName(_ receiverDeclaredType: BASICType?, fallbackClassName: String) -> String {
        switch receiverDeclaredType {
        case .interfaceType(let name):
            return "INTERFACE \(name)"
        case .classType(let name):
            return "CLASS \(name)"
        default:
            return "CLASS \(fallbackClassName)"
        }
    }

    private func lookupInterfaceMethod(
        named normalizedName: String,
        interfaceName: String,
        in classDefinition: BASICClassDefinition
    ) -> FunctionDefinition? {
        guard let interfaceDefinition = interfaceDefinitions[interfaceName.uppercased()] else {
            return nil
        }
        return interfaceMember(named: normalizedName, in: interfaceDefinition).flatMap {
            method(for: $0.member, interface: $0.interface, in: classDefinition)
        }
    }

    private func interfaceMember(
        named normalizedName: String,
        in interfaceDefinition: BASICInterfaceDefinition
    ) -> (member: BASICInterfaceMember, interface: BASICInterfaceDefinition)? {
        for inheritedName in interfaceDefinition.inheritedInterfaces {
            if let inherited = interfaceDefinitions[inheritedName.uppercased()],
               let match = interfaceMember(named: normalizedName, in: inherited) {
                return match
            }
        }
        if let member = interfaceDefinition.members.first(where: { $0.normalizedName == normalizedName }) {
            return (member, interfaceDefinition)
        }
        return nil
    }

    private func validateMethodAccess(_ method: FunctionDefinition, receiverClass: String) throws {
        switch method.visibility {
        case .public:
            return
        case .private:
            guard currentClassContext?.uppercased() == method.ownerClassName?.uppercased() else {
                throw BASICError.runtime("\(method.displayName) is PRIVATE")
            }
        case .protected:
            guard let ownerClassName = method.ownerClassName,
                  let currentClassContext,
                  currentClassContext.uppercased() == ownerClassName.uppercased()
                    || isClass(currentClassContext, subclassOf: ownerClassName) else {
                throw BASICError.runtime("\(method.displayName) is PROTECTED")
            }
        }
    }

    private func isClass(_ className: String, subclassOf baseName: String) -> Bool {
        var current = classDefinitions[className.uppercased()]?.baseClassName
        while let currentName = current {
            if currentName.uppercased() == baseName.uppercased() {
                return true
            }
            current = classDefinitions[currentName.uppercased()]?.baseClassName
        }
        return false
    }

    private func callFunction(
        definition: FunctionDefinition,
        receiver: BASICValue?,
        receiverClassName: String?,
        arguments: [Expression],
        allowVoid: Bool
    ) throws -> FunctionCallResult {
        if definition.isAsync {
            return try scheduleAsyncFunction(
                definition: definition,
                receiver: receiver,
                receiverClassName: receiverClassName,
                arguments: arguments,
                allowVoid: allowVoid
            )
        }
        return try callFunctionSynchronously(
            definition: definition,
            receiver: receiver,
            receiverClassName: receiverClassName,
            arguments: arguments,
            allowVoid: allowVoid
        )
    }

    private func scheduleAsyncFunction(
        definition: FunctionDefinition,
        receiver: BASICValue?,
        receiverClassName: String?,
        arguments: [Expression],
        allowVoid: Bool
    ) throws -> FunctionCallResult {
        guard let taskScheduler else {
            throw BASICError.runtime("ASYNC FUNCTION requires a running BASIC session")
        }
        guard allowVoid || definition.returnType != .void else {
            throw BASICError.runtime("VOID function \(definition.displayName) cannot be used in an expression")
        }
        guard arguments.count == definition.parameters.count else {
            throw BASICError.runtime("Function \(definition.displayName) expects \(definition.parameters.count) arguments, got \(arguments.count)")
        }
        let argumentValues = try arguments.map(evaluate)
        guard let host else {
            throw BASICError.runtime("ASYNC FUNCTION requires a host")
        }
        let job = BASICAsyncFunctionJob(
            program: program,
            host: BASICHostReference(host: host),
            runtimeSnapshot: runtime.snapshotForAsyncLaunch(),
            definition: definition,
            receiver: receiver,
            receiverClassName: receiverClassName,
            argumentValues: argumentValues,
            allowVoid: allowVoid,
            outputCoordinator: outputCoordinator
        )
        let handle = taskScheduler.startBASICOperationTaskWithResult(
            name: definition.displayName,
            parentID: task?.id ?? taskScheduler.currentTask?.id
        ) { [eventLoop, executionControl] asyncTask in
            let result = try await job.run(
                task: asyncTask,
                taskScheduler: taskScheduler,
                eventLoop: eventLoop,
                executionControl: executionControl
            )
            return result.value
        }
        return FunctionCallResult(value: .task(handle), receiver: nil)
    }

    private func callFunctionSynchronously(
        definition: FunctionDefinition,
        receiver: BASICValue?,
        receiverClassName: String?,
        arguments: [Expression],
        allowVoid: Bool
    ) throws -> FunctionCallResult {
        let values = try arguments.map(evaluate)
        return try callFunctionSynchronously(
            definition: definition,
            receiver: receiver,
            receiverClassName: receiverClassName,
            argumentValues: values,
            allowVoid: allowVoid
        )
    }

    func callFunctionSynchronously(
        definition: FunctionDefinition,
        receiver: BASICValue?,
        receiverClassName: String?,
        argumentValues values: [BASICValue],
        allowVoid: Bool
    ) throws -> FunctionCallResult {
        let returnType = resolvedDeclaredType(definition.returnType)
        guard allowVoid || returnType != .void else {
            throw BASICError.runtime("VOID function \(definition.displayName) cannot be used in an expression")
        }
        guard values.count == definition.parameters.count else {
            throw BASICError.runtime("Function \(definition.displayName) expects \(definition.parameters.count) arguments, got \(values.count)")
        }
        guard functionStack.count < 512 else {
            throw BASICError.runtime("Function call depth exceeded")
        }

        let localContextIndex = runtime.pushLocalContext()
        if let receiver {
            try runtime.assign(
                kind: .local,
                variable: VariableName(name: "ME", column: 0),
                declaredType: definition.ownerClassName.map(BASICType.classType),
                value: receiver
            )
        }
        for (parameter, value) in zip(definition.parameters, values) {
            try runtime.assign(kind: .local, variable: parameter.variable, declaredType: parameter.type, value: value)
        }

        functionStack.append(FunctionFrame(
            definition: definition,
            receiverClassName: receiverClassName,
            localContextIndex: localContextIndex,
            returnValue: runtime.defaultValue(for: returnType)
        ))
        defer {
            _ = functionStack.popLast()
            runtime.popLocalContext()
        }

        if let bodyExpression = definition.bodyExpression {
            let value = try runtime.coerce(
                try evaluate(bodyExpression),
                to: returnType,
                variable: VariableName(name: definition.displayName, column: 0)
            )
            return FunctionCallResult(value: value, receiver: receiver)
        }

        func resultValue() -> FunctionCallResult {
            let value = functionStack.last?.returnValue ?? runtime.defaultValue(for: returnType)
            let receiver = receiver == nil ? nil : runtime.value(for: VariableName(name: "ME", column: 0))
            return FunctionCallResult(value: value, receiver: receiver)
        }

        var labelIndexByName: [String: Int] = [:]
        if definition.startIndex < definition.endIndex {
            for index in (definition.startIndex + 1)..<definition.endIndex {
                if let label = parsedLines[index].statement.label {
                    labelIndexByName[label.uppercased()] = index
                }
            }
        }

        var pc = definition.startIndex + 1
        let parsed = parsedLines
        while pc < definition.endIndex {
            do {
                if let task, task.isCancellationRequested {
                    throw CancellationError()
                }
                updateExecutionLocation(parsed[pc])
                try checkExecutionBreak()
                let flow = try execute(parsed[pc].statement, pc: pc, parsed: parsed)
                try drainPendingEventsIfAllowed(limit: 16)
                switch flow {
                case .next:
                    pc += 1
                case .jump(let index):
                    pc = index
                case .goto(let line):
                    guard let index = lineIndexByNumber[line] else { throw BASICError.missingLine(line) }
                    pc = index
                case .gotoLabel(let label):
                    guard let index = labelIndexByName[label.uppercased()] ?? lineIndexByLabel[label.uppercased()] else {
                        throw BASICError.missingLabel(label)
                    }
                    pc = index
                case .returnTo(let index):
                    pc = index
                case .exitSelect:
                    guard let index = matchingEndSelect(after: pc, in: parsed) else {
                        throw BASICError.runtime("EXIT SELECT without SELECT")
                    }
                    pc = index + 1
                case .functionReturn:
                    return resultValue()
                case .end:
                    return resultValue()
                }

                if executionControl?.shouldPauseAfterStep(callDepth: debugCallDepth, taskID: task?.id) == true {
                    if pc < definition.endIndex {
                        updateExecutionLocation(parsed[pc])
                        throw BASICError.stepComplete(parsed[pc].breakpointLocation)
                    }
                }
            } catch let error as BASICError {
                if error.isDebugPause {
                    snapshotPausedDebugState()
                    if try suspendAsyncFunctionForDebugger(error) {
                        continue
                    }
                }
                throw error
            }
        }

        return resultValue()
    }

    private func suspendAsyncFunctionForDebugger(_ error: BASICError) throws -> Bool {
        guard let task,
              task.parentID != nil,
              let taskScheduler else {
            return false
        }
        if case .breakRequested = error,
           executionControl?.shouldRetainBreakRequestsAsDebuggerPauses != true {
            return false
        }

        let snapshot = task.snapshot()
        let frames = currentSuspendedFrames(
            fallbackKind: "Function",
            fallbackName: functionStack.last?.definition.displayName ?? task.name,
            fallbackLocation: snapshot.location
        )
        let resumedControl = try taskScheduler.suspendForDebugger(
            task: task,
            error: error,
            frames: frames,
            globalVariables: runtime.globalSnapshots()
        )
        setExecutionControl(resumedControl)
        clearPausedDebugSnapshots()
        return true
    }

    /// Calls a BASIC function by name, for a TUI control's handler.
    ///
    /// Named functions, not closures: a BASIC closure captures by snapshot and
    /// its writes do not escape, so a closure used as a button handler would
    /// run and silently discard everything it did (TUIKIT_PLAN.md §2.1).
    func callNamedHandler(_ name: String) throws {
        guard let definition = functionDefinitions[name.uppercased()] else {
            throw BASICError.runtime("No handler called \(name)")
        }
        guard !definition.isAsync else {
            throw BASICError.runtime("Handler \(definition.displayName) must be synchronous")
        }
        _ = try callFunctionSynchronously(
            definition: definition,
            receiver: nil,
            receiverClassName: nil,
            argumentValues: [],
            allowVoid: true
        )
    }

    func dispatchEvent(selector: BASICEventSelector, data: BASICValue) throws {
        let registration = runtime.eventHandler(for: selector)
            ?? selector.subtype.map { _ in runtime.eventHandler(for: BASICEventSelector(type: selector.type)) }
            ?? nil
        guard let registration else {
            logMissingEventHandler(selector: selector, detail: nil)
            return
        }
        guard let definition = functionDefinitions[registration.normalizedHandlerName] else {
            logMissingEventHandler(selector: selector, detail: " handler=\(registration.handlerName)")
            return
        }
        guard !definition.isAsync else {
            throw BASICError.runtime("Event handler \(definition.displayName) must be synchronous")
        }
        let payload = try eventPayload(for: selector, data: data, handler: definition)
        logTarget(
            module: "BASICInterpreter.swift",
            text: "event handler begin selector=\(selector.description) handler=\(definition.displayName)"
        )
        do {
            _ = try callFunctionSynchronously(
                definition: definition,
                receiver: nil,
                receiverClassName: nil,
                argumentValues: [payload],
                allowVoid: true
            )
            logTarget(
                module: "BASICInterpreter.swift",
                text: "event handler completed selector=\(selector.description) handler=\(definition.displayName)"
            )
        } catch {
            logTarget(
                module: "BASICInterpreter.swift",
                text: "event handler failed selector=\(selector.description) handler=\(definition.displayName) error=\(error)"
            )
            throw error
        }
    }

    private func eventPayload(
        for selector: BASICEventSelector,
        data: BASICValue,
        handler definition: FunctionDefinition
    ) throws -> BASICValue {
        guard definition.parameters.count == 1 else {
            return data
        }
        let parameterType = resolvedDeclaredType(definition.parameters[0].type)
        guard case .classType(let typeName) = parameterType,
              BASICRuntime.builtInEventClassName(typeName) != nil else {
            return data
        }
        return try typedEventObject(for: selector, data: data)
    }

    private func typedEventObject(for selector: BASICEventSelector, data: BASICValue) throws -> BASICValue {
        guard case .dictionary(let dictionary) = data else {
            return data
        }
        let typeName: String
        switch selector.type {
        case "RESIZE":
            typeName = "BASICResizeEvent"
        case "MOUSE":
            typeName = "BASICMouseEvent"
        case "TIMER":
            typeName = "BASICTimerEvent"
        case "GAMEPAD":
            typeName = "BASICGamepadEvent"
        case "FRAME":
            typeName = "BASICFrameEvent"
        case "ROUTE":
            typeName = "BASICRouteEvent"
        case "NETWORK":
            typeName = "BASICNetworkEvent"
        default:
            typeName = "BASICEvent"
        }

        var fields: [String: BASICValue] = [
            "TYPE": fieldValue("type", from: dictionary) ?? .string(BASICString(selector.type)),
            "SUBTYPE": fieldValue("subtype", from: dictionary) ?? .string(BASICString(selector.subtype ?? "")),
            "TIMESTAMP": fieldValue("timestamp", from: dictionary) ?? .number(Date().timeIntervalSince1970),
            "TARGET": fieldValue("target", from: dictionary) ?? .string(BASICString("")),
            "HANDLED": fieldValue("handled", from: dictionary) ?? .boolean(false)
        ]

        switch selector.type {
        case "RESIZE":
            fields["WIDTH"] = fieldValue("width", from: dictionary) ?? .number(0)
            fields["HEIGHT"] = fieldValue("height", from: dictionary) ?? .number(0)
        case "MOUSE":
            fields["X"] = fieldValue("x", from: dictionary) ?? .number(0)
            fields["Y"] = fieldValue("y", from: dictionary) ?? .number(0)
            fields["BUTTON"] = fieldValue("button", from: dictionary) ?? .number(0)
            fields["BUTTONS"] = fieldValue("buttons", from: dictionary) ?? .number(0)
            fields["BUTTONFLAGS"] = fieldValue("buttonFlags", from: dictionary)
                ?? fieldValue("buttons", from: dictionary)
                ?? .number(0)
            fields["DURATION"] = fieldValue("duration", from: dictionary) ?? .number(0)
            fields["DELTAX"] = fieldValue("deltaX", from: dictionary) ?? .number(0)
            fields["DELTAY"] = fieldValue("deltaY", from: dictionary) ?? .number(0)
            fields["HITID"] = fieldValue("hitId", from: dictionary)
                ?? fieldValue("hitID", from: dictionary)
                ?? fieldValue("hit", from: dictionary)
                ?? .string(BASICString(""))
        case "TIMER":
            fields["TIMERID"] = fieldValue("timerID", from: dictionary)
                ?? fieldValue("timerId", from: dictionary)
                ?? .number(0)
            fields["SEQUENCE"] = fieldValue("sequence", from: dictionary) ?? .number(0)
            fields["TICK"] = fieldValue("tick", from: dictionary) ?? .number(0)
            fields["TICKS"] = fieldValue("ticks", from: dictionary)
                ?? fieldValue("tick", from: dictionary)
                ?? .number(0)
            fields["INTERVAL"] = fieldValue("interval", from: dictionary) ?? .number(0)
            fields["BASEINTERVAL"] = fieldValue("baseInterval", from: dictionary)
                ?? fieldValue("interval", from: dictionary)
                ?? .number(0)
            fields["ELAPSED"] = fieldValue("elapsed", from: dictionary) ?? .number(0)
        case "GAMEPAD":
            fields["CONTROLLER"] = fieldValue("controller", from: dictionary) ?? .number(0)
            fields["CONTROL"] = fieldValue("control", from: dictionary) ?? .string(BASICString(""))
            fields["VALUE"] = fieldValue("value", from: dictionary) ?? .number(0)
        case "FRAME":
            fields["FRAMEID"] = fieldValue("frameID", from: dictionary)
                ?? fieldValue("id", from: dictionary)
                ?? .string(BASICString(""))
            fields["FRAMETYPE"] = fieldValue("frameType", from: dictionary)
                ?? fieldValue("subtype", from: dictionary)
                ?? .string(BASICString(""))
            fields["REASON"] = fieldValue("reason", from: dictionary) ?? .string(BASICString(""))
            fields["TIMEOUT"] = fieldValue("timeout", from: dictionary)
                ?? fieldValue("timeoutMilliseconds", from: dictionary)
                ?? .number(0)
            fields["RAW"] = fieldValue("raw", from: dictionary)
                ?? fieldValue("rawResponse", from: dictionary)
                ?? .string(BASICString(""))
        case "ROUTE":
            fields["REQUESTID"] = fieldValue("requestID", from: dictionary)
                ?? fieldValue("requestId", from: dictionary)
                ?? .string(BASICString(""))
            fields["METHOD"] = fieldValue("method", from: dictionary) ?? .string(BASICString(""))
            fields["PATH"] = fieldValue("path", from: dictionary) ?? .string(BASICString(""))
            fields["ROUTE"] = fieldValue("route", from: dictionary) ?? .string(BASICString(""))
            fields["QUERY"] = fieldValue("query", from: dictionary) ?? .string(BASICString(""))
            fields["BODY"] = fieldValue("body", from: dictionary) ?? .string(BASICString(""))
            fields["STATUS"] = fieldValue("status", from: dictionary) ?? .number(0)
        case "NETWORK":
            fields["OPERATION"] = fieldValue("operation", from: dictionary) ?? .string(BASICString(""))
            fields["URL"] = fieldValue("url", from: dictionary) ?? .string(BASICString(""))
            fields["STATUS"] = fieldValue("status", from: dictionary) ?? .number(0)
            fields["BYTES"] = fieldValue("bytes", from: dictionary) ?? .number(0)
            fields["ERROR"] = fieldValue("error", from: dictionary) ?? .string(BASICString(""))
            fields["REQUESTID"] = fieldValue("requestID", from: dictionary)
                ?? fieldValue("requestId", from: dictionary)
                ?? .string(BASICString(""))
        default:
            break
        }

        return BASICRuntime.builtInEventObject(typeName: typeName, fields: fields)
    }

    private func fieldValue(_ key: String, from dictionary: BASICDictionary) -> BASICValue? {
        dictionary.values[key] ?? dictionary.values[key.uppercased()]
    }

    private func synchronizeHostInput(for type: String) {
        guard type.uppercased() == "MOUSE",
              let vectorHost = host as? BASICVectorTerminalHost,
              vectorHost.isVectorTerminalAvailable else {
            return
        }
        do {
            if runtime.isHostInputEnabled(for: BASICEventSelector(type: "MOUSE")) {
                try vectorHost.vectorTerminalEnableMouseReporting(mode: "all")
            } else {
                try vectorHost.vectorTerminalDisableMouseReporting()
            }
        } catch {
            logTarget(
                module: "BASICInterpreter.swift",
                text: "mouse input sync failed error=\(error)"
            )
        }
    }

    private func logTarget(module: String, text: String) {
        guard let loggingHost,
              loggingHost.isBASICLoggingEnabled else {
            return
        }
        outputCoordinator.log(level: "TARGET", issuer: "B", module: module, text: text)
    }

    private func traceExecution(_ line: ParsedLine) {
        guard let loggingHost,
              loggingHost.isBASICLoggingEnabled,
              traceOverride ?? loggingHost.isBASICTraceEnabled else {
            return
        }
        let basicLine = line.displayLineNumber != line.sourceLineNumber ? "(\(line.displayLineNumber))" : ""
        let prefix = "\(line.sourceLineNumber)\(basicLine): "
        outputCoordinator.log(
            level: "TRACE",
            issuer: "B",
            module: line.fileName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? defaultLogModuleName(),
            text: prefix + traceText(for: line.statement)
        )
    }

    private func traceText(for statement: Statement) -> String {
        switch statement {
        case .empty:
            return ""
        case .remark:
            return "rem"
        case .label(let name):
            return "\(name):"
        case .labeled(let name, let statement):
            return "\(name): \(traceText(for: statement))"
        case .sequence(let statements):
            return statements.map(traceText(for:)).joined(separator: ":")
        case .print(let parts):
            return "print " + traceText(for: parts)
        case .printUsing(let format, let values, let trailingSeparator):
            var text = "print using \(traceText(for: format)); " + values.map(traceText(for:)).joined(separator: ", ")
            if let trailingSeparator { text += traceText(for: trailingSeparator) }
            return text
        case .log(let level, let parts):
            return "log \(traceText(for: level)), \(traceText(for: parts))"
        case .module(let name):
            return "module \(traceText(for: name))"
        case .traceOn:
            return "tron"
        case .traceOff:
            return "troff"
        case .screen(let mode):
            return "screen \(traceText(for: mode))"
        case .color(let values):
            return "color " + values.map(traceText(for:)).joined(separator: ", ")
        case .cls:
            return "cls"
        case .locate(let row, let column):
            return "locate \(traceText(for: row)), \(traceText(for: column))"
        case .pset(let point, let color):
            return "pset \(traceText(for: point))" + (color.map { ", \(traceText(for: $0))" } ?? "")
        case .preset(let point, let color):
            return "preset \(traceText(for: point))" + (color.map { ", \(traceText(for: $0))" } ?? "")
        case .line(let start, let end, let color):
            return "line \(traceText(for: start))-\(traceText(for: end))" + (color.map { ", \(traceText(for: $0))" } ?? "")
        case .circle(let center, let radius, let color, let aspect):
            return "circle \(traceText(for: center)), \(traceText(for: radius))"
                + (color.map { ", \(traceText(for: $0))" } ?? "")
                + (aspect.map { ", \(traceText(for: $0))" } ?? "")
        case .paint(let point, let fill, let border):
            return "paint \(traceText(for: point)), \(traceText(for: fill))" + (border.map { ", \(traceText(for: $0))" } ?? "")
        case .draw(let expression):
            return "draw \(traceText(for: expression))"
        case .assignment(let kind, let name, let type, let value):
            let keyword = traceText(for: kind)
            let typed = type.map { " as \(traceText(for: $0))" } ?? ""
            let assigned = value.map { " = \(traceText(for: $0))" } ?? ""
            return "\(keyword)\(name.name)\(typed)\(assigned)"
        case .referenceAssignment(let reference, let value):
            return "\(traceText(for: reference))" + (value.map { " = \(traceText(for: $0))" } ?? "")
        case .expression(let expression):
            return traceText(for: expression)
        case .dim(let kind, let name, let dimensions, let type):
            let keyword = kind == .bare ? "dim " : traceText(for: kind)
            let dimensionText = dimensions.map { $0.map(traceText(for:)) ?? "" }.joined(separator: ", ")
            let typed = type.map { " as \(traceText(for: $0))" } ?? ""
            return "\(keyword)\(name.name)(\(dimensionText))\(typed)"
        case .input(let prompt, let target):
            return "input " + [prompt.map(traceText(for:)), Optional(traceText(for: target))].compactMap { $0 }.joined(separator: ", ")
        case .lineInput(let prompt, let target, let exitTarget, let fieldLength, let maxLength, let defaultValue):
            var text = "line input "
            if let prompt { text += "\(traceText(for: prompt)), " }
            text += traceText(for: target)
            if let fieldLength { text += " length \(traceText(for: fieldLength))" }
            if let maxLength { text += " max \(traceText(for: maxLength))" }
            if let defaultValue { text += " default \(traceText(for: defaultValue))" }
            if let exitTarget { text += " exitvar \(traceText(for: exitTarget))" }
            return text
        case .goto(let line):
            return "goto \(line)"
        case .gotoLabel(let label):
            return "goto \(label)"
        case .gosub(let target):
            return "gosub \(traceText(for: target))"
        case .returnFromSubroutine:
            return "return"
        case .returnValue(let value):
            return "return \(traceText(for: value))"
        case .ifThen(let condition, let thenAction, let elseAction):
            var text = "if \(traceText(for: condition)) then \(traceText(for: thenAction))"
            if let elseAction { text += " else \(traceText(for: elseAction))" }
            return text
        case .forLoop(let variable, let start, let end, let step):
            var text = "for \(variable.name) = \(traceText(for: start)) to \(traceText(for: end))"
            if let step { text += " step \(traceText(for: step))" }
            return text
        case .nextLoop(let variables):
            return "next" + (variables.isEmpty ? "" : " " + variables.map(\.name).joined(separator: ", "))
        case .selectCase(let expression):
            return "select case \(traceText(for: expression))"
        case .caseClause(let clauses):
            return "case " + clauses.map(traceText(for:)).joined(separator: ", ")
        case .caseElse:
            return "case else"
        case .endSelect:
            return "end select"
        case .end:
            return "end"
        default:
            return String(describing: statement)
        }
    }

    private func traceText(for action: ConditionalAction) -> String {
        switch action {
        case .branch(let target): return traceText(for: target)
        case .statement(let statement): return traceText(for: statement)
        }
    }

    private func traceText(for target: BranchTarget) -> String {
        switch target {
        case .line(let line): return "\(line)"
        case .label(let label): return label
        }
    }

    private func traceText(for clause: CaseClause) -> String {
        switch clause {
        case .equals(let expression): return traceText(for: expression)
        case .range(let start, let end): return "\(traceText(for: start)) to \(traceText(for: end))"
        case .comparison(let operation, let expression): return "\(traceText(for: operation)) \(traceText(for: expression))"
        }
    }

    private func traceText(for parts: [PrintPart]) -> String {
        parts.map { part in
            switch part {
            case .expression(let expression): return traceText(for: expression)
            case .separator(let separator): return traceText(for: separator)
            }
        }.joined()
    }

    private func traceText(for separator: PrintSeparator) -> String {
        switch separator {
        case .comma: return ", "
        case .semicolon: return "; "
        }
    }

    private func traceText(for point: GraphicsPoint) -> String {
        "(\(traceText(for: point.x)),\(traceText(for: point.y)))"
    }

    private func traceText(for target: ReadTarget) -> String {
        switch target {
        case .variable(let name): return name.name
        case .reference(let reference): return traceText(for: reference)
        }
    }

    private func traceText(for reference: VariableReference) -> String {
        var text = reference.base.name
        if !reference.indexes.isEmpty || reference.hasEmptyIndexList {
            text += "(" + reference.indexes.map(traceText(for:)).joined(separator: ", ") + ")"
        }
        for (index, field) in reference.fields.enumerated() {
            text += "." + field
            let indexes = reference.fieldIndexes.indices.contains(index) ? reference.fieldIndexes[index] : []
            if !indexes.isEmpty {
                text += "(" + indexes.map(traceText(for:)).joined(separator: ", ") + ")"
            }
        }
        return text
    }

    private func traceText(for expression: Expression) -> String {
        switch expression {
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value):
            return "\"\(value)\""
        case .interpolatedString(let value):
            return "$\"\(value)\""
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .variable(let name):
            return name.name
        case .variableReference(let reference):
            return traceText(for: reference)
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            return "\(name.name)(\(arguments.map(traceText(for:)).joined(separator: ", ")))"
        case .methodCall(let receiver, let name, let arguments):
            return "\(traceText(for: receiver)).\(name.name)(\(arguments.map(traceText(for:)).joined(separator: ", ")))"
        case .newObject(let name, let arguments):
            return "new \(name)(\(arguments.map(traceText(for:)).joined(separator: ", ")))"
        case .unaryMinus(let expression):
            return "-\(traceText(for: expression))"
        case .binary(let left, let operation, let right):
            return "\(traceText(for: left)) \(traceText(for: operation)) \(traceText(for: right))"
        case .await(let expression):
            return "await \(traceText(for: expression))"
        case .pointFunction(let point):
            return "point\(traceText(for: point))"
        case .chrFunction(let expression):
            return "chr$(\(traceText(for: expression)))"
        case .lenFunction(let expression):
            return "len(\(traceText(for: expression)))"
        case .systemFunction(let expression):
            return "system$(\(traceText(for: expression)))"
        default:
            return String(describing: expression)
        }
    }

    private func traceText(for operation: BinaryOperation) -> String {
        switch operation {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .equal: return "="
        case .notEqual: return "<>"
        case .less: return "<"
        case .lessEqual: return "<="
        case .greater: return ">"
        case .greaterEqual: return ">="
        case .and: return "and"
        case .or: return "or"
        }
    }

    private func traceText(for type: BASICType) -> String {
        switch type {
        case .scalar(let scalar): return String(describing: scalar).uppercased()
        case .void: return "VOID"
        case .record(let name), .classType(let name), .interfaceType(let name), .functionType(let name): return name
        case .dictionary: return "DICTIONARY"
        }
    }

    private func traceText(for kind: AssignmentKind) -> String {
        switch kind {
        case .bare: return ""
        case .letValue: return "let "
        case .global: return "global "
        case .local: return "local "
        }
    }

    private func logMissingEventHandler(selector: BASICEventSelector, detail: String?) {
        let key = selector.description + (detail ?? "")
        guard loggedMissingEventSelectors.insert(key).inserted else {
            return
        }
        logTarget(
            module: "BASICInterpreter.swift",
            text: "event handler missing selector=\(selector.description)\(detail ?? "")"
        )
    }

    func callClosureBlock(_ closure: BASICCapturedClosure) throws -> BASICValue {
        guard let bodyStatements = closure.bodyStatements else {
            throw BASICError.runtime("Closure has no block body")
        }
        let returnType = resolvedDeclaredType(closure.returnType)
        let definition = FunctionDefinition(
            displayName: closure.name,
            normalizedName: closure.name.uppercased(),
            parameters: closure.parameters,
            returnType: returnType,
            startIndex: 0,
            endIndex: bodyStatements.count
        )
        functionStack.append(FunctionFrame(
            definition: definition,
            receiverClassName: nil,
            localContextIndex: 0,
            returnValue: runtime.defaultValue(for: returnType)
        ))
        defer { _ = functionStack.popLast() }

        let parsed = bodyStatements.enumerated().map { index, line in
            ParsedLine(
                number: nil,
                displayLineNumber: line.sourceLineNumber,
                fileName: line.fileName,
                sourceLineNumber: line.sourceLineNumber,
                statementNumber: index,
                isImported: false,
                statement: line.statement
            )
        }
        var labelIndexByName: [String: Int] = [:]
        for (index, line) in parsed.enumerated() {
            if let label = line.statement.label {
                labelIndexByName[label.uppercased()] = index
            }
        }

        var pc = 0
        while pc < parsed.count {
            let flow = try execute(parsed[pc].statement, pc: pc, parsed: parsed)
            switch flow {
            case .next:
                pc += 1
            case .jump(let index):
                pc = index
            case .gotoLabel(let label):
                guard let index = labelIndexByName[label.uppercased()] else {
                    throw BASICError.missingLabel(label)
                }
                pc = index
            case .goto(let line):
                throw BASICError.runtime("GOTO line \(line) is not supported inside closure bodies yet")
            case .returnTo:
                throw BASICError.runtime("RETURN without GOSUB")
            case .exitSelect:
                guard let index = matchingEndSelect(after: pc, in: parsed) else {
                    throw BASICError.runtime("EXIT SELECT without SELECT")
                }
                pc = index + 1
            case .functionReturn, .end:
                let value = functionStack.last?.returnValue ?? runtime.defaultValue(for: returnType)
                return try runtime.coerce(value, to: returnType, variable: VariableName(name: closure.name, column: 0))
            }
        }

        let value = functionStack.last?.returnValue ?? runtime.defaultValue(for: returnType)
        return try runtime.coerce(value, to: returnType, variable: VariableName(name: closure.name, column: 0))
    }

    private func assignFunctionReturnIfNeeded(variable: VariableName, declaredType: BASICType?, value: BASICValue?) throws -> Bool {
        guard let frame = functionStack.last, variable.normalized == frame.definition.normalizedName else {
            return false
        }
        guard declaredType == nil else {
            throw BASICError.type(message: "Cannot redeclare function return \(variable.name)")
        }
        try setFunctionReturn(value)
        return true
    }

    private func setFunctionReturn(_ value: BASICValue?) throws {
        guard var frame = functionStack.popLast() else {
            throw BASICError.runtime("RETURN outside FUNCTION")
        }
        let returnType = resolvedDeclaredType(frame.definition.returnType)
        if returnType == .void {
            if value != nil {
                functionStack.append(frame)
                throw BASICError.type(message: "VOID function \(frame.definition.displayName) cannot return a value")
            }
            frame.didReturn = true
            functionStack.append(frame)
            return
        }
        let coerced = try runtime.coerce(
            value ?? runtime.defaultValue(for: returnType),
            to: returnType,
            variable: VariableName(name: frame.definition.displayName, column: 0)
        )
        frame.returnValue = coerced
        frame.didReturn = true
        functionStack.append(frame)
    }

    private func resolvedDeclaredType(_ type: BASICType) -> BASICType {
        if case .record(let name) = type, classDefinitions[name.uppercased()] != nil || BASICRuntime.isBuiltInClass(name) {
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

    private func blockIfFlow(_ condition: Expression, pc: Int, parsed: [ParsedLine]) throws -> Flow {
        if try evaluate(condition).truthy {
            return .next
        }

        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .blockIf:
                depth += 1
            case .endIf:
                if depth == 0 {
                    return .jump(index + 1)
                }
                depth -= 1
            case .elseIf(let condition) where depth == 0:
                if try evaluate(condition).truthy {
                    return .jump(index + 1)
                }
            case .elseBlock where depth == 0:
                return .jump(index + 1)
            default:
                break
            }
            index += 1
        }

        throw BASICError.runtime("IF without END IF")
    }

    private func matchingEndIf(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .blockIf:
                depth += 1
            case .endIf:
                if depth == 0 {
                    return index
                }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return nil
    }

    private func loadProgram(path: String) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("LOAD is not supported by this host")
        }
        do {
            program.loadSource(try fileHost.loadTextFile(path: path), fileName: path)
            fileState.lastFilePath = path
        } catch {
            throw BASICError.runtime("Could not load \(path): \(error.localizedDescription)")
        }
    }

    private func saveProgram(path: String) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("SAVE is not supported by this host")
        }
        do {
            try fileHost.saveTextFile(path: path, text: program.listing())
            fileState.lastFilePath = path
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not save \(path): \(error.localizedDescription)")
        }
    }

    private func changeDirectory(path: Expression?) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("CD is not supported by this host")
        }
        guard let path else {
            outputCoordinator.printLine(try fileHost.currentDirectoryPath())
            return
        }
        let resolvedPath = try validatedBASICFilePath(string(path))
        do {
            try fileHost.changeDirectory(path: resolvedPath)
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not change directory to \(resolvedPath): \(error.localizedDescription)")
        }
    }

    private func pushDirectory(path: Expression?) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("PUSHD is not supported by this host")
        }
        let current = try fileHost.currentDirectoryPath()
        let destination = try path.map(string) ?? runtime.environmentValue(name: "HOME")
        guard !destination.isEmpty else {
            throw BASICError.runtime("PUSHD requires a directory")
        }
        do {
            try fileHost.changeDirectory(path: destination)
            runtime.directoryStack.append(current)
            try printDirectoryStack()
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not change directory to \(destination): \(error.localizedDescription)")
        }
    }

    private func popDirectory() throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("POPD is not supported by this host")
        }
        guard let destination = runtime.directoryStack.popLast() else {
            throw BASICError.runtime("Directory stack is empty")
        }
        do {
            try fileHost.changeDirectory(path: destination)
            try printDirectoryStack()
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not change directory to \(destination): \(error.localizedDescription)")
        }
    }

    private func printDirectoryStack() throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("DIRS is not supported by this host")
        }
        let paths = [try fileHost.currentDirectoryPath()] + runtime.directoryStack.reversed()
        outputCoordinator.printLine(paths.joined(separator: " "))
    }

    private func listFiles() throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("FILES is not supported by this host")
        }
        do {
            let files = try fileHost.listFiles()
            if !files.isEmpty {
                let columns = (host as? BASICConsoleHost)?.screenColumns() ?? 80
                outputCoordinator.printLine(BASICFileListFormatter.columns(files, terminalColumns: columns))
            }
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not list files: \(error.localizedDescription)")
        }
    }

    private func openLegacyFile(path: Expression, mode: BASICLegacyFileMode, number: Expression, recordLength: Expression?) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("File I/O is not supported by this host")
        }
        let handle = try legacyFileHandle(number)
        guard legacyFiles[handle]?.isOpen != true else {
            throw BASICError.runtime("File Already Open")
        }
        let resolvedPath = try validatedBASICFilePath(string(path))
        let resolvedRecordLength = try recordLength.map(integer) ?? (mode == .random ? 128 : nil)
        if recordLength != nil, mode != .random {
            throw BASICError.runtime("LEN is only valid for RANDOM files")
        }
        if mode == .random, (resolvedRecordLength ?? 0) <= 0 {
            throw BASICError.runtime("Bad record length")
        }
        let exists = try fileHost.fileExists(path: resolvedPath)
        let content: BASICString
        let position: Int
        let access: BASICFileAccess
        let contentType: BASICFileContentType
        switch mode {
        case .input:
            guard exists else { throw BASICError.runtime("File Not Found") }
            let text = try fileHost.loadTextFile(path: resolvedPath)
            content = BASICString(text)
            position = 0
            access = .read
            contentType = .text
        case .output:
            content = BASICString("")
            position = 0
            access = .write
            contentType = .text
            try fileHost.saveTextFile(path: resolvedPath, text: "")
        case .append:
            let text = exists ? try fileHost.loadTextFile(path: resolvedPath) : ""
            content = BASICString(text)
            position = text.count
            access = .write
            contentType = .text
        case .binary, .random:
            let data = exists ? try fileHost.loadFileData(path: resolvedPath) : Data()
            content = BASICString(rawData: data)
            position = 0
            access = .both
            contentType = .raw
            if !exists {
                try fileHost.saveFileData(path: resolvedPath, data: Data())
            }
        }
        legacyFiles[handle] = BASICOpenFile(
            path: resolvedPath,
            access: access,
            contentType: contentType,
            legacyMode: mode,
            isOpen: true,
            content: content,
            position: position,
            recordLength: resolvedRecordLength
        )
    }

    private func closeLegacyFile(number: Expression?) throws {
        if let number {
            let handle = try legacyFileHandle(number)
            guard var file = legacyFiles[handle], file.isOpen else {
                throw BASICError.runtime("Bad file number")
            }
            file.isOpen = false
            legacyFiles[handle] = file
            return
        }

        for handle in legacyFiles.keys {
            legacyFiles[handle]?.isOpen = false
        }
    }

    private func resetLegacyFile(number: Expression) throws {
        let handle = try legacyFileHandle(number)
        guard var file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        file.position = 0
        legacyFiles[handle] = file
    }

    private func printLegacyFile(number: Expression, parts: [PrintPart]) throws {
        let handle = try legacyFileHandle(number)
        var file = try writableLegacyFile(handle: handle)
        guard file.contentType == .text else {
            throw BASICError.runtime("Bad file mode")
        }
        let rendered = try renderPrint(parts)
        let path = try legacyOpenPath(file)
        let text = rendered.text + rendered.terminator
        file.content = file.content.concatenating(BASICString(text))
        file.position = file.content.rawString.count
        try legacyFileHost().saveTextFile(path: path, text: file.content.rawString)
        legacyFiles[handle] = file
    }

    private func writeLegacyFile(number: Expression, values: [Expression]) throws {
        let handle = try legacyFileHandle(number)
        var file = try writableLegacyFile(handle: handle)
        guard file.contentType == .text else {
            throw BASICError.runtime("Bad file mode")
        }
        let fields = try values.map { expression -> String in
            let value = try evaluate(expression)
            switch value {
            case .string(let string):
                return "\"" + string.rawString.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .boolean(let boolean):
                return boolean ? "TRUE" : "FALSE"
            case .empty, .null:
                return ""
            default:
                return value.description
            }
        }
        let text = fields.joined(separator: ",") + "\n"
        let path = try legacyOpenPath(file)
        file.content = file.content.concatenating(BASICString(text))
        file.position = file.content.characterCount
        try legacyFileHost().saveTextFile(path: path, text: file.content.rawString)
        legacyFiles[handle] = file
    }

    private func defineLegacyFields(number: Expression, fields: [BASICLegacyFieldSpec]) throws {
        let handle = try legacyFileHandle(number)
        guard var file = legacyFiles[handle], file.isOpen, file.legacyMode == .random,
              let recordLength = file.recordLength, recordLength > 0 else {
            throw BASICError.runtime("Bad file mode")
        }
        var definitions: [BASICRandomField] = []
        var totalWidth = 0
        for field in fields {
            let width = try integer(field.width)
            guard width > 0 else { throw BASICError.runtime("FIELD width must be positive") }
            guard field.variable.name.hasSuffix("$") else {
                throw BASICError.runtime("FIELD requires string variables")
            }
            totalWidth += width
            guard totalWidth <= recordLength else {
                throw BASICError.runtime("FIELD overflow")
            }
            definitions.append(BASICRandomField(width: width, variable: field.variable))
            try runtime.assign(
                kind: .bare,
                variable: field.variable,
                declaredType: nil,
                value: .string(BASICString(rawData: Data(repeating: 32, count: width)))
            )
        }
        file.fields = definitions
        legacyFiles[handle] = file
    }

    private func setLegacyFieldString(target: ReadTarget, value: Expression, rightAligned: Bool) throws {
        guard case .variable(let variable) = target else {
            throw BASICError.runtime("LSET and RSET require a FIELD string variable")
        }
        guard let field = legacyFiles.values.lazy.compactMap({ file in
            file.fields.first { $0.variable.normalized == variable.normalized }
        }).first else {
            throw BASICError.runtime("LSET and RSET require a FIELD string variable")
        }
        guard let string = try evaluate(value).string else {
            throw BASICError.runtime("Expected a string")
        }
        var bytes = Data(string.rawData.prefix(field.width))
        if bytes.count < field.width {
            let padding = Data(repeating: 32, count: field.width - bytes.count)
            bytes = rightAligned ? padding + bytes : bytes + padding
        }
        try assignReadValue(.string(BASICString(rawData: bytes)), to: target)
    }

    private func putLegacyRecord(handle: Int, parts: [PrintPart]) throws {
        guard var file = legacyFiles[handle], file.isOpen, file.legacyMode == .random,
              let recordLength = file.recordLength, recordLength > 0 else {
            throw BASICError.runtime("Bad file mode")
        }
        let recordNumber: Int
        if parts.isEmpty {
            recordNumber = file.position / recordLength + 1
        } else if parts.count == 1, case .expression(let expression) = parts[0] {
            recordNumber = try integer(expression)
        } else {
            throw BASICError.runtime("PUT expects an optional record number in RANDOM mode")
        }
        guard recordNumber > 0 else { throw BASICError.runtime("Bad record number") }
        var record = Data()
        for field in file.fields {
            guard let value = runtime.value(for: field.variable).string else {
                throw BASICError.runtime("FIELD variable must be a string")
            }
            var bytes = Data(value.rawData.prefix(field.width))
            if bytes.count < field.width {
                bytes.append(Data(repeating: 32, count: field.width - bytes.count))
            }
            record.append(bytes)
        }
        if record.count < recordLength {
            record.append(Data(repeating: 0, count: recordLength - record.count))
        }
        let offset = (recordNumber - 1) * recordLength
        var data = file.content.rawData
        if data.count < offset {
            data.append(Data(repeating: 0, count: offset - data.count))
        }
        let replacementEnd = min(data.count, offset + recordLength)
        data.replaceSubrange(offset..<replacementEnd, with: record.prefix(recordLength))
        file.content = BASICString(rawData: data)
        file.position = offset + recordLength
        try legacyFileHost().saveFileData(path: legacyOpenPath(file), data: data)
        legacyFiles[handle] = file
    }

    private func getLegacyRecord(handle: Int, record: Expression?) throws {
        guard var file = legacyFiles[handle], file.isOpen, file.legacyMode == .random,
              let recordLength = file.recordLength, recordLength > 0 else {
            throw BASICError.runtime("Bad file mode")
        }
        let recordNumber = try record.map(integer) ?? (file.position / recordLength + 1)
        guard recordNumber > 0 else { throw BASICError.runtime("Bad record number") }
        let offset = (recordNumber - 1) * recordLength
        let data = file.content.rawData
        guard offset + recordLength <= data.count else {
            throw BASICError.runtime("Input past end")
        }
        let bytes = data.subdata(in: offset..<(offset + recordLength))
        var fieldOffset = 0
        for field in file.fields {
            let end = fieldOffset + field.width
            try runtime.assign(
                kind: .bare,
                variable: field.variable,
                declaredType: nil,
                value: .string(BASICString(rawData: bytes.subdata(in: fieldOffset..<end)))
            )
            fieldOffset = end
        }
        file.position = offset + recordLength
        legacyFiles[handle] = file
    }

    private func seekLegacyFile(number: Expression, position: Expression) throws {
        let handle = try legacyFileHandle(number)
        guard var file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        let requested = try integer(position)
        guard requested > 0 else { throw BASICError.runtime("Bad file position") }
        if file.legacyMode == .random, let recordLength = file.recordLength {
            file.position = (requested - 1) * recordLength
        } else {
            file.position = requested - 1
        }
        legacyFiles[handle] = file
    }

    private func printLegacyFileUsing(number: Expression, format: Expression, values: [Expression], trailingSeparator: PrintSeparator?) throws {
        let handle = try legacyFileHandle(number)
        var file = try writableLegacyFile(handle: handle)
        guard file.contentType == .text else {
            throw BASICError.runtime("Bad file mode")
        }
        let rendered = try renderUsing(format: format, values: values, trailingSeparator: trailingSeparator)
        let path = try legacyOpenPath(file)
        let text = rendered.text + rendered.terminator
        file.content = file.content.concatenating(BASICString(text))
        file.position = file.content.rawString.count
        try legacyFileHost().saveTextFile(path: path, text: file.content.rawString)
        legacyFiles[handle] = file
    }

    private func inputLegacyFile(number: Expression, targets: [ReadTarget]) throws {
        let handle = try legacyFileHandle(number)
        var fields: [String] = []
        while fields.count < targets.count {
            guard let line = try readLegacyLine(handle: handle) else {
                throw BASICError.runtime("Input past end")
            }
            fields.append(contentsOf: parseLegacyInputFields(line))
        }
        for (target, field) in zip(targets, fields) {
            try assignLegacyInput(field, to: target)
        }
    }

    private func lineInputLegacyFile(number: Expression, target: ReadTarget) throws {
        let handle = try legacyFileHandle(number)
        guard let line = try readLegacyLine(handle: handle) else {
            throw BASICError.runtime("Input past end")
        }
        try assignReadValue(.string(BASICString(line)), to: target)
    }

    private func legacyEOF(_ number: Expression) throws -> BASICValue {
        let handle = try legacyFileHandle(number)
        let file = try readableLegacyFile(handle: handle)
        let size = file.contentType == .raw ? file.content.byteCount : file.content.characterCount
        return .boolean(file.position >= size)
    }

    private func intrinsicInputString(name: String, arguments: [Expression]) throws -> BASICValue {
        try requireArgumentRange(name, arguments, 1...2)
        let count = try integer(arguments[0])
        guard count >= 0 else { throw BASICError.runtime("INPUT$ requires a non-negative length") }
        guard count > 0 else { return .string(BASICString("")) }

        if arguments.count == 2 {
            let handle = try legacyFileHandle(arguments[1])
            return .string(try readLegacyCharacters(handle: handle, count: count))
        }

        let encoding: BASICKeyEncoding = runtime.keyMode == .ibm ? .ibm : .aibasic
        var result = ""
        if let keyboardHost = host as? BASICBlockingKeyboardHost {
            while result.count < count {
                try checkExecutionBreak()
                guard let rawKey = keyboardHost.readBlockingKey() else {
                    try checkExecutionBreak()
                    break
                }
                result += BASICKeyNormalizer.normalize(rawKey, encoding: encoding)
                try checkExecutionBreak()
            }
        } else if let keyboardHost = host as? BASICKeyboardHost {
            while result.count < count, let rawKey = keyboardHost.readKey(), !rawKey.isEmpty {
                try checkExecutionBreak()
                result += BASICKeyNormalizer.normalize(rawKey, encoding: encoding)
            }
        }
        return .string(BASICString(String(result.prefix(count))))
    }

    private func readLegacyCharacters(handle: Int, count: Int) throws -> BASICString {
        var file = try readableLegacyFile(handle: handle)
        if file.contentType == .raw {
            let data = file.content.rawData
            guard file.position < data.count else {
                legacyFiles[handle] = file
                throw BASICError.runtime("Input past end")
            }
            let end = min(data.count, file.position + count)
            let value = BASICString(rawData: data.subdata(in: file.position..<end))
            file.position = end
            legacyFiles[handle] = file
            return value
        }
        let raw = file.content.rawString
        guard file.position < raw.count else {
            legacyFiles[handle] = file
            throw BASICError.runtime("Input past end")
        }
        let start = raw.index(raw.startIndex, offsetBy: file.position)
        let end = raw.index(start, offsetBy: count, limitedBy: raw.endIndex) ?? raw.endIndex
        let value = String(raw[start..<end])
        file.position = raw.distance(from: raw.startIndex, to: end)
        legacyFiles[handle] = file
        return BASICString(value)
    }

    private func readLegacyLine(handle: Int) throws -> String? {
        var file = try readableLegacyFile(handle: handle)
        guard file.contentType == .text else {
            throw BASICError.runtime("Bad file mode")
        }
        let raw = file.content.rawString
        guard file.position < raw.count else {
            legacyFiles[handle] = file
            return nil
        }
        let start = raw.index(raw.startIndex, offsetBy: file.position)
        if let newline = raw[start...].firstIndex(of: "\n") {
            let lineEnd = newline > start && raw[raw.index(before: newline)] == "\r" ? raw.index(before: newline) : newline
            let line = String(raw[start..<lineEnd])
            file.position = raw.distance(from: raw.startIndex, to: raw.index(after: newline))
            legacyFiles[handle] = file
            return line
        }
        let line = String(raw[start...])
        file.position = raw.count
        legacyFiles[handle] = file
        return line
    }

    private func parseLegacyInputFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private func assignLegacyInput(_ field: String, to target: ReadTarget) throws {
        try assignReadValue(try inputValue(from: field, to: target), to: target)
    }

    private func assignReadValue(_ value: BASICValue, to target: ReadTarget) throws {
        switch target {
        case .variable(let variable):
            try runtime.assign(kind: .bare, variable: variable, declaredType: nil, value: value)
        case .reference(let reference):
            try runtime.assign(
                reference: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                value: value,
                accessClassName: currentClassContext
            )
        }
    }

    private func inputValue(from raw: String, to target: ReadTarget) throws -> BASICValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let current = try currentValue(for: target)
        switch current {
        case .string:
            return .string(BASICString(raw))
        case .boolean:
            if trimmed.uppercased() == "TRUE" {
                return .boolean(true)
            }
            if trimmed.uppercased() == "FALSE" {
                return .boolean(false)
            }
            if trimmed == "1" {
                return .boolean(true)
            }
            if trimmed == "0" {
                return .boolean(false)
            }
            throw BASICError.runtime("Type Mismatch")
        case .number:
            guard let number = Double(trimmed) else {
                throw BASICError.runtime("Expected numeric input for \(inputTargetName(target))")
            }
            return .number(number)
        case .empty:
            if inputTargetName(target).hasSuffix("$") {
                return .string(BASICString(raw))
            }
            if trimmed.uppercased() == "TRUE" {
                return .boolean(true)
            }
            if trimmed.uppercased() == "FALSE" {
                return .boolean(false)
            }
            guard let number = Double(trimmed) else {
                throw BASICError.runtime("Type Mismatch")
            }
            return .number(number)
        default:
            throw BASICError.runtime("Type Mismatch")
        }
    }

    private func currentValue(for target: ReadTarget) throws -> BASICValue {
        switch target {
        case .variable(let variable):
            return runtime.value(for: variable)
        case .reference(let reference):
            return try runtime.value(
                for: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                accessClassName: currentClassContext
            )
        }
    }

    private func inputTargetName(_ target: ReadTarget) -> String {
        switch target {
        case .variable(let variable):
            return variable.name
        case .reference(let reference):
            return ([reference.base.name] + reference.fields).joined(separator: ".")
        }
    }

    private func readableLegacyFile(handle: Int) throws -> BASICOpenFile {
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        guard file.access == .read || file.access == .both else {
            throw BASICError.runtime("Bad file mode")
        }
        return file
    }

    private func writableLegacyFile(handle: Int) throws -> BASICOpenFile {
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        guard file.access == .write || file.access == .both else {
            throw BASICError.runtime("Bad file mode")
        }
        return file
    }

    private func legacyFileHandle(_ expression: Expression) throws -> Int {
        let handle = try integer(expression)
        guard handle > 0 else {
            throw BASICError.runtime("Bad file number")
        }
        return handle
    }

    private func legacyFileLength(_ expression: Expression) throws -> Int {
        let handle = try legacyFileHandle(expression)
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        return file.content.byteCount
    }

    private func legacyFileLocation(handle: Int) throws -> Int {
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        if file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 {
            return file.position / recordLength
        }
        return file.position
    }

    private func legacyFileSeekPosition(handle: Int) throws -> Int {
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        if file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 {
            return file.position / recordLength + 1
        }
        return file.position + 1
    }

    private enum BinaryByteOrder {
        case little
        case big
    }

    private func integerEncodingArguments(
        name: String,
        arguments: [Expression]
    ) throws -> (value: Int64, width: Int, order: BinaryByteOrder) {
        guard (1...3).contains(arguments.count) else {
            throw BASICError.runtime("\(name) expects 1 to 3 arguments")
        }
        let number = try numeric(try evaluate(arguments[0]))
        guard number.isFinite, number.rounded() == number, let value = Int64(exactly: number) else {
            throw BASICError.runtime("Overflow")
        }
        let width = try binaryIntegerWidth(name: name, arguments: arguments, index: 1)
        switch width {
        case 16 where value < Int64(Int16.min) || value > Int64(Int16.max),
             32 where value < Int64(Int32.min) || value > Int64(Int32.max):
            throw BASICError.runtime("Overflow")
        default:
            break
        }
        return (value, width, try binaryByteOrder(name: name, arguments: arguments, index: 2))
    }

    private func integerDecodingArguments(
        name: String,
        arguments: [Expression]
    ) throws -> (data: Data, width: Int, order: BinaryByteOrder) {
        guard (1...3).contains(arguments.count) else {
            throw BASICError.runtime("\(name) expects 1 to 3 arguments")
        }
        let width = try binaryIntegerWidth(name: name, arguments: arguments, index: 1)
        return (
            try conversionData(name: name, expression: arguments[0], count: width / 8),
            width,
            try binaryByteOrder(name: name, arguments: arguments, index: 2)
        )
    }

    private func floatingEncodingArguments(
        name: String,
        arguments: [Expression]
    ) throws -> (value: Double, order: BinaryByteOrder) {
        guard (1...2).contains(arguments.count) else {
            throw BASICError.runtime("\(name) expects 1 or 2 arguments")
        }
        return (
            try numeric(try evaluate(arguments[0])),
            try binaryByteOrder(name: name, arguments: arguments, index: 1)
        )
    }

    private func floatingDecodingArguments(
        name: String,
        arguments: [Expression],
        byteCount: Int
    ) throws -> (data: Data, order: BinaryByteOrder) {
        guard (1...2).contains(arguments.count) else {
            throw BASICError.runtime("\(name) expects 1 or 2 arguments")
        }
        return (
            try conversionData(name: name, expression: arguments[0], count: byteCount),
            try binaryByteOrder(name: name, arguments: arguments, index: 1)
        )
    }

    private func binaryIntegerWidth(name: String, arguments: [Expression], index: Int) throws -> Int {
        guard arguments.indices.contains(index) else { return 16 }
        let width = try integer(arguments[index])
        guard width == 16 || width == 32 || width == 64 else {
            throw BASICError.runtime("\(name) width must be 16, 32, or 64")
        }
        return width
    }

    private func binaryByteOrder(name: String, arguments: [Expression], index: Int) throws -> BinaryByteOrder {
        guard arguments.indices.contains(index) else { return nativeBinaryByteOrder }
        guard let value = try evaluate(arguments[index]).string else {
            throw BASICError.runtime("\(name) byte order must be NATIVE, LITTLE, or BIG")
        }
        switch value.description.uppercased() {
        case "NATIVE": return nativeBinaryByteOrder
        case "LITTLE": return .little
        case "BIG": return .big
        default:
            throw BASICError.runtime("\(name) byte order must be NATIVE, LITTLE, or BIG")
        }
    }

    private var nativeBinaryByteOrder: BinaryByteOrder {
        var marker: UInt16 = 1
        return withUnsafeBytes(of: &marker) { bytes in
            bytes[0] == 1 ? .little : .big
        }
    }

    private func signedIntegerData(_ value: Int64, width: Int, order: BinaryByteOrder) -> Data {
        binaryData(UInt64(bitPattern: value), byteCount: width / 8, order: order)
    }

    private func binaryData(_ value: UInt64, byteCount: Int, order: BinaryByteOrder) -> Data {
        let littleEndianBytes = (0..<byteCount).map {
            UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
        }
        return Data(order == .little ? littleEndianBytes : littleEndianBytes.reversed())
    }

    private func conversionData(name: String, expression: Expression, count: Int) throws -> Data {
        guard let value = try evaluate(expression).string else {
            throw BASICError.runtime("\(name) expects a string")
        }
        guard value.byteCount >= count else {
            throw BASICError.runtime("\(name) requires at least \(count) bytes")
        }
        return Data(value.rawData.prefix(count))
    }

    private func binaryUInt(_ data: Data, order: BinaryByteOrder) -> UInt64 {
        let bytes = order == .little ? Array(data) : Array(data.reversed())
        return bytes.enumerated().reduce(into: UInt64(0)) { value, byte in
            value |= UInt64(byte.element) << UInt64(byte.offset * 8)
        }
    }

    private func legacyFileHost() throws -> BASICFileHost {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("File I/O is not supported by this host")
        }
        return fileHost
    }

    private func legacyOpenPath(_ file: BASICOpenFile) throws -> String {
        guard let path = file.path else { throw BASICError.runtime("File is not open") }
        return path
    }

    private func runSystemCommand(_ expression: Expression) throws -> String {
        guard let systemHost = host as? BASICSystemHost else {
            throw BASICError.runtime("SYSTEM is not supported by this host")
        }
        let result = try systemHost.runSystemCommandResult(try string(expression), environment: runtime.environmentPatch)
        runtime.lastSystemStatus = result.exitCode
        return result.output
    }

    private func runStructuredProcess(
        command: Expression,
        arguments: [Expression],
        stdout: ReadTarget?,
        stderr: ReadTarget?,
        tty: Bool,
        timeout: Expression?
    ) throws -> BASICProcessResult {
        guard let processHost = host as? BASICProcessHost else {
            throw BASICError.runtime("EXEC is not supported by this host")
        }
        if tty && (stdout != nil || stderr != nil) {
            throw BASICError.runtime("EXEC TTY TRUE cannot capture stdout or stderr")
        }
        let fileHost = host as? BASICFileHost
        let consoleHost = host as? BASICConsoleHost
        let commandText = try string(command)
        let executable: String
        let processArguments: [String]
        if arguments.isEmpty {
            executable = "/bin/sh"
            processArguments = ["-lc", commandText]
        } else {
            executable = commandText
            processArguments = try arguments.map(string)
        }
        let request = BASICProcessRequest(
            executable: executable,
            arguments: processArguments,
            workingDirectory: try fileHost?.currentDirectoryPath(),
            columns: consoleHost?.screenColumns(),
            rows: consoleHost?.screenRows(),
            environment: runtime.environmentPatch,
            timeoutSeconds: try timeout.map { try positiveTimeoutSeconds($0) },
            ioMode: tty ? .inheritedTerminal : .captured
        )
        let result = try processHost.runProcess(request)
        runtime.lastSystemStatus = result.exitCode
        return result
    }

    private func positiveTimeoutSeconds(_ expression: Expression) throws -> Double {
        let seconds = try numeric(try evaluate(expression))
        guard seconds > 0 else {
            throw BASICError.runtime("EXEC TIMEOUT must be greater than zero")
        }
        return seconds
    }

    private func runStructuredPipeline(input: Expression?, stages: [BASICPipelineStage]) throws -> BASICProcessResult {
        guard input != nil || stages.count > 1 else {
            throw BASICError.runtime("PIPE expects at least two commands")
        }
        guard let processHost = host as? BASICProcessHost else {
            throw BASICError.runtime("PIPE is not supported by this host")
        }
        let fileHost = host as? BASICFileHost
        let consoleHost = host as? BASICConsoleHost
        let workingDirectory = try fileHost?.currentDirectoryPath()
        let columns = consoleHost?.screenColumns()
        let rows = consoleHost?.screenRows()
        var requests = try stages.map { stage in
            BASICProcessRequest(
                executable: try string(stage.command),
                arguments: try stage.arguments.map(string),
                workingDirectory: workingDirectory,
                columns: columns,
                rows: rows,
                environment: runtime.environmentPatch
            )
        }
        if let input {
            guard !requests.isEmpty else {
                throw BASICError.runtime("PIPE expects a command after TO")
            }
            requests[0] = requests[0].withStandardInput(try string(input))
        }
        let result = try processHost.runPipeline(requests)
        runtime.lastSystemStatus = result.exitCode
        return result
    }

    private func printExecutablePath(command: String) throws {
        guard let resolver = host as? BASICExecutableResolverHost else {
            throw BASICError.runtime("WHICH is not supported by this host")
        }
        guard let path = try resolver.resolveExecutable(command, environment: runtime.environmentPatch) else {
            runtime.lastSystemStatus = 1
            outputCoordinator.printLine("\(command) not found")
            return
        }
        runtime.lastSystemStatus = 0
        outputCoordinator.printLine(path)
    }

    private func printCommandType(command: String) throws {
        let upper = command.uppercased()
        if Self.basicBuiltinCommands.contains(upper) {
            runtime.lastSystemStatus = 0
            outputCoordinator.printLine("\(command) is a BASICShell builtin")
            return
        }
        guard let resolver = host as? BASICExecutableResolverHost else {
            throw BASICError.runtime("TYPE is not supported by this host")
        }
        guard let path = try resolver.resolveExecutable(command, environment: runtime.environmentPatch) else {
            runtime.lastSystemStatus = 1
            outputCoordinator.printLine("\(command) not found")
            return
        }
        runtime.lastSystemStatus = 0
        outputCoordinator.printLine("\(command) is \(path)")
    }

    private func environmentName(forExport name: String) -> String {
        guard let last = name.last, "$%#".contains(last) else { return name }
        return String(name.dropLast())
    }

    private static let basicBuiltinCommands: Set<String> = [
        "CD", "DIRS", "EDIT", "EXPORT", "FILES", "HELP", "LIST", "LOAD", "NEW", "POPD",
        "PROMPT", "PUSHD", "PWD", "QUIT", "RUN", "SAVE", "SETENV", "STATUS", "SYSTEM",
        "TASK", "TASKS", "TYPE", "UNSETENV", "WHICH"
    ]

    private func advanceNextLoop(variable: VariableName?) throws -> Flow {
        guard let frame = forStack.last else {
            throw BASICError.runtime("NEXT without FOR")
        }
        if let variable, variable.normalized != frame.variable.normalized {
            throw BASICError.runtime("NEXT \(variable.name) without matching FOR")
        }

        let currentValue = try numeric(runtime.value(for: frame.variable))
        let nextValue = currentValue + frame.stepValue
        try runtime.assign(kind: .bare, variable: frame.variable, declaredType: nil, value: .number(nextValue))

        let continues = frame.stepValue > 0 ? nextValue <= frame.endValue : nextValue >= frame.endValue
        if continues {
            return .jump(frame.loopStartIndex + 1)
        }

        _ = forStack.popLast()
        return .next
    }

    private func renderPrint(_ parts: [PrintPart], startColumn: Int = 0) throws -> PrintOutput {
        var output = ""
        var column = startColumn
        let tabWidth = 14

        for part in parts {
            switch part {
            case .expression(let expression):
                if let spacing = try printSpacing(for: expression, column: column) {
                    output += spacing
                    column += spacing.count
                    continue
                }
                let text = try evaluate(expression).description
                output += text
                column += text.count
            case .separator(.comma):
                let spaces = tabWidth - (column % tabWidth)
                output += String(repeating: " ", count: spaces)
                column += spaces
            case .separator(.semicolon):
                break
            }
        }

        let terminator = parts.last?.suppressesNewline == true ? "" : "\n"
        return PrintOutput(text: output, terminator: terminator, endColumn: column)
    }

    private func renderUsing(format: Expression, values: [Expression], trailingSeparator: PrintSeparator?, startColumn: Int = 0) throws -> PrintOutput {
        let format = try string(format)
        let rendered = try formatUsing(format: format, values: try values.map(evaluate))
        return PrintOutput(text: rendered, terminator: trailingSeparator == nil ? "\n" : "", endColumn: startColumn + rendered.count)
    }

    private func updateOutputColumn(_ output: PrintOutput) {
        if output.terminator.contains("\n") {
            outputColumn = 0
        } else {
            outputColumn = output.endColumn
        }
    }

    private func updateOutputColumn(text: String, terminator: String) {
        let combined = text + terminator
        if let lastNewline = combined.lastIndex(of: "\n") {
            outputColumn = combined.distance(from: combined.index(after: lastNewline), to: combined.endIndex)
        } else {
            outputColumn += combined.count
        }
    }

    private func formatUsing(format: String, values: [BASICValue]) throws -> String {
        guard !values.isEmpty else { return format }

        var rendered = ""
        var valueIndex = 0
        while valueIndex < values.count {
            let startIndex = valueIndex
            let pass = try formatUsingPass(format: format, values: values, valueIndex: &valueIndex)
            if pass.fieldCount == 0 {
                if rendered.isEmpty {
                    rendered += format
                }
                break
            }
            rendered += pass.text
            if valueIndex == startIndex {
                break
            }
        }
        return rendered
    }

    private func formatUsingPass(format: String, values: [BASICValue], valueIndex: inout Int) throws -> (text: String, fieldCount: Int) {
        var output = ""
        var fieldCount = 0
        var index = format.startIndex

        while index < format.endIndex {
            let character = format[index]
            if character == "!" {
                guard valueIndex < values.count else { break }
                let value = values[valueIndex]
                valueIndex += 1
                fieldCount += 1
                output += String(value.description.prefix(1))
                index = format.index(after: index)
                continue
            }
            if character == "&" {
                guard valueIndex < values.count else { break }
                let value = values[valueIndex]
                valueIndex += 1
                fieldCount += 1
                output += value.description
                index = format.index(after: index)
                continue
            }
            if isNumericUsingCharacter(character) {
                let start = index
                while index < format.endIndex, isNumericUsingCharacter(format[index]) {
                    index = format.index(after: index)
                }
                let field = String(format[start..<index])
                if field.contains("#") {
                    guard valueIndex < values.count else { break }
                    let value = values[valueIndex]
                    valueIndex += 1
                    fieldCount += 1
                    output += try formatNumericUsingField(field, value: value)
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

    private func isNumericUsingCharacter(_ character: Character) -> Bool {
        "#.,+$-*".contains(character)
    }

    private func formatNumericUsingField(_ field: String, value: BASICValue) throws -> String {
        let number = try numeric(value)
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

    private func groupedDigits(_ digits: String) -> String {
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return String(result.reversed())
    }

    private func printSpacing(for expression: Expression, column: Int) throws -> String? {
        let name: VariableName
        let arguments: [Expression]
        switch expression {
        case .callOrArray(let callName, let callArguments), .functionCall(let callName, let callArguments):
            name = callName
            arguments = callArguments
        default:
            return nil
        }

        switch name.normalized {
        case "SPC":
            let count = max(0, try singleIntegerArgument(name: name.name, arguments: arguments))
            return String(repeating: " ", count: count)
        case "TAB":
            let targetColumn = max(0, try singleIntegerArgument(name: name.name, arguments: arguments) - 1)
            return String(repeating: " ", count: max(0, targetColumn - column))
        default:
            return nil
        }
    }

    private func execute(_ action: ConditionalAction, pc: Int, parsed: [ParsedLine]) throws -> Flow {
        switch action {
        case .branch(let target):
            return target.flow
        case .statement(let statement):
            return try execute(statement, pc: pc, parsed: parsed)
        }
    }

    private func selectCaseFlow(_ expression: Expression, pc: Int, parsed: [ParsedLine]) throws -> Flow {
        let testValue = try evaluate(expression)
        var depth = 0
        var elseIndex: Int?
        var index = pc + 1

        while index < parsed.count {
            switch parsed[index].statement {
            case .selectCase:
                depth += 1
            case .endSelect:
                if depth == 0 {
                    if let elseIndex {
                        return .jump(elseIndex + 1)
                    }
                    return .jump(index + 1)
                }
                depth -= 1
            case .caseClause(let clauses) where depth == 0:
                for clause in clauses {
                    if try caseClause(clause, matches: testValue) {
                        return .jump(index + 1)
                    }
                }
            case .caseElse where depth == 0:
                elseIndex = index
            default:
                break
            }
            index += 1
        }

        throw BASICError.runtime("SELECT without END SELECT")
    }

    private func matchingEndSelect(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .selectCase:
                depth += 1
            case .endSelect:
                if depth == 0 {
                    return index
                }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return nil
    }

    private func matchingNext(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            for event in loopEvents(in: parsed[index].statement) {
                switch event {
                case .forLoop:
                    depth += 1
                case .nextLoop:
                    if depth == 0 {
                        return index
                    }
                    depth -= 1
                }
            }
            index += 1
        }
        return nil
    }

    private func loopEvents(in statement: Statement) -> [LoopEvent] {
        switch statement {
        case .forLoop:
            return [.forLoop]
        case .nextLoop:
            return [.nextLoop]
        case .labeled(_, let statement):
            return loopEvents(in: statement)
        case .sequence(let statements):
            return statements.flatMap(loopEvents)
        default:
            return []
        }
    }

    private func caseClause(_ clause: CaseClause, matches testValue: BASICValue) throws -> Bool {
        switch clause {
        case .equals(let expression):
            return try compare(testValue, .equal, evaluate(expression))
        case .range(let lower, let upper):
            return try compare(testValue, .greaterEqual, evaluate(lower)) && compare(testValue, .lessEqual, evaluate(upper))
        case .comparison(let operation, let expression):
            return try compare(testValue, operation, evaluate(expression))
        }
    }

    private func compare(_ left: BASICValue, _ operation: BinaryOperation, _ right: BASICValue) throws -> Bool {
        switch operation {
        case .equal:
            return left == right
        case .notEqual:
            return left != right
        case .less, .lessEqual, .greater, .greaterEqual:
            if let leftNumber = left.number, let rightNumber = right.number {
                switch operation {
                case .less: return leftNumber < rightNumber
                case .lessEqual: return leftNumber <= rightNumber
                case .greater: return leftNumber > rightNumber
                case .greaterEqual: return leftNumber >= rightNumber
                default: break
                }
            }
            if let leftString = left.string?.description, let rightString = right.string?.description {
                switch operation {
                case .less: return leftString < rightString
                case .lessEqual: return leftString <= rightString
                case .greater: return leftString > rightString
                case .greaterEqual: return leftString >= rightString
                default: break
                }
            }
            throw BASICError.runtime("Cannot compare these values")
        case .add, .subtract, .multiply, .divide, .and, .or:
            throw BASICError.runtime("Invalid CASE comparison")
        }
    }

    func evaluate(_ expression: Expression) throws -> BASICValue {
        switch expression {
        case .number(let value):
            return .number(value)
        case .string(let value):
            if runtime.stringSubstitutionEnabled {
                return .string(BASICString(try interpolatedString(value)))
            }
            return .string(BASICString(value))
        case .interpolatedString(let value):
            return .string(BASICString(try interpolatedString(value)))
        case .boolean(let value):
            return .boolean(value)
        case .null:
            return .null
        case .closure(let parameters, let returnType, let captures, let body):
            let environment = BASICCapturedEnvironment()
            let parameterNames = Set(parameters.map { $0.variable.normalized })
            let captureSpecs = captures.isEmpty
                ? capturedVariableNames(in: body)
                    .filter { !parameterNames.contains($0.normalized) }
                    .map { ClosureCaptureSpec(variable: $0, access: .readOnly) }
                : captures.filter { !parameterNames.contains($0.variable.normalized) }
            for capture in captureSpecs {
                _ = environment.capture(
                    name: capture.variable.name,
                    value: runtime.value(for: capture.variable),
                    access: capture.access
                )
            }
            return .closure(BASICCapturedClosure(
                name: "<closure>",
                parameters: parameters,
                returnType: returnType,
                bodyExpression: body,
                environment: environment
            ))
        case .variable(let name):
            if name.normalized == "ERR" {
                return .number(Double(runtime.lastErrorNumber))
            }
            if name.normalized == "ERL" {
                return .number(Double(runtime.lastErrorLine))
            }
            if name.normalized == "CURRENT_TASK$" {
                return .string(BASICString(currentTaskName()))
            }
            if name.normalized == "CURRENT_FUNCTION$" {
                return .string(BASICString(currentFunctionName()))
            }
            if name.normalized == "CURRENT_THREAD$" {
                return .string(BASICString(currentThreadName()))
            }
            if name.normalized == "STATUS" || name.normalized == "ERRORLEVEL" {
                return .number(Double(runtime.lastSystemStatus))
            }
            if let constant = builtInConstant(named: name.normalized) {
                return constant
            }
            return runtime.value(for: name)
        case .variableReference(let reference):
            return try runtime.value(
                for: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                accessClassName: currentClassContext
            )
        case .callOrArray(let name, let arguments):
            if name.normalized == "FILE" {
                return try constructFile(arguments: arguments)
            }
            if name.normalized == "HTTPCLIENT" {
                return try constructHTTPClient(arguments: arguments)
            }
            if name.normalized == "VECTORTERMINAL" || name.normalized == "VTG" {
                return try constructVectorTerminal(arguments: arguments)
            }
            if name.normalized == "SECONDSTIMER" {
                return try constructSecondsTimer(arguments: arguments)
            }
            // The same table the `.newObject` case above uses. The pseudo-class
            // names are listed in two places — here for `RichTable()` and there
            // for `NEW RichTable()` — and the four that came before this were
            // spelled out separately in both, which is a drift waiting to
            // happen. One dictionary, consulted twice.
            if let richName = Self.richClassNames[name.normalized] {
                guard arguments.isEmpty else {
                    throw BASICError.runtime("\(richName) takes no arguments")
                }
                return runtime.richObject(typeName: richName)
            }
            if let tuiName = Self.tuiClassNames[name.normalized] {
                return try runtime.tuiObject(
                    typeName: tuiName, arguments: try arguments.map(evaluate)
                )
            }
            if functionDefinitions[name.normalized] != nil {
                return try callFunction(name: name, arguments: arguments)
            }
            if Self.intrinsicFunctionNames.contains(name.normalized) {
                return try callIntrinsicFunction(name: name, arguments: arguments)
            }
            if case .closure(let closure) = runtime.value(for: name) {
                return try closure.call(arguments: arguments.map(evaluate), interpreter: self)
            }
            return try runtime.value(for: VariableReference(base: name, indexes: arguments), indexes: try arguments.map(evaluate), accessClassName: currentClassContext)
        case .methodCall(let receiver, let method, let arguments):
            return try callMethod(receiver: receiver, method: method, arguments: arguments)
        case .newObject(let className, let arguments):
            if className.uppercased() == "FILE" {
                return try constructFile(arguments: arguments)
            }
            if className.uppercased() == "HTTPCLIENT" {
                return try constructHTTPClient(arguments: arguments)
            }
            if className.uppercased() == "VECTORTERMINAL" || className.uppercased() == "VTG" {
                return try constructVectorTerminal(arguments: arguments)
            }
            if className.uppercased() == "SECONDSTIMER" {
                return try constructSecondsTimer(arguments: arguments)
            }
            // The Rich* family. They take no constructor arguments — everything
            // is set by method afterwards — so one line handles all of them.
            if let richName = Self.richClassNames[className.uppercased()] {
                guard arguments.isEmpty else {
                    throw BASICError.runtime("\(richName) takes no arguments")
                }
                return runtime.richObject(typeName: richName)
            }
            if let tuiName = Self.tuiClassNames[className.uppercased()] {
                return try runtime.tuiObject(
                    typeName: tuiName, arguments: try arguments.map(evaluate)
                )
            }
            guard let classDefinition = classDefinitions[className.uppercased()] else {
                throw BASICError.runtime("Unknown CLASS \(className)")
            }
            let object = runtime.defaultValue(for: .classType(className))
            guard !arguments.isEmpty || lookupMethod(named: "NEW", in: classDefinition) != nil else {
                return object
            }
            guard let constructor = lookupMethod(named: "NEW", in: classDefinition) else {
                throw BASICError.runtime("CLASS \(classDefinition.displayName) has no constructor")
            }
            let result = try callFunction(
                definition: constructor,
                receiver: object,
                receiverClassName: classDefinition.displayName,
                arguments: arguments,
                allowVoid: true
            )
            return result.receiver ?? object
        case .unaryMinus(let expression):
            guard let value = try evaluate(expression).number else {
                throw BASICError.runtime("Unary minus requires a number")
            }
            return .number(-value)
        case .binary(let left, let operation, let right):
            return try evaluateBinary(left, operation, right)
        case .await(let expression):
            let value = try evaluate(expression)
            return try awaitTaskValueIfKnown(value) ?? value
        case .functionCall(let name, let arguments):
            return try callFunction(name: name, arguments: arguments)
        case .pointFunction(let point):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            guard graphicsHost.isGraphicsAvailable else {
                throw BASICError.runtime(graphicsHost.graphicsUnavailableMessage)
            }
            let resolved = try resolve(point: point)
            return .number(Double(graphicsHost.getPixel(x: resolved.x, y: resolved.y)))
        case .chrFunction(let expression):
            return .string(try BASICString.character(code: integer(expression)))
        case .lenFunction(let expression):
            let value = try evaluate(expression)
            if case .array(let array) = value {
                return .number(Double(array.values.count))
            }
            guard let string = value.string else {
                throw BASICError.runtime("LEN requires a string or array")
            }
            return .number(Double(string.characterCount))
        case .environmentFunction(let expression):
            return .string(BASICString(runtime.environmentValue(name: try string(expression))))
        case .pwdFunction:
            guard let fileHost = host as? BASICFileHost else {
                throw BASICError.runtime("PWD$ is not supported by this host")
            }
            return .string(BASICString(try fileHost.currentDirectoryPath()))
        case .systemFunction(let expression):
            return .string(BASICString(try runSystemCommand(expression)))
        }
    }

    private func evaluateStandaloneExpression(_ expression: Expression) throws -> BASICValue {
        switch expression {
        case .callOrArray(let name, let arguments):
            if functionDefinitions[name.normalized] != nil {
                return try callFunction(name: name, arguments: arguments, allowVoid: true)
            }
            return try evaluate(expression)
        case .functionCall(let name, let arguments):
            return try callFunction(name: name, arguments: arguments, allowVoid: true)
        case .methodCall(let receiver, let method, let arguments):
            return try callMethod(receiver: receiver, method: method, arguments: arguments, allowVoid: true)
        default:
            return try evaluate(expression)
        }
    }

    private func awaitTaskValueIfKnown(_ value: BASICValue) throws -> BASICValue? {
        guard let taskScheduler else { return nil }
        let taskID: Int
        switch value {
        case .task(let handle):
            taskID = handle.id
        case .number(let number) where number > 0 && Double(Int(number)) == number:
            taskID = Int(number)
        default:
            return nil
        }
        _ = taskScheduler.markObserved(id: taskID)

        var suspendedTask: BASICTask?
        var didSuspend = false
        let breakWakeToken = executionControl?.registerWaitWakeHandler { [weak taskScheduler] in
            taskScheduler?.notifyWaiters()
        }
        defer {
            if let breakWakeToken {
                executionControl?.unregisterWaitWakeHandler(breakWakeToken)
            }
            if didSuspend, let suspendedTask {
                taskScheduler.markResumedRunning(suspendedTask)
            }
        }

        while true {
            let generation = taskScheduler.currentStateGeneration
            switch taskScheduler.awaitState(for: taskID) {
            case .missing:
                return nil
            case .completed(let result):
                return result
            case .cancelled:
                throw BASICError.runtime("Awaited task was cancelled")
            case .failed(let message):
                throw BASICError.runtime(message.map { "Awaited task failed: \($0)" } ?? "Awaited task failed")
            case .waiting:
                if let currentTask = task ?? taskScheduler.currentTask,
                   currentTask.isCancellationRequested {
                    cancelOwnedAwaitedTask(taskID, parent: currentTask, scheduler: taskScheduler)
                    throw BASICError.breakRequested(currentTask.snapshot().location?.lineNumber)
                }
                if !didSuspend {
                    guard let currentTask = task ?? taskScheduler.currentTask else {
                        throw BASICError.runtime("AWAIT requires a running BASIC task")
                    }
                    suspendedTask = currentTask
                    let frames = currentSuspendedFrames(
                        fallbackKind: "Expression",
                        fallbackName: "AWAIT",
                        fallbackLocation: currentTask.snapshot().location
                    )
                    _ = taskScheduler.suspendForAwait(
                        id: currentTask.id,
                        awaitingTaskID: taskID,
                        frames: frames,
                        globalVariables: runtime.globalSnapshots()
                    )
                    didSuspend = true
                }
                try throwPendingAsyncDebuggerPause()
                try checkExecutionBreak()
                try eventLoop?.throwPendingError()
                taskScheduler.waitForStateChange(after: generation)
            }
        }
    }

    private func joinTask(_ value: BASICValue) throws {
        guard let taskScheduler else {
            throw BASICError.runtime("JOIN requires a running BASIC session")
        }
        let taskID = try taskHandleID(from: value, operation: "JOIN")
        _ = taskScheduler.markObserved(id: taskID)

        var suspendedTask: BASICTask?
        var didSuspend = false
        let breakWakeToken = executionControl?.registerWaitWakeHandler { [weak taskScheduler] in
            taskScheduler?.notifyWaiters()
        }
        defer {
            if let breakWakeToken {
                executionControl?.unregisterWaitWakeHandler(breakWakeToken)
            }
            if didSuspend, let suspendedTask {
                taskScheduler.markResumedRunning(suspendedTask)
            }
        }

        while true {
            let generation = taskScheduler.currentStateGeneration
            switch taskScheduler.joinState(for: taskID) {
            case .missing:
                throw BASICError.runtime("JOIN requires a known task handle")
            case .completed:
                return
            case .cancelled:
                throw BASICError.runtime("Joined task was cancelled")
            case .failed(let message):
                throw BASICError.runtime(message.map { "Joined task failed: \($0)" } ?? "Joined task failed")
            case .waiting:
                if let currentTask = task ?? taskScheduler.currentTask,
                   currentTask.isCancellationRequested {
                    cancelOwnedAwaitedTask(taskID, parent: currentTask, scheduler: taskScheduler)
                    throw BASICError.breakRequested(currentTask.snapshot().location?.lineNumber)
                }
                if !didSuspend {
                    guard let currentTask = task ?? taskScheduler.currentTask else {
                        throw BASICError.runtime("JOIN requires a running BASIC task")
                    }
                    suspendedTask = currentTask
                    let frames = currentSuspendedFrames(
                        fallbackKind: "Statement",
                        fallbackName: "JOIN",
                        fallbackLocation: currentTask.snapshot().location
                    )
                    _ = taskScheduler.suspendForAwait(
                        id: currentTask.id,
                        awaitingTaskID: taskID,
                        frames: frames,
                        globalVariables: runtime.globalSnapshots()
                    )
                    didSuspend = true
                }
                try throwPendingAsyncDebuggerPause()
                try checkExecutionBreak()
                try eventLoop?.throwPendingError()
                taskScheduler.waitForStateChange(after: generation)
            }
        }
    }

    private func cancelOwnedAwaitedTask(
        _ awaitedTaskID: Int,
        parent: BASICTask,
        scheduler: BASICTaskScheduler
    ) {
        guard scheduler.handle(for: awaitedTaskID)?.parentID == parent.id else { return }
        _ = scheduler.requestCancellation(id: awaitedTaskID)
    }

    private func taskHandleID(from value: BASICValue, operation: String) throws -> Int {
        if case .task(let handle) = value {
            return handle.id
        }
        guard let number = value.number else {
            throw BASICError.runtime("\(operation) requires a task handle")
        }
        let taskID = Int(number)
        guard taskID > 0, Double(taskID) == number else {
            throw BASICError.runtime("\(operation) requires a task handle")
        }
        return taskID
    }

    private func capturedVariableNames(in expression: Expression) -> [VariableName] {
        var ordered: [VariableName] = []
        var seen: Set<String> = []

        func append(_ variable: VariableName) {
            guard !seen.contains(variable.normalized),
                  builtInConstant(named: variable.normalized) == nil else {
                return
            }
            seen.insert(variable.normalized)
            ordered.append(variable)
        }

        func visit(_ expression: Expression) {
            switch expression {
            case .number, .string, .interpolatedString, .boolean, .null:
                return
            case .closure:
                return
            case .variable(let name):
                append(name)
            case .variableReference(let reference):
                append(reference.base)
                reference.indexes.forEach(visit)
                reference.fieldIndexes.flatMap { $0 }.forEach(visit)
            case .callOrArray(let name, let arguments):
                if functionDefinitions[name.normalized] == nil,
                   !Self.intrinsicFunctionNames.contains(name.normalized),
                   name.normalized != "FILE" {
                    append(name)
                }
                arguments.forEach(visit)
            case .methodCall(let receiver, _, let arguments):
                append(receiver.base)
                receiver.indexes.forEach(visit)
                receiver.fieldIndexes.flatMap { $0 }.forEach(visit)
                arguments.forEach(visit)
            case .newObject(_, let arguments):
                arguments.forEach(visit)
            case .unaryMinus(let expression), .await(let expression), .chrFunction(let expression),
                 .lenFunction(let expression), .environmentFunction(let expression), .systemFunction(let expression):
                visit(expression)
            case .pwdFunction:
                return
            case .binary(let left, _, let right):
                visit(left)
                visit(right)
            case .functionCall(_, let arguments):
                arguments.forEach(visit)
            case .pointFunction(let point):
                visit(point.x)
                visit(point.y)
            }
        }

        visit(expression)
        return ordered
    }

    private func capturedVariableNames(in body: [ClosureBodyLine]) -> [VariableName] {
        var ordered: [VariableName] = []
        var seen: Set<String> = []
        var localNames: Set<String> = []

        func append(_ variable: VariableName) {
            guard !seen.contains(variable.normalized),
                  !localNames.contains(variable.normalized),
                  builtInConstant(named: variable.normalized) == nil else {
                return
            }
            seen.insert(variable.normalized)
            ordered.append(variable)
        }

        func visit(_ expression: Expression) {
            for variable in capturedVariableNames(in: expression) {
                append(variable)
            }
        }

        func visitPrintParts(_ parts: [PrintPart]) {
            for part in parts {
                if case .expression(let expression) = part {
                    visit(expression)
                }
            }
        }

        func visit(_ point: GraphicsPoint) {
            visit(point.x)
            visit(point.y)
        }

        func visit(_ target: ReadTarget, capturesBase: Bool) {
            switch target {
            case .variable(let variable):
                if capturesBase {
                    append(variable)
                }
            case .reference(let reference):
                if capturesBase {
                    append(reference.base)
                }
                reference.indexes.forEach(visit)
                reference.fieldIndexes.flatMap { $0 }.forEach(visit)
            }
        }

        func visit(_ action: ConditionalAction) {
            if case .statement(let statement) = action {
                visit(statement)
            }
        }

        func visit(_ statement: Statement) {
            switch statement {
            case .assignment(let kind, let variable, _, let expression):
                if kind == .local {
                    localNames.insert(variable.normalized)
                } else if kind == .bare, expression == nil {
                    localNames.insert(variable.normalized)
                }
                expression.map(visit)
            case .closureAssignment(let kind, let variable, _, _, _, _, let nestedBody):
                if kind == .local {
                    localNames.insert(variable.normalized)
                }
                for variable in capturedVariableNames(in: nestedBody) {
                    append(variable)
                }
            case .referenceAssignment(let reference, let expression):
                append(reference.base)
                reference.indexes.forEach(visit)
                reference.fieldIndexes.flatMap { $0 }.forEach(visit)
                expression.map(visit)
            case .print(let parts), .log(_, let parts), .printFile(_, let parts), .putFile(_, let parts):
                visitPrintParts(parts)
            case .printUsing(let format, let values, _), .printFileUsing(_, let format, let values, _):
                visit(format)
                values.forEach(visit)
            case .module(let expression), .screen(let expression), .load(let expression),
                 .system(let expression), .error(let expression):
                visit(expression)
            case .color(let expressions):
                expressions.forEach(visit)
            case .randomize(let expression), .save(let expression), .cd(let expression), .closeFile(let expression):
                expression.map(visit)
            case .locate(let row, let column):
                visit(row)
                visit(column)
            case .pset(let point, let color), .preset(let point, let color):
                visit(point)
                color.map(visit)
            case .line(let start, let end, let color):
                visit(start)
                visit(end)
                color.map(visit)
            case .circle(let center, let radius, let color, let aspect):
                visit(center)
                visit(radius)
                color.map(visit)
                aspect.map(visit)
            case .paint(let point, let color, let borderColor):
                visit(point)
                visit(color)
                borderColor.map(visit)
            case .draw(let expression):
                visit(expression)
            case .dim(_, let variable, let dimensions, _):
                localNames.insert(variable.normalized)
                dimensions.compactMap { $0 }.forEach(visit)
            case .input(let prompt, let target):
                prompt.map(visit)
                visit(target, capturesBase: false)
            case .lineInput(let prompt, let target, let exitTarget, let fieldLength, let maxLength, let defaultValue):
                prompt.map(visit)
                fieldLength.map(visit)
                maxLength.map(visit)
                defaultValue.map(visit)
                visit(target, capturesBase: false)
                exitTarget.map { visit($0, capturesBase: false) }
            case .openFile(let path, _, let number, let recordLength):
                visit(path)
                visit(number)
                recordLength.map(visit)
            case .getFile(let number, let targets), .inputFile(let number, let targets):
                visit(number)
                targets.forEach { visit($0, capturesBase: false) }
            case .getRecordFile(let number, let record):
                visit(number)
                record.map(visit)
            case .writeFile(let number, let values):
                visit(number)
                values.forEach(visit)
            case .fieldFile(let number, let fields):
                visit(number)
                fields.forEach {
                    visit($0.width)
                    append($0.variable)
                }
            case .setFieldString(let target, let value, _):
                visit(target, capturesBase: false)
                visit(value)
            case .seekFile(let number, let position):
                visit(number)
                visit(position)
            case .resetFile(let number):
                visit(number)
            case .lineInputFile(let number, let target):
                visit(number)
                visit(target, capturesBase: false)
            case .expression(let expression), .returnValue(let expression), .selectCase(let expression),
                 .blockIf(let expression):
                visit(expression)
            case .ifThen(let condition, let thenAction, let elseAction):
                visit(condition)
                visit(thenAction)
                elseAction.map(visit)
            case .forLoop(let variable, let start, let end, let step):
                localNames.insert(variable.normalized)
                visit(start)
                visit(end)
                step.map(visit)
            case .caseClause(let clauses):
                for clause in clauses {
                    switch clause {
                    case .equals(let expression), .comparison(_, let expression):
                        visit(expression)
                    case .range(let lower, let upper):
                        visit(lower)
                        visit(upper)
                    }
                }
            case .labeled(_, let nested):
                visit(nested)
            case .sequence(let statements):
                statements.forEach(visit)
            case .read(let targets):
                targets.forEach { visit($0, capturesBase: false) }
            case .computedGoto(_, let expression), .computedGosub(_, let expression), .elseIf(let expression):
                visit(expression)
            case .defFunction(_, _, _, let body):
                visit(body)
            default:
                break
            }
        }

        for line in body {
            visit(line.statement)
        }

        return ordered
    }

    private func evaluatedFieldIndexes(for reference: VariableReference) throws -> [[BASICValue]] {
        try reference.fieldIndexes.map { indexes in
            try indexes.map(evaluate)
        }
    }

    private func builtInConstant(named normalized: String) -> BASICValue? {
        switch normalized {
        case "READ", "WRITE", "BOTH", "RAW", "TEXT", "JSON", "NATIVE", "LITTLE", "BIG":
            return .string(BASICString(normalized))
        default:
            return nil
        }
    }

    private func constructFile(arguments: [Expression]) throws -> BASICValue {
        let file = runtime.fileObject()
        guard arguments.isEmpty || arguments.count == 4 else {
            throw BASICError.runtime("File expects 0 or 4 arguments")
        }
        if arguments.count == 4 {
            guard case .systemObject(let typeName, let id) = file else { return file }
            _ = try runtime.callSystemObjectMethod(
                typeName: typeName,
                id: id,
                method: "open",
                arguments: try arguments.map(evaluate),
                fileHost: host as? BASICFileHost,
                jsonDecoder: { [runtime] source in try runtime.valueFromJSONString(source, permissive: true) },
                jsonEncoder: { [runtime] value, pretty in try runtime.jsonString(for: value, pretty: pretty) }
            )
        }
        return file
    }

    private func constructHTTPClient(arguments: [Expression]) throws -> BASICValue {
        guard arguments.count == 1 else {
            throw BASICError.runtime("HttpClient expects 1 argument")
        }
        let baseURL = try string(arguments[0])
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw BASICError.runtime("HttpClient requires an http or https base URL")
        }
        return runtime.httpClientObject(baseURL: baseURL)
    }

    private func callHTTPClientGet(id: Int, arguments: [Expression]) throws -> BASICValue {
        guard arguments.count == 1 || arguments.count == 2 else {
            throw BASICError.runtime("HttpClient.get expects a path and optional substitutions dictionary")
        }
        guard let taskScheduler else {
            throw BASICError.runtime("HttpClient.get requires a running BASIC session")
        }
        guard let networkHost = host as? BASICNetworkHost else {
            throw BASICError.runtime("HTTP is not supported by this host")
        }
        let client = try runtime.httpClientState(id: id)
        var path = try string(arguments[0])
        if arguments.count == 2 {
            let substitutions = try evaluate(arguments[1])
            guard case .dictionary(let dictionary) = substitutions else {
                throw BASICError.runtime("HttpClient.get substitutions must be a dictionary")
            }
            path = try substituteURLTemplate(path, values: dictionary.values)
        } else if path.contains("{") || path.contains("}") {
            throw BASICError.runtime("HttpClient.get URL template requires a substitutions dictionary")
        }
        let requestURL = try resolvedHTTPURL(baseURL: client.baseURL, path: path)
        let request = BASICHTTPRequest(method: "GET", url: requestURL, headers: client.headers)
        let hostReference = BASICHostReference(host: networkHost)
        let handle = taskScheduler.startHostOperationTaskWithResult(
            name: "HttpClient.get",
            parentID: task?.id ?? taskScheduler.currentTask?.id,
            operation: "http-get"
        ) {
            guard let host = hostReference.host as? BASICNetworkHost else {
                throw BASICError.runtime("HTTP host became unavailable")
            }
            let response = try await host.http(request)
            let headers = response.headers.reduce(into: [String: BASICValue]()) { result, entry in
                result[entry.key] = .string(BASICString(entry.value))
            }
            return .dictionary(BASICDictionary(values: [
                "BODY": .string(BASICString(response.body)),
                "HEADERS": .dictionary(BASICDictionary(values: headers)),
                "OK": .boolean((200..<300).contains(response.statusCode)),
                "STATUS": .number(Double(response.statusCode)),
                "URL": .string(BASICString(response.url))
            ]))
        }
        return .task(handle)
    }

    private func substituteURLTemplate(_ template: String, values: [String: BASICValue]) throws -> String {
        var result = template
        for (key, value) in values {
            let text: String
            switch value {
            case .string(let string): text = string.description
            case .number(let number):
                if number.rounded() == number,
                   number >= Double(Int64.min), number <= Double(Int64.max) {
                    text = String(Int64(number))
                } else {
                    text = String(number)
                }
            case .boolean(let boolean): text = boolean ? "true" : "false"
            default: throw BASICError.runtime("URL substitution {\(key)} must be a scalar value")
            }
            let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? text
            result = result.replacingOccurrences(of: "{\(key)}", with: encoded)
        }
        if result.contains("{") || result.contains("}") {
            throw BASICError.runtime("URL template has an unresolved substitution")
        }
        return result
    }

    private func resolvedHTTPURL(baseURL: String, path: String) throws -> String {
        if let absolute = URL(string: path), absolute.scheme != nil {
            guard absolute.scheme?.lowercased() == "http" || absolute.scheme?.lowercased() == "https" else {
                throw BASICError.runtime("HTTP URL requires an http or https scheme")
            }
            return absolute.absoluteString
        }
        guard let base = URL(string: baseURL), let resolved = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw BASICError.runtime("Invalid HTTP URL")
        }
        return resolved.absoluteString
    }

    private func constructVectorTerminal(arguments: [Expression]) throws -> BASICValue {
        guard arguments.isEmpty else {
            throw BASICError.runtime("VectorTerminal expects 0 arguments")
        }
        return runtime.vectorTerminalObject()
    }

    /// The Rich* pseudo classes, spelled as the runtime stores them.
    ///
    /// Keyed by the uppercased name a program writes, valued by the canonical
    /// spelling, so `richmarkdown()` and `RichMarkdown()` reach the same object
    /// and the debugger shows one name rather than however it was typed.
    static let richClassNames: [String: String] = [
        "RICHTEXT": "RichText",
        "RICHMARKDOWN": "RichMarkdown",
        "RICHTABLE": "RichTable",
        "RICHPANEL": "RichPanel",
        "RICHSYNTAX": "RichSyntax",
        "RICHPROGRESS": "RichProgress",
    ]

    /// The TUIKit pseudo classes, spelled as the runtime stores them.
    static let tuiClassNames: [String: String] = [
        "TUIAPP": "TUIApp",
        "TUIWINDOW": "TUIWindow",
        "TUISTACK": "TUIStack",
        "TUIBUTTON": "TUIButton",
        "TUILABEL": "TUILabel",
    ]

    private func constructSecondsTimer(arguments: [Expression]) throws -> BASICValue {
        guard arguments.count == 1 else {
            throw BASICError.runtime("SecondsTimer expects 1 argument")
        }
        let intervalSeconds = try numeric(evaluate(arguments[0]))
        guard intervalSeconds > 0 else {
            throw BASICError.runtime("SecondsTimer interval must be greater than zero")
        }
        return runtime.secondsTimerObject(intervalSeconds: intervalSeconds)
    }

    private func evaluateBinary(_ leftExpression: Expression, _ operation: BinaryOperation, _ rightExpression: Expression) throws -> BASICValue {
        if operation == .add {
            return try evaluateAddChain(leftExpression, rightExpression)
        }

        let left = try evaluate(leftExpression)
        let right = try evaluate(rightExpression)

        switch operation {
        case .add:
            if let leftString = left.string, let rightString = right.string {
                return .string(leftString.concatenating(rightString))
            }
            return .number(try numeric(left) + numeric(right))
        case .subtract:
            return .number(try numeric(left) - numeric(right))
        case .multiply:
            return .number(try numeric(left) * numeric(right))
        case .divide:
            let divisor = try numeric(right)
            guard divisor != 0 else { throw BASICError.runtime("Division by zero") }
            return .number(try numeric(left) / divisor)
        case .equal:
            return .number(left == right ? 1 : 0)
        case .notEqual:
            return .number(left != right ? 1 : 0)
        case .less:
            return .number(try numeric(left) < numeric(right) ? 1 : 0)
        case .lessEqual:
            return .number(try numeric(left) <= numeric(right) ? 1 : 0)
        case .greater:
            return .number(try numeric(left) > numeric(right) ? 1 : 0)
        case .greaterEqual:
            return .number(try numeric(left) >= numeric(right) ? 1 : 0)
        case .and:
            return .number(left.truthy && right.truthy ? 1 : 0)
        case .or:
            return .number(left.truthy || right.truthy ? 1 : 0)
        }
    }

    private func evaluateAddChain(_ leftExpression: Expression, _ rightExpression: Expression) throws -> BASICValue {
        var terms: [Expression] = [rightExpression]
        var cursor = leftExpression

        while case .binary(let left, .add, let right) = cursor {
            terms.append(right)
            cursor = left
        }

        var value = try evaluate(cursor)
        for expression in terms.reversed() {
            let right = try evaluate(expression)
            if let leftString = value.string, let rightString = right.string {
                value = .string(leftString.concatenating(rightString))
            } else {
                value = .number(try numeric(value) + numeric(right))
            }
        }
        return value
    }

    private func interpolatedString(_ template: String) throws -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "$",
               template.index(after: index) < template.endIndex,
               template[template.index(after: index)] == "{" {
                let expressionStart = template.index(index, offsetBy: 2)
                guard let expressionEnd = interpolationEnd(in: template, from: expressionStart) else {
                    throw BASICError.runtime("Unterminated string interpolation")
                }
                let source = String(template[expressionStart..<expressionEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else {
                    throw BASICError.runtime("Empty string interpolation")
                }
                var parser = try Parser(source: source)
                output += try evaluate(parser.parseExpressionOnly()).description
                index = template.index(after: expressionEnd)
            } else {
                output.append(template[index])
                index = template.index(after: index)
            }
        }
        return output
    }

    private func interpolationEnd(in template: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < template.endIndex {
            if template[index] == "}" {
                return index
            }
            index = template.index(after: index)
        }
        return nil
    }

    private func numeric(_ value: BASICValue) throws -> Double {
        guard let number = value.number else {
            throw BASICError.runtime("Expected a number")
        }
        return number
    }

    private func integer(_ expression: Expression) throws -> Int {
        Int(try numeric(try evaluate(expression)).rounded())
    }

    private func string(_ expression: Expression) throws -> String {
        guard let string = try evaluate(expression).string else {
            throw BASICError.runtime("Expected a string")
        }
        return string.description
    }

    private func rawString(_ expression: Expression) throws -> String {
        guard let string = try evaluate(expression).string else {
            throw BASICError.runtime("Expected a string")
        }
        return string.rawString
    }

    private func currentTaskName() -> String {
        if let task {
            return "#\(task.id) \(task.name)"
        }
        if let currentTask = taskScheduler?.currentTask {
            return "#\(currentTask.id) \(currentTask.name)"
        }
        return "Program"
    }

    private func currentFunctionName() -> String {
        if let frame = gosubStack.last, frame.functionDepth == functionStack.count {
            return frame.displayName
        }
        guard let frame = functionStack.last else {
            return "[main]"
        }
        if let receiverClassName = frame.receiverClassName ?? frame.definition.ownerClassName {
            return "\(receiverClassName).\(frame.definition.displayName)"
        }
        return frame.definition.displayName
    }

    private func gosubDisplayName(for target: BranchTarget) -> String {
        switch target {
        case .line(let line):
            return "GOSUB \(line)"
        case .label(let label):
            return "GOSUB \(label)"
        }
    }

    private func currentThreadName() -> String {
        if Thread.isMainThread {
            return "main"
        }
        if let name = Thread.current.name, !name.isEmpty {
            return name
        }
        return "background"
    }

    private func boolean(_ value: BASICValue) throws -> Bool {
        switch value {
        case .boolean(let boolean):
            return boolean
        case .number(let number) where number == 0:
            return false
        case .number(let number) where number == 1:
            return true
        default:
            throw BASICError.runtime("Expected a boolean")
        }
    }

    private func resolve(point: GraphicsPoint) throws -> (x: Int, y: Int) {
        (try integer(point.x), try integer(point.y))
    }

    private func ellipseRadii(radius: Int, aspect expression: Expression) throws -> (x: Int, y: Int) {
        let aspect = try numeric(try evaluate(expression))
        guard aspect > 0 else {
            throw BASICError.runtime("CIRCLE aspect must be greater than zero")
        }
        let safeRadius = max(0, radius)
        if aspect < 1 {
            return (safeRadius, max(0, Int((Double(safeRadius) * aspect).rounded())))
        }
        return (max(0, Int((Double(safeRadius) / aspect).rounded())), safeRadius)
    }

    private func drawGraphicsPath(_ source: String, graphicsHost: BASICGraphicsHost) throws {
        let characters = Array(source)
        var index = 0
        var drawColor = currentGraphicsColor
        var blankNext = false
        var noUpdateNext = false
        var scale = 4
        var angle = 0
        var pendingPath: [BASICGraphicsPoint] = []
        var pendingPathColor: BASICColor?

        func skipSeparators() {
            while index < characters.count {
                let character = characters[index]
                if character == " " || character == "\t" || character == ";" {
                    index += 1
                } else {
                    break
                }
            }
        }

        func readSignedNumber(default defaultValue: Int? = nil) throws -> Int {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
            guard index > start else {
                if let defaultValue { return defaultValue }
                throw BASICError.runtime("DRAW expected number")
            }
            guard let value = Int(String(characters[start..<index])) else {
                throw BASICError.runtime("DRAW expected number")
            }
            return value
        }

        func flushPendingPath() {
            guard pendingPath.count >= 2, let color = pendingPathColor else {
                pendingPath.removeAll()
                pendingPathColor = nil
                return
            }
            graphicsHost.drawPath(points: pendingPath, color: color)
            pendingPath.removeAll()
            pendingPathColor = nil
        }

        func queueSegment(from start: (x: Int, y: Int), to end: (x: Int, y: Int), color: BASICColor) {
            let startPoint = BASICGraphicsPoint(x: start.x, y: start.y)
            let endPoint = BASICGraphicsPoint(x: end.x, y: end.y)
            if pendingPathColor == color, pendingPath.last == startPoint {
                pendingPath.append(endPoint)
            } else {
                flushPendingPath()
                pendingPathColor = color
                pendingPath = [startPoint, endPoint]
            }
        }

        func drawTo(_ x: Int, _ y: Int) {
            let old = currentGraphicsPoint
            if !blankNext {
                queueSegment(from: old, to: (x, y), color: drawColor)
            } else {
                flushPendingPath()
            }
            if !noUpdateNext {
                currentGraphicsPoint = (x, y)
            } else {
                flushPendingPath()
            }
            blankNext = false
            noUpdateNext = false
        }

        func scaled(_ value: Int) -> Int {
            Int((Double(value) * Double(scale) / 4.0).rounded())
        }

        func rotated(dx: Int, dy: Int) -> (dx: Int, dy: Int) {
            let scaledDX = scaled(dx)
            let scaledDY = scaled(dy)
            switch ((angle % 4) + 4) % 4 {
            case 1:
                return (scaledDY, -scaledDX)
            case 2:
                return (-scaledDX, -scaledDY)
            case 3:
                return (-scaledDY, scaledDX)
            default:
                return (scaledDX, scaledDY)
            }
        }

        func drawRelative(dx: Int, dy: Int) {
            let transformed = rotated(dx: dx, dy: dy)
            drawTo(currentGraphicsPoint.x + transformed.dx, currentGraphicsPoint.y + transformed.dy)
        }

        while index < characters.count {
            skipSeparators()
            guard index < characters.count else { break }
            let command = String(characters[index]).uppercased()
            index += 1

            switch command {
            case "B":
                blankNext = true
            case "N":
                noUpdateNext = true
            case "C":
                flushPendingPath()
                let color = try readSignedNumber()
                drawColor = .legacy(color)
                currentGraphicsColor = drawColor
                graphicsHost.setGraphicsColor(drawColor)
            case "S":
                let newScale = try readSignedNumber()
                guard newScale > 0 else {
                    throw BASICError.runtime("DRAW scale must be greater than zero")
                }
                scale = newScale
            case "A":
                let newAngle = try readSignedNumber()
                guard (0...3).contains(newAngle) else {
                    throw BASICError.runtime("DRAW angle must be 0, 1, 2, or 3")
                }
                angle = newAngle
            case "U":
                let amount = try readSignedNumber(default: 1)
                drawRelative(dx: 0, dy: -amount)
            case "D":
                drawRelative(dx: 0, dy: try readSignedNumber(default: 1))
            case "L":
                let amount = try readSignedNumber(default: 1)
                drawRelative(dx: -amount, dy: 0)
            case "R":
                drawRelative(dx: try readSignedNumber(default: 1), dy: 0)
            case "E":
                let amount = try readSignedNumber(default: 1)
                drawRelative(dx: amount, dy: -amount)
            case "F":
                let amount = try readSignedNumber(default: 1)
                drawRelative(dx: amount, dy: amount)
            case "G":
                let amount = try readSignedNumber(default: 1)
                drawRelative(dx: -amount, dy: amount)
            case "H":
                let amount = try readSignedNumber(default: 1)
                drawRelative(dx: -amount, dy: -amount)
            case "M":
                skipSeparators()
                let xStart = index
                let x = try readSignedNumber()
                let xWasRelative = xStart < characters.count && (characters[xStart] == "+" || characters[xStart] == "-")
                skipSeparators()
                guard index < characters.count, characters[index] == "," else {
                    throw BASICError.runtime("DRAW expected comma in M command")
                }
                index += 1
                skipSeparators()
                let yStart = index
                let y = try readSignedNumber()
                let yWasRelative = yStart < characters.count && (characters[yStart] == "+" || characters[yStart] == "-")
                let targetX = xWasRelative ? currentGraphicsPoint.x + x : x
                let targetY = yWasRelative ? currentGraphicsPoint.y + y : y
                drawTo(targetX, targetY)
            default:
                throw BASICError.runtime("DRAW unknown command \(command)")
            }
        }
        flushPendingPath()
    }

    private func resolveColor(_ expression: Expression) throws -> BASICColor {
        let value = try evaluate(expression)
        if let string = value.string {
            return try BASICColor.parse(string.description)
        }
        guard let number = value.number else {
            throw BASICError.runtime("Expected a color")
        }
        return BASICColor.legacy(Int(number.rounded()))
    }

    private func resolveColorStatement(_ expressions: [Expression]) throws -> (foreground: BASICColor, background: BASICColor?) {
        guard !expressions.isEmpty, expressions.count <= 2 else {
            throw BASICError.runtime("COLOR expects foreground and optional background")
        }
        let foreground = try resolveColor(expressions[0])
        let background = expressions.count == 2 ? try resolveColor(expressions[1]) : nil
        return (foreground, background)
    }

    private func nativeScreenMode(for number: Int) -> BASICScreenMode {
        BASICScreenMode(number: number, width: 0, height: 0, colorCount: 0)
    }

    private func ansiColorSequence(foreground: BASICColor, background: BASICColor?) -> String {
        var parts = ["38;2;\(foreground.red);\(foreground.green);\(foreground.blue)"]
        if let background {
            parts.append("48;2;\(background.red);\(background.green);\(background.blue)")
        }
        return "\u{001B}[\(parts.joined(separator: ";"))m"
    }
}

struct ParsedLine {
    let number: Int?
    let displayLineNumber: Int
    let fileName: String?
    let sourceLineNumber: Int
    let statementNumber: Int
    let isImported: Bool
    let statement: Statement

    var breakpointLocation: BASICBreakpointLocation {
        BASICBreakpointLocation(fileName: fileName, lineNumber: sourceLineNumber, statementNumber: statementNumber)
    }

    static func flatten(number: Int?, fileName: String?, sourceLineNumber: Int, isImported: Bool, statement: Statement) -> [ParsedLine] {
        let displayLineNumber = number ?? sourceLineNumber
        guard case .sequence(let statements) = statement else {
            return [
                ParsedLine(
                    number: number,
                    displayLineNumber: displayLineNumber,
                    fileName: fileName,
                    sourceLineNumber: sourceLineNumber,
                    statementNumber: 0,
                    isImported: isImported,
                    statement: statement
                )
            ]
        }

        return statements.enumerated().map { index, statement in
            ParsedLine(
                number: index == 0 ? number : nil,
                displayLineNumber: displayLineNumber,
                fileName: fileName,
                sourceLineNumber: sourceLineNumber,
                statementNumber: index,
                isImported: isImported,
                statement: statement
            )
        }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
