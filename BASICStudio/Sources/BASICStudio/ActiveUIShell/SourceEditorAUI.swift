//
//  SourceEditorAUI.swift
//  BASICStudio
//
//  The program editor in the ActiveUI shell: ActiveUI's own source editor
//  over SwiftyCodeEditor on the Mac, where the SwiftUI shell has Monaco, and
//  ActiveUI's canvas editor on iPhone and iPad, where SwiftyCodeEditor's
//  AppKit text engine does not run.
//

#if canImport(SwiftyCodeEditor)
import ActiveUI
import ActiveUICode
import AppKit
import BASICCore
import SwiftyCodeEditor

/// A source editor drawn from ``EditorRenderInput``, as
/// `MonacoEditorController` is in the SwiftUI shell. The main editor and the
/// Debug code view are both one of these.
///
/// What Monaco did, and where it went:
///
/// | Monaco | Here |
/// |---|---|
/// | the BASIC grammar | ``highlighter``, built from `BASICKeywords` |
/// | Dark, Light, High Contrast | ``theme(for:)``, in Monaco's own colors |
/// | the line-number toggle | the gutter's ruler, shown or hidden |
/// | find and replace | the text view's find bar |
/// | (new) indenting | ``behavior(_:)``, from Settings ▸ Editor |
/// | errors, diagnostics | `EditorDiagnostic`s |
/// | the paused line, breakpoints | `stoppedLine`, `breakpoints` |
@MainActor
final class SourceEditorAUI {
    /// The editor, to put in a layout.
    let editor: AUISourceEditor
    /// Called with the whole text after each edit.
    var onTextChange: ((String) -> Void)?
    /// Called with a 1-based line when its gutter is clicked.
    var onToggleBreakpoint: ((Int) -> Void)? {
        get { editor.onToggleBreakpoint }
        set { editor.onToggleBreakpoint = newValue }
    }
    /// What was last drawn.
    private(set) var drawn: EditorRenderInput?

    init() {
        editor = AUISourceEditor(
            text: "",
            highlighter: Self.highlighter,
            theme: Self.theme(for: .dark),
            documentIdentifier: "program.bas"
        )
        editor.onChange = { [weak self] text in self?.onTextChange?(text) }
    }

    /// Brings the editor up to `input`, changing only what differs.
    func sync(_ input: EditorRenderInput) {
        let old = drawn
        // Against the editor's own text: typing changes it without a sync,
        // and setting it again would put the caret back at the start.
        if editor.text != input.text {
            editor.text = input.text
        }
        if input.theme != old?.theme {
            editor.theme = Self.theme(for: input.theme)
        }
        if input.fontFamily != old?.fontFamily || input.fontSize != old?.fontSize {
            let size = CGFloat(input.fontSize)
            editor.sourceFont = NSFont(name: input.fontFamily, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if input.isReadOnly != old?.isReadOnly {
            editor.isEditable = !input.isReadOnly
        }
        if input.diagnostics != old?.diagnostics || input.errorLine != old?.errorLine {
            editor.diagnostics = Self.diagnostics(input)
        }
        if input.breakpointLines != old?.breakpointLines {
            editor.breakpoints = Dictionary(uniqueKeysWithValues: input.breakpointLines.map { ($0, SwiftyCodeEditor.EditorBreakpointState()) })
        }
        if input.executionLine != old?.executionLine {
            editor.stoppedLine = input.executionLine
            if let line = input.executionLine {
                editor.reveal(line: line)
            }
        }
        if input.findRequest > (old?.findRequest ?? 0) {
            showFind(replacing: false)
        }
        if input.replaceRequest > (old?.replaceRequest ?? 0) {
            showFind(replacing: true)
        }
        let behavior = Self.behavior(input)
        if behavior != editor.editorBehavior {
            editor.editorBehavior = behavior
        }
        // Every change above re-renders the surface, and a render turns the
        // gutter back on, so the setting is applied after them, every time.
        showLineNumbers(input.showsLineNumbers)
        drawn = input
    }

    // MARK: Typing

    /// The typing conveniences Studio offers, and the ones it turns off.
    ///
    /// SwiftyCodeEditor's defaults are for brace languages and HTML. Its
    /// auto-close pairs `'`, which starts a BASIC comment, and completes a
    /// "tag" on `>`, which in `IF x<y AND y>z` is a comparison; the tag sync,
    /// the Return expansion and the folding ribbon work on braces and tags
    /// BASIC does not have; and Studio keeps no git baseline for the gutter.
    static func behavior(_ input: EditorRenderInput) -> EditorBehaviorPreferences {
        EditorBehaviorPreferences(
            indentsSelectionWithTab: input.indentsSelectionWithTab,
            closesPairsAutomatically: false,
            synchronizesClosingTag: false,
            expandsPairsOnReturn: false,
            indentsNewLines: input.indentsNewLines,
            showsFoldingRibbon: false,
            showsGitChangeGutter: false,
            indentUnit: input.indentUnit
        )
    }

    // MARK: The gutter and find

    /// The gutter is an `NSRulerView`; hiding the ruler hides the numbers.
    /// SwiftyCodeEditor has no switch of its own for it.
    private func showLineNumbers(_ shows: Bool) {
        guard let scrollView = Self.descendant(NSScrollView.self, of: editor.nativeView, where: \.hasVerticalRuler),
              scrollView.rulersVisible != shows else { return }
        scrollView.rulersVisible = shows
    }

    /// Opens the find bar, or find and replace. SwiftyCodeEditor never turns
    /// the find bar on, so it is turned on here, on its text view.
    private func showFind(replacing: Bool) {
        guard let textView = Self.descendant(NSTextView.self, of: editor.nativeView) else { return }
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = (replacing ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        textView.performTextFinderAction(sender)
    }

    private static func descendant<View: NSView>(_ type: View.Type, of view: NSView, where test: (View) -> Bool = { _ in true }) -> View? {
        if let match = view as? View, test(match) { return match }
        for subview in view.subviews {
            if let match = descendant(type, of: subview, where: test) { return match }
        }
        return nil
    }

    // MARK: Diagnostics

    /// The model's diagnostics, and the error line as an error of its own
    /// when no diagnostic already marks it.
    static func diagnostics(_ input: EditorRenderInput) -> [SwiftyCodeEditor.EditorDiagnostic] {
        var diagnostics = input.diagnostics.map { diagnostic in
            SwiftyCodeEditor.EditorDiagnostic(
                line: diagnostic.lineNumber,
                column: diagnostic.column > 0 ? diagnostic.column : nil,
                severity: diagnostic.severity == .error ? .error : .warning,
                message: diagnostic.message
            )
        }
        if let line = input.errorLine, !diagnostics.contains(where: { $0.line == line && $0.severity == .error }) {
            diagnostics.append(SwiftyCodeEditor.EditorDiagnostic(line: line, severity: .error, message: "Error"))
        }
        return diagnostics
    }

    // MARK: The BASIC grammar

    /// BASIC, colored by the interpreter's own word lists.
    ///
    /// SwiftyCodeEditor ships a BASIC highlighter, but its lists are copied
    /// from `BASICKeywords` by hand, the drift that once broke the Monaco
    /// grammar (ACTIVEUI_TRANSITION.md §7). These are read from it, in the
    /// categories Monaco's grammar used.
    static let highlighter: SyntaxHighlighting = {
        // The first rule to match owns the characters, so comments and
        // strings come before anything that could appear inside them.
        var rules: [(String, String, Int)] = [
            (#"'.*"#, "comment.basic", 0),
            (#"(?i)(?:^|:)\s*REM\b.*"#, "comment.basic", 0),
            (#"//.*"#, "comment.extension", 0),
            (#"^\s*#.*"#, "comment.extension", 0),
            (#"\$\{[^}]*\}"#, "string.escape", 0),
            (#"\$?"[^"\n]*""#, "string", 0),
            (#"^\s*[0-9]+\b"#, "number.line", 0),
            (#"^\s*[A-Za-z_][A-Za-z0-9_]*:(?=\s*(?:'.*)?$)"#, "identifier.label", 0),
        ]
        let categories: [(Set<String>, String)] = [
            (BASICKeywords.control, "keyword.control"),
            (BASICKeywords.declaration, "keyword.declaration"),
            (BASICKeywords.io, "keyword.io"),
            (BASICKeywords.graphics, "keyword.graphics"),
            (BASICKeywords.options, "keyword.option"),
            (BASICKeywords.types, "keyword.type"),
            (BASICKeywords.functions, "predefined"),
        ]
        for (words, scope) in categories where !words.isEmpty {
            // Longest first, so `LINE INPUT` wins over `LINE`; escaped, for
            // the `$` in `LEFT$`.
            let alternatives = words.sorted { $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            rules.append((#"(?i)(?<![A-Za-z0-9_$%#.])(?:"# + alternatives + #")(?![A-Za-z0-9_$%#])"#, scope, 0))
        }
        rules.append((#"\b[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\b"#, "number", 0))
        return RegexSyntaxHighlighter(
            rules: rules.compactMap { try? RegexHighlightRule(pattern: $0.0, scope: $0.1, captureGroup: $0.2) },
            fallbackScope: "source.basic"
        )
    }()

    // MARK: Themes

    /// Studio's theme, in the colors Monaco drew it with: `vs-dark`, `vs` and
    /// `hc-black`'s token colors, so switching editors changes nothing a
    /// reader sees.
    static func theme(for theme: EditorTheme) -> SwiftyCodeEditor.EditorTheme {
        let colors: (text: UInt32, background: UInt32, selection: UInt32, caret: UInt32,
                     keyword: UInt32, comment: UInt32, string: UInt32, number: UInt32)
        switch theme {
        case .dark:
            colors = (0xD4D4D4, 0x1E1E1E, 0x264F78, 0x75BEFF, 0x569CD6, 0x6A9955, 0xCE9178, 0xB5CEA8)
        case .light:
            colors = (0x1F1F1F, 0xFFFFFF, 0xADD6FF, 0x005FB8, 0x0000FF, 0x008000, 0xA31515, 0x098658)
        case .highContrast:
            colors = (0xFFFFFF, 0x000000, 0x264F78, 0xFFFFFF, 0x569CD6, 0x7CA668, 0xCE9178, 0xB5CEA8)
        }
        func style(_ value: UInt32) -> TextStyle { TextStyle(foreground: color(value)) }
        return SwiftyCodeEditor.EditorTheme(
            name: theme.label,
            defaultStyle: style(colors.text),
            tokenStyles: [
                "keyword": style(colors.keyword),
                "comment": style(colors.comment),
                "string": style(colors.string),
                "number": style(colors.number),
            ],
            background: color(colors.background),
            selectionBackground: color(colors.selection),
            caret: color(colors.caret)
        )
    }

    private static func color(_ value: UInt32) -> EditorColor {
        EditorColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

#else
import ActiveUI
import ActiveUICoreEditor
import BASICCore
import CoreGraphics

/// The program editor on iPhone and iPad: `AUICoreSourceEditor`, which draws
/// through ActiveUI's canvas and so runs where SwiftyCodeEditor's AppKit text
/// engine cannot. Driven by the same ``EditorRenderInput``.
///
/// BASIC is colored by CodeEditorCore's `basic` grammar. Not yet here, and on
/// the Mac: find, and the breakpoint gutter.
@MainActor
final class SourceEditorAUI {
    /// The editor, to put in a layout.
    let editor: AUICoreSourceEditor
    /// Called with the whole text after each edit.
    var onTextChange: ((String) -> Void)?
    /// Called with a 1-based line when its gutter is clicked; not yet wired
    /// on iOS.
    var onToggleBreakpoint: ((Int) -> Void)?
    /// What was last drawn.
    private(set) var drawn: EditorRenderInput?

    init() {
        editor = AUICoreSourceEditor(text: "", language: "basic")
        editor.onChange = { [weak self] text in self?.onTextChange?(text) }
    }

    /// Brings the editor up to `input`, changing only what differs.
    func sync(_ input: EditorRenderInput) {
        let old = drawn
        // Against the editor's own text, which typing changes without a sync.
        if editor.text != input.text {
            editor.text = input.text
        }
        if input.isReadOnly != old?.isReadOnly {
            editor.isEditable = !input.isReadOnly
        }
        if input.showsLineNumbers != old?.showsLineNumbers {
            editor.showsLineNumbers = input.showsLineNumbers
        }
        if input.fontSize != old?.fontSize {
            editor.fontSize = CGFloat(input.fontSize)
        }
        if input.executionLine != old?.executionLine, let line = input.executionLine {
            editor.scroll(toLine: line)
        }
        drawn = input
    }
}
#endif
