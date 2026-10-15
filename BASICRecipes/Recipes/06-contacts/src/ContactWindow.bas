' ContactWindow.bas - the window: toolbar, list, and edit form.
'
' The window is built once, in BuildContactWindow, and then never rebuilt.
' Everything that happens afterwards changes a control that already exists:
' RefreshList replaces the rows, ShowContact fills the fields, RefreshChrome
' rewrites the title and the status line. That is the shape to copy. A
' program that tears down its window to show new data loses the selection,
' the scroll position and the focus every time, and the person using it can
' feel every one of those losses.
'
' Handlers are named FUNCTIONs: every "onclick" below names a function
' further down this file.

' Builds the one window and answers it, for the caller to present.
FUNCTION BuildContactWindow() AS VARIANT
    mainWindow = TUIFloatWindow("Contacts")
    mainWindow.frame(2, 1, 76, 22)
    mainWindow.minsize(54, 14)
    mainWindow.maximizeinsets(1, 1)

    ' The window's close box asks the same question the File menu's Quit
    ' asks. One gate, reached from both, is the only way the two can agree.
    mainWindow.onclose("WindowCloseRequested")

    InstallContactToolbar()

    ' Left: the contacts. Right: the one being edited.
    LOCAL browser = TUISplit("h", BuildContactList(), BuildEditForm())
    browser.minimums(22, 26)

    mainWindow.add(browser)
    RETURN mainWindow
END FUNCTION

' ------------------------------------------------------------- the toolbar
'
' Open, Save and New Contact - the three things this program does often -
' with the file name beside them in a field that stretches to the window.
'
' The field is not decoration. This binding's dialogs hold a message and
' buttons but no text entry, so the toolbar is where a file name is typed:
' the same arrangement as a browser's address bar, which is where the
' pattern comes from.
FUNCTION InstallContactToolbar() AS VARIANT
    LOCAL bar = TUIToolbar()

    ' "both" draws the icon and the title. A toolbar of bare symbols is a
    ' guessing game for anyone who did not write it.
    bar.displaymode("both")

    pathField = TUIField()
    pathField.text(CurrentPath$)

    bar.additem("Open", "^", "ToolbarOpen")
    bar.additem("Save", "*", "ToolbarSave")
    bar.additem("New Contact", "+", "ToolbarNewContact")
    bar.divider()
    bar.addview(pathField, "File", 1)

    mainWindow.toolbar(bar)
    RETURN 0
END FUNCTION

' --------------------------------------------------------------- the list

FUNCTION BuildContactList() AS VARIANT
    LOCAL panel = TUIPanel("Contacts")
    contactList = TUIList()
    contactList.onselect("ContactSelected")
    panel.add(contactList)
    RETURN panel
END FUNCTION

' Replaces every row from the model.
'
' items() with no arguments empties the list; additem appends. Called after
' anything that changes what contacts exist - adding, deleting, opening a
' file - and never for a change that only affects one contact's text, which
' is what UpdateRow is for.
FUNCTION RefreshList() AS INTEGER
    contactList.items()

    ' LOCAL row, and not because the loop needs it: a name that is not
    ' LOCAL is shared with the whole program, so an undeclared loop
    ' counter here would overwrite a variable of the same name in the
    ' function that called this one. Declare what you use.
    LOCAL row
    FOR row = 0 TO ContactCount - 1
        contactList.additem(ContactRow$(row))
    NEXT row
    RETURN ContactCount
END FUNCTION

' ---------------------------------------------------------- the edit form
'
' TUIForm lays out label-and-control rows in one column, which is exactly
' what a form is; doing it by hand with stacks and labels is four times the
' code and comes out crooked when the window is resized.

FUNCTION BuildEditForm() AS VARIANT
    fullNameField = TUIField()
    fullNameField.placeholder("full name")
    emailField = TUIField()
    emailField.placeholder("you@example.com")
    phoneField = TUIField()
    phoneField.placeholder("555-0100")
    notesField = TUIField()
    notesField.placeholder("anything worth remembering")

    LOCAL entry = TUIForm()
    entry.section("Contact")
    entry.field("Name", fullNameField)
    entry.field("Email", emailField)
    entry.field("Phone", phoneField)
    entry.field("Notes", notesField)

    ' Apply is explicit rather than saving on every keystroke. Typing into
    ' a field is not a decision; pressing Apply is - and it means Revert
    ' can put back what was there without remembering keystrokes.
    LOCAL applyButton = TUIButton("&Apply")
    applyButton.onclick("ApplyEdits")
    LOCAL revertButton = TUIButton("&Revert")
    revertButton.onclick("RevertEdits")
    LOCAL deleteButton = TUIButton("&Delete")
    deleteButton.onclick("DeleteContactAction")

    LOCAL buttons = TUIStack("h")
    buttons.add(applyButton)
    buttons.add(revertButton)
    buttons.add(deleteButton)
    buttons.height(1)

    LOCAL column = TUIStack("v")
    column.add(entry)
    column.add(buttons)

    LOCAL panel = TUIPanel("Details")
    panel.add(column)
    RETURN panel
END FUNCTION

' Moves the list highlight and the form to one row, together.
'
' Two things have to agree about which contact is current: the highlighted
' row and the fields beside it. Every place that changes the current
' contact calls this, so they cannot drift apart - and selecting in code
' does not fire the list's own handler, which would re-enter this function
' halfway through.
FUNCTION SelectRow(row AS INTEGER) AS INTEGER
    IF ContactExists(row) THEN
        contactList.select(row)
    END IF
    ShowContact(row)
    RETURN 0
END FUNCTION

' Fills the form from one contact, or empties it when there is none.
FUNCTION ShowContact(row AS INTEGER) AS INTEGER
    IF NOT ContactExists(row) THEN
        EditingRow = -1
        fullNameField.text("")
        emailField.text("")
        phoneField.text("")
        notesField.text("")
        RETURN 0
    END IF

    EditingRow = row
    fullNameField.text(Contacts(row).FullName)
    emailField.text(Contacts(row).Email)
    phoneField.text(Contacts(row).Phone)
    notesField.text(Contacts(row).Notes)
    RETURN 1
END FUNCTION

' ------------------------------------------------------------- the chrome

' Rewrites the window title and the status line from the model.
'
' One function, called after every change, rather than each handler
' remembering to update the title itself. The asterisk in the title is the
' whole of the unsaved-changes display, and it comes from IsDirty, so it
' can never disagree with the dialog that asks about it.
FUNCTION RefreshChrome() AS INTEGER
    LOCAL marker$ = ""
    IF IsDirty THEN
        marker$ = " *"
    END IF

    mainWindow.title("Contacts - " + CurrentPath$ + marker$)
    statusTitle.text(" " + Number$(ContactCount) + " contacts")

    IF LastMessage$ = "" THEN
        statusHint.text("Tab moves focus - Apply commits an edit - Esc quits")
    ELSE
        statusHint.text(LastMessage$)
    END IF
    RETURN 0
END FUNCTION

' Everything the screen shows, from the model. Used after opening a file.
FUNCTION RefreshEverything() AS INTEGER
    RefreshList()
    pathField.text(CurrentPath$)

    ' Land on the first contact when nothing is current, so the form is
    ' showing something the moment the window opens. An empty book leaves
    ' EditingRow at -1 and the form empty, which is also correct.
    IF EditingRow < 0 THEN
        EditingRow = 0
    END IF
    SelectRow(EditingRow)

    RefreshChrome()
    RETURN 0
END FUNCTION

' -------------------------------------------------------------- handlers
'
' Below here, one FUNCTION per thing a person can do. They are short on
' purpose: each one changes the model, then asks the screen to catch up.

FUNCTION ContactSelected() AS VARIANT
    ShowContact(contactList.selected())
    RETURN 0
END FUNCTION

FUNCTION ApplyEdits() AS VARIANT
    IF NOT ContactExists(EditingRow) THEN
        LastMessage$ = "nothing selected - pick a contact or press New Contact"
        RefreshChrome()
        RETURN 0
    END IF

    UpdateContact(EditingRow, fullNameField.value$(), emailField.value$(), phoneField.value$(), notesField.value$())

    ' Only one contact changed, but the list holds strings rather than
    ' contacts, so its row has to be rewritten - and replacing the rows
    ' clears the highlight, which is why the row is selected again after.
    RefreshList()
    SelectRow(EditingRow)
    LastMessage$ = "applied changes to " + ContactRow$(EditingRow)
    RefreshChrome()
    RETURN 0
END FUNCTION

FUNCTION RevertEdits() AS VARIANT
    ShowContact(EditingRow)
    LastMessage$ = "reverted the form to the saved contact"
    RefreshChrome()
    RETURN 0
END FUNCTION

FUNCTION NewContactAction() AS VARIANT
    LOCAL row = AddContact("New Contact", "", "", "")
    IF row < 0 THEN
        LastMessage$ = "the book is full - " + Number$(MaxContacts + 1) + " contacts is the limit"
        RefreshChrome()
        RETURN 0
    END IF

    RefreshList()
    SelectRow(row)
    LastMessage$ = "added a contact - type a name and press Apply"
    RefreshChrome()
    RETURN 0
END FUNCTION

FUNCTION DeleteContactAction() AS VARIANT
    IF NOT ContactExists(EditingRow) THEN
        LastMessage$ = "nothing selected - pick a contact first"
        RefreshChrome()
        RETURN 0
    END IF

    LOCAL gone$ = ContactRow$(EditingRow)
    LOCAL removed = EditingRow
    RemoveContact(removed)

    ' Select whatever moved up into the gap, or the new last row when the
    ' one deleted was at the end. A window that deselects after every
    ' delete makes deleting three in a row three separate hunts.
    IF removed >= ContactCount THEN
        removed = ContactCount - 1
    END IF

    RefreshList()
    SelectRow(removed)
    LastMessage$ = "deleted " + gone$
    RefreshChrome()
    RETURN 0
END FUNCTION

' ------------------------------------------------------- toolbar handlers
'
' The toolbar buttons do not do the work; they call the same functions the
' menu items call. Two ways in, one thing done - so a fix to Save is a fix
' to both.

FUNCTION ToolbarOpen() AS VARIANT
    FileOpen()
    RETURN 0
END FUNCTION

FUNCTION ToolbarSave() AS VARIANT
    FileSave()
    RETURN 0
END FUNCTION

FUNCTION ToolbarNewContact() AS VARIANT
    NewContactAction()
    RETURN 0
END FUNCTION

FUNCTION WindowCloseRequested() AS VARIANT
    ' The close box is a quit: one window, and closing it leaves nothing.
    RequestQuit()
    RETURN 0
END FUNCTION
