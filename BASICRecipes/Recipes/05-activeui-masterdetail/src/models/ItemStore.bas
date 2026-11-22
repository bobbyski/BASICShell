' ItemStore.bas — the items between launches: items.txt, in and out.
'
'     ReadItems(path)          ──► an ItemList (three samples on a first run)
'     WriteItems(path, items)  ──► items.txt, replaced whole
'
' One item a line, in TabSeparated.bas's format: `favorite` or `item`, the
' title and the notes, split by tabs. The controller writes after every
' change, so quitting never loses anything.

/// The items a file holds, or the samples a first launch starts with.
///
/// - Parameter path: The file, such as `.../Application Support/MyApp/items.txt`.
/// - Returns: The items, in the file's order.
FUNCTION ReadItems(path AS STRING) AS ItemList
    LOCAL items AS ItemList
    items = NEW ItemList()

    ' No file yet: this is the first launch, so start with something to read.
    IF NOT File.Exists(path) THEN
        items.Add("Getting started", "A list on the left, the chosen item on the right. Edit the title and these notes; they are saved as you type.", TRUE)
        items.Add("The model", "models/Item.bas, ItemList.bas and ItemStore.bas: plain BASIC, and the file.", FALSE)
        items.Add("The views", "views/ItemSidebarView.bas and views/ItemDetailView.bas show; the controller decides.", FALSE)
        RETURN items
    END IF

    ' Each line is one item; a blank line (the last one) is none.
    LOCAL text$ = File.ReadText$(path)
    LOCAL start = 1
    LOCAL entry$ = ""
    LOCAL isFavorite AS BOOLEAN
    WHILE start <= LEN(text$)
        entry$ = LineAt$(text$, start)
        IF entry$ <> "" THEN
            ' A comparison is a number here, not a BOOLEAN, so the flag is
            ' set in two steps.
            isFavorite = FALSE
            IF FieldAt$(entry$, 0) = "favorite" THEN isFavorite = TRUE
            items.Add(FieldAt$(entry$, 1), FieldAt$(entry$, 2), isFavorite)
        END IF
        start = start + LEN(entry$) + 1
    WEND
    RETURN items
END FUNCTION

/// Writes every item to a file, replacing what it held.
///
/// - Parameter path: The file.
/// - Parameter items: The items to keep.
FUNCTION WriteItems(path AS STRING, items AS ItemList) AS VOID
    LOCAL text$ = ""
    LOCAL kind$ = ""
    LOCAL index = 0
    ' One line an item: favorite or item, its title and its notes, escaped.
    FOR index = 0 TO items.Count - 1
        kind$ = "item"
        IF items.Items(index).IsFavorite THEN kind$ = "favorite"
        text$ = text$ + kind$ + CHR$(9) + EscapeField$(items.Items(index).Title) + CHR$(9) + EscapeField$(items.Items(index).Notes) + CHR$(10)
    NEXT index
    File.WriteText path, text$
END FUNCTION
