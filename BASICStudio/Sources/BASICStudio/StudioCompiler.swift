//
//  StudioCompiler.swift
//  BASICStudio
//
//  basicc's compiler core, in process (BASIC-44). On an iPad nothing else can
//  be started, so a program is compiled here, from the editor's text, and run
//  as WebAssembly in JavaScriptCore (BASIC-45). On the Mac the same calls
//  serve the WebAssembly choice for compiled runs; ⚡ with LLVM still runs
//  basicc as its own process.
//

import BASICCompilerKit
import BASICDialectSwift
import BASICDialectTraditional
import Foundation

enum StudioCompiler {
    /// The program's BIR, printed as `basicc build --emit-bir` prints it.
    static func bir(source: String, name: String) throws -> String {
        BIRPrinter().render(try Compilation(dialect: TraditionalDialect()).bir(source: source, name: name))
    }

    /// The program's LLVM IR, as `basicc build --emit-llvm -g0` prints it:
    /// what the WebAssembly translator reads. The text is the LLVM path's own;
    /// nothing here changes how it is made.
    ///
    /// `hostedActiveUI` is for a run Studio hosts: the program's ActiveUI
    /// windows are Studio's, so it may make them (basicc refuses them
    /// otherwise, as a native build has none).
    ///
    /// `path` is the file the text belongs to, so its `IMPORT`s are found
    /// beside it as the interpreter finds them; `projectRoot`, the project it
    /// is in. Without a path the text is compiled on its own, imports refused.
    ///
    /// An `IMPORT` nothing on disk answers may name a framework Studio
    /// contains (BASIC-45, slice 11): its API comes from the map, and the
    /// program is lowered by the Swift dialect's mapped mode, every member
    /// through a shim Studio has. A program that imports none is lowered
    /// exactly as before, by the traditional dialect.
    static func llvmIR(source: String, name: String, hostedActiveUI: Bool = false,
                       path: String? = nil, projectRoot: String? = nil, debugInfo: Bool = false,
                       chainTarget: Bool = false) throws -> String {
        // Debug info names each variable's type, for a run the debugger can
        // look into (BASIC-46).
        var options = CompileOptions(emitDebugInfo: debugInfo)
        options.hostedActiveUI = hostedActiveUI
        options.chainTarget = chainTarget
        guard let path else {
            let compilation = Compilation(dialect: TraditionalDialect(), options: options)
            return try compilation.dialect.lower(compilation.bir(source: source, name: name), options: options).llvmIR
        }
        let loaded = try StudioFrameworkMap.imports.load(source: source, path: path, name: name,
                                                         projectRoot: projectRoot, options: options)
        guard !loaded.imports.isEmpty else {
            return try TraditionalDialect().lower(loaded.module, options: options).llvmIR
        }
        return try SwiftDialect(mappedImports: loaded.imports).lower(loaded.module, options: options).llvmIR
    }
}
