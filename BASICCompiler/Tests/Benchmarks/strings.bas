' String work, for the dialect performance gate (R2.4).
'
' Rev 2 keeps BASIC strings as the runtime's exact-byte objects and converts
' only where they cross into Swift (R2.1), so this should cost the two
' dialects the same. It is here to *prove* that rather than assume it — a
' regression would mean a conversion crept into a path that stays in BASIC.

DIM s AS STRING
DIM out AS STRING
DIM i AS INTEGER
DIM n AS INTEGER

FOR i = 1 TO 300000
    s = "row-" + STR$(i)
    out = LEFT$(s, 3) + RIGHT$(s, 2)
    n = n + LEN(out) + INSTR(s, "-")
NEXT i

PRINT "STRINGS"; n
