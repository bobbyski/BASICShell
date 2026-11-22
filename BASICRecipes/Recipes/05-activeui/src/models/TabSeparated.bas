' TabSeparated.bas — the file format: one record a line, fields split by tabs.
'
'     done<TAB>Buy milk
'     todo<TAB>Call Ada\tor Grace
'
' A tab, a new line or a backslash inside a field is written as \t, \n or
' \\, so every record stays on one line and every field stays whole.

/// A field made safe to write between tabs, on one line.
///
/// - Parameter original: The field as the app holds it.
/// - Returns: The same original with each backslash, tab and new line escaped.
FUNCTION EscapeField$(original AS STRING) AS STRING
    LOCAL result$ = ""
    LOCAL c$ = ""
    LOCAL i = 0
    ' One character at a time: the escapes are the only ones that change.
    FOR i = 1 TO LEN(original)
        c$ = MID$(original, i, 1)
        SELECT CASE c$
            CASE "\": result$ = result$ + "\\"
            CASE CHR$(9): result$ = result$ + "\t"
            CASE CHR$(10): result$ = result$ + "\n"
            CASE ELSE: result$ = result$ + c$
        END SELECT
    NEXT i
    RETURN result$
END FUNCTION

/// A field as it was before ``EscapeField$`` wrote it.
///
/// - Parameter escaped: The field as the file holds it.
/// - Returns: The escaped with \t, \n and \\ turned back into a tab, a new line
///   and a backslash.
FUNCTION UnescapeField$(escaped AS STRING) AS STRING
    LOCAL result$ = ""
    LOCAL c$ = ""
    LOCAL i = 1
    WHILE i <= LEN(escaped)
        c$ = MID$(escaped, i, 1)
        ' A backslash and the character after it are one escape.
        IF c$ = "\" AND i < LEN(escaped) THEN
            c$ = MID$(escaped, i + 1, 1)
            SELECT CASE c$
                CASE "t": result$ = result$ + CHR$(9)
                CASE "n": result$ = result$ + CHR$(10)
                CASE ELSE: result$ = result$ + c$
            END SELECT
            i = i + 2
        ELSE
            result$ = result$ + c$
            i = i + 1
        END IF
    WEND
    RETURN result$
END FUNCTION

/// One field of a record, unescaped.
///
/// - Parameter entry: A line of the file, without its new line.
/// - Parameter index: Which field, from 0.
/// - Returns: The field, or "" when the record has fewer fields.
FUNCTION FieldAt$(entry AS STRING, index AS INTEGER) AS STRING
    LOCAL rest$ = entry
    LOCAL skipped = 0
    LOCAL tabAt = 0
    ' Drop a field and its tab until the one wanted is at the front.
    WHILE skipped < index
        tabAt = INSTR(rest$, CHR$(9))
        IF tabAt = 0 THEN RETURN ""
        rest$ = MID$(rest$, tabAt + 1)
        skipped = skipped + 1
    WEND
    ' Then keep it up to the next tab, if there is one.
    LOCAL endAt = INSTR(rest$, CHR$(9))
    IF endAt > 0 THEN rest$ = LEFT$(rest$, endAt - 1)
    RETURN UnescapeField$(rest$)
END FUNCTION

/// The line of a fileText that starts at a place, without its new line.
///
/// - Parameter fileText: The whole file.
/// - Parameter start: Where the line starts, from 1.
/// - Returns: The line.
FUNCTION LineAt$(fileText AS STRING, start AS INTEGER) AS STRING
    LOCAL rest$ = MID$(fileText, start)
    LOCAL endAt = INSTR(rest$, CHR$(10))
    IF endAt = 0 THEN RETURN rest$
    RETURN LEFT$(rest$, endAt - 1)
END FUNCTION
