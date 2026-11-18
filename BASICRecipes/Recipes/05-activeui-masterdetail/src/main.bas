' {{NAME}} — a master/detail app, in a window of its own made with ActiveUI.
'
' Build it with basicc: make run builds it and runs it (make build only
' builds it, into Build/). The program is a Mac application with a window
' of its own, and it runs until the window closes. (BASICShell runs in a
' terminal, which has no windows, and says so.)
'
' A list of items on the left, and the chosen one on the right: the shape
' of most document and record apps. Pick an item and the labels beside the
' list show its title, summary and body.
'
' The list names the FUNCTION that handles it: itemList.onselect("Picked").
' A handler is always a named FUNCTION, not a closure, because a closure's
' changes would not get out of it. win.run() shows the window and waits,
' running handlers as you work, until the window closes.
'
' The same app as Swift's ActiveUI Master/Detail, and where it differs:
' - Swift puts the two panes in an AUIMasterDetailView, a sidebar list
'   titled "Items", 220 points wide, beside the detail. BASIC has no
'   master/detail view or sidebar yet, so two stacks side by side stand in
'   for it: "Items" over the list, and the detail beside them. The list is
'   as wide as ActiveUI makes it.
' - Swift's labels pull their text from closures, and a pick asks them to
'   pull again. Here ShowItem sets their text: the same result, pushed
'   rather than pulled.
' - Swift's title is in the title font, its summary in the secondary color,
'   and its body wraps. BASIC's AUILabel sets text only, on one line, so
'   each body here is short enough to fit beside the list.
' - The menu bar is the same: built with basicc, the program has the app
'   menu, File (Close, and Quit as ⌘Q), Edit and Window, as Swift's does.
'   BASIC cannot add items to it yet. Closing the window ends the program.

' The items, kept here: each is a title (what the list shows), a summary and
' a body (what the detail pane says about it). Plain BASIC: the views read
' these, and nothing in them knows about ActiveUI.
GLOBAL ITEMCOUNT AS INTEGER = 3
GLOBAL itemTitle$(3) AS STRING
GLOBAL itemSummary$(3) AS STRING
GLOBAL itemBody$(3) AS STRING

GLOBAL win = AUIWindow("{{NAME}}")
GLOBAL itemList = AUIList()
GLOBAL titleLabel = AUILabel("")
GLOBAL summaryLabel = AUILabel("")
GLOBAL bodyLabel = AUILabel("")

SampleItems()

' The master: "Items" over the list of titles.
LET master = AUIStack("vertical")
master.add(AUILabel("Items"))
master.add(itemList)
LET i = 0
FOR i = 0 TO ITEMCOUNT - 1
    itemList.add(itemTitle$(i))
NEXT i

' The detail: the chosen item's title, summary and body.
LET detail = AUIStack("vertical")
detail.add(titleLabel)
detail.add(summaryLabel)
detail.add(bodyLabel)

' The two panes, side by side.
LET panes = AUIStack("horizontal")
panes.add(master)
panes.add(detail)
win.add(panes)

' The first item, chosen and shown.
itemList.select(0)
ShowItem(0)

' Who handles what.
itemList.onselect("Picked")

' Swift's window is 760 by 460 points.
win.size(760, 460)
win.run()

' ================================================================= handlers

' A row was picked: the event says which.
FUNCTION Picked(event AS BASICAUIEvent)
    ShowItem(event.Index)
END FUNCTION

' ================================================================= the items

' The items the app starts with. Change these (or where they come from) to
' make it yours.
FUNCTION SampleItems() AS VOID
    itemTitle$(0) = "Getting started"
    itemSummary$(0) = "What this app is"
    itemBody$(0) = "A list on the left, the chosen item on the right. Edit SampleItems to make it yours."
    itemTitle$(1) = "The model"
    itemSummary$(1) = "Plain BASIC"
    itemBody$(1) = "Each item is three strings. The views read them; they know nothing of ActiveUI."
    itemTitle$(2) = "The views"
    itemSummary$(2) = "ActiveUI from BASIC"
    itemBody$(2) = "Two stacks hold the panes and AUIList the rows. A pick updates these labels."
END FUNCTION

' The detail pane shows item `row`.
FUNCTION ShowItem(row AS INTEGER) AS VOID
    IF row < 0 OR row >= ITEMCOUNT THEN RETURN
    titleLabel.text(itemTitle$(row))
    summaryLabel.text(itemSummary$(row))
    bodyLabel.text(itemBody$(row))
END FUNCTION
