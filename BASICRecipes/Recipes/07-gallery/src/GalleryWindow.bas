' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The gallery window: an icon toolbar across the top, then folder tabs, one
' per control group. RULE (PLAN.md maintenance rules): a new TUIKit control
' lands with a spot in one of these tabs, in the same commit.

' final class GalleryWindow: FloatingWindow
'
' The subclass exists for one override: ^L toggles the leading slide-out.
' BASIC cannot subclass a TUIKit window, so the key is not bound here - the
' View menu's "Toggle Controls Panel" and the [>] title button reach the same
' toggleslideout. ^L itself is the one thing this file loses.

' Builds one gallery window - a resizable, maximizable *content* window
' (Turbo dresses it blue with a white double frame) whose content is a
' folder-tab view over every control in the kit, with a Controls panel
' that slides out of the left edge to jump between the tabs.
'
' No `app`/`settings` parameters: both are globals. No `live` parameter
' either - it exists in the Swift to keep the Terminal tab from starting a
' real shell during snapshots, and the Terminal tab is deliberately absent.
function MakeGalleryWindow(index as integer) as variant
    if index = 0 then
        win = TUIFloatWindow("TUIKit Gallery")
    else
        win = TUIFloatWindow("TUIKit Gallery " + STR$(index + 1))
    end if

    win.frame(2 + index * 2, 1 + index, 78, 24)
    ' window.themeContext = .contentWindow - the document surface, Turbo
    ' blue. Set by the binding for every TUIFloatWindow.
    win.minsize(50, 14)
    win.maximizeinsets(1, 1)
    win.onclose("GalleryWindowCloseRequested")

    InstallToolbar()

    tabs = TUITabs()

    ' let pages: [(title, summary, content)]
    '
    ' BASIC has no tuple array, so the three columns are read straight into
    ' the two places the Swift uses them - addtab, and the Controls index -
    ' one page per pair of lines rather than one row per page.
    controlsIndex = TUISidebar()

    AddGalleryPage("Buttons", "roles, long-press, dialogs", MakeButtonsTab())
    AddGalleryPage("Inputs", "fields, values, progress", MakeInputsTab())
    AddGalleryPage("Fields", "search, tokens, completion", MakeFieldsTab())
    AddGalleryPage("Pickers", "dates, colours, matrix", MakePickersTab())
    AddGalleryPage("Lists", "lists, trees, tables", MakeListsTab())
    AddGalleryPage("Data", "master-detail, collection", MakeDataTab())
    AddGalleryPage("Text", "editors and markdown", MakeTextTab())
    AddGalleryPage("Layout", "stacks, splits, forms", MakeLayoutTab())
    AddGalleryPage("Nav", "pages, navigator, accordion", MakeNavigationTab())
    AddGalleryPage("Wizard", "steps, validation, branching", MakeWizardTab())
    AddGalleryPage("Gauges", "ring, dial, bar, levels", MakeGaugesTab())
    AddGalleryPage("Drawing", "canvas and images", MakeDrawingTab())
    AddGalleryPage("Charts", "cells and VTG", MakeChartsTab())
    AddGalleryPage("Boards", "kanban - TUIBoards", MakeBoardsTab())
    AddGalleryPage("Diagram", "nodes and edges - TUIDiagram", MakeDiagramTab())
    ' ("Terminal", "a shell - TUITerminal", makeTerminalTab(live:)) is left
    ' out on purpose, with WebBrowser: both drive a live subprocess.
    AddGalleryPage("Log", "TUILogger + LogView", MakeLogTab())

    ' Every page click lands in the log - which is what fills the Log page.
    tabs.onselect("GalleryPageSelected")

    ' A rule between the toolbar and the folder tabs; connected, so the
    ' window welds it into its frame.
    let content = TUIStack("v")
    content.add(PinnedHeight(TUIDivider("h"), 1))
    content.add(tabs)
    win.add(content)

    ' The Controls panel: the slide-out, holding an index of the tabs.
    ' Selecting a row shows that tab; the panel stays put (pinned) because
    ' jumping between tabs is exactly when you want it open.
    controlsIndex.onselect("GalleryControlsIndexSelected")
    ' index.onActivate = { tabs?.select(selected) } - a BASIC sidebar has one
    ' selection handler, and it already selects the tab, so activating a row
    ' does what the Swift's second closure does.

    ' if settings.controlsPanelOpen { window.openSlideOut(.leading) }
    '
    ' The fifth argument is that `if`: the panel is installed open or shut,
    ' because a window that has not been presented yet has no open panel to
    ' close afterwards.
    win.slideout("leading", "Controls", controlsIndex, 28, ControlsPanelOpen())

    return win
end function

' One page: a tab, and the row that indexes it in the Controls panel. The
' Swift builds an array of triples and then walks it twice; BASIC has no
' tuple array, so the two walks become one call per page.
function AddGalleryPage(title as string, summary as string, content as variant) as variant
    tabs.addtab(title, content)
    controlsIndex.additem(">", title, summary)
    return 0
end function

function GalleryPageSelected() as variant
    ' TUILogger.shared.info("page: \(titles[selected])")
    galleryLog.write("info", "page: " + tabs.selectedtitle())
    return 0
end function

function GalleryControlsIndexSelected() as variant
    let selected = controlsIndex.selected()
    if selected < 0 then
        return 0
    end if

    tabs.select(selected)
    galleryLog.write("info", "page: " + tabs.selectedtitle() + " - controls panel")
    return 0
end function

function GalleryWindowCloseRequested() as variant
    ' window.onCloseRequest = { app.dismiss(window) }
    app.dismiss()
    return 0
end function

' The window toolbar: icon buttons, a flexible address field (R6), and the
' long-press example - hold Back for its history menu, exactly the browser
' gesture the feature was built for.
function InstallToolbar() as variant
    let bar = TUIToolbar()
    bar.displaymode("both")

    address = TUIField()
    address.text("tuikit://gallery/charts")

    bar.additem("Back", "<", "ToolbarBack")
    ' back.longPressAction - the held-Back history menu.
    bar.longpress("Back", "ToolbarBackHistory")

    bar.additem("Forward", ">", "ToolbarForward")
    bar.additem("Reload", "@", "ToolbarReload")
    bar.divider()
    bar.addview(address, "Address", 1)
    bar.divider()
    bar.additem("Settings", "*", "ToolbarSettings")

    win.toolbar(bar)
    return 0
end function

function ToolbarBack() as variant
    address.text("tuikit://gallery/back - quick click")
    return 0
end function

function ToolbarBackHistory() as variant
    let history = TUIMenu()
    history.menu("")
    history.item("tuikit://gallery/charts", "ToolbarHistoryCharts")
    history.item("tuikit://gallery/text", "ToolbarHistoryText")
    history.item("tuikit://gallery/buttons", "ToolbarHistoryButtons")
    ' Below the toolbar row, at the button.
    win.contextmenu(history, 3, 2)
    return 0
end function

' for entry in [...] { history.addItem(...) { address.setText(...) } }
'
' Three handlers rather than a loop: the Swift closure captures its entry,
' and a menu item's carried argument is a string, so the loop could be kept -
' but the three URLs are literals in the Swift too, and one handler each
' reads the same as the array does.
function ToolbarHistoryCharts() as variant
    address.text("tuikit://gallery/charts - from held Back")
    return 0
end function

function ToolbarHistoryText() as variant
    address.text("tuikit://gallery/text - from held Back")
    return 0
end function

function ToolbarHistoryButtons() as variant
    address.text("tuikit://gallery/buttons - from held Back")
    return 0
end function

function ToolbarForward() as variant
    address.text("tuikit://gallery/forward")
    return 0
end function

function ToolbarReload() as variant
    address.text("tuikit://gallery - reloaded")
    return 0
end function

function ToolbarSettings() as variant
    ' the real preferences dialog
    PresentPreferences()
    return 0
end function

' ------------------------------------------- Shared layout helpers
'
' Used by every tab file, as in the Swift.

' A group box: a titled panel whose content is a padded vertical stack.
'
' `group(_:spacing:_:)` takes an array of children; BASIC has no array
' literal of handles, so a group is opened, added to, and used - TUIPanel
' stacks what it is given, which is what the Swift's helper does by hand.
function Group(title as string) as variant
    return TUIPanel(title)
end function

' Pins a stack row to an exact height, so flexible rows don't absorb it.
function PinnedHeight(view as variant, height as integer) as variant
    view.height(height)
    return view
end function

' A row of side-by-side flexible children.
function Row() as variant
    return TUIStack("h")
end function
