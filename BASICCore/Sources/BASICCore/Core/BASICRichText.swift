//
//  BASICRichText.swift
//  BASICCore
//
//  The Rich* pseudo classes: RichSwift's rendering, presented to BASIC the way
//  `FILE`, `HTTPCLIENT` and `VECTORTERMINAL` already are.
//
//      let md = RichMarkdown()
//      print md.render$("# Report" + chr$(10) + "All **360** tests passed.")
//
//      let t = RichTable()
//      t.column("Suite")
//      t.column("Tests")
//      t.addRow("BASICCore", "360")
//      print t.render$()
//
//  Phase 1 of TUIKIT_PLAN.md, and deliberately first: it exercises the whole
//  pseudo-class mechanism — construction, method dispatch, the vocabulary
//  obligation — with no event loop, no terminal ownership, and no `@MainActor`.
//  Everything here returns a string that `PRINT` can take, which is why it can
//  live in BASICCore and serve both hosts without either of them knowing.
//

import Foundation
import RichSwift

/// What one Rich* handle is holding.
///
/// One type rather than six, because the objects differ only in which fields
/// they use and BASIC cannot see the difference anyway — a `RichTable` that has
/// never had a column added and a `RichPanel` are the same empty box until
/// somebody renders one.
struct BASICRichObject {
    /// Column headings, for a table.
    var columns: [String] = []
    /// Rows, for a table.
    var rows: [[String]] = []
    /// Title, for a table or a panel.
    var title: String?
    /// Render width in columns.
    var width: Int = 80
    /// Whether ANSI colour is emitted.
    var isColored: Bool = true
}

extension BASICRuntime {

    /// The render context every Rich* object draws through.
    ///
    /// `markup: false` is not a detail. RichSwift's markup pass reads
    /// `[bold]like this[/bold]` out of the *content*, so a BASIC program that
    /// prints a bracketed string — a matrix row, a citation, anything —
    /// would have it silently eaten or, worse, interpreted. A program says what
    /// it wants styled by calling a method, never by embedding a tag in data.
    ///
    /// The flag alone is not enough, and this is the trap: only `String`'s
    /// `RichRenderable` conformance consults it. RichSwift's `Text` parses
    /// markup unconditionally, so anything rendered *through* `Text` — which is
    /// what `Panel(someString)` does — eats the brackets whatever this says.
    /// Every renderer below therefore hands RichSwift a bare `String`.
    private func richContext(_ object: BASICRichObject) -> RenderContext {
        RenderContext(
            width: object.width,
            colorMode: object.isColored ? .standard : .disabled,
            markup: false
        )
    }

    /// Builds a Rich* handle.
    func richObject(typeName: String) -> BASICValue {
        let id = nextRichObjectID
        nextRichObjectID += 1
        richObjects[id] = BASICRichObject()
        return .systemObject(typeName, id)
    }

    /// Dispatches a method on a Rich* handle.
    ///
    /// Method names arrive as the program spelled them and are matched
    /// case-insensitively, because BASIC is: `render$`, `RENDER$` and `Render$`
    /// are one method.
    func callRichMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue]
    ) throws -> BASICValue {
        guard var object = richObjects[id] else {
            throw BASICError.runtime("Bad \(typeName) object")
        }
        // Written back on every path that changes anything, including the ones
        // that also render — `width` returns the object so a program can chain,
        // and losing the write would make chaining silently do nothing.
        defer { richObjects[id] = object }

        func text(_ index: Int, _ what: String) throws -> String {
            guard index < arguments.count, let value = arguments[index].string else {
                throw BASICError.runtime("\(typeName).\(method) expects \(what)")
            }
            return value.description
        }

        switch method.uppercased() {
        case "WIDTH":
            guard let number = arguments.first?.number, number >= 1 else {
                throw BASICError.runtime("\(typeName).width expects a positive number")
            }
            object.width = Int(number)
            return .empty

        // `ansi`, not `color`. `COLOR` is a graphics *statement keyword*, so
        // `panel.color(0)` is parsed as the COLOR statement and never reaches
        // here — it fails with "has no field color", which names neither the
        // real problem nor the fix. A pseudo-class method may not share a name
        // with a statement keyword; see BASICKeywords for the list.
        case "ANSI":
            object.isColored = arguments.first?.truthy ?? true
            return .empty

        case "TITLE":
            object.title = try text(0, "a title")
            return .empty

        case "COLUMN":
            object.columns.append(try text(0, "a column title"))
            return .empty

        case "ADDROW":
            // Short rows are padded rather than refused. A table gaining a
            // column should not turn every existing `addRow` into a runtime
            // error halfway through a program's output.
            var row = try arguments.map { value -> String in
                guard let string = value.string else {
                    return Self.richPlainDescription(value)
                }
                return string.description
            }
            while row.count < object.columns.count { row.append("") }
            object.rows.append(row)
            return .empty

        case "CLEAR":
            object.rows.removeAll()
            return .empty

        case "RENDER$", "RENDER":
            return .string(BASICString(try renderRich(typeName, object, arguments, method)))

        default:
            throw BASICError.runtime("\(typeName) has no method \(method)")
        }
    }

    /// Renders one Rich* object.
    private func renderRich(
        _ typeName: String,
        _ object: BASICRichObject,
        _ arguments: [BASICValue],
        _ method: String
    ) throws -> String {
        let context = richContext(object)

        func argument(_ index: Int) -> String? {
            guard index < arguments.count, let value = arguments[index].string else { return nil }
            return value.description
        }

        switch typeName.uppercased() {
        case "RICHMARKDOWN":
            guard let source = argument(0) else {
                throw BASICError.runtime("RichMarkdown.render$ expects markdown text")
            }
            return Markdown(source).render(in: context)

        case "RICHTABLE":
            let columns = object.columns.map { TableColumn($0) }
            return Table(
                title: object.title,
                columns: columns,
                rows: object.rows,
                showHeader: !columns.isEmpty
            ).render(in: context)

        case "RICHPANEL":
            guard let body = argument(0) else {
                throw BASICError.runtime("RichPanel.render$ expects body text")
            }
            // The title may come from the call or from `title`, in that order:
            // `panel.render$(body$, "Results")` is one line where setting the
            // property first is two, and a program that does set it should not
            // have to repeat it on every render.
            //
            // `body` as a bare String, not `Panel(body)`. That convenience
            // initialiser wraps the text in RichSwift's `Text`, which parses
            // markup unconditionally — `context.markup` is only honoured by
            // `String`'s own conformance. Through `Text`, a program printing
            // `[bold]x[/bold]` got `x`, its brackets eaten by a styling
            // language it never asked for.
            return Panel(body as any RichRenderable, title: argument(1) ?? object.title)
                .render(in: context)

        case "RICHTEXT":
            guard let body = argument(0) else {
                throw BASICError.runtime("RichText.render$ expects text")
            }
            // Same reason as the panel above: `String`'s conformance is the one
            // that honours `context.markup`.
            return body.render(in: context)

        default:
            throw BASICError.runtime("\(typeName) has no method \(method)")
        }
    }

    /// A non-string BASIC value as a table cell.
    ///
    /// Numbers reach `addRow` constantly — a row of counts is the ordinary
    /// case — and refusing them would make every call site wrap in `STR$`.
    static func richPlainDescription(_ value: BASICValue) -> String {
        if let number = value.number {
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)
        }
        if case .boolean(let flag) = value {
            return flag ? "True" : "False"
        }
        return ""
    }
}
