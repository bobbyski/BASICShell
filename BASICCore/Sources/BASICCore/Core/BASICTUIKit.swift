//
//  BASICTUIKit.swift
//  BASICCore
//
//  TUIKit presented to BASIC as pseudo classes — phases 2 and 3 of
//  TUIKIT_PLAN.md.
//
//      let app = TUIApp()
//      let win = TUIWindow("Save changes?")
//      let row = TUIStack("h")
//      let ok  = TUIButton("Save")
//      ok.onclick("Saved")
//      row.add(ok)
//      win.add(row)
//      app.run(win)
//
//      function Saved()
//          app.stop()
//      end function
//
//  The binding lives in BASICCore rather than in either host, so one BASIC
//  program runs in both (TUIKIT_PLAN.md §5). What stays host-specific is only
//  where the cells go — see ``BASICTUIPresentationHost``.
//

import Foundation
import TUIKit
import TUIBoards
import TUIDiagram

// MARK: - The host seam

/// Supplies the surface a TUI application draws on.
///
/// The whole of what differs between hosts: BASICShell returns `ANSIDriver()`,
/// BASICStudio will return a driver over its console, and a headless host
/// returns TUIKit's `HeadlessDriver` — which is how this can be tested without
/// a terminal.
public protocol BASICTUIPresentationHost: BASICHost {
    /// The driver a TUI application should run on, or `nil` where there is no
    /// surface to draw to.
    ///
    /// Deliberately not `@MainActor`: constructing a driver needs no isolation,
    /// and requiring it made the host itself un-sendable at the one place the
    /// binding uses it.
    func makeTUIDriver() -> (any TerminalDriver)?
}

// MARK: - The registry

/// The live TUIKit objects, by handle.
///
/// `@MainActor` because every TUIKit view is, and a separate class rather than
/// fields on `BASICRuntime` for the same reason: the runtime is not main-actor
/// isolated and cannot hold them.
@MainActor
final class BASICTUIRegistry {
    static let shared = BASICTUIRegistry()
    private init() {}

    /// Views by handle. `TUIView` is a class, so these are the real objects.
    var views: [Int: TUIView] = [:]
    /// Applications by handle.
    var apps: [Int: App] = [:]
    /// Windows by handle.
    var windows: [Int: Window] = [:]
    /// Menu bars by handle. Not views a program adds to a stack — a bar is
    /// attached to a window and lays itself across the top.
    var menus: [Int: MenuBar] = [:]
    /// What each dialog will be, when it is shown.
    ///
    /// A description rather than a `Dialog`, because TUIKit takes a dialog's
    /// message at construction and offers no setter — so the real object cannot
    /// exist until the program has finished saying what it wants, which is at
    /// `show`. The same reason `TUIApp` holds no `App` until `run`.
    var dialogs: [Int: BASICTUIDialogSpec] = [:]
    /// Columns described for a board that has not been built yet.
    var boardColumns: [Int: [BoardColumn]] = [:]
    /// Nodes and edges described for a diagram that has not been built yet.
    var diagramNodes: [Int: [DiagramNode]] = [:]
    var diagramEdges: [Int: [DiagramEdge]] = [:]
    /// Steps described for a wizard that has not been built yet.
    var wizardSteps: [Int: [Wizard.Step]] = [:]
    /// The handler a wizard calls when it finishes.
    var wizardFinish: [Int: String] = [:]
    /// Rows described for a master-detail that has not been built yet.
    var masterRows: [Int: [SidebarItem]] = [:]
    /// Detail panes by row, per master-detail handle — see `detail`.
    var detailViews: [Int: [Int: TUIView]] = [:]
    /// Tree nodes by path, per tree handle — see `addnode`.
    var treeNodes: [Int: [String: TreeNode]] = [:]
    /// The stack inside each panel, which is what its children go into.
    var panelStacks: [Int: StackView] = [:]
    /// The menu a `TUIMenu` is currently building items into.
    var openMenus: [Int: Menu] = [:]
    /// Windows that have a menu bar, and so have one row less to give.
    var windowsWithMenuBars: Set<Int> = []
    /// Windows that have a status strip, and so have one row less at the foot.
    var windowsWithStatusBars: Set<Int> = []
    /// Backing store for ``floatingWindows`` (see BASICTUIChrome.swift).
    var floatingWindowStorage: [Int: FloatingWindow] = [:]
    /// The handle most recently allocated, so a builder can reach it.
    var lastAllocatedID = 0
    /// A theme set before the app existed, applied when it does.
    ///
    /// A program configures its application before running it — that is the
    /// natural order to write — but `TUIApp` holds no `App` until `run`,
    /// because TUIKit takes the driver at construction. So everything said to
    /// the application early is remembered here and applied at `run`.
    var pendingTheme: Theme?
    /// Timers asked for before the app existed.
    var pendingTimers: [(seconds: Double, handler: String)] = []

    /// One-shot work asked for before there was an application to ask.
    var pendingSchedules: [(milliseconds: Int, handler: String)] = []

    /// Preferences stores, aligned forms and paged dialogs — see
    /// BASICTUIPreferences.swift.
    var preferences: [Int: Preferences] = [:]
    var formFields: [Int: [(title: String, view: TUIView)]] = [:]
    var preferencesDialogs: [Int: PreferencesDialog] = [:]

    /// Tab titles, in order. A `TabView` keeps its own privately, so a program
    /// that wants to name the page it just switched to has nowhere to read.
    var tabTitles: [Int: [String]] = [:]
    /// Windows to present once the app is up.
    var pendingPresents: [Int] = []
    /// The BASIC function each control calls, by handle.
    var handlers: [Int: String] = [:]
    /// The first control that can take focus, per window, in the order the
    /// program added them.
    ///
    /// A window opens with nothing focused otherwise, so the first keystroke
    /// goes nowhere and the program looks hung. Tab still moves focus after
    /// that; this only decides where it starts.
    var pendingFirstResponder: TUIView?
    /// What each handle is, for error messages that can name it.
    var kinds: [Int: String] = [:]

    private var nextID = 1

    func allocate(kind: String) -> Int {
        let id = nextID
        nextID += 1
        kinds[id] = kind
        lastAllocatedID = id
        return id
    }

    /// Everything a finished application leaves behind.
    ///
    /// Called when `run` returns rather than left to accumulate: a program that
    /// opens a dialog in a loop would otherwise retain every window it ever
    /// showed, and the handles are dead the moment the app stops.
    func releaseAll() {
        pendingFirstResponder = nil
        windowsWithMenuBars.removeAll()
        windowsWithStatusBars.removeAll()
        floatingWindowStorage.removeAll()
        pendingTheme = nil
        pendingTimers.removeAll()
        pendingPresents.removeAll()
        views.removeAll()
        menus.removeAll()
        dialogs.removeAll()
        openMenus.removeAll()
        panelStacks.removeAll()
        treeNodes.removeAll()
        detailViews.removeAll()
        masterRows.removeAll()
        wizardSteps.removeAll()
        wizardFinish.removeAll()
        boardColumns.removeAll()
        diagramNodes.removeAll()
        diagramEdges.removeAll()
        apps.removeAll()
        windows.removeAll()
        handlers.removeAll()
        kinds.removeAll()
    }
}

/// What a `TUIDialog` will be when it is shown.
struct BASICTUIDialogSpec {
    var title: String
    var message: String = ""
    var buttons: [(title: String, handler: String?)] = []
}

/// A vertical stack whose scroll height can be declared.
///
/// A `ScrollView` measures its document by `intrinsicContentSize`, and a stack
/// of rows pinned with `height` has none of its own — the pinned rows carry a
/// minimum and maximum, not an intrinsic. So the document reported zero height
/// and nothing scrolled.
///
/// The gallery's own `ChartsColumn` solves it the same way: declare the total
/// and let the scroll view believe it.
@MainActor
final class BASICTUIDocumentStack: StackView {
    var declaredHeight = 0

    override var intrinsicContentSize: Size? {
        declaredHeight > 0 ? Size(width: 0, height: declaredHeight) : super.intrinsicContentSize
    }
}

/// Runs `body` on the main actor, from wherever the interpreter happens to be.
///
/// TUIKit is main-actor isolated. The interpreter is not isolated at all, and —
/// this is the part that matters — an ordinary `RUN` executes on a **worker
/// lane**, not the main thread. So neither `assumeIsolated` alone nor a plain
/// main-thread assumption is enough.
///
/// On the main thread `assumeIsolated` is correct and free. Off it, the work is
/// posted to the main actor and this thread blocks until it finishes — which is
/// safe precisely because the blocked thread is not the main one, and because
/// `runProgramSynchronously` leaves the main thread pumping its run loop rather
/// than parked in a semaphore.
func withTUIRegistry<Value: Sendable>(
    _ body: @escaping @MainActor @Sendable (BASICTUIRegistry) throws -> Value
) throws -> Value {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated { try body(BASICTUIRegistry.shared) }
    }
    // The main thread is waiting for this worker and will not service the main
    // actor until it is told to. Asked for before posting, or the Task below
    // would never run.
    BASICMainActorPump.request()
    let box = BASICTUIResultBox<Value>()
    let finished = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do {
            box.value = try body(BASICTUIRegistry.shared)
        } catch {
            box.error = error
        }
        finished.signal()
    }
    finished.wait()
    if let error = box.error { throw error }
    guard let value = box.value else {
        throw BASICError.runtime("A TUI operation finished without a result")
    }
    return value
}

/// Carries a result across the actor hop above.
final class BASICTUIResultBox<Value>: @unchecked Sendable {
    var value: Value?
    var error: Error?
}

// MARK: - Construction

extension BASICRuntime {

    /// Builds a TUI pseudo-class handle.
    func tuiObject(typeName: String, arguments: [BASICValue]) throws -> BASICValue {
        let title = arguments.first?.string?.description ?? ""
        let id = try withTUIRegistry { registry -> Int in
            let id = registry.allocate(kind: typeName)
            switch typeName.uppercased() {
            case "TUIAPP":
                // No `App` yet. TUIKit takes the driver at construction and has
                // no way to swap it later, and the driver comes from the host
                // at `run` time — so the handle is an empty seat until then.
                break

            case "TUIWINDOW":
                let window = Window()
                window.fillsScreen = true
                registry.windows[id] = window

            case "TUISTACK":
                // "h" or "v", defaulting to vertical: a column of controls is
                // the shape a form takes, and the one a program writing its
                // first window almost always means.
                //
                // A vertical stack is the document-capable one, so it can be
                // given a scroll height with `contentheight`.
                if title.lowercased().hasPrefix("h") {
                    registry.views[id] = HStack(spacing: 1)
                } else {
                    let column = BASICTUIDocumentStack(axis: .vertical, spacing: 0)
                    registry.views[id] = column
                }

            case "TUIBUTTON":
                registry.views[id] = Button(title)

            case "TUITOGGLE":
                registry.views[id] = ToggleButton(title)

            case "TUIRADIO":
                // Options at construction, as TUIKit takes them — so this is
                // the one family that reads every argument rather than just
                // the first: TUIRadio("Ask", "Allow", "Block").
                registry.views[id] = RadioGroup(Self.tuiStrings(arguments), selectedIndex: 0)

            case "TUIBOARD":
                // Columns and cards are fixed at construction, so the handle
                // collects them and the board is built where it is added — the
                // pattern TUIDialog, TUIMasterDetail and TUIWizard all use.
                registry.boardColumns[id] = []

            case "TUIDIAGRAM":
                registry.diagramNodes[id] = []
                registry.diagramEdges[id] = []

            case "TUILOG":
                // The view watches LogStore.shared; the logger has to be fed
                // into that store before anything appears.
                TUILogger.shared.add(LogStore.shared)
                TUILogger.shared.level = .debug
                registry.views[id] = LogView()

            case "TUISPARKLINE":
                registry.views[id] = Sparkline(values: Self.tuiNumbers(arguments))

            case "TUIBARCHART":
                registry.views[id] = BarChart()

            case "TUILINECHART":
                registry.views[id] = LineChart()

            case "TUIPIECHART":
                registry.views[id] = PieChart()

            case "TUISCATTER":
                registry.views[id] = ScatterChart()

            case "TUITIMELINE":
                registry.views[id] = TimelineChart()

            case "TUIIMAGE":
                registry.views[id] = ImageView(caption: title)

            case "TUICANVAS":
                // No drawing closure: a Canvas paints through
                // `(Painter, Rect) -> Void`, which BASIC has no way to supply.
                // The control is bound so a program can place one; what it
                // draws waits on a callback that can paint.
                registry.views[id] = Canvas()

            case "TUIWIZARD":
                registry.wizardSteps[id] = []

            case "TUIVIEWTHATFITS":
                // Candidates widest-first; the first that fits is shown.
                let candidates = arguments.compactMap { value -> TUIView? in
                    guard case .systemObject(_, let viewID) = value else { return nil }
                    return registry.views[viewID]
                }
                registry.views[id] = ViewThatFits(axis: .horizontal, candidates: candidates)

            case "TUIPAGES":
                let pages = arguments.compactMap { value -> TUIView? in
                    guard case .systemObject(_, let viewID) = value else { return nil }
                    return registry.views[viewID]
                }
                registry.views[id] = PageView(pages: pages)

            case "TUIACCORDION":
                registry.views[id] = Accordion()

            case "TUIFLOW":
                registry.views[id] = FlowStack(spacing: 1)

            case "TUITOOLBOX":
                // Axis, then alternating glyph/caption pairs.
                let words = Array(Self.tuiStrings(arguments).dropFirst())
                var tools: [Toolbox.Tool] = []
                var index = 0
                while index < words.count {
                    tools.append(Toolbox.Tool(
                        glyph: words[index].first ?? "?",
                        caption: index + 1 < words.count ? words[index + 1] : ""
                    ))
                    index += 2
                }
                registry.views[id] = Toolbox(
                    axis: title.lowercased().hasPrefix("v") ? .vertical : .horizontal,
                    tools: tools
                )

            case "TUISCROLLER":
                registry.views[id] = Scroller(
                    axis: title.lowercased().hasPrefix("h") ? .horizontal : .vertical,
                    span: ScrollSpan(
                        offset: 0,
                        viewport: Self.tuiInt(arguments, 1) ?? 8,
                        content: Self.tuiInt(arguments, 2) ?? 30
                    )
                )

            case "TUISPLIT":
                // Both panes at construction — SplitView has no way to set one
                // afterwards.
                guard case .systemObject(_, let firstID) = arguments.count > 1
                        ? arguments[1] : .empty,
                      case .systemObject(_, let secondID) = arguments.count > 2
                        ? arguments[2] : .empty,
                      let first = registry.views[firstID],
                      let second = registry.views[secondID] else {
                    throw BASICError.runtime("TUISplit expects an axis and two views")
                }
                let split = SplitView(
                    axis: title.lowercased().hasPrefix("v") ? .vertical : .horizontal,
                    first: first, second: second
                )
                // Minimums keep the divider sane through the zero-size first
                // layout a freshly built tab goes through.
                split.minimumFirstLength = 8
                split.minimumSecondLength = 8
                registry.views[id] = split

            case "TUISCROLL":
                guard let documentArgument = arguments.first,
                      case .systemObject(_, let documentID) = documentArgument,
                      let document = registry.views[documentID] else {
                    throw BASICError.runtime("TUIScroll expects a document view")
                }
                // Fitted to the viewport width, which is what makes a
                // declared height work at all: a document stack reports
                // `Size(width: 0, height: total)`, and without this the scroll
                // view lays the document out zero-wide and draws nothing.
                //
                // That was the whole of the earlier "ScrollView binds but does
                // not render" — one flag, and the gallery sets it too.
                let scroll = ScrollView(document: document)
                scroll.fitsDocumentWidth = true
                registry.views[id] = scroll

            case "TUIDISCLOSURE":
                registry.views[id] = DisclosureGroup(
                    title, isExpanded: (arguments.count > 1 ? arguments[1].truthy : true)
                )

            case "TUIRIBBON":
                registry.views[id] = Ribbon()

            case "TUISYNTAX":
                registry.views[id] = SyntaxTextView(
                    text: title,
                    language: (arguments.count > 1
                        ? arguments[1].string?.description : nil) ?? "swift"
                )

            case "TUIMARKDOWN":
                registry.views[id] = MarkdownView(markdown: title)

            case "TUIRICH":
                registry.views[id] = RichText(markup: title)

            case "TUIMASTERDETAIL":
                // Nothing built yet. `MasterDetail` fixes its rows at
                // construction and offers no way to add one after, so the
                // handle collects a description and the control is built when
                // it is added to something — the same shape as TUIDialog,
                // which cannot exist until `show`.
                registry.masterRows[id] = []

            case "TUICOLLECTION":
                // Same shape, and the gallery's builder is `{ Label($0) }` — so
                // that is exactly what this is, with no way to be anything else
                // until a BASIC closure can return a view.
                registry.views[id] = CollectionView(sections: []) { Label($0) }

            case "TUITREE":
                registry.views[id] = TreeView(roots: [])
                registry.treeNodes[id] = [:]

            case "TUIDIRTREE":
                let directory = DirectoryTree(root: title.isEmpty
                    ? FileManager.default.currentDirectoryPath : title)
                directory.expandRoot()
                registry.views[id] = directory

            case "TUIBROWSER":
                registry.views[id] = Browser(fileSystemRoot: title.isEmpty
                    ? FileManager.default.currentDirectoryPath : title)

            case "TUIPATH":
                registry.views[id] = PathControl(path: title)

            case "TUIFAVORITES":
                registry.views[id] = TUIFavorites()

            case "TUISEARCH":
                registry.views[id] = SearchField(placeholder: title.isEmpty ? "Search" : title)

            case "TUIPASTE":
                registry.views[id] = PasteButton(title.isEmpty ? "&Paste" : title) { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }

            case "TUITOKENS":
                // Placeholder first, tokens after — BASIC's variadic tail has
                // to be last.
                registry.views[id] = TokenField(
                    tokens: Array(Self.tuiStrings(arguments).dropFirst()),
                    placeholder: title
                )

            case "TUICOMPLETIONS":
                // Attaches to a plain field, or to a token field's inner one —
                // and on a token field, accepting mints, as the gallery does.
                guard case .systemObject(_, let targetID) = arguments.first,
                      let target = registry.views[targetID] else {
                    throw BASICError.runtime("TUICompletions expects a field")
                }
                if let tokens = target as? TokenField {
                    let list = CompletionList(for: tokens.field)
                    list.onAccept = { [weak tokens] accepted in tokens?.mint(accepted) }
                    registry.views[id] = list
                } else if let field = target as? TextField {
                    registry.views[id] = CompletionList(for: field)
                } else {
                    throw BASICError.runtime("TUICompletions expects a field")
                }

            case "TUIRANGE":
                registry.views[id] = RangeSlider(
                    lower: Self.tuiInt(arguments, 0) ?? 0,
                    upper: Self.tuiInt(arguments, 1) ?? 100,
                    in: (Self.tuiInt(arguments, 2) ?? 0)...(Self.tuiInt(arguments, 3) ?? 100),
                    minimumGap: Self.tuiInt(arguments, 4) ?? 0
                )

            case "TUIDATE":
                // "date" gives YYYY-MM-DD segments with a calendar popup;
                // "calendar" is the month grid itself.
                registry.views[id] = DatePicker(
                    mode: title.lowercased().hasPrefix("c") ? .calendar
                        : title.lowercased().hasPrefix("t") ? .time : .date
                )

            case "TUICOLOR":
                registry.views[id] = ColorPicker()

            case "TUIMATRIX":
                // Columns and mode first, titles after, because BASIC's
                // variadic tail has to be last: TUIMatrix(4, "highlight",
                // "Mon", "Tue", …).
                let titles = Self.tuiStrings(arguments).dropFirst()
                registry.views[id] = Matrix(
                    titles: Array(titles),
                    columns: max(1, Self.tuiInt(arguments, 0) ?? 1),
                    mode: (arguments.count > 1
                        ? arguments[1].string?.description ?? "" : "")
                        .lowercased().hasPrefix("h") ? .highlight : .radio
                )

            case "TUICOMBO":
                registry.views[id] = ComboBox(items: Self.tuiStrings(arguments))

            case "TUIPOPUP":
                registry.views[id] = PopUpButton(
                    items: Self.tuiStrings(arguments), selectedIndex: 0
                )

            case "TUISLIDER":
                registry.views[id] = Slider(
                    value: Self.tuiInt(arguments, 0) ?? 0,
                    in: (Self.tuiInt(arguments, 1) ?? 0)...(Self.tuiInt(arguments, 2) ?? 100)
                )

            case "TUISTEPPER":
                registry.views[id] = Stepper(
                    value: Self.tuiInt(arguments, 0) ?? 0,
                    in: (Self.tuiInt(arguments, 1) ?? 0)...(Self.tuiInt(arguments, 2) ?? 10)
                )

            case "TUILEVEL":
                registry.views[id] = LevelIndicator(
                    value: Self.tuiInt(arguments, 0) ?? 0,
                    maximum: Self.tuiInt(arguments, 1) ?? 5
                )

            case "TUIPROGRESS":
                // "bar" is determinate; "spinner" advances a glyph per tick and
                // is what an App timer drives.
                registry.views[id] = ProgressIndicator(
                    style: title.lowercased().hasPrefix("s") ? .spinner : .bar,
                    value: (arguments.count > 1 ? arguments[1].number : nil) ?? 0
                )

            case "TUISEGMENTS":
                registry.views[id] = SegmentedControl(Self.tuiStrings(arguments), selectedIndex: 0)

            case "TUILABEL":
                registry.views[id] = Label(title)

            case "TUIFIELD":
                registry.views[id] = TextField(placeholder: title)

            case "TUILIST":
                registry.views[id] = ListView()

            case "TUITABLE":
                // Columns arrive later, through `column`. TableView wants them
                // at construction, so it starts with one placeholder that the
                // first `column` call replaces — a table with no columns at all
                // draws nothing and looks like a failure to build.
                registry.views[id] = TableView(columns: [])

            case "TUICHECK":
                registry.views[id] = Checkbox(title)

            case "TUITEXT":
                registry.views[id] = TextView(text: title)

            case "TUIGAUGE":
                // value, then "bar" | "ring" | "dial", then a label.
                let gauge = Gauge(
                    value: arguments.first?.number ?? 0,
                    in: 0...100,
                    style: {
                        switch (arguments.count > 1
                            ? arguments[1].string?.description ?? "" : "").lowercased() {
                        case "ring": return .ring
                        case "dial": return .dial
                        default: return .bar
                        }
                    }()
                )
                if arguments.count > 2, let caption = arguments[2].string?.description {
                    gauge.label = caption
                }
                registry.views[id] = gauge

            case "TUIMENU":
                // The bar, not a menu: a program adds menus to it by title.
                registry.menus[id] = MenuBar()

            case "TUIDIALOG":
                registry.dialogs[id] = BASICTUIDialogSpec(title: title)

            default:
                guard try BASICRuntime.tuiChromeObject(
                    typeName: typeName, title: title, registry: registry
                ) || BASICRuntime.tuiPreferencesObject(
                    typeName: typeName, title: title, registry: registry
                ) else {
                    throw BASICError.runtime("Unknown TUI class \(typeName)")
                }
            }
            return id
        }
        return .systemObject(typeName, id)
    }

    /// Dispatches a method on a TUI handle.
    ///
    /// - Parameter invokeHandler: Calls a BASIC function by name. Passed in
    ///   rather than reached for, because the runtime has no way to call into
    ///   the interpreter and a control's whole purpose is to do exactly that.
    func callTUIMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue],
        presentationHost: (any BASICTUIPresentationHost)?,
        invokeHandler: @escaping (String, [BASICValue]) throws -> Void
    ) throws -> BASICValue {
        let name = method.uppercased()

        // `run` is the one that blocks, and the one that needs a driver and an
        // event loop, so it is handled before the ordinary property setters.
        if name == "RUN" {
            return try runTUIApplication(
                appID: id,
                arguments: arguments,
                presentationHost: presentationHost,
                invokeHandler: invokeHandler
            )
        }

        return try withTUIRegistry { registry in
            // A local rather than a nested `func`, which would not inherit the
            // closure's main-actor isolation and so could not read the registry.
            let subject = registry.views[id]
            func view() throws -> TUIView {
                guard let subject else {
                    throw BASICError.runtime("\(typeName) is not a view")
                }
                return subject
            }

            // Preferences handles are dispatched before the control switch,
            // not after it. Their method names overlap the controls' — a
            // store's `text` is not a label's, a form's `field` is not a
            // TUIField — and a shared switch would hand the call to whichever
            // case happens to come first.
            if let answer = try BASICRuntime.callTUIPreferencesMethod(
                typeName: typeName, id: id, method: name,
                arguments: arguments, registry: registry
            ) {
                return answer
            }

            switch name {
            case "ADD":
                guard let first = arguments.first,
                      case .systemObject(_, let childID) = first else {
                    throw BASICError.runtime("\(typeName).add expects a TUI view")
                }
                // A menu bar is attached, not stacked: it anchors itself across
                // the top of the window rather than taking a place in a column.
                // Checked before the view lookup below, because a bar is not in
                // the view table and would be rejected as "not a TUI view".
                // A status strip owns the last row, the way a menu bar owns the
                // first. Filling the window with it would hide everything else.
                if let window = registry.windows[id],
                   let strip = registry.views[childID] as? StatusBar {
                    strip.anchors = AnchorSet(leading: 0, trailing: 0, bottom: 0, height: 1)
                    window.addSubview(strip)
                    registry.windowsWithStatusBars.insert(id)
                    return .empty
                }
                if let window = registry.windows[id], let bar = registry.menus[childID] {
                    bar.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, height: 1)
                    window.addSubview(bar)
                    registry.windowsWithMenuBars.insert(id)
                    // A shell window hands Esc to an open dropdown rather than
                    // quitting under it, so it has to know which bar to ask.
                    (window as? BASICTUIShellWindow)?.menuBar = bar
                    // Anything already filling the window is covering the bar.
                    // Push it down a row rather than leaving a menu that is
                    // drawn and then painted over — which looks like a menu bar
                    // that does not work.
                    for existing in window.subviews where existing !== bar {
                        existing.anchors = AnchorSet(leading: 0, trailing: 0, top: 1, bottom: 0)
                    }
                    return .empty
                }
                // A master-detail is described, then built here — the first
                // and only place it is consumed.
                if let columns = registry.boardColumns[childID], registry.views[childID] == nil {
                    let board = BoardView(columns: columns)
                    if let handler = registry.handlers[childID] {
                        board.onCardMoved = { _, _, _, _ in
                            BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                        }
                    }
                    registry.views[childID] = board
                }
                if let nodes = registry.diagramNodes[childID], registry.views[childID] == nil {
                    let diagram = DiagramView(
                        nodes: nodes, edges: registry.diagramEdges[childID] ?? []
                    )
                    if let handler = registry.handlers[childID] {
                        diagram.onSelectionChanged = { _ in
                            BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                        }
                    }
                    registry.views[childID] = diagram
                }
                if let steps = registry.wizardSteps[childID], registry.views[childID] == nil {
                    let wizard = Wizard(steps: steps)
                    if let handler = registry.wizardFinish[childID] {
                        wizard.onFinish = {
                            BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                        }
                    }
                    registry.views[childID] = wizard
                }
                if let rows = registry.masterRows[childID], registry.views[childID] == nil {
                    registry.views[childID] = MasterDetail(items: rows) { index in
                        BASICTUIRegistry.shared.detailViews[childID]?[index] ?? Label("")
                    }
                }
                guard let child = registry.views[childID] else {
                    throw BASICError.runtime("\(typeName).add expects a TUI view")
                }
                // A panel and a floating window are frames: things go *inside*
                // them, not on top of them. Adding to the view itself would put
                // the child over the border.
                if let window = registry.floatingWindows[id] {
                    child.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
                    window.content.addSubview(child)
                    return .empty
                }
                if let stack = registry.panelStacks[id] {
                    stack.addSubview(child)
                    return .empty
                }
                if let disclosure = registry.views[id] as? DisclosureGroup {
                    child.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
                    disclosure.content.addSubview(child)
                    return .empty
                }
                if let window = registry.windows[id] {
                    // Fill the window unless the program has said otherwise. A
                    // view added with no anchors gets zero size and the window
                    // comes up blank — which looks like the app failing to
                    // start rather than a layout that was never given.
                    //
                    // One row down when there is a menu bar, which owns the top.
                    let top = registry.windowsWithMenuBars.contains(id) ? 1 : 0
                    let bottom = registry.windowsWithStatusBars.contains(id) ? 1 : 0
                    child.anchors = AnchorSet(
                        leading: 0, trailing: 0, top: top, bottom: bottom
                    )
                    window.addSubview(child)
                } else {
                    let parent = try view()
                    // A stack lays its children out along its axis, but only
                    // once they have a height to be laid out with.
                    if parent is StackView, child.frame.size.height == 0 {
                        child.frame = Rect(x: 0, y: 0, width: 1, height: 1)
                    }
                    parent.addSubview(child)
                }
                return .empty

            case "TITLE", "TEXT":
                guard let value = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).\(method) expects a string")
                }
                if let label = try? view() as? Label {
                    label.text = value
                } else if let button = try? view() as? Button {
                    button.title = value
                } else if let field = try? view() as? TextField {
                    // `text` is private(set); `setText` is the door.
                    field.setText(value)
                }
                return .empty

            case "COLUMN":
                guard let table = try view() as? TableView else {
                    throw BASICError.runtime("\(typeName) has no columns")
                }
                guard let heading = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).column expects a title")
                }
                // An optional second argument fixes the column's width, as the
                // gallery's Size and Kind columns do.
                if let width = Self.tuiInt(arguments, 1), width > 0 {
                    table.columns.append(TableColumn(heading, width: .fixed(width)))
                } else {
                    table.columns.append(TableColumn(heading))
                }
                return .empty

            case "ADDROW":
                guard let table = subject as? TableView else {
                    // A sidebar's `addrow` — icon, title, subtitle.
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                // Short rows are padded rather than refused, as RichTable does:
                // a table gaining a column should not turn every existing
                // addrow into a runtime error halfway through a program.
                var row = arguments.map { $0.string?.description ?? Self.tuiPlain($0) }
                while row.count < table.columns.count { row.append("") }
                table.rows.append(row)
                return .empty

            case "MENU":
                guard let bar = registry.menus[id] else {
                    throw BASICError.runtime("\(typeName) is not a menu bar")
                }
                guard let heading = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).menu expects a title")
                }
                let menu = Menu(heading)
                bar.addMenu(menu)
                // Items go into the menu most recently opened, so a program
                // reads top to bottom: menu "File", item, item, menu "Edit".
                registry.openMenus[id] = menu
                return .empty

            case "ITEM":
                guard let menu = registry.openMenus[id] else {
                    throw BASICError.runtime("\(typeName).item needs a menu — call menu first")
                }
                guard let label = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).item expects a title")
                }
                let handler = arguments.count > 1
                    ? arguments[1].string?.description
                    : nil
                // An optional third argument travels to the handler, so one
                // function can serve a whole menu — the shape of a Swift item
                // whose closure captures what it applies.
                let carried = arguments.count > 2 ? [arguments[2]] : []
                _ = menu.addItem(label) {
                    guard let handler else { return }
                    BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler, with: carried)
                }
                return .empty

            case "SEPARATOR":
                guard let menu = registry.openMenus[id] else {
                    throw BASICError.runtime("\(typeName).separator needs a menu")
                }
                menu.addSeparator()
                return .empty

            case "MESSAGE":
                guard let dialog = registry.dialogs[id] else {
                    throw BASICError.runtime("\(typeName) is not a dialog")
                }
                guard let body = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).message expects text")
                }
                registry.dialogs[id]?.message = body
                _ = dialog
                return .empty

            case "ADDBUTTON":
                guard let dialog = registry.dialogs[id] else {
                    throw BASICError.runtime("\(typeName) is not a dialog")
                }
                guard let label = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).addbutton expects a title")
                }
                let handler = arguments.count > 1 ? arguments[1].string?.description : nil
                registry.dialogs[id]?.buttons.append((title: label, handler: handler))
                _ = dialog
                return .empty

            case "CHECKED":
                guard let box = try view() as? Checkbox else {
                    throw BASICError.runtime("\(typeName) has nothing to check")
                }
                // With an argument it sets; without one it reads. A program
                // asking "is it ticked?" and a program ticking it are the same
                // word in BASIC, and splitting them into `checked` and
                // `setchecked` buys nothing.
                if let wanted = arguments.first {
                    box.setChecked(wanted.truthy)
                    return .empty
                }
                return .boolean(box.isChecked)

            case "ONTOGGLE":
                if let toggle = subject as? ToggleButton {
                    guard let handler = arguments.first?.string?.description else {
                        throw BASICError.runtime("\(typeName).ontoggle expects a handler name")
                    }
                    registry.handlers[id] = handler
                    if registry.pendingFirstResponder == nil {
                        registry.pendingFirstResponder = toggle
                    }
                    toggle.onChange = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                guard let box = try view() as? Checkbox else {
                    throw BASICError.runtime("\(typeName) has nothing to toggle")
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).ontoggle expects a handler name")
                }
                registry.handlers[id] = handler
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = box
                }
                box.onChange = { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "ADDITEM":
                if registry.masterRows[id] != nil {
                    // icon, title, subtitle — the sidebar row shape.
                    let icon = arguments.first?.string?.description
                    registry.masterRows[id]?.append(
                        SidebarItem(
                            icon: icon.flatMap { $0.count == 1 ? $0.first : nil },
                            title: (arguments.count > 1
                                ? arguments[1].string?.description : nil) ?? (icon ?? ""),
                            subtitle: arguments.count > 2
                                ? arguments[2].string?.description : nil
                        )
                    )
                    return .empty
                }
                if let sidebar = subject as? SidebarList {
                    // icon, title, subtitle — the same row shape a master
                    // detail's `additem` takes, on the standalone list.
                    let icon = arguments.first?.string?.description
                    sidebar.items.append(
                        SidebarItem(
                            icon: icon.flatMap { $0.count == 1 ? $0.first : nil },
                            title: (arguments.count > 1
                                ? arguments[1].string?.description : nil) ?? (icon ?? ""),
                            subtitle: arguments.count > 2
                                ? arguments[2].string?.description : nil
                        )
                    )
                    return .empty
                }
                if let collection = subject as? CollectionView {
                    guard !collection.sections.isEmpty else {
                        throw BASICError.runtime(
                            "\(typeName).additem needs a section — call section first"
                        )
                    }
                    guard let text = arguments.first?.string?.description else {
                        throw BASICError.runtime("\(typeName).additem expects a title")
                    }
                    collection.sections[collection.sections.count - 1].items.append(text)
                    return .empty
                }
                if let favorites = subject as? TUIFavorites {
                    guard let itemTitle = arguments.first?.string?.description else {
                        throw BASICError.runtime("\(typeName).additem expects a title")
                    }
                    favorites.items.append(TUIFavorites.Item(title: itemTitle))
                    return .empty
                }
                guard let list = subject as? ListView else {
                    // A toolbar's `additem` — same word, different control.
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                guard let value = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).additem expects a string")
                }
                list.items.append(value)
                return .empty

            case "SELECTED":
                if let radio = subject as? RadioGroup {
                    return .number(Double(radio.selectedIndex ?? -1))
                }
                if let popUp = subject as? PopUpButton {
                    return .number(Double(popUp.selectedIndex ?? -1))
                }
                if let matrix = subject as? Matrix {
                    return .number(Double(matrix.selectedIndex ?? -1))
                }
                if let toolbox = subject as? Toolbox {
                    return .number(Double(toolbox.selectedIndex))
                }
                if let segments = subject as? SegmentedControl {
                    return .number(Double(segments.selectedIndex ?? -1))
                }
                if let table = try? view() as? TableView {
                    return .number(Double(table.selectedIndex ?? -1))
                }
                guard let list = subject as? ListView else {
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                // -1 rather than an error when nothing is selected: a program
                // asking "which row?" before the user has touched anything is
                // the ordinary case, not a mistake.
                return .number(Double(list.selectedIndex ?? -1))

            case "SELECTEDTEXT$", "SELECTEDTEXT":
                if let matrix = subject as? Matrix {
                    // Every selected title, in order — a highlight matrix has
                    // a *set*, and reporting only the first would lose what the
                    // control exists to show.
                    let chosen = matrix.selected.sorted().compactMap { index in
                        matrix.titles.indices.contains(index) ? matrix.titles[index] : nil
                    }
                    return .string(BASICString(chosen.joined(separator: ", ")))
                }
                guard let list = try view() as? ListView else {
                    throw BASICError.runtime("\(typeName) is not a list")
                }
                guard let index = list.selectedIndex, list.items.indices.contains(index) else {
                    return .string(BASICString(""))
                }
                return .string(BASICString(list.items[index]))

            case "VALUE$", "VALUE":
                // A label reads too. It has no *input*, but "what does it say
                // now?" is the obvious question to ask one after a handler has
                // been changing it, and refusing meant a handler that read a
                // label threw mid-frame — parking the error and never reaching
                // `app.stop()`, so the program hung instead of quitting.
                if let label = try? view() as? Label {
                    if let wanted = arguments.first?.string?.description {
                        label.text = wanted
                        return .empty
                    }
                    return .string(BASICString(label.text))
                }
                if let button = try? view() as? Button {
                    return .string(BASICString(button.title))
                }
                if let box = try? view() as? Checkbox {
                    return .boolean(box.isChecked)
                }
                if let search = subject as? SearchField {
                    return .string(BASICString(search.text))
                }
                if let slider = subject as? Slider {
                    return .number(Double(slider.value))
                }
                if let stepper = subject as? Stepper {
                    return .number(Double(stepper.value))
                }
                if let level = subject as? LevelIndicator {
                    return .number(Double(level.value))
                }
                if let gauge = try? view() as? Gauge {
                    if let wanted = arguments.first?.number {
                        gauge.setValue(wanted)
                        return .empty
                    }
                    return .number(gauge.value)
                }
                if let editor = try? view() as? SyntaxTextView {
                    if let wanted = arguments.first?.string?.description {
                        editor.setText(wanted)
                        return .empty
                    }
                    return .string(BASICString(editor.text))
                }
                if let editor = try? view() as? TextView {
                    if let wanted = arguments.first?.string?.description {
                        editor.setText(wanted)
                        return .empty
                    }
                    return .string(BASICString(editor.text))
                }
                guard let field = try view() as? TextField else {
                    throw BASICError.runtime("\(typeName) has no value to read")
                }
                return .string(BASICString(field.text))

            case "ONMOVE":
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onmove expects a handler name")
                }
                registry.handlers[id] = handler
                return .empty

            case "ONSELECT":
                if registry.diagramNodes[id] != nil || registry.boardColumns[id] != nil {
                    // Recorded now, wired when the control is built.
                    guard let handler = arguments.first?.string?.description else {
                        throw BASICError.runtime("\(typeName).onselect expects a handler name")
                    }
                    registry.handlers[id] = handler
                    return .empty
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onselect expects a handler name")
                }
                registry.handlers[id] = handler
                if let toolbox = subject as? Toolbox {
                    toolbox.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let matrix = subject as? Matrix {
                    matrix.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let popUp = subject as? PopUpButton {
                    popUp.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let radio = subject as? RadioGroup {
                    if registry.pendingFirstResponder == nil {
                        registry.pendingFirstResponder = radio
                    }
                    radio.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let segments = subject as? SegmentedControl {
                    if registry.pendingFirstResponder == nil {
                        registry.pendingFirstResponder = segments
                    }
                    segments.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let table = try? view() as? TableView {
                    if registry.pendingFirstResponder == nil {
                        registry.pendingFirstResponder = table
                    }
                    table.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                guard let list = subject as? ListView else {
                    // A tab strip's or a sidebar's selection.
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = list
                }
                list.onSelectionChanged = { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "ONCHANGE":
                if let span = subject as? RangeSlider {
                    guard let handler = arguments.first?.string?.description else {
                        throw BASICError.runtime("\(typeName).onchange expects a handler name")
                    }
                    registry.handlers[id] = handler
                    span.onValuesChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                guard let field = try view() as? TextField else {
                    throw BASICError.runtime("\(typeName) has no text to handle")
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onchange expects a handler name")
                }
                registry.handlers[id] = handler
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = field
                }
                field.onChanged = { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "COLUMN2":
                // A board column: id, title, and an optional WIP limit.
                guard registry.boardColumns[id] != nil else {
                    throw BASICError.runtime("\(typeName) has no columns")
                }
                guard let columnID = arguments.first?.string?.description,
                      arguments.count > 1,
                      let columnTitle = arguments[1].string?.description else {
                    throw BASICError.runtime("\(typeName).column2 expects an id and a title")
                }
                registry.boardColumns[id]?.append(
                    BoardColumn(
                        id: columnID,
                        title: columnTitle,
                        cards: [],
                        limit: Self.tuiInt(arguments, 2),
                        isCollapsed: arguments.count > 3 ? arguments[3].truthy : false
                    )
                )
                return .empty

            case "CARD":
                guard registry.boardColumns[id] != nil else {
                    throw BASICError.runtime("\(typeName) has no cards")
                }
                guard let cardID = arguments.first?.string?.description,
                      arguments.count > 1,
                      let cardTitle = arguments[1].string?.description else {
                    throw BASICError.runtime("\(typeName).card expects an id and a title")
                }
                guard var columns = registry.boardColumns[id], !columns.isEmpty else {
                    throw BASICError.runtime("\(typeName).card needs a column — call column2 first")
                }
                columns[columns.count - 1].cards.append(
                    BoardCard(
                        id: cardID,
                        title: cardTitle,
                        subtitle: arguments.count > 2 ? arguments[2].string?.description : nil
                    )
                )
                registry.boardColumns[id] = columns
                return .empty

            case "NODE":
                guard registry.diagramNodes[id] != nil else {
                    throw BASICError.runtime("\(typeName) has no nodes")
                }
                guard let nodeID = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).node expects an id")
                }
                registry.diagramNodes[id]?.append(
                    DiagramNode(
                        id: nodeID,
                        title: arguments.count > 1 ? arguments[1].string?.description : nil
                    )
                )
                return .empty

            case "EDGE":
                guard registry.diagramEdges[id] != nil else {
                    throw BASICError.runtime("\(typeName) has no edges")
                }
                guard let from = arguments.first?.string?.description,
                      arguments.count > 1,
                      let to = arguments[1].string?.description else {
                    throw BASICError.runtime("\(typeName).edge expects two node ids")
                }
                registry.diagramEdges[id]?.append(
                    DiagramEdge(
                        from: from, to: to,
                        label: arguments.count > 2 ? arguments[2].string?.description : nil
                    )
                )
                return .empty

            case "WRITE":
                // level, then the message. Not `log`: LOG is both the
                // logarithm and a statement keyword, so `entries.log(...)`
                // parses as LOG and fails with "Expected expression".
                let level = (arguments.first?.string?.description ?? "info").lowercased()
                let message = (arguments.count > 1
                    ? arguments[1].string?.description : nil) ?? ""
                switch level.first {
                case "d": TUILogger.shared.debug(message, category: "gallery")
                case "w": TUILogger.shared.warning(message, category: "gallery")
                case "e": TUILogger.shared.error(message, category: "gallery")
                case "n": TUILogger.shared.notice(message, category: "gallery")
                default: TUILogger.shared.info(message, category: "gallery")
                }
                TUILogger.shared.flush()
                // The view watches the store but does not poll it. Without
                // this the entries are recorded and the page stays empty,
                // which reads as logging that does not work.
                (subject as? LogView)?.reload()
                return .empty

            case "SERIES":
                // label, then the values — or x/y pairs for a scatter.
                let words = Self.tuiStrings(arguments)
                let numbers = Self.tuiNumbers(arguments)
                guard let label = words.first else {
                    throw BASICError.runtime("\(typeName).series expects a label")
                }
                if let bars = subject as? BarChart {
                    bars.series.append(BarChart.Series(label: label, values: numbers))
                    return .empty
                }
                if let lines = subject as? LineChart {
                    lines.series.append(LineChart.Series(label: label, values: numbers))
                    return .empty
                }
                if let scatter = subject as? ScatterChart {
                    var points: [ScatterChart.DataPoint] = []
                    var index = 0
                    while index + 1 < numbers.count {
                        points.append(
                            ScatterChart.DataPoint(x: numbers[index], y: numbers[index + 1])
                        )
                        index += 2
                    }
                    scatter.series.append(ScatterChart.Series(label: label, points: points))
                    return .empty
                }
                throw BASICError.runtime("\(typeName) has no series")

            case "LEGEND":
                // The Swift sets `showsLegend` on every multi-series chart; a
                // series without it is drawn but never named, which is what
                // "builds" missing from the bar chart meant.
                let wanted = arguments.first?.truthy ?? true
                if let bars = subject as? BarChart { bars.showsLegend = wanted; return .empty }
                if let lines = subject as? LineChart { lines.showsLegend = wanted; return .empty }
                if let scatter = subject as? ScatterChart {
                    scatter.showsLegend = wanted
                    return .empty
                }
                throw BASICError.runtime("\(typeName) has no legend")

            case "CATEGORIES":
                guard let bars = subject as? BarChart else {
                    throw BASICError.runtime("\(typeName) has no categories")
                }
                bars.categories = Self.tuiStrings(arguments)
                return .empty

            case "DONUT":
                guard let pie = subject as? PieChart else {
                    throw BASICError.runtime("\(typeName) is not a pie chart")
                }
                pie.innerRadiusFraction = arguments.first?.number ?? 0.55
                return .empty

            case "SLICE":
                guard let pie = subject as? PieChart else {
                    throw BASICError.runtime("\(typeName) has no slices")
                }
                guard let label = arguments.first?.string?.description,
                      let value = Self.tuiNumbers(arguments).first else {
                    throw BASICError.runtime("\(typeName).slice expects a label and a value")
                }
                pie.slices.append(PieChart.Slice(label: label, value: value))
                return .empty

            case "TRACK":
                // label, then start/duration pairs.
                guard let timeline = subject as? TimelineChart else {
                    throw BASICError.runtime("\(typeName) has no tracks")
                }
                guard let label = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).track expects a label")
                }
                let numbers = Self.tuiNumbers(arguments)
                var segments: [TimelineRow.Segment] = []
                var index = 0
                while index + 1 < numbers.count {
                    segments.append(
                        TimelineRow.Segment(
                            start: numbers[index], duration: numbers[index + 1]
                        )
                    )
                    index += 2
                }
                timeline.rows.append(TimelineRow(label: label, segments: segments))
                return .empty

            case "STEP":
                // A wizard step: id, title, and the view behind it.
                guard registry.wizardSteps[id] != nil else {
                    throw BASICError.runtime("\(typeName) has no steps")
                }
                guard let stepID = arguments.first?.string?.description,
                      arguments.count > 2,
                      let stepTitle = arguments[1].string?.description,
                      case .systemObject(_, let viewID) = arguments[2],
                      let stepView = registry.views[viewID] else {
                    throw BASICError.runtime("\(typeName).step expects an id, a title and a view")
                }
                registry.wizardSteps[id]?.append(
                    Wizard.Step(id: stepID, title: stepTitle, view: stepView)
                )
                return .empty

            case "ONFINISH":
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onfinish expects a handler name")
                }
                registry.handlers[id] = handler
                registry.wizardFinish[id] = handler
                return .empty

            case "SECTION2":
                // An accordion section: a title and the view behind it.
                guard let accordion = subject as? Accordion else {
                    throw BASICError.runtime("\(typeName) has no sections")
                }
                guard let sectionTitle = arguments.first?.string?.description,
                      arguments.count > 1,
                      case .systemObject(_, let contentID) = arguments[1],
                      let content = registry.views[contentID] else {
                    throw BASICError.runtime("\(typeName).section2 expects a title and a view")
                }
                _ = accordion.addSection(sectionTitle, content: content)
                return .empty

            case "THRESHOLDS":
                // A level indicator's thresholds are counts, not fractions:
                // `warningLevel = 4, criticalLevel = 5` out of five segments.
                if let level = subject as? LevelIndicator {
                    level.warningLevel = Int(arguments.first?.number ?? 0)
                    level.criticalLevel = Int(
                        (arguments.count > 1 ? arguments[1].number : nil) ?? 0
                    )
                    return .empty
                }
                guard let gauge = subject as? Gauge else {
                    throw BASICError.runtime("\(typeName) has no thresholds")
                }
                gauge.warningThreshold = arguments.first?.number ?? 0.7
                gauge.criticalThreshold = (arguments.count > 1 ? arguments[1].number : nil) ?? 0.9
                return .empty

            case "FLASH":
                guard let bar = subject as? StatusBar else {
                    throw BASICError.runtime("\(typeName) has nothing to flash")
                }
                bar.flash(arguments.first?.string?.description ?? "")
                return .empty

            case "GROUP":
                // One call per group, title then alternating item/glyph pairs:
                // Ribbon takes a group's items at once, so buffering them would
                // need a flush nobody would remember to call.
                guard let ribbon = subject as? Ribbon else {
                    throw BASICError.runtime("\(typeName) has no groups")
                }
                let words = Self.tuiStrings(arguments)
                guard let groupTitle = words.first else {
                    throw BASICError.runtime("\(typeName).group expects a title")
                }
                var items: [ToolbarItem] = []
                var index = 1
                while index < words.count {
                    let glyph = index + 1 < words.count ? words[index + 1].first : nil
                    items.append(ToolbarItem(
                        words[index],
                        icon: glyph.map { ToolbarIcon(glyph: $0) }
                    ))
                    index += 2
                }
                ribbon.addGroup(groupTitle, items: items)
                return .empty

            case "AXIS":
                guard let split = subject as? SplitView else {
                    throw BASICError.runtime("\(typeName) has no axis")
                }
                split.axis = (arguments.first?.string?.description ?? "")
                    .lowercased().hasPrefix("v") ? .vertical : .horizontal
                return .empty

            case "ALIGN":
                guard let label = subject as? Label else {
                    throw BASICError.runtime("\(typeName) has no alignment")
                }
                switch (arguments.first?.string?.description ?? "").lowercased().first {
                case "c": label.alignment = .center
                case "t", "r": label.alignment = .trailing
                default: label.alignment = .leading
                }
                return .empty

            case "LANGUAGE":
                guard let editor = subject as? SyntaxTextView else {
                    throw BASICError.runtime("\(typeName) has no language")
                }
                editor.language = arguments.first?.string?.description ?? "swift"
                return .empty

            case "TOGGLEEDIT":
                guard let markdown = subject as? MarkdownView else {
                    throw BASICError.runtime("\(typeName) has no source view")
                }
                markdown.toggleEditing()
                return .empty

            case "EDITING":
                guard let markdown = subject as? MarkdownView else {
                    throw BASICError.runtime("\(typeName) has no source view")
                }
                return .boolean(markdown.isEditing)

            case "DETAIL":
                guard registry.masterRows[id] != nil else {
                    throw BASICError.runtime("\(typeName) has no detail pane")
                }
                guard let index = Self.tuiInt(arguments, 0),
                      case .systemObject(_, let viewID) = arguments[1],
                      let pane = registry.views[viewID] else {
                    throw BASICError.runtime("\(typeName).detail expects a row number and a view")
                }
                // Anchored here, because a detail pane never passes through
                // `add` — MasterDetail places it itself, and a view with no
                // anchors gets zero size and never appears.
                pane.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
                registry.detailViews[id, default: [:]][index] = pane
                return .empty

            case "SECTION":
                guard let collection = subject as? CollectionView else {
                    throw BASICError.runtime("\(typeName) has no sections")
                }
                collection.sections.append(
                    CollectionView.Section(
                        title: arguments.first?.string?.description ?? "", items: []
                    )
                )
                return .empty

            case "ADDNODE":
                // A tree is built by *path*, not by nesting constructors, which
                // BASIC cannot do: addnode("Sources"), then
                // addnode("Sources/TUIKit"), then the leaves under it. Each
                // call finds its parent by the part before the last slash.
                guard let tree = subject as? TreeView else {
                    throw BASICError.runtime("\(typeName) has no nodes")
                }
                guard let path = arguments.first?.string?.description, !path.isEmpty else {
                    throw BASICError.runtime("\(typeName).addnode expects a path")
                }
                var known = registry.treeNodes[id] ?? [:]
                let parts = path.split(separator: "/").map(String.init)
                guard let leaf = parts.last else { return .empty }
                let node = TreeNode(leaf)
                known[path] = node
                if parts.count == 1 {
                    tree.roots.append(node)
                } else {
                    let parentPath = parts.dropLast().joined(separator: "/")
                    guard let parent = known[parentPath] else {
                        throw BASICError.runtime(
                            "\(typeName).addnode: no parent for \(path) — add \(parentPath) first"
                        )
                    }
                    parent.addChild(node)
                }
                registry.treeNodes[id] = known
                // Reassigned, not mutated: `roots` rebuilds the visible rows in
                // its `didSet`, and `addChild` on a node buried inside it never
                // touches the property — so a nested node would be added and
                // never drawn.
                tree.roots = tree.roots
                return .empty

            case "ITEMS":
                guard let list = subject as? CompletionList else {
                    throw BASICError.runtime("\(typeName) has no completion items")
                }
                list.items = Self.tuiStrings(arguments)
                return .empty

            case "TICKS":
                guard let slider = subject as? Slider else {
                    throw BASICError.runtime("\(typeName) has no tick marks")
                }
                let marks = Self.tuiInt(arguments, 0) ?? 0
                slider.tickMarks = marks
                // Ticks a value can rest between are decoration; the gallery
                // asks for both together, so this does too.
                slider.snapsToTicks = marks > 0
                return .empty

            case "ONSEARCH", "ONCOMMIT", "ONEMPTY":
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).\(method) expects a handler name")
                }
                if let search = subject as? SearchField {
                    if method.uppercased() == "ONSEARCH" {
                        search.onSearch = { _ in
                            BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                        }
                    } else {
                        search.onCommit = { _ in
                            BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                        }
                    }
                    return .empty
                }
                if let paste = subject as? PasteButton, method.uppercased() == "ONEMPTY" {
                    paste.onEmpty = {
                        BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                    }
                    return .empty
                }
                throw BASICError.runtime("\(typeName) has no \(method)")

            case "LOWER", "UPPER":
                guard let span = subject as? RangeSlider else {
                    throw BASICError.runtime("\(typeName) has no range")
                }
                return .number(Double(
                    method.uppercased() == "LOWER" ? span.lowerValue : span.upperValue
                ))

            case "PLACEHOLDER":
                guard let field = subject as? TextField else {
                    throw BASICError.runtime("\(typeName) has no placeholder")
                }
                field.placeholder = arguments.first?.string?.description ?? ""
                return .empty

            case "EDITABLE":
                guard let level = subject as? LevelIndicator else {
                    throw BASICError.runtime("\(typeName) has no editable state")
                }
                level.isEditable = arguments.first?.truthy ?? true
                return .empty

            case "WARNING":
                guard let level = subject as? LevelIndicator else {
                    throw BASICError.runtime("\(typeName) has no warning level")
                }
                level.warningLevel = Self.tuiInt(arguments, 0)
                return .empty

            case "CRITICAL":
                guard let level = subject as? LevelIndicator else {
                    throw BASICError.runtime("\(typeName) has no critical level")
                }
                level.criticalLevel = Self.tuiInt(arguments, 0)
                return .empty

            case "ADVANCE":
                guard let progress = subject as? ProgressIndicator else {
                    throw BASICError.runtime("\(typeName) has nothing to advance")
                }
                progress.advance()
                return .empty

            case "NOCHROME":
                // The gallery's cells-pinned twin: the same chart, told to
                // render ANSI even where a VectorTerminal would draw vectors.
                // On a plain terminal the two copies are identical by design.
                guard let view = subject else {
                    throw BASICError.runtime("\(typeName) cannot suppress chrome")
                }
                view.suppressesVectorChrome = arguments.first?.truthy ?? true
                return .empty

            case "CONTENTHEIGHT":
                guard let column = subject as? BASICTUIDocumentStack else {
                    throw BASICError.runtime("\(typeName) is not a scrollable column")
                }
                column.declaredHeight = Self.tuiInt(arguments, 0) ?? 0
                return .empty

            case "HEIGHT":
                // The gallery's `pinnedHeight`: a fixed row count, so a group
                // takes exactly the space it needs and the ones below it are
                // not pushed off the page.
                guard let view = subject else {
                    throw BASICError.runtime("\(typeName) has no height to pin")
                }
                guard let rows = arguments.first?.number, rows > 0 else {
                    throw BASICError.runtime("\(typeName).height expects a row count")
                }
                view.minimumSize = Size(width: 0, height: Int(rows))
                view.maximumSize = Size(width: Int.max, height: Int(rows))
                return .empty

            case "ROLE":
                guard let button = subject as? Button else {
                    throw BASICError.runtime("\(typeName) has no role")
                }
                switch (arguments.first?.string?.description ?? "").lowercased() {
                case "default": button.role = .default
                case "destructive": button.role = .destructive
                default: button.role = .normal
                }
                return .empty

            case "STYLE":
                // A label takes a theme role rather than a button style: chrome
                // a program builds itself — a status strip's own labels — is
                // not inside a themed control and so is not re-dressed by
                // `applyTheme`. Without this a BASIC status strip keeps the
                // terminal's default colours while everything around it changes
                // theme. "header" is the strip's own style; "headerplain" is the
                // same without bold, for the segments that should not shout.
                if let label = subject as? Label {
                    // Resolved through the label itself, so it picks up the
                    // context of whatever it was added to — which means the
                    // strip has to be in its window before this is called, as
                    // it is in the gallery.
                    var style = label.effectiveTheme.header
                    if (arguments.first?.string?.description ?? "").lowercased() != "header" {
                        style.flags.remove(.bold)
                    }
                    label.style = style
                    return .empty
                }
                guard let button = subject as? Button else {
                    throw BASICError.runtime("\(typeName) has no style")
                }
                button.style =
                    (arguments.first?.string?.description ?? "").lowercased() == "bordered"
                    ? .bordered : .tinted
                return .empty

            case "ONLONGPRESS":
                guard let button = subject as? Button else {
                    throw BASICError.runtime("\(typeName) has no long press")
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onlongpress expects a handler name")
                }
                button.onLongPress = {
                    BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                }
                return .empty

            case "CONTEXTMENU":
                // Any view can carry one; on a button with no handler, holding
                // it opens the menu instead of firing an action.
                // A window presents a menu at a point rather than carrying one:
                // the held-Back history menu opens under the button, not under
                // the pointer.
                if let window = registry.windows[id] {
                    guard case .systemObject(_, let menuID)? = arguments.first,
                          let bar = registry.menus[menuID],
                          let menu = bar.menus.first else {
                        throw BASICError.runtime("\(typeName).contextmenu expects a menu")
                    }
                    let x = arguments.count > 1 ? Int(arguments[1].number ?? 0) : 0
                    let y = arguments.count > 2 ? Int(arguments[2].number ?? 0) : 0
                    window.presentContextMenu(menu, at: Point(x: x, y: y))
                    return .empty
                }
                guard let view = subject else {
                    throw BASICError.runtime("\(typeName) cannot carry a menu")
                }
                guard case .systemObject(_, let menuID)? = arguments.first,
                      let menu = registry.openMenus[menuID] else {
                    throw BASICError.runtime("\(typeName).contextmenu expects a TUIMenu")
                }
                view.contextMenu = menu
                return .empty

            case "ONCLICK":
                // A paste button's action is fixed at construction — it has to
                // be, because TUIKit hands the pasted text to it — so this only
                // records which BASIC function that action should call.
                if subject is PasteButton {
                    guard let handler = arguments.first?.string?.description else {
                        throw BASICError.runtime("\(typeName).onclick expects a handler name")
                    }
                    registry.handlers[id] = handler
                    return .empty
                }
                // Recorded here rather than at `add`: a button only earns focus
                // once it has something to do.
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onclick expects a handler name")
                }
                guard let button = try view() as? Button else {
                    throw BASICError.runtime("\(typeName) has no click to handle")
                }
                registry.handlers[id] = handler
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = button
                }
                // The closure is installed once and reads the registry each
                // time, so `onclick` may be called again to change the handler
                // without leaving the old one wired underneath.
                button.onActivate = {
                    // A handler that throws must not escape into TUIKit, which
                    // has nowhere to put a BASIC error mid-frame. It is parked
                    // and re-thrown by `run`, the statement the program is
                    // actually sitting on.
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "SHOW":
                guard let app = registry.apps[id] else {
                    throw BASICError.runtime("\(typeName) is not an application")
                }
                guard case .systemObject(_, let dialogID)? = arguments.first else {
                    throw BASICError.runtime("\(typeName).show expects a dialog")
                }
                // A preferences dialog builds itself as it is described, so it
                // is presented as it stands rather than assembled from a spec.
                if let preferences = registry.preferencesDialogs[dialogID] {
                    preferences.onDismiss = { [weak app, weak preferences] in
                        if let app, let preferences { app.dismiss(preferences) }
                    }
                    preferences.sizeToFit(in: app.desktop.bounds.size)
                    app.present(preferences)
                    preferences.sizeToFit(in: app.desktop.bounds.size)
                    return .empty
                }
                guard let spec = registry.dialogs[dialogID] else {
                    throw BASICError.runtime("\(typeName).show expects a dialog")
                }
                let dialog = Dialog(title: spec.title, message: spec.message)
                for (index, button) in spec.buttons.enumerated() {
                    // The first button added is the default, and so the one
                    // with focus. Without a default nothing in the dialog is
                    // focused, Enter does nothing, and the dialog looks frozen —
                    // which is exactly how it first behaved.
                    _ = dialog.addButton(button.title, isDefault: index == 0) {
                        guard let handler = button.handler else { return }
                        BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                    }
                }
                // `addButton` calls the action and *then* `onDismiss`, so
                // confirming and cancelling both land here and neither leaves a
                // window behind.
                dialog.onDismiss = { [weak app, weak dialog] in
                    if let app, let dialog { app.dismiss(dialog) }
                }
                // Sized twice, as TUIKit's own document controller does: once
                // before it is placed, once after, when the desktop has given
                // it a frame to be measured against.
                dialog.sizeToFit(in: app.desktop.bounds.size)
                app.present(dialog)
                dialog.sizeToFit(in: app.desktop.bounds.size)
                return .empty

            case "STOP":
                guard let app = registry.apps[id] else {
                    throw BASICError.runtime("\(typeName) is not an application")
                }
                app.stop()
                return .empty

            default:
                // Not a control method — try the shell (BASICTUIChrome.swift).
                // One `default` rather than two switches the caller has to
                // choose between, so a program never has to know which half of
                // the binding a method lives in.
                return try BASICRuntime.callTUIChromeMethod(
                    typeName: typeName,
                    id: id,
                    method: method,
                    arguments: arguments,
                    registry: registry
                )
            }
        }
    }

    /// Runs a TUI application and blocks until it stops.
    private func runTUIApplication(
        appID: Int,
        arguments: [BASICValue],
        presentationHost: (any BASICTUIPresentationHost)?,
        invokeHandler: @escaping (String, [BASICValue]) throws -> Void
    ) throws -> BASICValue {
        guard case .systemObject(_, let windowID) = arguments.first else {
            throw BASICError.runtime("TUIApp.run expects a window")
        }
        guard let host = presentationHost else {
            throw BASICError.runtime("This host cannot show a TUI application")
        }
        BASICTUIRuntimeBridge.shared.invokeHandler = invokeHandler
        defer { BASICTUIRuntimeBridge.shared.invokeHandler = nil }

        try BASICTUIRuntimeBridge.runBlocking(appID: appID, windowID: windowID, host: host)

        if let failure = BASICTUIRuntimeBridge.shared.takeFailure() {
            throw failure
        }
        return .empty
    }
}

extension BASICRuntime {
    /// A non-string BASIC value as a table cell.
    ///
    /// Numbers reach `addrow` constantly — a row of counts is the ordinary
    /// case — and refusing them would make every call site wrap in `STR$`.
    static func tuiPlain(_ value: BASICValue) -> String {
        if let number = value.number {
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)
        }
        if case .boolean(let flag) = value { return flag ? "True" : "False" }
        return ""
    }
}

extension BASICRuntime {
    /// One numeric argument, for the controls TUIKit builds from numbers.
    static func tuiInt(_ arguments: [BASICValue], _ index: Int) -> Int? {
        guard index < arguments.count, let value = arguments[index].number else { return nil }
        return Int(value)
    }

    /// Every numeric argument, for the charts.
    static func tuiNumbers(_ arguments: [BASICValue]) -> [Double] {
        arguments.compactMap { $0.number }
    }

    /// Every string argument, for the controls TUIKit builds from a list.
    static func tuiStrings(_ arguments: [BASICValue]) -> [String] {
        arguments.compactMap { $0.string?.description }
    }
}
