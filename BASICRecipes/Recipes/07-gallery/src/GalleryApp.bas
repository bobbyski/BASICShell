' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The gallery's OmegaCLIDE-form shell: menu bar strip on top, the gallery
' window floating on the desktop, a status strip along the bottom. Boots
' into Modern Turbo; the Theme menu re-dresses everything live.
'
' final class GalleryApp
'
' BASIC has no classes, so the three stored properties are GLOBALs in
' main.bas rather than fields here:
'
'   let app = App(driver: ANSIDriver())   -> GLOBAL app = TUIApp()
'   let settings = GallerySettings(...)   -> GallerySettings.bas's globals
'   private var windowCount = 0           -> GLOBAL windowCount
'
' TUIApp() takes no driver. TUIKit fixes the driver at construction and the
' host owns the terminal, so the binding holds an empty seat until `run` and
' builds the App around the host's driver then.

' Backdrop for themes that don't paint their own desktop (their
' desktop-context background resolves `.standard`) - without it the
' terminal default shows through and reads as a hole.
'
' No `neutralBackdrop` local: the binding applies exactly this fallback
' whenever a theme is set (tuiDesktopFill - cell background, else the
' vector backdrop's top colour, else neutral grey), so in BASIC the
' desktop follows from asking for the theme.

function RunGalleryApp() as variant
    shell = TUIShell()
    ' shell.onQuit = { app.stop() }
    '
    ' Wired by the binding when the app starts, which is the first moment
    ' there is an application to stop. Esc quits from anywhere, and hands the
    ' key to an open dropdown instead - both in TUIShell.

    ' The Log page watches LogStore.shared; the gallery narrates itself
    ' into it - page clicks, and the VTG startup check below. DEBUG so
    ' the page's level filter has layers to peel.
    WireGalleryLogging()
    galleryLog.write("notice", "gallery starting")

    ' Status strip content, declared early so the theme path can
    ' restyle it.
    statusTitle = TUILabel(" TUIKit Gallery")
    statusHint = TUILabel("Tab moves focus - ^L controls panel - Theme menu restyles")
    clock = TUILabel("--:--:--")

    ' func styleStatusChrome() and func applyGalleryTheme(_:) are nested
    ' functions in the Swift, closing over the labels and over `app`. BASIC
    ' has no nested functions and no capture, so both are file-level
    ' functions below reading the same globals.

    ' settings.applyTheme = applyGalleryTheme
    ' settings.setHintsVisible = { visible in ... }
    '
    ' Function values cannot be stored in BASIC, so the settings page calls
    ' ApplyGalleryTheme and SetHintsVisible by name instead of through a
    ' property it was handed. The seam is the same one, named rather than
    ' assigned.

    ' File: more gallery windows, preferences, close, quit.
    let menuBar = TUIMenu()
    menuBar.menu("&File")
    menuBar.item("&New Gallery Window", "FileNewGalleryWindow")
    menuBar.separator()
    menuBar.item("&Preferences...", "FilePreferences")
    menuBar.separator()
    menuBar.item("&Close Window", "FileCloseWindow")
    menuBar.separator()
    menuBar.item("&Quit", "FileQuit")
    '
    ' No keyEquivalent: the binding's `item` takes a title and a handler.
    ' ^N/^P/^W/^Q are not bound, so the menu is the only way to these four.

    ' View: the Controls slide-out of the frontmost gallery window - the
    ' menu's equivalent of ^L and the [>] title button.
    menuBar.menu("&View")
    menuBar.item("Toggle &Controls Panel", "ViewToggleControlsPanel")

    ' Theme: every built-in, so the gallery doubles as the theme tour.
    '
    ' for (name, theme) in TUIKit.Theme.builtIn -> count and name, because
    ' this BASIC has no UBOUND and no FOR EACH. The Swift item closure
    ' captures its theme; a BASIC handler is a name, so the name travels as
    ' the item's third argument and one handler serves all fifteen.
    menuBar.menu("&Theme")
    let themeCount = app.themecount()
    for themeIndex = 0 to themeCount - 1
        let themeName = app.themename(themeIndex)
        menuBar.item(themeName, "ApplyGalleryThemeNamed", themeName)
    next themeIndex

    shell.add(menuBar)
    ' menuBar.anchors / shell.menuBar / shell.makeFirstResponder(menuBar) are
    ' all what `add` does for a menu bar: anchor it across the top row, tell
    ' the shell which bar owns Esc, and focus it.

    ' Status strip with a live clock.
    RefreshClock()
    app.timer(1, "RefreshClock")

    ' `let status = StatusBar()` - renamed, not restyled. STATUS is a reserved
    ' word in this BASIC: the assignment is accepted and the variable then
    ' reads back as 0, so `shell.add(status)` is handed a number and reports
    ' that it expected a view. The Swift name is kept in this comment because
    ' the rename is BASIC's, not the gallery's.
    let statusStrip = TUIStatus()
    ' status.showsSeparators = false - the binding's own default.
    statusStrip.addsegment(statusTitle, 16)
    statusStrip.addsegment(statusHint, 0, 100)
    statusStrip.addsegment(clock, 10)
    ' status.anchors = AnchorSet(leading: 0, trailing: 0, bottom: 0, height: 1)
    ' is what `add` does for a status strip: it owns the last row, the way a
    ' menu bar owns the first.
    shell.add(statusStrip)

    ' Boot look: the remembered theme, else Modern Turbo - via the same
    ' path the menu and the preferences dialog take.
    ApplyGalleryThemeNamed(StoredThemeName())
    SetHintsVisible(ShowsHints())

    app.present(MakeGalleryWindow(0))

    ' The VTG check happens inside run(); the first tick after it can
    ' say what the probe found.
    app.after(100, "ReportVTGCheck")

    ' do { try await app.run(shell) } catch { ... }
    '
    ' BASIC has no try/catch around this: a host with no terminal makes
    ' `run` raise, which the shell reports. The Swift's message and its
    ' "Restored terminal." are the same information the shell prints when a
    ' program ends.
    app.run(shell)

    print "Restored terminal."
    return 0
end function

' The one theming path, used at boot, by every Theme menu item, and
' by the preferences dialog's Appearance page.
'
' Takes the theme's *name* rather than a Theme: BASIC has no theme values,
' and the binding matches a name without case or spaces.
function ApplyGalleryThemeNamed(themeName as string) as variant
    app.theme(themeName)
    ' let backdrop = theme.resolved(for: .desktop).background
    ' app.desktop.fillStyle = ... - done by `theme` itself, which paints the
    ' desktop with the same `.standard` fallback the Swift spells out here.

    StyleStatusChrome()
    return 0
end function

function StyleStatusChrome() as variant
    ' let header = shell.effectiveTheme.header
    ' statusTitle.style = header
    ' var plain = header; plain.flags.remove(.bold)
    '
    ' A BASIC label takes the role name and resolves the style through
    ' itself - same theme, same context, because the strip is already in the
    ' shell by the time this runs.
    statusTitle.style("header")
    statusHint.style("headerplain")
    clock.style("headerplain")
    return 0
end function

function SetHintsVisible(visible as integer) as variant
    if visible = 1 then
        statusHint.text("Tab moves focus - ^L controls panel - Theme menu restyles")
    else
        statusHint.text("")
    end if
    return 0
end function

function RefreshClock() as variant
    ' let clockFormatter = DateFormatter(); dateFormat = "HH:mm:ss"
    '
    ' TIME$ is already HH:mm:ss, so BASIC needs no formatter.
    clock.text(TIME$)
    return 0
end function

' ---------------------------------------------------------------- menu items
'
' One function per menu item, because a BASIC menu item names a handler
' where the Swift writes a closure.

function FileNewGalleryWindow() as variant
    windowCount = windowCount + 1
    app.present(MakeGalleryWindow(windowCount))
    return 0
end function

function FilePreferences() as variant
    PresentPreferences()
    return 0
end function

function FileCloseWindow() as variant
    ' if let target = app.windows.last(where: { $0 !== shell }) { app.dismiss(target) }
    '
    ' BASIC cannot search app.windows, so the binding dismisses the
    ' front-most window that is not the shell - the same one the Swift picks.
    app.dismiss()
    return 0
end function

function FileQuit() as variant
    app.stop()
    return 0
end function

function ViewToggleControlsPanel() as variant
    ' (app.windows.last { $0 is GalleryWindow } as? GalleryWindow)?
    '     .toggleSlideOut(.leading)
    '
    ' `win` is the gallery window this program built; the Swift reaches for
    ' the front-most one because it may have opened several.
    win.toggleslideout("leading")
    return 0
end function

' The VTG check, a tick after the app is up.
function ReportVTGCheck() as variant
    ' app.isVectorChromeActive / app.graphicsCapabilities - the binding
    ' answers the probe as one line rather than as a capability record,
    ' because BASIC has no shape to hand the record back in.
    galleryLog.write("notice", app.vtgreport())
    return 0
end function
