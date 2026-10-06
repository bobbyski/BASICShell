' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The Log page: TUILogger's tools, watching the gallery's own diagnostics.
' The gallery logs its page clicks and the VTG startup check into
' LogStore.shared (see GalleryApp), so this page fills itself by being used -
' switch a few tabs and come back.

' extension LogCategory { static let gallery = "gallery" }
'
' BASIC has no extensions and no LogCategory type. The binding takes the
' category as a plain string and passes "gallery" for every line the gallery
' writes, which is what the constant stood for.

' Points TUILogger at the shared store, once - called by the app's run and
' by the page, whichever gets there first (snapshots never run the app).
'
' In BASIC this is what TUILog() does when it is constructed: it adds
' LogStore.shared to TUILogger and sets the level to debug. Constructing one
' is therefore the only way to wire the logger - so `galleryLoggingWired`
' guards it exactly as the Swift's private var does, and the handle is kept
' in a global because BASIC writes log lines through it rather than through
' a shared logger.
function WireGalleryLogging() as variant
    if galleryLoggingWired = 1 then
        return galleryLog
    end if

    galleryLoggingWired = 1
    galleryLog = TUILog()
    return galleryLog
end function

function MakeLogTab() as variant
    WireGalleryLogging()

    ' return LogView() - a fresh view, watching the same store. In BASIC a
    ' second TUILog() is that view; both show every line either one writes.
    let logView = TUILog()

    ' The page fills itself with the gallery's own diagnostics - page
    ' clicks, the VTG check - but an empty first open (or a snapshot) should
    ' still show what a log looks like, so seed one line per band. Flushed,
    ' so they are in the store before the view reads it.
    '
    ' The Swift seeds "gallery starting" only when the store is empty. BASIC
    ' cannot read LogStore.entries, so the line is written unconditionally;
    ' on a second open it appears twice rather than once.
    logView.write("notice", "gallery starting")

    logView.write("debug", "log page built - this line is DEBUG; the level picker hides it first")
    logView.write("info", "sample: something worth knowing happened")
    logView.write("warning", "sample: something is off but the gallery carried on")
    logView.write("error", "sample: something failed (it did not - this is the Log page)")

    return logView
end function
