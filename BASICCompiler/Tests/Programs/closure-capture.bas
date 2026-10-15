' Closure captures (Documents/CLOSURES.md, rulings C1-C6): a closure shares
' the variables it uses, as VB's do; CAPTURES STRONG is its own copy, which
' it may change; CAPTURES READONLY is a frozen copy it may not.
FUNCTION TYPE Counter() AS INTEGER
FUNCTION TYPE Getter() AS INTEGER

' A function's local, shared after the function returns: each counter counts.
FUNCTION MakeCounter() AS Counter
  LOCAL count AS INTEGER = 0
  LOCAL tick AS Counter
  tick = FUNCTION() AS INTEGER
    count = count + 1
    RETURN count
  END FUNCTION
  RETURN tick
END FUNCTION
c = MakeCounter()
d = MakeCounter()
PRINT "COUNTERS"; c(); c(); c(); d()

' A write reaches the variable, and a later change is seen.
total = 0
add = FUNCTION(n AS INTEGER) AS INTEGER
  total = total + n
  RETURN total
END FUNCTION
x = add(5)
x = add(7)
PRINT "TOTAL"; total
total = 100
PRINT "AFTER"; add(1)

' The variable where the closure was made, not a caller's of the same name.
FUNCTION Caller() AS INTEGER
  LOCAL total AS INTEGER = 500
  RETURN add(1)
END FUNCTION
PRINT "CALLER"; Caller(); total

' MUTABLE spells the default out.
n = 10
bump = FUNCTION() AS INTEGER CAPTURES MUTABLE n
  n = n + 1
  RETURN n
END FUNCTION
x = bump()
PRINT "MUTABLE"; n

' STRONG: the closure's own copy, kept between calls.
m = 10
own = FUNCTION() AS INTEGER CAPTURES STRONG m
  m = m + 1
  RETURN m
END FUNCTION
PRINT "STRONG"; own(); own()
m = 50
PRINT "STRONG"; own(); m

' READONLY: frozen; READONLY's other names are shared.
prefix$ = "LOCKED="
bonus = 5
locked = FUNCTION(v AS INTEGER) AS STRING CAPTURES READONLY prefix$ = prefix$ + STR$(v + bonus)
prefix$ = "LIVE="
bonus = 20
PRINT locked(2)

' A shared array.
DIM a(3) AS INTEGER
setter = FUNCTION(i AS INTEGER, v AS INTEGER) AS INTEGER
  a(i) = v
  RETURN a(i)
END FUNCTION
x = setter(2, 42)
a(1) = 7
PRINT "ARRAY"; a(2); a(1) + a(2)

' A function's local array, shared after it returns.
FUNCTION MakeStack() AS Getter
  DIM items(5) AS INTEGER
  LOCAL top AS INTEGER = 0
  LOCAL push AS Getter
  push = FUNCTION() AS INTEGER
    top = top + 1
    items(top) = top * 10
    RETURN items(top) + items(1)
  END FUNCTION
  RETURN push
END FUNCTION
p = MakeStack()
x = p()
PRINT "STACK"; p(); p()

' ME is the closure's own copy (C6); a record can be READONLY or shared.
FUNCTION TYPE Bump() AS INTEGER
TYPE Pt
  X AS INTEGER
END TYPE
CLASS Box
  PUBLIC N AS INTEGER
  FUNCTION Bumper() AS Bump
    LOCAL b AS Bump
    b = FUNCTION() AS INTEGER
      ME.N = ME.N + 1
      RETURN ME.N
    END FUNCTION
    RETURN b
  END FUNCTION
END CLASS
DIM box AS Box
box = NEW Box()
box.N = 5
f = box.Bumper()
PRINT "ME"; f(); f(); box.N
DIM pt AS Pt
pt.X = 3
g = FUNCTION() AS INTEGER CAPTURES READONLY pt = pt.X * 2
h = FUNCTION() AS INTEGER
  pt.X = pt.X + 1
  RETURN pt.X
END FUNCTION
pt.X = 4
PRINT "RECORD"; g(); h(); pt.X

' Assigning a READONLY capture is an error ON ERROR traps.
ON ERROR GOTO Trapped
q$ = "A"
frozen = FUNCTION() AS STRING CAPTURES READONLY q$
  q$ = "B"
  RETURN q$
END FUNCTION
r$ = frozen()
PRINT "AFTER TRAP "; q$
END

Trapped:
  PRINT "TRAPPED"; ERR
  RESUME NEXT
