import BASICCompilerKit
import BASICDialectTraditional
import Foundation
import Testing

/// How basicc holds what closures capture (Documents/CLOSURES.md 5.2–5.4):
/// a heap cell only for a local a closure shares and something writes, a
/// copy for one nothing writes, and nothing at all for a global.
@Suite("Closure lowering")
struct ClosureLoweringTests {
    private func module(_ source: String) throws -> BIRModule {
        try Compilation(dialect: TraditionalDialect()).bir(source: source, name: "closures")
    }

    @Test("a closure reading a parameter copies it: no cell in the function that makes it")
    func readOnlyParameterIsCopied() throws {
        let bir = try module("""
        FUNCTION TYPE Unary(x AS INTEGER) AS INTEGER
        FUNCTION MakeAdder(n AS INTEGER) AS Unary
          RETURN FUNCTION(x AS INTEGER) AS INTEGER = x + n
        END FUNCTION
        add5 = MakeAdder(5)
        PRINT add5(1)
        """)
        let maker = try #require(bir.functions.first { $0.name == "MAKEADDER" })
        #expect(maker.cells.isEmpty)
        let rendered = BIRPrinter().render(bir)
        #expect(rendered.contains("closure closure$1[N]"), "\(rendered)")
    }

    @Test("a closure that counts shares its local through exactly one cell")
    func writtenLocalIsCelled() throws {
        let bir = try module("""
        FUNCTION TYPE Counter() AS INTEGER
        FUNCTION MakeCounter() AS Counter
          LOCAL count AS INTEGER = 0
          LOCAL tick AS Counter
          tick = FUNCTION() AS INTEGER
            count = count + 1
            RETURN count
          END FUNCTION
          RETURN tick
        END FUNCTION
        c = MakeCounter()
        PRINT c()
        """)
        let maker = try #require(bir.functions.first { $0.name == "MAKECOUNTER" })
        #expect(maker.cells == ["COUNT": .frame])
        let body = try #require(bir.functions.first { $0.name.hasPrefix("closure$") })
        #expect(body.cells == ["COUNT": .environment(0)])
        #expect(BIRPrinter().render(bir).contains("[&COUNT]"))
    }

    @Test("a global is reached directly: a closure that shares one captures nothing")
    func globalIsNotCaptured() throws {
        let bir = try module("""
        total = 0
        add = FUNCTION(n AS INTEGER) AS INTEGER
          total = total + n
          RETURN total
        END FUNCTION
        PRINT add(3)
        """)
        #expect(bir.functions.allSatisfy { $0.cells.isEmpty })
        #expect(BIRPrinter().render(bir).contains("closure closure$1[]"))
    }
}
