' {{NAME}} — a full-screen terminal application, made with TUIKit.
'
' Run it in a terminal: a menu bar, a window with a toolbar, a field and a
' list, and a status line. Tab moves between controls, Enter presses one,
' Alt-F opens the File menu, and File ▸ Quit (or Quit in the toolbar)
' closes the application, as Esc does.
'
' THE FILES, in the order worth reading them:
'
'   main.bas                              you are here: the parts, wired together
'   models/LanguageList.bas               the languages to pick from
'   models/Greeting.bas                   what the program says back
'   views/GreetingView.bas                the banner, the name field, the list
'   views/StatusLine.bas                  the line along the bottom
'   controllers/MainWindowController.bas  the window, its toolbar, every command
'   app/AppMenus.bas                      the menu bar
'
' The models know nothing of the screen, the views never decide anything,
' and the controller is the one part that knows both. README.md says how
' the comments are written.

' ---------------------------------------------------------------- the files
'
' IMPORT reads another file's CLASSes and FUNCTIONs into this program, from
' a path relative to this file. Only this file's own statements run; an
' imported file's are declarations.
IMPORT "models/LanguageList.bas"
IMPORT "models/Greeting.bas"
IMPORT "views/GreetingView.bas"
IMPORT "views/StatusLine.bas"
IMPORT "controllers/MainWindowController.bas"
IMPORT "app/AppMenus.bas"

' ---------------------------------------------------------------- the parts
'
' Each part is a GLOBAL, declared here and made below, and the others reach
' it by name. Three things in this BASIC make that the way: an imported
' file's statements do not run (GLOBALs included), an object handed to a
' FUNCTION is a copy (BASIC-35), and the interpreter cannot yet call a
' method on an object kept in another object's field.

/// The application: TUIKit's run loop.
GLOBAL theApp AS VARIANT
/// The window's content: the banner, the field and the list.
GLOBAL theGreetingView AS GreetingView
/// The status line along the bottom.
GLOBAL theStatusLine AS StatusLine
/// The window's controller, which every handler hands its command to.
GLOBAL theWindow AS MainWindowController

' ------------------------------------------------------------------- start
theApp = TUIApp()
theGreetingView = NEW GreetingView()
theStatusLine = NEW StatusLine()
theWindow = NEW MainWindowController()
theWindow.Start("{{NAME}}", StarterLanguages())
theWindow.Run()

' Back here once Quit has stopped the app: the terminal is ours again.
PRINT "{{NAME}} closed."
IF theWindow.LastStatus <> "" THEN PRINT "Last status: " + theWindow.LastStatus
