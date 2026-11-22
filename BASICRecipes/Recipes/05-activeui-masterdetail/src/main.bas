' {{NAME}} — a master/detail app, in a window of its own made with ActiveUI.
'
' Build it with basicc: make run builds it and runs it (make build only
' builds it, into Build/). The program is a Mac application with a window
' of its own, and it runs until the window closes.
'
' A list of items on the left, Favorites first, and the chosen one on the
' right: the shape of most document and record apps. Search narrows the
' list; New Item makes one, Favorite moves the chosen one in or out of
' Favorites, and Delete takes it off. Edit the title and notes on the right
' and they are saved as you type, in items.txt, in
' ~/Library/Application Support/{{NAME}}/ (or in $APP_DATA_DIR when that is
' set), so they are there the next time it opens.
'
' THE FILES, in the order worth reading them:
'
'   main.bas                                you are here: the parts, wired together
'   models/Item.bas                         one item, and searching it
'   models/ItemList.bas                     the items, and what can be done with them
'   models/ItemStore.bas                    items.txt, in and out
'   models/TabSeparated.bas                 the file's one-record-a-line format
'   views/ItemSidebarView.bas               the search field and the list
'   views/ItemDetailView.bas                the chosen item, or none
'   controllers/ItemsWindowController.bas   the window, its commands, every change
'   app/DataFolder.bas                      where the app keeps its data
'
' The models know nothing of windows, the views never change an item, and
' the controller is the one part that knows both. README.md says how the
' comments are written.

' ---------------------------------------------------------------- the files
'
' IMPORT reads another file's TYPEs, CLASSes and FUNCTIONs into this
' program, from a path relative to this file. Only this file's own
' statements run; an imported file's are declarations.
IMPORT "models/Item.bas"
IMPORT "models/ItemList.bas"
IMPORT "models/ItemStore.bas"
IMPORT "models/TabSeparated.bas"
IMPORT "views/ItemSidebarView.bas"
IMPORT "views/ItemDetailView.bas"
IMPORT "controllers/ItemsWindowController.bas"
IMPORT "app/DataFolder.bas"

' ---------------------------------------------------------------- the parts
'
' Each part is a GLOBAL, declared here and made below, and the others reach
' it by name. Three things in this BASIC make that the way: an imported
' file's statements do not run (GLOBALs included), an object handed to a
' FUNCTION is a copy (BASIC-35), and the interpreter BASICStudio runs cannot
' yet call a method on an object kept in another object's field.

/// The items, read from items.txt.
GLOBAL theItems AS ItemList
/// The master pane: the search field and the list.
GLOBAL theSidebar AS ItemSidebarView
/// The detail pane: the chosen item, or none.
GLOBAL theDetail AS ItemDetailView
/// The window's controller, which every control's handler hands its command to.
GLOBAL theWindow AS ItemsWindowController

' ------------------------------------------------------------------- start
itemsFile$ = DataFolder$("{{NAME}}") + "/items.txt"
theItems = ReadItems(itemsFile$)
theSidebar = NEW ItemSidebarView()
theDetail = NEW ItemDetailView()
theWindow = NEW ItemsWindowController()
theWindow.Start("{{NAME}}", itemsFile$)
theWindow.Run()
