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
' Each one is labelled with the Swift file and binding it stands for, so the
' side-by-side reading still works.

' GalleryApp.swift
GLOBAL app = TUIApp()
GLOBAL statusTitle AS VARIANT
GLOBAL statusHint AS VARIANT
GLOBAL clock AS VARIANT
GLOBAL shell AS VARIANT
GLOBAL windowCount = 0

' GalleryLogPage.swift
GLOBAL galleryLog AS VARIANT
GLOBAL galleryLoggingWired = 0

' GallerySettings.swift
'
' `store` is the Swift's `let store: Preferences`. STORE is not reserved, but
' the name is kept distinct from the gallery's other handles for the same
' reason the Swift qualifies it with `self.`.
GLOBAL prefsStore = TUIPrefs("com.tuikit.gallery")
GLOBAL panelCheck AS VARIANT
GLOBAL hintsCheck AS VARIANT
GLOBAL themePopUp AS VARIANT

' GalleryWindow.swift
GLOBAL win AS VARIANT
GLOBAL tabs AS VARIANT
GLOBAL address AS VARIANT
GLOBAL controlsIndex AS VARIANT

' GalleryControlTabs.swift
GLOBAL holdResult AS VARIANT
GLOBAL dialogResult AS VARIANT
GLOBAL spinner AS VARIANT
GLOBAL days AS VARIANT

' GalleryNewPages.swift
GLOBAL searchResult AS VARIANT
GLOBAL search AS VARIANT
GLOBAL span AS VARIANT
GLOBAL spanLabel AS VARIANT
GLOBAL daysLabel AS VARIANT
GLOBAL days AS VARIANT
GLOBAL wizardName AS VARIANT
GLOBAL wizardDone AS VARIANT

' GalleryNavigationTab.swift
GLOBAL pages AS VARIANT
GLOBAL pageLabel AS VARIANT
GLOBAL navigator AS VARIANT
GLOBAL depthLabel AS VARIANT

' GalleryDataTabs.swift
GLOBAL markdown AS VARIANT
GLOBAL editToggle AS VARIANT
GLOBAL toolbox AS VARIANT
GLOBAL toolLabel AS VARIANT
GLOBAL splitter AS VARIANT
GLOBAL splitAxisIsHorizontal = 1
GLOBAL layoutStatus AS VARIANT
GLOBAL linkResult AS VARIANT

' GallerySiblingPages.swift
GLOBAL boardMoved AS VARIANT
GLOBAL diagramSelected AS VARIANT

' The snapshot branch of main.swift is deliberately absent: GallerySnapshot
' renders every tab to SVG headlessly, which is a test harness rather than
' part of the app. Scripts/gallery-parity.sh lists it as skipped.

RunGalleryApp()
