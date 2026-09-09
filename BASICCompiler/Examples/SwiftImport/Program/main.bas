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
