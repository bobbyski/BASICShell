' ItemsWindowController.bas — the window, its commands, and every change.
'
'     New Item ──► NewItem        ──► Items.Add            ──► Save ──► Refresh
'     Favorite ──► ToggleFavorite ──► Items.ToggleFavorite ──► Save ──► Refresh
'     Delete   ──► DeleteItem     ──► Items.Remove         ──► Save ──► Refresh
'     a row    ──► ChooseRow      ──► Choose               ──► Refresh
'     typing   ──► TitleEdited / NotesEdited ──► Items.SetTitle / SetNotes ──► Save
'     Search   ──► Search         ──► the sidebar, narrowed
'
' It is the only part that knows both the items and the views. The views
' report what the person did; the controller changes the items, saves them,
' and shows the result. Each command is one method, and Favorite and Delete
' are grayed out until an item is chosen.
'
' Where this differs from Swift's Master/Detail, because BASIC's ActiveUI
' classes cannot do it yet:
' - The two panes are two stacks side by side, where Swift's are
'   ActiveUI's own AUIMasterDetailView with a sidebar of its own width.
' - The commands are a row of buttons across the top of the window, in the
'   toolbar's place: an AUIWindow has no toolbar, so there is no sidebar
'   button, tracking separator or flexible space either.
' - There is no File ▸ New Item, Delete, or View menu: built with basicc,
'   the program has the menu bar every Mac app has (the app menu, File with
'   Close and Quit, Edit, Window), and BASIC cannot add to it yet. When it
'   can, each menu item names the same handler its button names.

/// The window, the commands across its top and the two panes, over the
/// app's items and views.
///
/// It works on `theItems`, `theSidebar` and `theDetail`, the parts main.bas
/// makes (see there for why they are GLOBALs). Every control names a plain
/// FUNCTION as its handler (the handlers at the end of this file), because
/// ActiveUI calls a handler by name and a method has none it can call.
/// Each handler hands its command to `theWindow`, this controller.
CLASS ItemsWindowController
    /// The window.
    PUBLIC Window AS VARIANT
    /// New Item: makes an item and chooses it.
    PUBLIC NewItemButton AS VARIANT
    /// Favorite: puts the chosen item in Favorites, or takes it out.
    PUBLIC FavoriteButton AS VARIANT
    /// Delete: takes the chosen item off the list.
    PUBLIC DeleteButton AS VARIANT
    /// The file the items are kept in.
    PUBLIC ItemsFile AS STRING
    /// The chosen item's index, or -1 for none.
    PUBLIC ChosenIndex AS INTEGER

    /// Builds the window over the items, with the first one chosen.
    ///
    /// - Parameter title: The window's title: the app's name.
    /// - Parameter itemsFile: The file the items are kept in, written after
    ///   every change.
    FUNCTION Start(title AS STRING, itemsFile AS STRING) AS VOID
        ME.ItemsFile = itemsFile
        ME.ChosenIndex = -1
        IF theItems.Count > 0 THEN ME.ChosenIndex = 0

        ' Top to bottom: the commands, then the two panes side by side.
        ME.Window = AUIWindow(title)
        ME.BuildCommands()
        LOCAL master = AUIStack("vertical")
        LOCAL detailPane = AUIStack("vertical")
        theSidebar.Build(master)
        theDetail.Build(detailPane)
        LOCAL panes = AUIStack("horizontal")
        panes.add(master)
        panes.add(detailPane)
        ME.Window.add(panes)

        ' Who handles what.
        theSidebar.Rows.onselect("ItemPicked")
        theSidebar.SearchField.onchange("SearchChanged")
        theDetail.TitleField.onchange("TitleChanged")
        theDetail.NotesField.onchange("NotesChanged")

        ' Swift's window is 760 by 460 points.
        ME.Window.size(760, 460)

        ' A button starts enabled, and nothing asks again until the first
        ' change, so everything is brought up to date before the window
        ' opens: with no items, Favorite and Delete start grayed out.
        ME.Refresh()
    END FUNCTION

    /// Makes the command buttons, in the toolbar's place across the top.
    FUNCTION BuildCommands() AS VOID
        LOCAL bar = AUIStack("horizontal")
        ME.NewItemButton = AUIButton("New Item")
        ME.FavoriteButton = AUIButton("Favorite")
        ME.DeleteButton = AUIButton("Delete")
        bar.add(ME.NewItemButton)
        bar.add(ME.FavoriteButton)
        bar.add(ME.DeleteButton)
        ME.Window.add(bar)

        ME.NewItemButton.onclick("NewItemPressed")
        ME.FavoriteButton.onclick("FavoritePressed")
        ME.DeleteButton.onclick("DeletePressed")
    END FUNCTION

    /// Shows the window and waits until it is closed.
    FUNCTION Run() AS VOID
        ME.Window.run()
    END FUNCTION

    ' ------------------------------------------------------------ commands

    /// The New Item command: makes an untitled item and chooses it.
    FUNCTION NewItem() AS VOID
        IF NOT theItems.HasRoom() THEN RETURN
        theItems.Add("", "", FALSE)
        ME.ChosenIndex = theItems.Count - 1
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// The Favorite command: puts the chosen item in Favorites, or takes it
    /// out.
    FUNCTION ToggleFavorite() AS VOID
        IF NOT theItems.HasIndex(ME.ChosenIndex) THEN RETURN
        theItems.ToggleFavorite(ME.ChosenIndex)
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// The Delete command: takes the chosen item off the list.
    FUNCTION DeleteItem() AS VOID
        IF NOT theItems.HasIndex(ME.ChosenIndex) THEN RETURN
        theItems.Remove(ME.ChosenIndex)
        ' The item is gone, so nothing is chosen now.
        ME.ChosenIndex = -1
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// Chooses the item a row shows, as a click on the row does.
    ///
    /// - Parameter row: The row, from 0. A heading chooses nothing.
    FUNCTION ChooseRow(row AS INTEGER) AS VOID
        ME.Choose(theSidebar.ItemAtRow(row))
    END FUNCTION

    /// Chooses an item, and shows it.
    ///
    /// - Parameter index: The item's index, or -1 for none.
    FUNCTION Choose(index AS INTEGER) AS VOID
        ME.ChosenIndex = index
        IF NOT theItems.HasIndex(index) THEN ME.ChosenIndex = -1
        theDetail.Show(theItems, ME.ChosenIndex)
        ME.RefreshCommands()
    END FUNCTION

    /// The title was edited: the chosen item takes it, and the list says so.
    ///
    /// - Parameter title: What the title field holds now.
    FUNCTION TitleEdited(title AS STRING) AS VOID
        IF NOT theItems.HasIndex(ME.ChosenIndex) THEN RETURN
        theItems.SetTitle(ME.ChosenIndex, title)
        ME.Save()
        ' The fields are left alone: they hold what is being typed.
        theSidebar.Show(theItems, ME.ChosenIndex)
        theDetail.ShowHeading(theItems, ME.ChosenIndex)
    END FUNCTION

    /// The notes were edited: the chosen item takes them.
    ///
    /// - Parameter notes: What the notes field holds now.
    FUNCTION NotesEdited(notes AS STRING) AS VOID
        IF NOT theItems.HasIndex(ME.ChosenIndex) THEN RETURN
        theItems.SetNotes(ME.ChosenIndex, notes)
        ME.Save()
    END FUNCTION

    /// The search changed: the list shows only the items that match.
    FUNCTION Search() AS VOID
        theSidebar.Show(theItems, ME.ChosenIndex)
    END FUNCTION

    ' -------------------------------------------------------------- showing

    /// Brings the whole window up to date with the items.
    FUNCTION Refresh() AS VOID
        theSidebar.Show(theItems, ME.ChosenIndex)
        theDetail.Show(theItems, ME.ChosenIndex)
        ME.RefreshCommands()
    END FUNCTION

    /// Grays out each command that has nothing to do.
    FUNCTION RefreshCommands() AS VOID
        ME.NewItemButton.enabled(theItems.HasRoom())
        ME.FavoriteButton.enabled(theItems.HasIndex(ME.ChosenIndex))
        ME.DeleteButton.enabled(theItems.HasIndex(ME.ChosenIndex))
    END FUNCTION

    /// Writes the items to their file.
    FUNCTION Save() AS VOID
        WriteItems(ME.ItemsFile, theItems)
    END FUNCTION
END CLASS

' ================================================================ handlers
'
' What each control calls. Each one hands its command to the controller,
' so a command is carried out in one place, whichever control asked.

/// New Item.
FUNCTION NewItemPressed() AS VOID
    theWindow.NewItem()
END FUNCTION

/// Favorite.
FUNCTION FavoritePressed() AS VOID
    theWindow.ToggleFavorite()
END FUNCTION

/// Delete.
FUNCTION DeletePressed() AS VOID
    theWindow.DeleteItem()
END FUNCTION

/// A row of the list was picked.
///
/// - Parameter event: Which row: `event.Index`, from 0.
FUNCTION ItemPicked(event AS BASICAUIEvent) AS VOID
    theWindow.ChooseRow(event.Index)
END FUNCTION

/// The search field's text changed.
FUNCTION SearchChanged() AS VOID
    theWindow.Search()
END FUNCTION

/// The title field's text changed.
///
/// - Parameter event: What the field holds now: `event.Text$`.
FUNCTION TitleChanged(event AS BASICAUIEvent) AS VOID
    theWindow.TitleEdited(event.Text$)
END FUNCTION

/// The notes field's text changed.
///
/// - Parameter event: What the field holds now: `event.Text$`.
FUNCTION NotesChanged(event AS BASICAUIEvent) AS VOID
    theWindow.NotesEdited(event.Text$)
END FUNCTION
