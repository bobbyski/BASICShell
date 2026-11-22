' ItemSidebarView.bas — the master pane: a search field over the list.
'
'     ┌──────────────────┐
'     │ Search           │  narrows the list as you type
'     ├──────────────────┤
'     │ FAVORITES        │  a heading row
'     │   ★ Getting st…  │
'     │ ITEMS            │
'     │   ▤ The model    │  every item that is not a favorite
'     │   ▤ The views    │
'     └──────────────────┘
'
' Swift's master is an AUISidebarList with real Favorites and Items
' sections and symbols. BASIC's ActiveUI classes have no sidebar list yet,
' so an AUIList stands in: the headings are rows of their own, and ★ and ▤
' in front of each title stand in for the symbols. The view keeps which
' item each row shows, so a pick on a heading chooses nothing.

/// The search field, and the list of items in two sections.
CLASS ItemSidebarView
    /// The search field.
    PUBLIC SearchField AS VARIANT
    /// The list: headings and items.
    PUBLIC Rows AS VARIANT
    /// The item each row shows, by index; -1 for a heading.
    PUBLIC RowItem(210) AS INTEGER
    /// How many rows the list has.
    PUBLIC RowCount AS INTEGER

    /// Makes the search field and the list, and puts them in a pane.
    ///
    /// - Parameter pane: The stack to add them to, top to bottom.
    FUNCTION Build(pane AS VARIANT) AS VOID
        ME.SearchField = AUIField("", "Search")
        ME.Rows = AUIList()
        pane.add(ME.SearchField)
        pane.add(ME.Rows)
    END FUNCTION

    /// Lists the items that match the search, Favorites first, with one
    /// chosen.
    ///
    /// - Parameter items: The items.
    /// - Parameter chosen: The chosen item's index, or -1 for none.
    FUNCTION Show(items AS ItemList, chosen AS INTEGER) AS VOID
        LOCAL query$ = ME.Query$()
        ME.Rows.clear()
        ME.RowCount = 0
        ' Favorites first, then the rest, each under its heading.
        ME.ShowSection(items, query$, TRUE, "FAVORITES", "★ ")
        ME.ShowSection(items, query$, FALSE, "ITEMS", "▤ ")
        ' Filling the list drops its selection, so the chosen item's row is
        ' picked again. Picking in code reports nothing, so no handler runs.
        ME.Rows.select(ME.RowOf(chosen))
    END FUNCTION

    /// Adds one section's rows: its heading, then its items.
    ///
    /// A section with no items that match shows no heading either.
    ///
    /// - Parameter items: The items.
    /// - Parameter query: What the search field holds.
    /// - Parameter favorites: TRUE for the favorites, FALSE for the rest.
    /// - Parameter heading: The section's heading.
    /// - Parameter mark: What goes in front of each item's title.
    FUNCTION ShowSection(items AS ItemList, query AS STRING, favorites AS BOOLEAN, heading AS STRING, mark AS STRING) AS VOID
        LOCAL hasHeading AS BOOLEAN
        hasHeading = FALSE
        LOCAL index = 0
        FOR index = 0 TO items.Count - 1
            IF items.Items(index).IsFavorite = favorites AND ItemMatches(items.Items(index), query) THEN
                ' The heading goes in with the section's first item.
                IF NOT hasHeading THEN
                    ME.AddRow(heading, -1)
                    hasHeading = TRUE
                END IF
                ME.AddRow("  " + mark + DisplayTitle$(items.Items(index)), index)
            END IF
        NEXT index
    END FUNCTION

    /// Adds a row to the list, remembering which item it shows.
    ///
    /// - Parameter rowText: What the row says.
    /// - Parameter index: The item's index, or -1 for a heading.
    FUNCTION AddRow(rowText AS STRING, index AS INTEGER) AS VOID
        ME.Rows.add(rowText)
        ME.RowItem(ME.RowCount) = index
        ME.RowCount = ME.RowCount + 1
    END FUNCTION

    /// The item a row shows.
    ///
    /// - Parameter row: The row, from 0.
    /// - Returns: The item's index, or -1 for a heading or no row.
    FUNCTION ItemAtRow(row AS INTEGER) AS INTEGER
        IF row < 0 OR row >= ME.RowCount THEN RETURN -1
        RETURN ME.RowItem(row)
    END FUNCTION

    /// The row that shows an item.
    ///
    /// - Parameter index: The item's index.
    /// - Returns: Its row, or -1 when the search hides it or it is none.
    FUNCTION RowOf(index AS INTEGER) AS INTEGER
        IF index < 0 THEN RETURN -1
        LOCAL row = 0
        FOR row = 0 TO ME.RowCount - 1
            IF ME.RowItem(row) = index THEN RETURN row
        NEXT row
        RETURN -1
    END FUNCTION

    /// What the search field holds.
    ///
    /// - Returns: The text typed so far.
    FUNCTION Query$() AS STRING
        RETURN ME.SearchField.text$()
    END FUNCTION
END CLASS
