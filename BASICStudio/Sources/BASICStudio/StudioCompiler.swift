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
    static func llvmIR(source: String, name: String) throws -> String {
        let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
        let module = try compilation.bir(source: source, name: name)
        return try compilation.dialect.lower(module, options: compilation.options).llvmIR
    }
}
