//
//  BASICTUIChrome.swift
//  BASICCore
//
//  The application *shell* — themes, floating windows, toolbars, tabs, panels,
//  sidebars, status bars — as pseudo classes.
//
//  Split from BASICTUIKit.swift, which binds the controls. The division is the
//  one the gallery draws: `GalleryApp` and `GalleryWindow` build the shell,
//  everything else fills a tab.
//

import Foundation
import TUIKit

extension BASICTUIRegistry {
    /// Floating windows by handle.
    ///
    /// Separate from `windows` because a `FloatingWindow` is a `Window` that
    /// also has chrome to reach — a title bar, a content view, a toolbar and
    /// slide-outs — and the binding has to tell the two apart to know whether
    /// `add` means "fill the screen" or "put this inside the frame".
    var floatingWindows: [Int: FloatingWindow] {
        get { floatingWindowStorage }
        set { floatingWindowStorage = newValue }
    }
}

/// A full-screen window that paints only its chrome rows.
///
/// The desktop is *behind* the root window, so a root that paints its whole
/// background hides it — and the theme's desktop colour never appears no
/// matter how carefully it is chosen. That is what made the gallery grey.
///
/// The gallery's own `GalleryShellWindow` paints the menu row and the status
/// row and leaves everything between untouched, which is what lets the
/// desktop show around the floating windows. This is that window.
@MainActor
final class BASICTUIShellWindow: Window {
    override func draw(_ painter: Painter) {
        painter.fill(Rect(x: 0, y: 0, width: bounds.size.width, height: 1), with: .blank)
        painter.fill(
            Rect(x: 0, y: bounds.size.height - 1, width: bounds.size.width, height: 1),
            with: .blank
        )
    }
}

extension BASICRuntime {

    /// Builds a chrome handle, or returns false when `typeName` is not one.
    ///
    /// `@MainActor` because every TUIKit view is, and this is only ever called
    /// from inside `withTUIRegistry`, which has already hopped.
    @MainActor
    static func tuiChromeObject(typeName: String, title: String, registry: BASICTUIRegistry) throws -> Bool {
        let id = registry.lastAllocatedID
        switch typeName.uppercased() {
        case "TUIFLOATWINDOW":
            // A frame is required at construction and cannot be zero: a window
            // with no size is present but invisible, which reads as the app
            // failing to open it. The program moves it afterwards with `frame`.
            let window = FloatingWindow(
                title: title, frame: Rect(x: 2, y: 1, width: 78, height: 24)
            )
            window.themeContext = ThemeContext.contentWindow
            registry.floatingWindows[id] = window
            registry.windows[id] = window

        case "TUISHELL":
            let shell = BASICTUIShellWindow()
            shell.fillsScreen = true
            registry.windows[id] = shell

        case "TUITOOLBAR":
            registry.views[id] = Toolbar()

        case "TUITABS":
            registry.views[id] = TabView()

        case "TUIPANEL":
            // A panel stacks what it is given, as the gallery's own `group`
            // helper does. Adding straight to `content` gives every child fill
            // anchors, so the second one covers the first — which looked like
            // controls that had failed to build.
            let panel = Panel(title)
            let stack = VStack(spacing: 1, insets: EdgeInsets(top: 0, left: 1, bottom: 0, right: 1))
            stack.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
            panel.content.addSubview(stack)
            registry.panelStacks[id] = stack
            registry.views[id] = panel

        case "TUISTATUS":
            let bar = StatusBar()
            bar.showsSeparators = false
            registry.views[id] = bar

        case "TUIDIVIDER":
            registry.views[id] = Divider(
                axis: title.lowercased().hasPrefix("v") ? .vertical : .horizontal
            )

        case "TUISIDEBAR":
            registry.views[id] = SidebarList()

        default:
            return false
        }
        return true
    }

    /// Dispatches a chrome method, for anything the control switch did not know.
    /// Static, and takes the registry rather than reaching for it.
    ///
    /// `withTUIRegistry`'s closure is `@Sendable`, so anything it captures must
    /// be too — and `BASICRuntime` is not. Neither of these needs runtime
    /// state, so the simplest fix is to stop capturing `self` at all.
    @MainActor
    static func callTUIChromeMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue],
        registry: BASICTUIRegistry
    ) throws -> BASICValue {
        do {
            func text(_ index: Int) -> String? {
                guard index < arguments.count else { return nil }
                return arguments[index].string?.description
            }
            func number(_ index: Int) -> Int? {
                guard index < arguments.count, let value = arguments[index].number else { return nil }
                return Int(value)
            }
            func handle(_ index: Int) -> Int? {
                guard index < arguments.count,
                      case .systemObject(_, let other) = arguments[index] else { return nil }
                return other
            }

            switch method.uppercased() {
            case "THEME":
                guard let wanted = text(0) else {
                    throw BASICError.runtime("\(typeName).theme expects a theme name")
                }
                guard let theme = Self.tuiTheme(named: wanted) else {
                    throw BASICError.runtime(
                        "No theme called \(wanted) — try one of: "
                            + Self.tuiThemeNames.joined(separator: ", ")
                    )
                }
                registry.pendingTheme = theme
                // Applied now if the app is already up, and remembered either
                // way: a program usually sets the theme before `run`, when
                // there is no App yet to apply it to.
                if let app = registry.apps[id] {
                    Self.applyTUITheme(theme, to: app)
                }
                return .empty

            case "FRAME":
                guard let window = registry.floatingWindows[id] else {
                    throw BASICError.runtime("\(typeName) has no frame to set")
                }
                guard let x = number(0), let y = number(1),
                      let width = number(2), let height = number(3) else {
                    throw BASICError.runtime("\(typeName).frame expects x, y, width, height")
                }
                window.frame = Rect(x: x, y: y, width: max(1, width), height: max(1, height))
                return .empty

            case "TOOLBAR":
                guard let window = registry.floatingWindows[id] else {
                    throw BASICError.runtime("\(typeName) has no toolbar")
                }
                guard let barID = handle(0), let bar = registry.views[barID] as? Toolbar else {
                    throw BASICError.runtime("\(typeName).toolbar expects a TUIToolbar")
                }
                window.setToolbar(bar)
                return .empty

            case "SLIDEOUT":
                guard let window = registry.floatingWindows[id] else {
                    throw BASICError.runtime("\(typeName) has no slide-out")
                }
                guard let edge = text(0), let panelTitle = text(1),
                      let contentID = handle(2), let content = registry.views[contentID] else {
                    throw BASICError.runtime(
                        "\(typeName).slideout expects an edge, a title and a view"
                    )
                }
                let slide = window.addSlideOut(
                    Self.tuiEdge(edge),
                    title: panelTitle,
                    content: content,
                    length: number(3) ?? 28,
                    minimumLength: 16
                )
                // Pinned, because the panel is an index of the tabs and moving
                // between tabs is exactly when it should stay put.
                slide.isPinned = true
                window.slideOutToggleEdge = Self.tuiEdge(edge)
                window.openSlideOut(Self.tuiEdge(edge))
                return .empty

            case "ADDTAB":
                guard let tabs = registry.views[id] as? TabView else {
                    throw BASICError.runtime("\(typeName) has no tabs")
                }
                guard let tabTitle = text(0), let contentID = handle(1),
                      let content = registry.views[contentID] else {
                    throw BASICError.runtime("\(typeName).addtab expects a title and a view")
                }
                tabs.addTab(tabTitle, content: content)
                return .empty

            case "ONSELECT":
                guard let handler = text(0) else {
                    throw BASICError.runtime("\(typeName).onselect expects a handler name")
                }
                registry.handlers[id] = handler
                if let tabs = registry.views[id] as? TabView {
                    tabs.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let pages = registry.views[id] as? PageView {
                    pages.onPageChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                if let sidebar = registry.views[id] as? SidebarList {
                    // Both, as the gallery wires them: moving the highlight
                    // changes the page, and Enter does too.
                    sidebar.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    sidebar.onActivate = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                throw BASICError.runtime("\(typeName) has no selection to handle")

            case "SELECTED":
                if let sidebar = registry.views[id] as? SidebarList {
                    return .number(Double(sidebar.selectedIndex ?? -1))
                }
                if let tabs = registry.views[id] as? TabView {
                    return .number(Double(tabs.selectedIndex))
                }
                if let pages = registry.views[id] as? PageView {
                    return .number(Double(pages.currentIndex))
                }
                throw BASICError.runtime("\(typeName) has nothing selected")

            case "SELECT":
                guard let index = number(0) else {
                    throw BASICError.runtime("\(typeName).select expects a row number")
                }
                if let tabs = registry.views[id] as? TabView {
                    tabs.select(index)
                    return .empty
                }
                if let sidebar = registry.views[id] as? SidebarList {
                    sidebar.select(index)
                    return .empty
                }
                if let matrix = registry.views[id] as? Matrix {
                    matrix.select([index])
                    return .empty
                }
                throw BASICError.runtime("\(typeName) has nothing to select")

            case "ADDROW":
                // The sidebar's row, not a table's: icon, title, subtitle. The
                // control switch reached `addrow` first and only knows tables,
                // so a sidebar falls through to here.
                guard let sidebar = registry.views[id] as? SidebarList else {
                    throw BASICError.runtime("\(typeName) has no rows")
                }
                guard let rowTitle = text(1) ?? text(0) else {
                    throw BASICError.runtime("\(typeName).addrow expects a title")
                }
                sidebar.items.append(
                    SidebarItem(
                        icon: text(0).flatMap { $0.count == 1 ? $0.first : nil } ?? "\u{25B8}",
                        title: rowTitle,
                        subtitle: text(2)
                    )
                )
                return .empty

            case "ADDITEM":
                // Toolbars only — a list's `additem` is handled by the control
                // switch before this is reached.
                guard let bar = registry.views[id] as? Toolbar else {
                    throw BASICError.runtime("\(typeName) has no items")
                }
                guard let itemTitle = text(0) else {
                    throw BASICError.runtime("\(typeName).additem expects a title")
                }
                let glyph = text(1).flatMap { $0.first } ?? " "
                let handler = text(2)
                _ = bar.addItem(itemTitle, glyph: glyph) {
                    guard let handler else { return }
                    BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                }
                return .empty

            case "DIVIDER":
                guard let bar = registry.views[id] as? Toolbar else {
                    throw BASICError.runtime("\(typeName) has no items to divide")
                }
                _ = bar.add(.divider())
                return .empty

            case "ADDVIEW":
                // A control hosted *in* the toolbar — the gallery's address
                // field. `flexible` is what makes it claim the leftover width
                // rather than sitting at its intrinsic size.
                guard let bar = registry.views[id] as? Toolbar else {
                    throw BASICError.runtime("\(typeName) cannot host a view")
                }
                guard let viewID = handle(0), let hosted = registry.views[viewID] else {
                    throw BASICError.runtime("\(typeName).addview expects a view")
                }
                _ = bar.add(.view(hosted, title: text(1) ?? "", flexible: true))
                return .empty

            case "DISPLAYMODE":
                guard let bar = registry.views[id] as? Toolbar else {
                    throw BASICError.runtime("\(typeName) has no display mode")
                }
                // "both" is the two-row bar the gallery uses: glyph over title.
                bar.displayMode = (text(0)?.lowercased() == "both") ? .both : .textOnly
                return .empty

            case "PRESENT":
                guard let windowID = handle(0),
                      let window = registry.floatingWindows[windowID] else {
                    throw BASICError.runtime("\(typeName).present expects a TUIFloatWindow")
                }
                if let app = registry.apps[id] {
                    app.present(window)
                } else {
                    registry.pendingPresents.append(windowID)
                }
                return .empty

            case "ADDSEGMENT":
                guard let bar = registry.views[id] as? StatusBar else {
                    throw BASICError.runtime("\(typeName) is not a status bar")
                }
                guard let contentID = handle(0), let content = registry.views[contentID] else {
                    throw BASICError.runtime("\(typeName).addsegment expects a view")
                }
                // A percentage claims the leftover width; a minimum width just
                // reserves room. The gallery's strip is title, stretchy hint,
                // clock — which is one of each.
                _ = bar.addSegment(
                    content,
                    minimumWidth: number(1),
                    percentage: number(2) ?? 0
                )
                return .empty

            case "TIMER":
                guard let seconds = arguments.first?.number, seconds > 0,
                      let handler = text(1) else {
                    throw BASICError.runtime("\(typeName).timer expects seconds and a handler")
                }
                if let app = registry.apps[id] {
                    _ = app.addTimer(every: .milliseconds(Int(seconds * 1000))) {
                        BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                    }
                } else {
                    registry.pendingTimers.append((seconds: seconds, handler: handler))
                }
                return .empty

            default:
                throw BASICError.runtime("\(typeName) has no method \(method)")
            }
        }
    }

    /// Applies a theme, and paints the desktop behind it.
    ///
    /// `applyTheme` alone dresses the windows and leaves the desktop as it
    /// was, so the terminal's own background shows through around them.
    ///
    /// ## Why the fallback is not grey
    ///
    /// Most themes — Modern Turbo among them — define no *cell* background for
    /// the desktop at all. They describe it once, in the vector chrome, as a
    /// gradient. On a VectorTerminal that gradient is what you see; on a plain
    /// terminal the cell layer has nothing, resolves to `.standard`, and the
    /// gallery's own fallback paints a neutral grey.
    ///
    /// That grey is what a plain terminal showed instead of Turbo's blue. So
    /// the cell fill borrows the vector backdrop's top colour when there is
    /// one, and only falls back to grey when the theme describes no desktop by
    /// either route — which makes the two renderings agree.
    @MainActor
    static func applyTUITheme(_ theme: Theme, to app: App) {
        app.applyTheme(theme)

        app.desktop.fillStyle = CellStyle(background: Self.tuiDesktopFill(for: theme))
    }

    /// The colour the desktop should be painted, for a theme.
    ///
    /// Separated from `applyTUITheme` so it can be tested without an
    /// application or a terminal — which is how the Modern Turbo case was
    /// pinned down after two rounds of guessing at a screen capture.
    static func tuiDesktopFill(for theme: Theme) -> TerminalColor {
        let cellBackground = theme.resolved(for: .desktop).background
        if cellBackground != .standard {
            return cellBackground
        }
        if let backdrop = theme.base.vector?.desktop?.topColor {
            return .rgb(red: backdrop.red, green: backdrop.green, blue: backdrop.blue)
        }
        return .rgb(red: 128, green: 128, blue: 128)
    }

    /// The built-in theme names, for an error message that helps.
    static var tuiThemeNames: [String] {
        Theme.builtIn.map(\.name)
    }

    /// A built-in theme by name, matched without case or spaces.
    ///
    /// `red sands`, `RedSands` and `Red Sands` are obviously the same request
    /// and a BASIC program types it by hand.
    static func tuiTheme(named name: String) -> Theme? {
        func normalized(_ value: String) -> String {
            value.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        }
        let wanted = normalized(name)
        return Theme.builtIn.first { normalized($0.name) == wanted }?.theme
    }

    /// An edge name as TUIKit spells it.
    static func tuiEdge(_ name: String) -> SlideOutEdge {
        // TUIKit has no top edge — the menu bar owns that row.
        switch name.lowercased().first {
        case "b": return .bottom
        case "r", "t": return .trailing
        default: return .leading
        }
    }
}
