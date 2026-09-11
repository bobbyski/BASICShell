' A BASIC program driving a Swift framework.
'
' The IMPORT below names a Swift package, not a .bas file. basicc asks
' SwiftPM where it is, builds it, reads its symbol graph, and calls its
' members by their own mangled symbols — there is no bridge object and
' nothing is reimplemented here.
'
'   basicc build main.bas -o Build/shapes-demo     ' Package.swift selects Rev 2
'   basicc import-report main.bas                  ' what was imported, and what was not

IMPORT "Shapes"

DIM R AS Rect
R = NEW Rect(3, 4)
PRINT "a rectangle 3 x 4 has area"; R.area()
PRINT "its width is"; R.width; " and its height is"; R.height

' A property write goes to the framework's own storage, so the method
' that reads it next sees the new value.
R.width = 10
PRINT "widened to 10, the area is now"; R.area()

' describe() is Swift's, it builds a Swift String, and the area() it
' calls inside is Rect's override — dispatched by Swift, from here.
PRINT R.describe()
PRINT "sides:"; R.sides()

DIM C AS Circle
C = NEW Circle(1)
PRINT C.describe()

' Strings cross in both directions.
C.rename("a unit circle")
PRINT C.name
PRINT C.describe()

' A Swift method that throws. Swift's throwing convention is
' branch-on-return — the callee writes the error into a register the caller
' reads — so basicc calls it with that register and turns a thrown error into
' an ordinary BASIC error. ON ERROR catches it like any other.
' An event handler written in BASIC, stored by a Swift control as an
' ordinary Swift closure. basicc passes the pair Swift needs — a C function
' pointer and the BASIC closure to invoke — and the shim makes a closure of
' them, so what the framework holds is the real thing.
DIM Taps AS INTEGER
FUNCTION Bump() AS INTEGER
    Taps = Taps + 1
    RETURN Taps
END FUNCTION
DIM B AS Button
B = NEW Button("Go")
B.whenTapped(FUNCTION() AS DOUBLE = Bump())
B.tap()
B.tap()
PRINT "taps recorded by BASIC:"; Taps

' An async Swift method. basicc compiles a shim that starts a real task and
' waits for it, so the suspension is Swift's and the BASIC statement simply
' does not finish until the value is in hand — which is what AWAIT already
' means here.
PRINT "measured (async):"; R.measured()

' Arrays across the boundary (R4.7). A BASIC array goes over as a Swift
' [String], and what comes back is a BASIC array again — LEN and (i) walk
' it, so nothing new had to be added to the language for this.
DIM Names(1) AS STRING
Names(0) = "first"
Names(1) = "second"
DIM Said AS VARIANT
Said = R.labelled(Names)
FOR I = 0 TO LEN(Said) - 1
  PRINT "  "; Said(I)
NEXT I

DIM Factors(2) AS DOUBLE
Factors(0) = 1
Factors(1) = 2
Factors(2) = 0.5
DIM Scaled AS VARIANT
Scaled = R.areas(Factors)
FOR I = 0 TO LEN(Scaled) - 1
  PRINT "  area x factor:"; Scaled(I)
NEXT I

' Plain Swift enums (E2). Tint and Button.Style are the framework's own
' enums; BASIC sees them as ordinary ENUMs — Button.Style is Button_Style,
' a BASIC type name having no dot — and PRINT shows the case's name.
R.tint = Tint.blue
DIM T AS Tint
T = R.tint
PRINT "tint:"; T; " ordinal"; STR$(T)
PRINT R.painted(Tint.green)
DIM Look AS Button_Style
B.style = Button_Style.bold
Look = B.style
PRINT "button style:"; Look

' Swift enums whose cases carry values (E4). Fill is the framework's; BASIC
' reads it the way it reads a payload ENUM of its own.
R.fill = Fill.pattern("stripes", 3)
DIM F AS Fill
F = R.fill
PRINT "fill:"; F
SELECT CASE F
  CASE Fill.pattern
    PRINT "pattern named "; F.name; " at scale"; F.scale
END SELECT
PRINT R.filled(Fill.solid(0.5))
F = R.defaultFill()
PRINT "default fill:"; F

' Members on enums (E5), reached with a dot as VB reaches an enum's members:
' on a value for an instance member, on the type for a static one.
PRINT "warm:"; T.isWarm; " blended: "; T.blended(Tint.red)
DIM Fav AS Tint
Fav = Tint.favourite
PRINT "favourite:"; Fav
PRINT "fill empty:"; F.isEmpty

ON ERROR GOTO Broken
PRINT "scaled by 2:"; R.scaled(2)
PRINT "scaled by -1:"; R.scaled(-1)
PRINT "not reached"
END

Broken:
' ERR is the BASIC error number the thrown ShapeError became. The error's
' own text is what the runtime prints when nothing catches it; BASIC has no
' pseudo-variable for it, which is a gap worth knowing rather than hiding.
PRINT "caught a throw from Swift, ERR ="; ERR
