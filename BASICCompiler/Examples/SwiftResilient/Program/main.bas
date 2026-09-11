' A BASIC class inheriting a class from a resilient Swift framework (R1.5).
'
' Canvas is built with library evolution, so where Widget's fields end is
' not known until the program runs. basicc does not try to know it: it
' writes Panel as Swift and lets swiftc lay it out, and the BASIC bodies of
' width and label are what Swift's own dispatch reaches.
'
'   ./run.sh

IMPORT "Canvas"

CLASS Panel
  INHERITS Widget
  PUBLIC Columns AS DOUBLE
  PUBLIC Title AS STRING
  OVERRIDES FUNCTION width() AS DOUBLE
    RETURN ME.Columns * 8
  END FUNCTION
  OVERRIDES FUNCTION label() AS STRING
    RETURN ME.Title + " (" + ME.name + ")"
  END FUNCTION
END CLASS

DIM P AS Panel
P = NEW Panel("main")
P.Columns = 10
P.Title = "Editor"
PRINT P.summary()

' The framework's own field and the program's, side by side in one object.
P.name = "side"
P.Columns = 3
PRINT P.summary()
PRINT "visible:"; P.visible; " columns:"; P.Columns
