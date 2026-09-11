' ENUM, the payload-free form — VB's enum exactly (E1).
'
' A member is a named integer constant. Values start at 0 and increment; an
' explicit `= n` resets the run. The value IS its number, so it compares and
' converts like one. What it does *not* do is print like one: PRINT shows the
' member's name, which is what VB's ToString does, and STR$ shows the number,
' which is what VB's CStr does. Same split, same place.

ENUM Suit
  Hearts
  Diamonds = 5
  Clubs
  Spades
END ENUM

ENUM Level
  Low
  Mid
  High
END ENUM

' The ordinals: implicit from 0, and an explicit value restarting the run.
' STR$ is asked for here because PRINT of an enum shows the *name* — the two
' halves of VB's split, side by side.
PRINT "ordinals:"; STR$(Suit.Hearts); STR$(Suit.Diamonds); STR$(Suit.Clubs); STR$(Suit.Spades)
PRINT "names:"; Suit.Hearts; Suit.Diamonds; Suit.Clubs; Suit.Spades

DIM S AS Suit
S = Suit.Clubs

' PRINT shows the name (VB's ToString); STR$ shows the number (VB's CStr).
PRINT "print:"; S
PRINT "str$ :"; STR$(S)

' It is a number, so it compares and does arithmetic like one.
IF S = Suit.Clubs THEN PRINT "equal to Clubs"
IF S > Suit.Hearts THEN PRINT "greater than Hearts"
PRINT "plus one:"; S + 1

' SELECT CASE, which is how a BASIC programmer would actually read one.
SELECT CASE S
  CASE Suit.Hearts
    PRINT "select: hearts"
  CASE Suit.Clubs
    PRINT "select: clubs"
  CASE ELSE
    PRINT "select: something else"
END SELECT

' A second enum, to show the names are per-type and not one flat namespace.
DIM L AS Level
L = Level.High
PRINT "level:"; L; "value"; STR$(L)

' Assigning a number in is legal in the payload-free form, exactly as VB
' allows CType(6, Suit). A value that matches a member prints as that member.
S = 5
PRINT "from a number:"; S

' A value matching no member prints as the number, as VB's ToString does.
S = 42
PRINT "no member:"; S

' The default is zero, which here is a member.
DIM D AS Suit
PRINT "default:"; D
