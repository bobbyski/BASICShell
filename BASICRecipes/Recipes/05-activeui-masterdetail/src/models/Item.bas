' Item.bas — one item, and whether it matches a search.
'
' Plain BASIC: nothing here knows there is a window, so the same item works
' in a program with no screen at all.

/// One item: a title, its notes, and whether it is a favorite.
TYPE Item
    /// What the item is called; the sidebar lists it by this.
    Title AS STRING
    /// What is written about it.
    Notes AS STRING
    /// Whether it is in Favorites, at the top of the sidebar.
    IsFavorite AS BOOLEAN
END TYPE

/// The name the sidebar and the detail give an item.
///
/// - Parameter entry: The item.
/// - Returns: Its title, or "Untitled" when it has none yet.
FUNCTION DisplayTitle$(entry AS Item) AS STRING
    IF entry.Title = "" THEN RETURN "Untitled"
    RETURN entry.Title
END FUNCTION

/// Whether an item matches what was typed in the search field.
///
/// - Parameter entry: The item.
/// - Parameter query: What was typed; "" matches every item.
/// - Returns: TRUE when the title or the notes hold the query, whatever
///   its case.
FUNCTION ItemMatches(entry AS Item, query AS STRING) AS BOOLEAN
    IF query = "" THEN RETURN TRUE
    LOCAL wanted$ = UpperCase$(query)
    IF INSTR(UpperCase$(entry.Title), wanted$) > 0 THEN RETURN TRUE
    IF INSTR(UpperCase$(entry.Notes), wanted$) > 0 THEN RETURN TRUE
    RETURN FALSE
END FUNCTION

/// A original in capitals, so a search can ignore case.
///
/// This BASIC has no UCASE$ yet, so the letters a to z are turned into
/// capitals here, one at a time; every other character stays as it is.
///
/// - Parameter original: The original.
/// - Returns: The same original with a to z in capitals.
FUNCTION UpperCase$(original AS STRING) AS STRING
    LOCAL result$ = ""
    LOCAL code = 0
    LOCAL i = 0
    FOR i = 1 TO LEN(original)
        code = ASC(MID$(original, i, 1))
        ' a is 97 and z is 122; each capital is 32 before its letter.
        IF code >= 97 AND code <= 122 THEN code = code - 32
        result$ = result$ + CHR$(code)
    NEXT i
    RETURN result$
END FUNCTION
