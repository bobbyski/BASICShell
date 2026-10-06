' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The gallery's real preferences: a `Preferences` suite on disk and the
' `PreferencesDialog` that edits it - reached from the toolbar's Settings
' button and File > Preferences..., the way an app would do it.
'
' Keys: `theme` (a built-in theme name), `controlsPanelOpen` (whether the
' Controls slide-out starts open), `showsHints` (the status-bar hint).
'
' final class GallerySettings
'
' BASIC has no classes, so the store is a GLOBAL in main.bas and the
' computed properties below are functions. The two closure properties -
'
'   var applyTheme: (Theme) -> Void
'   var setHintsVisible: (Bool) -> Void
'
' - are not stored at all: BASIC cannot hold a function value, so the pages
' call ApplyGalleryThemeNamed and SetHintsVisible in GalleryApp.bas by name.
' The seam is the same one, named rather than assigned.

' var storedTheme: Theme?
'
' Returns the *name*, not a Theme: BASIC has no theme values, and the name is
' what every consumer of this ends up passing on. "" would be the Swift's
' nil, so the fallback to Modern Turbo lives here rather than at the call
' site, where `?? .modernTurbo` is in the Swift.
function StoredThemeName() as string
    ' `let name = store.string(forKey: "theme")` - renamed: NAME is a
    ' reserved word, so a variable called `name` reads back empty.
    let storedName = prefsStore.text("theme")
    if storedName = "" then
        return "Modern Turbo"
    end if

    ' guard the stored name still names a built-in one, as
    ' `Theme.builtIn.first { $0.name == name }` does - a suite that outlives a
    ' renamed theme should fall back rather than fail.
    for themeIndex = 0 to app.themecount() - 1
        if app.themename(themeIndex) = storedName then
            return storedName
        end if
    next themeIndex

    return "Modern Turbo"
end function

' var controlsPanelOpen: Bool { get { ... ?? false } set { ... } }
'
' A BASIC function cannot be a property, so the getter and setter are two.
function ControlsPanelOpen() as integer
    return prefsStore.flag("controlsPanelOpen", 0)
end function

function SetControlsPanelOpen(value as integer) as variant
    prefsStore.setflag("controlsPanelOpen", value)
    return 0
end function

' var showsHints: Bool { get { ... ?? true } set { ... } }
function ShowsHints() as integer
    return prefsStore.flag("showsHints", 1)
end function

function SetShowsHints(value as integer) as variant
    prefsStore.setflag("showsHints", value)
    return 0
end function

' Presents the preferences dialog - the same pages in either selector
' style (the toolbar strip is the default; the split list is the
' legacy look).
'
' No `style` parameter: the binding builds the toolbar strip, which is the
' Swift's default and the only style the gallery asks for.
function PresentPreferences() as variant
    let dialog = TUIPrefsDialog("Preferences")

    ' General: the two behaviours the gallery itself reads.
    panelCheck = TUICheck("Open the Controls panel at launch")
    panelCheck.checked(ControlsPanelOpen())
    panelCheck.onchange("PreferencesPanelChanged")
    hintsCheck = TUICheck("Show the status-bar hint")
    hintsCheck.checked(ShowsHints())
    hintsCheck.onchange("PreferencesHintsChanged")
    let general = TUIForm()
    general.field("Startup", panelCheck)
    general.field("Status bar", hintsCheck)

    ' Appearance: the theme, applied live and remembered.
    let themeCount = app.themecount()
    let stored = StoredThemeName()
    let current = 0
    themePopUp = TUIPopup()
    for themeIndex = 0 to themeCount - 1
        let themeName = app.themename(themeIndex)
        themePopUp.additem(themeName)
        if themeName = stored then
            current = themeIndex
        end if
    next themeIndex
    themePopUp.selected(current)
    themePopUp.onselect("PreferencesThemeChanged")
    let appearance = TUIForm()
    appearance.field("Theme", themePopUp)

    dialog.addpage("General", "*", general)
    dialog.addpage("Appearance", "~", appearance)
    dialog.addbutton("&Done", 1)
    ' dialog.onDismiss = { app.dismiss(dialog) } and the two sizeToFit calls
    ' either side of the present are what `show` does - TUIKit's own document
    ' controller sizes twice, once before the desktop has given the dialog a
    ' frame and once after.
    app.show(dialog)
    return 0
end function

' The three onChange/onSelectionChanged closures, as named handlers. Each
' reads its control rather than being handed the new value, because a BASIC
' handler takes no argument from a control.

function PreferencesPanelChanged() as variant
    SetControlsPanelOpen(panelCheck.checked())
    return 0
end function

function PreferencesHintsChanged() as variant
    let visible = hintsCheck.checked()
    SetShowsHints(visible)
    SetHintsVisible(visible)
    return 0
end function

function PreferencesThemeChanged() as variant
    let index = themePopUp.selected()
    if index < 0 then
        return 0
    end if

    ' self.store.set(names[index], forKey: "theme"); self.applyTheme(...)
    let themeName = app.themename(index)
    prefsStore.settext("theme", themeName)
    ApplyGalleryThemeNamed(themeName)
    return 0
end function
