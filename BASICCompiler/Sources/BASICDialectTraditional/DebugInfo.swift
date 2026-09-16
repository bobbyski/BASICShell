import BASICCompilerKit
import Foundation

/// DWARF for one lowered module (decision D10, plan item J1.4).
///
/// Every BIR instruction already carries the file and line it came from; this
/// turns those into the metadata LLVM writes out as DWARF, so `lldb` on a
/// compiled program stops on BASIC lines, steps by them, names BASIC
/// functions in a backtrace, and shows variables.
///
/// ```text
///   BIRLocation(file, line) ─► !DILocation(line, scope: !DISubprogram)
///   BIRFunction             ─► !DISubprogram, attached to its `define`
///   BIRVariable (local)     ─► !DILocalVariable + llvm.dbg.declare on its alloca
///   BIRVariable (global)    ─► !DIGlobalVariableExpression on its global
/// ```
///
/// Shared by every function emitter in a module, the way ``ConstantPool`` is:
/// metadata is numbered module-wide, and a file or a type is described once.
///
/// What it deliberately does not do yet:
/// - **Columns.** A location knows its statement index within a
///   colon-separated line but not its column, and a statement index written
///   as a column would be a column that points at the wrong character. Every
///   location is column 0, so `A = 1 : B = 2` is one stop.
/// - **String contents.** A string, array, record or object is a pointer to
///   runtime storage. It is described as a pointer *named* for its BASIC type
///   (`STRING`, `VARIANT`, `ARRAY`, the class's name), so it appears in
///   `frame variable` with the right type name — which is also the hook a
///   data formatter would attach to — but its text is not decoded.
/// - **Case.** BASIC names are case-insensitive and stored uppercased, and
///   that is how they are written into DWARF: `frame variable COUNT`, not
///   `count`.
final class DebugInfo {
    /// Every metadata node, as `!N = …` lines, in allocation order.
    private var nodes: [Int: String] = [:]
    private var nextID = 3

    private let compileUnitID = 0
    private let emptyTupleID = 1
    private let subroutineTypeID = 2
    private let primaryFile: String

    private var fileIDs: [String: Int] = [:]
    private var lexicalFileIDs: [String: Int] = [:]
    private var locationIDs: [String: Int] = [:]
    private var typeIDs: [String: Int] = [:]
    private var globalIDs: [Int] = []

    /// Creates the module's compile unit.
    ///
    /// - Parameters:
    ///   - primarySource: The entry file, as the loader named it; nil when the
    ///     program was compiled from text (tests), which is then described as
    ///     `<module>.bas` in the working directory.
    ///   - moduleName: The module's name.
    ///   - optimized: Whether the code is optimized, which tells the debugger
    ///     to expect variables that are not where the declaration says.
    init(primarySource: String?, moduleName: String, optimized: Bool) {
        primaryFile = Self.absolutePath(primarySource ?? "\(moduleName).bas")
        isOptimized = optimized
        nodes[emptyTupleID] = "!{}"
        nodes[subroutineTypeID] = "!DISubroutineType(types: \(ref(emptyTupleID)))"
        // The compile unit's own text waits for `render`, when its globals are
        // known; its file is described now, so it is numbered with the rest.
        primaryFileID = fileID(primaryFile)
    }

    private let isOptimized: Bool
    private var primaryFileID = 0

    // MARK: - Functions

    /// A function's scope: what its `define` carries, and what every location
    /// inside it points at.
    struct Scope {
        /// The subprogram's metadata reference.
        let subprogram: String
        let subprogramID: Int
        /// The file the function was written in.
        let file: String
        /// The line it starts on — also where the prologue is attributed.
        let line: Int
        /// The location of `line`, for code the source did not write: the
        /// prologue, and the dispatch blocks after the body.
        let entryLocation: String
    }

    /// Describes one function.
    ///
    /// Its file and line are those of its first instruction that has a line,
    /// which for a `FUNCTION` is the line after its header — the first thing
    /// a breakpoint on the function should stop at.
    func scope(for function: BIRFunction, isMain: Bool, linkageName: String) -> Scope {
        let first = function.blocks.lazy
            .flatMap(\.instructions)
            .map(\.location)
            .first { $0.line > 0 && (!isMain || $0.file == nil || Self.absolutePath($0.file!) == primaryFile) }
        let file = first?.file.map(Self.absolutePath) ?? primaryFile
        let line = first?.line ?? 0

        let id = nextID; nextID += 1
        let fileRef = ref(fileID(file))
        // `main` keeps its C name, so `b main` and a backtrace agree with the
        // symbol; a BASIC function is named as BASIC names it, with the
        // mangled `F.NAME` as its linkage name.
        let name = isMain ? "main" : function.name
        let linkage = isMain ? "" : "linkageName: \(Self.quoted(linkageName)), "
        nodes[id] = "distinct !DISubprogram(name: \(Self.quoted(name)), \(linkage)scope: \(fileRef), file: \(fileRef), "
            + "line: \(line), type: \(ref(subroutineTypeID)), scopeLine: \(line), "
            + "spFlags: DISPFlagDefinition, unit: \(ref(compileUnitID)), retainedNodes: \(ref(emptyTupleID)))"

        let entry = locationID(line: line, file: file, subprogramID: id, subprogramFile: file)
        return Scope(subprogram: ref(id), subprogramID: id, file: file, line: line, entryLocation: ref(entry))
    }

    /// The location for an instruction, or nil when it has no line — the
    /// caller then keeps the location it had, so compiler-made code between
    /// two statements is attributed to the statement before it rather than to
    /// line 0, which a debugger would stop on as "no line".
    func location(_ location: BIRLocation, in scope: Scope) -> String? {
        guard location.line > 0 else { return nil }
        let file = location.file.map(Self.absolutePath) ?? scope.file
        return ref(locationID(line: location.line, file: file, subprogramID: scope.subprogramID, subprogramFile: scope.file))
    }

    private func locationID(line: Int, file: String, subprogramID: Int, subprogramFile: String) -> Int {
        let key = "\(subprogramID):\(file):\(line)"
        if let id = locationIDs[key] { return id }
        // A location's file is its scope's file. Main's body holds the
        // top-level statements of every IMPORTed file, so a line from another
        // file is scoped to a lexical block that names that file — without it,
        // line 12 of ContactModel.bas would be reported as line 12 of main.bas.
        let scopeID = file == subprogramFile ? subprogramID : lexicalFileID(file: file, subprogramID: subprogramID)
        let id = nextID; nextID += 1
        nodes[id] = "!DILocation(line: \(line), column: 0, scope: \(ref(scopeID)))"
        locationIDs[key] = id
        return id
    }

    private func lexicalFileID(file: String, subprogramID: Int) -> Int {
        let key = "\(subprogramID):\(file)"
        if let id = lexicalFileIDs[key] { return id }
        let id = nextID; nextID += 1
        nodes[id] = "!DILexicalBlockFile(scope: \(ref(subprogramID)), file: \(ref(fileID(file))), discriminator: 0)"
        lexicalFileIDs[key] = id
        return id
    }

    // MARK: - Variables

    /// A local variable or parameter; nil for the compiler's own slots.
    ///
    /// - Parameter argument: The 1-based parameter position, for a parameter.
    func localVariable(_ variable: BIRVariable, argument: Int?, in scope: Scope, module: BIRModule) -> String? {
        guard Self.isDescribable(variable) else { return nil }
        let id = nextID; nextID += 1
        let arg = argument.map { "arg: \($0), " } ?? ""
        nodes[id] = "!DILocalVariable(name: \(Self.quoted(variable.name)), \(arg)scope: \(scope.subprogram), "
            + "file: \(ref(fileID(scope.file))), line: \(scope.line), type: \(ref(typeID(variable, module: module))))"
        return ref(id)
    }

    /// A global's attachment, for the end of its definition; nil for the
    /// compiler's own slots.
    func globalVariable(_ variable: BIRVariable, module: BIRModule) -> String? {
        guard Self.isDescribable(variable) else { return nil }
        let variableID = nextID; nextID += 1
        nodes[variableID] = "distinct !DIGlobalVariable(name: \(Self.quoted(variable.name)), scope: \(ref(compileUnitID)), "
            + "file: \(ref(fileID(primaryFile))), line: 0, type: \(ref(typeID(variable, module: module))), "
            + "isLocal: false, isDefinition: true)"
        let expressionID = nextID; nextID += 1
        nodes[expressionID] = "!DIGlobalVariableExpression(var: \(ref(variableID)), expr: !DIExpression())"
        globalIDs.append(expressionID)
        return ref(expressionID)
    }

    /// Names the compiler invents (`$ENV`, `$RESULT`) are not the program's,
    /// and a debugger that lists them is showing the machinery.
    private static func isDescribable(_ variable: BIRVariable) -> Bool {
        !variable.name.hasPrefix("$")
    }

    /// A variable's type, described once per distinct BASIC type.
    ///
    /// Each is a typedef named as BASIC names it, over the C type that says
    /// how to read the bytes. A debugger that knows C shows `(INTEGER) N = 3`
    /// — the declared type — and still reads a double as a double; a bare
    /// base type named `INTEGER` is canonicalized back to `double` and the
    /// program's own word is lost.
    private func typeID(_ variable: BIRVariable, module: BIRModule) -> Int {
        let name: String
        let underlying: Int
        if variable.rank != nil {
            name = "ARRAY"
            underlying = pointerID()
        } else {
            switch variable.type {
            case .number:
                name = variable.isInteger ? "INTEGER" : "DOUBLE"
                underlying = baseTypeID(name: "double", size: 64, encoding: "DW_ATE_float")
            case .boolean:
                name = "BOOLEAN"
                underlying = baseTypeID(name: "bool", size: 8, encoding: "DW_ATE_boolean")
            default:
                name = Self.pointerTypeName(variable.type, module: module)
                underlying = pointerID()
            }
        }
        let key = "typedef:" + name
        if let id = typeIDs[key] { return id }
        let id = nextID; nextID += 1
        nodes[id] = "!DIDerivedType(tag: DW_TAG_typedef, name: \(Self.quoted(name)), file: \(ref(primaryFileID)), baseType: \(ref(underlying)))"
        typeIDs[key] = id
        return id
    }

    private func baseTypeID(name: String, size: Int, encoding: String) -> Int {
        let key = "base:" + name
        if let id = typeIDs[key] { return id }
        let id = nextID; nextID += 1
        nodes[id] = "!DIBasicType(name: \(Self.quoted(name)), size: \(size), encoding: \(encoding))"
        typeIDs[key] = id
        return id
    }

    /// `void *`: what a runtime handle is, as far as C can say.
    private func pointerID() -> Int {
        let key = "pointer"
        if let id = typeIDs[key] { return id }
        let id = nextID; nextID += 1
        nodes[id] = "!DIDerivedType(tag: DW_TAG_pointer_type, baseType: null, size: 64)"
        typeIDs[key] = id
        return id
    }

    private static func pointerTypeName(_ type: BIRType, module: BIRModule) -> String {
        switch type {
        case .string: return "STRING"
        case .variant: return "VARIANT"
        case .dictionary: return "DICTIONARY"
        case .closure: return "FUNCTION"
        case .array: return "ARRAY"
        case .composite(let name):
            return module.types.first { $0.name == name }?.displayName ?? name
        case .system(let name): return name
        default: return "OBJECT"
        }
    }

    // MARK: - Files

    private func fileID(_ path: String) -> Int {
        if let id = fileIDs[path] { return id }
        let id = nextID; nextID += 1
        let url = URL(fileURLWithPath: path)
        nodes[id] = "!DIFile(filename: \(Self.quoted(url.lastPathComponent)), "
            + "directory: \(Self.quoted(url.deletingLastPathComponent().path)))"
        fileIDs[path] = id
        return id
    }

    /// Absolute, so a debugger run from anywhere finds the source — and so one
    /// file reached by two spellings (`src/A.bas`, `./src/A.bas`) is one file.
    static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    // MARK: - Output

    /// The metadata section and the module flags that make LLVM emit it.
    func render() -> String {
        let globals = globalIDs.isEmpty ? ref(emptyTupleID) : {
            let id = nextID; nextID += 1
            nodes[id] = "!{" + globalIDs.map(ref).joined(separator: ", ") + "}"
            return ref(id)
        }()
        nodes[compileUnitID] = "distinct !DICompileUnit(language: DW_LANG_C99, file: \(ref(primaryFileID)), "
            + "producer: \"basicc\", isOptimized: \(isOptimized), runtimeVersion: 0, emissionKind: FullDebug, "
            + "globals: \(globals))"

        let dwarfVersion = nextID; nextID += 1
        nodes[dwarfVersion] = "!{i32 7, !\"Dwarf Version\", i32 4}"
        let debugInfoVersion = nextID; nextID += 1
        nodes[debugInfoVersion] = "!{i32 2, !\"Debug Info Version\", i32 3}"

        var lines = [
            "!llvm.dbg.cu = !{\(ref(compileUnitID))}",
            "!llvm.module.flags = !{\(ref(dwarfVersion)), \(ref(debugInfoVersion))}",
        ]
        for id in nodes.keys.sorted() {
            lines.append("\(ref(id)) = \(nodes[id]!)")
        }
        return lines.joined(separator: "\n")
    }

    private func ref(_ id: Int) -> String { "!\(id)" }

    /// A metadata string: printable ASCII as itself, everything else escaped,
    /// the same rule as a `c"…"` constant without its terminator.
    static func quoted(_ text: String) -> String {
        var body = ""
        for byte in text.utf8 {
            if byte >= 0x20 && byte < 0x7f && byte != 0x22 && byte != 0x5c {
                body.append(Character(UnicodeScalar(byte)))
            } else {
                body += String(format: "\\%02X", byte)
            }
        }
        return "\"\(body)\""
    }
}
