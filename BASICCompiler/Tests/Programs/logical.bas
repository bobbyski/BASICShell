' The logical operators, and the order they bind in.
'
' All six answer 1 or 0, as every comparison in this language does, and all
' six take the truthiness of what they are given — the same test IF applies,
' so they work on whatever IF works on rather than only on booleans.
'
' Loosest first: IMP, EQV, XOR, OR, AND, NOT, then the comparisons. That is
' where BASIC has always put them, which is why `NOT a = b` inverts the
' comparison rather than the a.
DIM t AS INTEGER
DIM f AS INTEGER
t = 1
f = 0

PRINT "NOT  "; NOT f; NOT t
PRINT "AND  "; (t AND t); (t AND f); (f AND t); (f AND f)
PRINT "OR   "; (t OR t); (t OR f); (f OR t); (f OR f)
PRINT "XOR  "; (t XOR t); (t XOR f); (f XOR t); (f XOR f)
PRINT "EQV  "; (t EQV t); (t EQV f); (f EQV t); (f EQV f)
PRINT "IMP  "; (t IMP t); (t IMP f); (f IMP t); (f IMP f)

' Precedence, each one checked against the parenthesised form it should mean.
DIM a AS INTEGER
DIM b AS INTEGER
a = 1
b = 2
PRINT "cmp  "; (NOT a = b); (NOT (a = b))
PRINT "and  "; (NOT f AND t); ((NOT f) AND t)
PRINT "or   "; (t OR f XOR t); ((t OR f) XOR t)
PRINT "xor  "; (t XOR t EQV f); ((t XOR t) EQV f)
PRINT "eqv  "; (f EQV f IMP f); ((f EQV f) IMP f)

' Truthiness of things that are not booleans.
PRINT "text "; NOT ""; NOT "x"
PRINT "zero "; NOT 0; NOT 5

' In conditions, where they are mostly written.
IF NOT f AND (a < b) THEN PRINT "guarded"
IF a = 1 XOR b = 9 THEN PRINT "exactly one"
IF a = 1 IMP b = 2 THEN PRINT "implied"
