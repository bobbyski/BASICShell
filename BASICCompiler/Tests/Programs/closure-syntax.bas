' Closure syntax (Documents/CLOSURES.md, Phase 3): a multi-line closure
' wherever an expression goes, VOID closures, nesting, VARIANT results.
FUNCTION TYPE Unary(x AS INTEGER) AS INTEGER
FUNCTION TYPE Action() AS VOID
TYPE Holder
  F AS Unary
END TYPE

FUNCTION Apply(f AS Unary, n AS INTEGER) AS INTEGER
  RETURN f(n)
END FUNCTION

FUNCTION Twice(a AS Action) AS VOID
  a()
  a()
END FUNCTION

FUNCTION Hello() AS VOID
  PRINT "HELLO"
END FUNCTION

FUNCTION MakeAdder(n AS INTEGER) AS Unary
  RETURN FUNCTION(x AS INTEGER) AS INTEGER
    RETURN x + n
  END FUNCTION
END FUNCTION

' An argument, the call going on after END FUNCTION.
PRINT "APPLY"; Apply(FUNCTION(x AS INTEGER) AS INTEGER
  LOCAL y AS INTEGER = x * 2
  RETURN y + 1
END FUNCTION, 5)

' A VOID closure: no AS on the multi-line form.
count = 0
Twice(FUNCTION()
  count = count + 1
END FUNCTION)
PRINT "COUNT"; count

' AS VOID on the one-line form runs a call.
DIM greet AS Action
greet = FUNCTION() AS VOID = Hello()
greet()

' After RETURN.
add5 = MakeAdder(5)
PRINT "ADDER"; add5(10)

' Assigned to a field.
DIM h AS Holder
h.F = FUNCTION(x AS INTEGER) AS INTEGER
  RETURN x * 10
END FUNCTION
PRINT "FIELD"; h.F(4)

' Nested.
outer = FUNCTION(a AS INTEGER) AS INTEGER
  inner = FUNCTION(b AS INTEGER) AS INTEGER
    RETURN a * b
  END FUNCTION
  RETURN inner(3) + 1
END FUNCTION
PRINT "NESTED"; outer(7)

' VARIANT results.
pick = FUNCTION(n AS INTEGER) = n * 2
PRINT "VARIANT"; pick(21)
mixed = FUNCTION(n AS INTEGER) AS VARIANT
  IF n > 0 THEN RETURN "POSITIVE"
  RETURN n
END FUNCTION
PRINT "MIXED "; mixed(1); mixed(-2)
