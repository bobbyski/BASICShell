@testable import BASICCompilerKit
import BASICDialectTraditional
import Foundation
import Testing

/// Phase 0.5 of BASIC_COMPILER.md, kept proved: hand-written IR that calls
/// into BASICRT is assembled by clang, linked by swiftc, and runs.
///
/// No code generator is involved — this pins the *link line*, so when the
/// first real lowering fails we know which half broke.
struct ToolchainSpikeTests {
    /// The program the spike compiles: `PRINT "HELLO, WORLD"` and
    /// `PRINT 40 + 2`, written by hand in LLVM IR.
    static let spikeIR = """
    target triple = "\(TargetTriple.host.rawValue)"

    @.str = private constant [13 x i8] c"HELLO, WORLD\\00"

    declare ptr @basic_rt_string_literal(ptr, i64)
    declare void @basic_rt_print_text(ptr)
    declare void @basic_rt_print_number(double)
    declare void @basic_rt_print_newline()
    declare void @basic_rt_finish()

    define i32 @main(i32 %argc, ptr %argv) {
    entry:
      %s = call ptr @basic_rt_string_literal(ptr @.str, i64 12)
      call void @basic_rt_print_text(ptr %s)
      call void @basic_rt_print_newline()
      %x = fadd double 40.0, 2.0
      call void @basic_rt_print_number(double %x)
      call void @basic_rt_print_newline()
      call void @basic_rt_finish()
      ret i32 0
    }

    """

    @Test func handWrittenIRLinksAgainstBASICRTAndRuns() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-spike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let path = { (name: String) in workDir.appendingPathComponent(name).path }

        let toolchain = Toolchain()
        let runtime = TraditionalDialect().runtimeLibrary(for: .host)

        try toolchain.compileRuntime(sources: try runtime.sources(), objectPath: path("rt.o"))
        try toolchain.assemble(llvmIR: Self.spikeIR, irPath: path("spike.ll"), objectPath: path("spike.o"))
        try toolchain.link(objects: [path("spike.o"), path("rt.o")], output: path("spike"))

        let run = try ProcessRunner.run(path("spike"), [])
        #expect(run.exitCode == 0)
        #expect(run.stdout == "HELLO, WORLD\n42\n")
    }
}

/// The registry resolves names the way `--dialect` needs.
struct DialectRegistryTests {
    let registry = DialectRegistry([TraditionalDialect()])

    @Test func traditionalIsTheDefault() throws {
        #expect(type(of: registry.defaultDialect).identity.identifier == "traditional")
        #expect(type(of: try registry.dialect(named: nil)).identity.isDefault)
    }

    @Test func lookupIsCaseInsensitive() throws {
        #expect(type(of: try registry.dialect(named: "Traditional")).identity.identifier == "traditional")
    }

    @Test func unknownNamesListWhatWouldHaveWorked() {
        #expect(throws: DialectRegistry.UnknownDialect.self) {
            try registry.dialect(named: "cobol")
        }
    }
}
