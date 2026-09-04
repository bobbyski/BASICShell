import BASICCompilerKit
import BASICDialectTraditional
import Foundation

// basicc — the CLI driver.
//
// Owns no language knowledge. Parses the command line, asks the registry for
// a dialect, and hands it the work. Commands grow with the phases in
// BASIC_COMPILER.md; today: `--version`, `dialects`, and `help`.

let version = "0.1.0"

let registry = DialectRegistry([TraditionalDialect()])

func printUsage() {
    print("""
    basicc \(version) — a BASIC compiler that builds LLVM modules and links Swift libraries

    usage:
      basicc dialects            list the dialects this build supports
      basicc --version           print the version
      basicc help                this text

    build and run arrive with Phase 3 and Phase 6 of BASIC_COMPILER.md.
    """)
}

func printDialects() {
    for identity in registry.identities {
        let marker = identity.isDefault ? " (default)" : ""
        print("\(identity.identifier)\(marker)\t\(identity.summary)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--version", "-v":
    print("basicc \(version)")
case "dialects":
    printDialects()
case nil, "help", "--help", "-h":
    printUsage()
case let other?:
    FileHandle.standardError.write(Data("basicc: unknown command '\(other)'\n\n".utf8))
    printUsage()
    exit(2)
}
