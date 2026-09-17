' The ActiveUI catalog, in BASIC — page one.
'
' ActiveUI is a real Swift framework of 157 classes, imported by reading its
' own symbol graph. There is no binding layer here: no shims written by hand,
' no generated wrapper to keep in step. IMPORT and call.
'
'   ./run.sh              build, print the tour, and open the window
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

' Structs as BASIC TYPE records. A view's padding is an AUIEdgeInsets: built
' here, written into the label, and read back out of the framework. A label's
' preferred size is a CGSize the framework works out and hands back.
DIM Insets AS AUIEdgeInsets
Insets.top = 8
Insets.leading = 16
Insets.bottom = 4
Insets.trailing = 12
Caption.padding = Insets
DIM Back AS AUIEdgeInsets
Back = Caption.padding
PRINT "padding        : "; Back.top; " "; Back.leading; " "; Back.bottom; " "; Back.trailing
DIM Fits AS CGSize
Fits = Caption.preferredSize(400, 400)
PRINT "label fits in  : "; Fits.width; " x "; Fits.height

' A button, and its title read back through the framework.
DIM Go AS AUIButton
Go = NEW AUIButton("Press me")
PRINT "button title   : "; Go.title

' A boxed struct, made and used from BASIC. AUIColor wraps a platform color,
' so BASIC holds it in a box and reaches what it can do the way it reaches an
' enum's members: C.isDark, C.opacity(0.25), AUIColor.primary.
DIM Red AS AUIColor
Red = NEW AUIColor(1, 0, 0, 1)
PRINT "red is dark    : "; Red.isDark
PRINT "red as CSS     : "; Red.cssText
DIM Faint AS AUIColor
Faint = Red.opacity(0.25)
PRINT "faint as CSS   : "; Faint.cssText
Caption.textColor = Red
DIM Shown AS AUIColor
Shown = Caption.textColor
PRINT "label color    : "; Shown.cssText
DIM Primary AS AUIColor
Primary = AUIColor.primary
PRINT "primary is dark: "; Primary.isDark

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

' The window. AUIApplication.run is the same call the Swift catalog ends
' with: it starts the platform application - AppKit on macOS - puts the
' root view in a real window, and keeps the main thread until the app quits,
' so nothing after it runs. Everything PRINTed above is already on the
' terminal by then; the window is the catalog.
'
' Set AUI_BACKGROUND=1 to open it without taking the keyboard focus, which
' is what an automated run wants.
PRINT "opening window : close it or press Cmd-Q to quit"
AUIApplication.run(Column, AUIRootPlacement.centered)
