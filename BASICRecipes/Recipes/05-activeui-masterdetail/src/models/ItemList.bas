' ItemList.bas — the items, in the order they were made.
'
'     controller ──► Add / SetTitle / SetNotes / ToggleFavorite / Remove
'     views      ◄── Count, Items(index)
'
' Like Item, it knows nothing of windows or files: the controller changes
' it, the views read it, and ItemStore.bas reads and writes it.

/// The items, oldest first, and what can be done with them.
///
/// An item is found by its index, from 0. This BASIC has no REDIM, so the
/// places are made once at their most (``Capacity``) and `Count` says how
/// many are real.
CLASS ItemList
    /// Every place there can be; the first `Count` hold items.
    PUBLIC Items(200) AS Item
    /// How many items there are.
    PUBLIC Count AS INTEGER

    /// How many items the list can hold: the size `Items` is made with.
    ///
    /// - Returns: 200.
    FUNCTION Capacity() AS INTEGER
        RETURN 200
    END FUNCTION

    /// Whether an index holds an item.
    ///
    /// - Parameter index: The index, from 0; -1 means none.
    /// - Returns: TRUE when there is an item at `index`.
    FUNCTION HasIndex(index AS INTEGER) AS BOOLEAN
        IF index >= 0 AND index < ME.Count THEN RETURN TRUE
        RETURN FALSE
    END FUNCTION

    /// Whether there is room for one more item.
    ///
    /// - Returns: TRUE until every place holds an item.
    FUNCTION HasRoom() AS BOOLEAN
        IF ME.Count < ME.Capacity() THEN RETURN TRUE
        RETURN FALSE
    END FUNCTION

    /// Adds an item at the end.
    ///
    /// - Parameter title: Its title.
    /// - Parameter notes: Its notes.
    /// - Parameter isFavorite: Whether it is in Favorites.
    FUNCTION Add(title AS STRING, notes AS STRING, isFavorite AS BOOLEAN) AS VOID
        ' A full list keeps what it has; the New Item command is grayed out
        ' before this can happen.
        IF NOT ME.HasRoom() THEN RETURN
        ME.Items(ME.Count).Title = title
        ME.Items(ME.Count).Notes = notes
        ME.Items(ME.Count).IsFavorite = isFavorite
        ME.Count = ME.Count + 1
    END FUNCTION

    /// Gives an item a new title.
    ///
    /// - Parameter index: The item's index.
    /// - Parameter title: Its new title.
    FUNCTION SetTitle(index AS INTEGER, title AS STRING) AS VOID
        IF ME.HasIndex(index) THEN ME.Items(index).Title = title
    END FUNCTION

    /// Gives an item new notes.
    ///
    /// - Parameter index: The item's index.
    /// - Parameter notes: Its new notes.
    FUNCTION SetNotes(index AS INTEGER, notes AS STRING) AS VOID
        IF ME.HasIndex(index) THEN ME.Items(index).Notes = notes
    END FUNCTION

    /// Puts an item in Favorites, or takes it out.
    ///
    /// - Parameter index: The item's index.
    FUNCTION ToggleFavorite(index AS INTEGER) AS VOID
        IF NOT ME.HasIndex(index) THEN RETURN
        IF ME.Items(index).IsFavorite THEN
            ME.Items(index).IsFavorite = FALSE
        ELSE
            ME.Items(index).IsFavorite = TRUE
        END IF
    END FUNCTION

    /// Takes an item off the list; the ones after it move up a place.
    ///
    /// - Parameter index: The item's index.
    FUNCTION Remove(index AS INTEGER) AS VOID
        IF NOT ME.HasIndex(index) THEN RETURN
        LOCAL i = 0
        FOR i = index TO ME.Count - 2
            ME.Items(i) = ME.Items(i + 1)
        NEXT i
        ME.Count = ME.Count - 1
    END FUNCTION
END CLASS
