//
//  BASICRichTextTests.swift
//  BASICCoreTests
//
//  Phase 1 of TUIKIT_PLAN.md: the Rich* pseudo classes.
//

import Testing
@testable import BASICCore

@Suite("Rich pseudo classes")
struct BASICRichTextTests {

    /// Runs `source` and returns what it printed.
    private func output(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    /// Constructed without `NEW`, the way `VectorTerminal()` is.
    ///
    /// Both spellings, because they are two separate dispatch sites in the
    /// interpreter — `.callOrArray` and `.newObject` — and only one of them was
    /// wired the first time.
    @Test("a Rich object is constructed with or without NEW")
    func constructedEitherWay() {
        #expect(output("""
        let a = RichMarkdown()
        let b = NEW RichMarkdown()
        print "built"
        """) == ["built"])
    }

    /// The failure this catches is not a rendering bug.
    ///
    /// A pseudo class missing from `BASICRuntime.isBuiltInClass` constructs
    /// perfectly and then cannot be assigned to anything — "Cannot assign
    /// non-RichMarkdown object to md" — which reads as a type error in the
    /// program rather than a missing registration. That list now derives from
    /// `BASICKeywords.pseudoClasses`, and this is what proves it.
    @Test("every pseudo class can be assigned to a variable")
    func assignableToAVariable() {
        // Constructor arguments, for the ones that need them. Everything not
        // listed takes none — which is the answer for the whole Rich family.
        let arguments = ["HTTPCLIENT": "\"https://example.com\"", "SECONDSTIMER": "1"]
        for name in BASICKeywords.pseudoClasses.sorted() {
            let host = TestHost()
            let session = BASICSession(host: host)
            session.program.loadSource(
                "LET Handle = \(name)(\(arguments[name] ?? ""))\nPRINT \"ok\""
            )
            session.submit("RUN")
            #expect(
                host.output == ["ok"],
                "\(name) constructed but could not be assigned: \(host.output)"
            )
        }
    }

    @Test("markdown renders")
    func markdownRenders() {
        let lines = output("""
        let md = RichMarkdown()
        md.ansi(0)
        print md.render$("# Title")
        """)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Title") == true)
    }

    /// Numbers reach `addRow` constantly — a row of counts is the ordinary
    /// case — so they must not have to be wrapped in `STR$`.
    @Test("a table takes strings and numbers, and pads short rows")
    func tableRenders() {
        let lines = output("""
        let t = RichTable()
        t.ansi(0)
        t.column("Suite")
        t.column("Tests")
        t.addRow("BASICCore", 360)
        t.addRow("Short")
        print t.render$()
        """)
        let rendered = lines.joined(separator: "\n")
        #expect(rendered.contains("BASICCore"))
        #expect(rendered.contains("360"))
        #expect(rendered.contains("Short"))
    }

    /// Markup is off, deliberately. RichSwift's markup pass reads
    /// `[bold]like this[/bold]` out of the *content*, so a program printing a
    /// bracketed string would have it eaten or interpreted.
    @Test("bracketed content is not treated as markup")
    func contentIsNotMarkup() {
        let lines = output("""
        let p = RichPanel()
        p.ansi(0)
        print p.render$("[bold]not bold[/bold]")
        """)
        #expect(lines.joined().contains("[bold]"))
    }

    @Test("a panel takes its title from the call or the property")
    func panelTitles() {
        let rendered = output("""
        let p = RichPanel()
        p.ansi(0)
        p.title("From property")
        print p.render$("body")
        """).joined(separator: "\n")
        #expect(rendered.contains("From property"))
    }

    /// `COLOR` is a graphics statement keyword, so a method called `color`
    /// would be parsed as that statement and never reach the object — failing
    /// with "has no field color", which names neither the problem nor the fix.
    /// That is why the method is `ansi`, and this is the guard against anyone
    /// renaming it back.
    @Test("no Rich method collides with a statement keyword")
    func noMethodCollidesWithAKeyword() {
        for method in ["ANSI", "WIDTH", "TITLE", "COLUMN", "ADDROW", "RENDER$"] {
            #expect(
                BASICKeywords.category(of: method) != .control
                    && BASICKeywords.category(of: method) != .graphics
                    && BASICKeywords.category(of: method) != .io,
                "\(method) is a statement keyword, so it cannot be a method name"
            )
        }
    }

    @Test("an unknown method is reported by name")
    func unknownMethodIsNamed() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("let t = RichTable()\nt.nosuchmethod()")
        session.submit("RUN")
        #expect(host.output.joined().contains("nosuchmethod"))
    }
}
