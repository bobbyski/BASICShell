' Exact-byte strings and the named constants.
'
' A BASIC string is bytes, not characters: CHR$(0) survives, a high byte
' survives, and MKI$/CVI round-trip. And a named constant stays itself
' however a program assigns to it.
DIM s AS STRING
s = "A" + CHR$(0) + "B"
PRINT "LEN ="; LEN(s)
PRINT "ASC ="; ASC(s)
PRINT "EQUALS PLAIN ="; (s = "AB")
PRINT "CHR EQUALS ="; (CHR$(65) = "A")

PRINT "MKI ="; LEN(MKI$(258)); CVI(MKI$(258))
PRINT "MKS ="; LEN(MKS$(2.5)); CVS(MKS$(2.5))
PRINT "MKD ="; LEN(MKD$(1.5)); CVD(MKD$(1.5))

DIM high AS STRING
high = CHR$(255) + CHR$(200)
PRINT "HIGH ="; ASC(high); LEN(high)

PRINT "RAW ="; RAW; " TEXT ="; TEXT; " JSON ="; JSON
RAW = "changed"
PRINT "STILL ="; RAW
