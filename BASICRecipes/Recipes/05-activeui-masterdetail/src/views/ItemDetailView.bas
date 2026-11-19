' ItemDetailView.bas — the detail pane: the chosen item, or a note that
' none is chosen.
'
'     ┌──────────────────────────────┐
'     │ Getting started              │  the title, as a heading
'     │ Favorite                     │  a caption
'     │ Title                        │
'     │ [Getting started           ] │  edits are saved as you type
'     │ Notes                        │
'     │ [A list on the left, …     ] │
'     └──────────────────────────────┘
'
' With nothing chosen the heading says No Item Selected and the fields are
' empty and grayed out. Swift draws the heading in its title font and the
' notes in a text editor of many lines, and hides the fields when nothing
' is chosen; BASIC's AUILabel sets text only, its AUIField is one line, and
' a view cannot be hidden yet, so this is the nearest it comes.

/// The chosen item's heading, caption, title field and notes field.
CLASS ItemDetailView
    /// The heading: the item's title, or No Item Selected.
    PUBLIC HeadingLabel AS VARIANT
    /// The caption under it: Favorite, or what to do with nothing chosen.
    PUBLIC CaptionLabel AS VARIANT
    /// The title, to edit.
    PUBLIC TitleField AS VARIANT
    /// The notes, to edit.
    PUBLIC NotesField AS VARIANT

    /// Makes the labels and the fields, and puts them in a pane.
    ///
    /// - Parameter pane: The stack to add them to, top to bottom.
    FUNCTION Build(pane AS VARIANT) AS VOID
        ME.HeadingLabel = AUILabel("")
        ME.CaptionLabel = AUILabel("")
        ME.TitleField = AUIField("", "Title")
        ME.NotesField = AUIField("", "Notes")
        pane.add(ME.HeadingLabel)
        pane.add(ME.CaptionLabel)
        pane.add(AUILabel("Title"))
        pane.add(ME.TitleField)
        pane.add(AUILabel("Notes"))
        pane.add(ME.NotesField)
    END FUNCTION

    /// Shows an item, filling the fields from it; or, with none, the empty
    /// state.
    ///
    /// - Parameter items: The items.
    /// - Parameter chosen: The chosen item's index, or -1 for none.
    FUNCTION Show(items AS ItemList, chosen AS INTEGER) AS VOID
        IF NOT items.HasIndex(chosen) THEN
            ' The empty state: nothing to edit, so the fields are grayed out.
            ME.HeadingLabel.text("No Item Selected")
            ME.CaptionLabel.text("Choose an item in the list, or press New Item.")
            ME.TitleField.text("")
            ME.NotesField.text("")
            ME.TitleField.enabled(FALSE)
            ME.NotesField.enabled(FALSE)
            RETURN
        END IF
        ME.TitleField.enabled(TRUE)
        ME.NotesField.enabled(TRUE)
        ME.TitleField.text(items.Items(chosen).Title)
        ME.NotesField.text(items.Items(chosen).Notes)
        ME.ShowHeading(items, chosen)
    END FUNCTION

    /// Shows the heading and caption for an item, leaving the fields as
    /// they are: while the title is typed, the field is the truth.
    ///
    /// - Parameter items: The items.
    /// - Parameter chosen: The chosen item's index.
    FUNCTION ShowHeading(items AS ItemList, chosen AS INTEGER) AS VOID
        ME.HeadingLabel.text(DisplayTitle$(items.Items(chosen)))
        IF items.Items(chosen).IsFavorite THEN
            ME.CaptionLabel.text("Favorite")
        ELSE
            ME.CaptionLabel.text("Item")
        END IF
    END FUNCTION
END CLASS
