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
    static func llvmIR(source: String, name: String, hostedActiveUI: Bool = false,
                       path: String? = nil, projectRoot: String? = nil) throws -> String {
        var options = CompileOptions(emitDebugInfo: false)
        options.hostedActiveUI = hostedActiveUI
        let compilation = Compilation(dialect: TraditionalDialect(), options: options)
        let module = try path.map { try compilation.bir(source: source, path: $0, projectRoot: projectRoot) }
            ?? compilation.bir(source: source, name: name)
        return try compilation.dialect.lower(module, options: compilation.options).llvmIR
    }
}
