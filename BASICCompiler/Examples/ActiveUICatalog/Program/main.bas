' The ActiveUI catalog, in BASIC — page one.
'
' ActiveUI is a real Swift framework of 157 classes, imported by reading its
' own symbol graph. There is no binding layer here: no shims written by hand,
' no generated wrapper to keep in step. IMPORT and call.
'
'   ./run.sh              build and run
'   ./run.sh --report     what imported, and what did not
'   ./run.sh --probe      every shim compiled, every thunk emitted
'
IMPORT "ActiveUI"

PRINT "== ActiveUI, driven from BASIC =="
PRINT

' A label. NEW calls the framework's own initializer; the property reads and
' writes go through its real accessors, so what it says back is its own state.
DIM Caption AS AUILabel
Caption = NEW AUILabel("Hello from BASIC")
PRINT "label text     : "; Caption.text
Caption.isBold = TRUE
Caption.isUnderlined = TRUE
PRINT "bold, underline: "; Caption.isBold; " "; Caption.isUnderlined

' An imported Swift enum, spelled as a BASIC ENUM (E2).
Caption.alignment = AUILabel_Alignment.center
PRINT "alignment      : "; Caption.alignment

' The same enum in a variable of its own, for comparison with the property
' read above: VB's rule is that PRINT shows the name.
DIM Side AS AUILabel_Alignment
Side = AUILabel_Alignment.center
PRINT "enum variable  : "; Side

' Static members — VB's Shared — read on the class itself, with no instance.
PRINT "appearance     : "; AUIApplication.appearance
PRINT "logs uncaught  : "; AUIApplication.logsUncaughtExceptions

' A button, and its title read back through the framework.
DIM Go AS AUIButton
Go = NEW AUIButton("Press me")
PRINT "button title   : "; Go.title

' A stack, ActiveUI's layout container, holding the label and the button.
' Its spacing is a CGFloat — which kept the stack from being constructed at
' all until the compiler spelled a CGFloat's symbol the way the binary does.
DIM Column AS AUIStack
Column = NEW AUIStack(AUIStack_Axis.vertical, 12, AUIStack_CrossAxisAlignment.leading, AUIStack_LayoutMode.flow)
Column.addChild(Caption)
Column.addChild(Go)
PRINT "stack axis     : "; Column.axis
PRINT "stack spacing  : "; Column.spacing
Column.spacing = 20
PRINT "spacing now    : "; Column.spacing

' A path, built the way the Swift catalog's Drawing page builds one. Every
' point is a CGPoint that crosses as two numbers and is rebuilt in the shim.
DIM Outline AS AUIBezierPath
Outline = NEW AUIBezierPath()
Outline.move(10, 10)
Outline.line(90, 10)
Outline.arc(50, 50, 40, 0, 3.14159, TRUE)
Outline.rect(0, 0, 100, 100)
Outline.close()
PRINT "path built     : move, line, arc, rect, close"

' A window, built around the stack. Nothing is shown: making the window is
' the test, and a catalog page that opens a window belongs behind --run.
DIM Shell AS AUIWindow
Shell = NEW AUIWindow("Catalog", Column, AUIRootPlacement.centered)
PRINT "window title   : "; Shell.title
