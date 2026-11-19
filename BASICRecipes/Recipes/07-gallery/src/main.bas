' TUIKit Gallery - every control, grouped into folder tabs.
'
'   basicshell basicPrograms/demos/tui/gallery.basproj/main.bas
'
' The shell is the OmegaCLIDE form: a menu bar strip across the top, a
' resizable gallery window floating on the desktop, and a status strip
' along the bottom. The Theme menu restyles everything live (the app boots
' into Modern Turbo); the Charts tab shows each chart's VTG and ANSI
' renderings side by side on a VectorTerminal.
'
' A file-for-file translation of TUIGallery/Sources/TUIKitGallery. Every
' <Name>.swift has a <Name>.bas beside it with its functions in the same
' order; Scripts/gallery-parity.sh shows the two side by side.

' One IMPORT per Swift file, added as each is translated, so the gallery runs
' at every step rather than only at the end. The list is complete when
' Scripts/gallery-parity.sh reports no file left.
IMPORT "GalleryLogPage.bas"
IMPORT "GalleryApp.bas"
IMPORT "GallerySettings.bas"
IMPORT "GalleryWindow.bas"
IMPORT "GalleryControlTabs.bas"
IMPORT "GalleryDataTabs.bas"
IMPORT "GalleryNewPages.bas"
IMPORT "GalleryCharts.bas"
IMPORT "GallerySiblingPages.bas"
IMPORT "GalleryNavigationTab.bas"

' ---------------------------------------------------------------- globals
'
' Every GLOBAL the gallery uses is declared HERE rather than in the file that
' owns it, and that is not a preference. A GLOBAL declared inside an IMPORTed
' file does not reach the importer - functions cross the boundary, state does
' not - so state has to be declared in the entry file to be shared at all.
'
' Each one is labeled with the Swift file and binding it stands for, so the
' side-by-side reading still works.

' GalleryApp.swift
/// The TUIKit application: the terminal, the windows, the themes and the timers.
GLOBAL app = TUIApp()
/// The status strip's leading segment, the app's name.
GLOBAL statusTitle AS VARIANT
/// The status strip's hint segment, blank while hints are turned off.
GLOBAL statusHint AS VARIANT
/// The status strip's clock, refreshed once a second by RefreshClock.
GLOBAL clock AS VARIANT
/// The shell window: the menu bar strip, the desktop and the status strip.
GLOBAL shell AS VARIANT
/// How many more gallery windows File > New Gallery Window has opened.
GLOBAL windowCount = 0

' GalleryLogPage.swift
/// The log handle the gallery writes its own diagnostics through.
GLOBAL galleryLog AS VARIANT
/// 1 once WireGalleryLogging has made the logger, so it is made only once.
GLOBAL galleryLoggingWired = 0

' GallerySettings.swift
/// The gallery's preferences suite on disk.
///
/// `store` is the Swift's `let store: Preferences`. STORE is not reserved, but
/// the name is kept distinct from the gallery's other handles for the same
/// reason the Swift qualifies it with `self.`.
GLOBAL prefsStore = TUIPrefs("com.tuikit.gallery")
/// The preferences dialog's Controls panel at launch check box.
GLOBAL panelCheck AS VARIANT
/// The preferences dialog's status-bar hint check box.
GLOBAL hintsCheck AS VARIANT
/// The preferences dialog's theme pop-up.
GLOBAL themePopUp AS VARIANT

' GalleryWindow.swift
/// The gallery window MakeGalleryWindow built most recently.
GLOBAL win AS VARIANT
/// The gallery window's folder tabs, one per control group.
GLOBAL tabs AS VARIANT
/// The toolbar's address field, which the toolbar buttons write into.
GLOBAL address AS VARIANT
/// The Controls slide-out's index of the tabs.
GLOBAL controlsIndex AS VARIANT

' GalleryControlTabs.swift
/// The Buttons tab's label reporting the long-press button and its menu.
GLOBAL holdResult AS VARIANT
/// The Buttons tab's label reporting the dialogs.
GLOBAL dialogResult AS VARIANT
/// The Inputs tab's spinner, advanced by an app timer.
GLOBAL spinner AS VARIANT
/// The Pickers tab's day-of-the-week matrix.
GLOBAL days AS VARIANT

' GalleryNewPages.swift
/// The Fields tab's label reporting the search field and the paste button.
GLOBAL searchResult AS VARIANT
/// The Fields tab's search field.
GLOBAL search AS VARIANT
/// The Fields tab's range slider.
GLOBAL span AS VARIANT
/// The label showing the range slider's two values.
GLOBAL spanLabel AS VARIANT
/// The Pickers tab's label reporting the day matrix's selection.
GLOBAL daysLabel AS VARIANT
/// The Pickers tab's day-of-the-week matrix, listed a second time under this heading.
GLOBAL days AS VARIANT
/// The Wizard tab's user name field.
GLOBAL wizardName AS VARIANT
/// The Wizard tab's label reporting a finished setup.
GLOBAL wizardDone AS VARIANT

' GalleryNavigationTab.swift
/// The Navigation tab's page view.
GLOBAL pages AS VARIANT
/// The label showing which page the page view is on.
GLOBAL pageLabel AS VARIANT
/// The Navigation tab's drill-down navigator.
GLOBAL navigator AS VARIANT
/// The label showing how deep the navigator is.
GLOBAL depthLabel AS VARIANT

' GalleryDataTabs.swift
/// The Text tab's Markdown view, which Edit flips to its source.
GLOBAL markdown AS VARIANT
/// The Text tab's Edit source / Render button.
GLOBAL editToggle AS VARIANT
/// The Layout tab's tool palette.
GLOBAL toolbox AS VARIANT
/// The label naming the toolbox's selected tool.
GLOBAL toolLabel AS VARIANT
/// The Layout tab's split view, whose axis Flip Axis changes.
GLOBAL splitter AS VARIANT
/// 1 while the split view is horizontal, 0 while it is vertical.
GLOBAL splitAxisIsHorizontal = 1
/// The Layout tab's status bar, which Flash writes a timed message into.
GLOBAL layoutStatus AS VARIANT
/// The Text tab's label reporting the link and the help link.
GLOBAL linkResult AS VARIANT

' GallerySiblingPages.swift
/// The Boards tab's label reporting card moves.
GLOBAL boardMoved AS VARIANT
/// The Diagram tab's label reporting the selection.
GLOBAL diagramSelected AS VARIANT

' The snapshot branch of main.swift is deliberately absent: GallerySnapshot
' renders every tab to SVG headlessly, which is a test harness rather than
' part of the app. Scripts/gallery-parity.sh lists it as skipped.

RunGalleryApp()
