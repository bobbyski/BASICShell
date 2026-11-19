' {{NAME}} — the click counter, in a window of its own made with ActiveUI.
'
' Build it with basicc: make run builds it and runs it (make build only
' builds it, into Build/). The program is a Mac application with a window
' of its own, and it runs until the window closes.
'
' ActiveUI's smallest complete app: a label that counts, and a button.
' Press Click me and the count goes up; Reset takes it back to zero, and is
' grayed out while there is nothing to reset.
'
' THE FILES, in the order worth reading them:
'
'   main.bas                                 you are here: the parts, wired together
'   models/Counter.bas                       the count
'   views/CounterView.bas                    the label and the Click me button
'   controllers/CounterWindowController.bas  the window, Reset, and each count
'
' The model knows nothing of windows, the view never changes the count, and
' the controller is the one part that knows both. README.md says how the
' comments are written.

' ---------------------------------------------------------------- the files
'
' IMPORT reads another file's CLASSes and FUNCTIONs into this program, from
' a path relative to this file. Only this file's own statements run; an
' imported file's are declarations.
IMPORT "models/Counter.bas"
IMPORT "views/CounterView.bas"
IMPORT "controllers/CounterWindowController.bas"

' ---------------------------------------------------------------- the parts
'
' Each part is a GLOBAL, declared here and made below, and the others reach
' it by name. Three things in this BASIC make that the way: an imported
' file's statements do not run (GLOBALs included), an object handed to a
' FUNCTION is a copy (BASIC-35), and the interpreter BASICStudio runs cannot
' yet call a method on an object kept in another object's field.

/// The count.
GLOBAL theCounter AS Counter
/// The count's label and the Click me button.
GLOBAL theCounterView AS CounterView
/// The window's controller, which every button's handler hands its command to.
GLOBAL theWindow AS CounterWindowController

' ------------------------------------------------------------------- start
theCounter = NEW Counter()
theCounterView = NEW CounterView()
theWindow = NEW CounterWindowController()
theWindow.Start("{{NAME}}")
theWindow.Run()
