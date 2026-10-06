' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The Buttons, Inputs, and Pickers folder tabs.

' ---------------------------------------------------------------- Buttons

function MakeButtonsTab() as variant
    let root = TUIStack("v")

    ' Roles: how a theme dresses ordinary/default/destructive.
    let ok = TUIButton("&Save")
    ok.role("default")
    let danger = TUIButton("&Delete")
    danger.role("destructive")
    let plain = TUIButton("&Reset")
    let bordered = TUIButton("Bordered")
    bordered.style("bordered")

    ' Long-press: hold fires the alternate; a quick click still clicks.
    holdResult = TUILabel("click / hold 600ms - the toolbar's Back button holds too")
    let hold = TUIButton("&Back")
    hold.onclick("ButtonsHoldClicked")
    hold.onlongpress("ButtonsHoldLongPressed")

    let menuButton = TUIButton("Menu on hold")
    let context = TUIMenu()
    context.menu("")
    context.item("Reopen Closed Tab", "ButtonsMenuReopen")
    context.item("Copy Address", "ButtonsMenuCopy")
    ' no handler -> long-press opens this
    menuButton.contextmenu(context)

    let toggle = TUIToggle("Wrap Lines")
    let check = TUICheck("Show hidden files")
    let radios = TUIRadio("Ask", "Allow", "Block")
    let segments = TUISegments("Day", "Week", "Month")

    ' Dialogs: modal Dialog, and the open/save FileDialogs.
    dialogResult = TUILabel("dialogs report here")

    let showDialog = TUIButton("Dialog...")
    showDialog.onclick("ButtonsShowDialog")

    let openFile = TUIButton("Open File...")
    openFile.onclick("ButtonsOpenFile")

    ' Phase 16.25: a document window - DocumentController owns Open/Save/
    ' Save As/Close, the dirty marker in the title, and the close confirm.
    let openDocument = TUIButton("Document...")
    openDocument.onclick("ButtonsOpenDocument")

    let rolesRow = Row()
    rolesRow.add(ok)
    rolesRow.add(danger)
    rolesRow.add(plain)
    rolesRow.add(bordered)
    let rolesGroup = Group("Roles & Styles")
    rolesGroup.add(rolesRow)
    root.add(PinnedHeight(rolesGroup, 4))

    let holdRow = Row()
    holdRow.add(hold)
    holdRow.add(menuButton)
    let holdGroup = Group("Long-press (hold a fresh press ~600 ms)")
    holdGroup.add(holdRow)
    holdGroup.add(holdResult)
    root.add(PinnedHeight(holdGroup, 5))

    let stateRow = Row()
    stateRow.add(toggle)
    stateRow.add(check)
    let stateGroup = Group("State")
    stateGroup.add(stateRow)
    root.add(PinnedHeight(stateGroup, 4))

    ' The preferences dialog in each variation - the gallery's own
    ' preferences (theme, panel at launch, hints), so the pages are real.
    '
    ' Both buttons reach the same dialog: the binding builds the toolbar
    ' strip, and the split-list style is not exposed, so "(split)" opens the
    ' toolbar one. The pair is kept because the Swift shows both.
    let preferencesToolbar = TUIButton("Preferences (toolbar)...")
    preferencesToolbar.onclick("ButtonsPreferences")
    let preferencesSplit = TUIButton("Preferences (split)...")
    preferencesSplit.onclick("ButtonsPreferences")

    let dialogsRow = Row()
    dialogsRow.add(showDialog)
    dialogsRow.add(openFile)
    dialogsRow.add(openDocument)
    let preferencesRow = Row()
    preferencesRow.add(preferencesToolbar)
    preferencesRow.add(preferencesSplit)
    let dialogsGroup = Group("Dialogs - Document (16.25) - Preferences (16.29)")
    dialogsGroup.add(dialogsRow)
    dialogsGroup.add(preferencesRow)
    dialogsGroup.add(dialogResult)
    root.add(PinnedHeight(dialogsGroup, 6))

    let choiceRow = Row()
    choiceRow.add(radios)
    choiceRow.add(segments)
    let choiceGroup = Group("Choice")
    choiceGroup.add(choiceRow)
    root.add(choiceGroup)

    return root
end function

function ButtonsHoldClicked() as variant
    holdResult.text("clicked - quick press")
    return 0
end function

function ButtonsHoldLongPressed() as variant
    holdResult.text("long-pressed - the alternate action fired")
    return 0
end function

function ButtonsMenuReopen() as variant
    holdResult.text("menu: reopen")
    return 0
end function

function ButtonsMenuCopy() as variant
    holdResult.text("menu: copy")
    return 0
end function

function ButtonsShowDialog() as variant
    let dialog = TUIDialog("Delete Page?")
    dialog.message("This cannot be undone.")
    dialog.addbutton("&Cancel", "ButtonsDialogCancelled")
    dialog.addbutton("&Delete", "ButtonsDialogDeleted")
    ' isCancel / isDefault / isDestructive are not carried: the binding makes
    ' the first button added the default one. The Swift's Delete is the
    ' default and the destructive one, so here Cancel takes the focus and
    ' neither button is dressed in the destructive role.
    '
    ' dialog.onDismiss and the two sizeToFit calls are what `show` does.
    app.show(dialog)
    return 0
end function

function ButtonsDialogCancelled() as variant
    dialogResult.text("dialog: cancelled")
    return 0
end function

function ButtonsDialogDeleted() as variant
    dialogResult.text("dialog: deleted")
    return 0
end function

function ButtonsOpenFile() as variant
    ' FileDialog(mode: .open, root: FileManager.default.currentDirectoryPath)
    '
    ' Not bound: BASIC has no FileDialog pseudo class, so there is no way to
    ' raise the open panel or to receive its onConfirm path. The button is
    ' kept, and says so, rather than being quietly dropped from the tab.
    dialogResult.text("open: FileDialog is not bound to BASIC yet")
    return 0
end function

function ButtonsOpenDocument() as variant
    ' The document window is buildable; DocumentController is not bound, so
    ' Open/Save/Save As/Close have nothing to drive and the dirty marker in
    ' the title never appears. The window is still opened, because the
    ' FloatingWindow, the TextView and the button row all translate.
    let window = TUIFloatWindow("Untitled")
    window.frame(6, 3, 64, 16)
    let editor = TUIText("Type here, then File-style buttons below: the title shows a dot while dirty.")

    ' `let bar = HStack(...)` - renamed: BASIC fixes a name's type at its
    ' first assignment across the whole program, and `bar` is the toolbar in
    ' GalleryWindow.bas.
    let buttonRow = Row()
    buttonRow.add(TUIButton("&Open..."))
    buttonRow.add(TUIButton("&Save"))
    buttonRow.add(TUIButton("Save &As..."))
    buttonRow.add(TUIButton("&Close"))

    let column = TUIStack("v")
    column.add(PinnedHeight(buttonRow, 1))
    column.add(editor)
    window.add(column)
    app.present(window)
    return 0
end function

function ButtonsPreferences() as variant
    PresentPreferences()
    return 0
end function

' ----------------------------------------------------------------- Inputs

function MakeInputsTab() as variant
    let root = TUIStack("v")

    ' `let field = TextField()` - renamed: FIELD is a reserved word in this
    ' BASIC, so a variable called `field` derails the parser on the line after
    ' it ("Expected file number").
    let entry = TUIField()
    entry.placeholder("type here...")
    let combo = TUICombo("Mercury", "Venus", "Earth", "Mars")
    let popUp = TUIPopup("Balanced", "Performance", "Quiet")

    let slider = TUISlider(35, 0, 100)
    let stepper = TUIStepper(4, 0, 10)
    let level = TUILevel(3, 5)
    level.editable(1)
    ' Phase 16.12: thresholds recolour the fill
    level.thresholds(4, 5)

    let progressBar = TUIProgress("bar", 0.6)
    spinner = TUIProgress("spinner")

    ' The App timer story: the spinner animates like input redraws.
    '
    ' `app.addTimer(every: .milliseconds(150))` - the binding's timer takes
    ' seconds, so 150ms is 0.15.
    app.timer(0.15, "InputsAdvanceSpinner")

    let textRow = Row()
    textRow.add(entry)
    textRow.add(combo)
    textRow.add(popUp)
    let textGroup = Group("Text & Choices")
    textGroup.add(textRow)
    root.add(PinnedHeight(textGroup, 4))

    let valuesRow = Row()
    valuesRow.add(slider)
    valuesRow.add(stepper)
    valuesRow.add(level)
    let valuesGroup = Group("Values")
    valuesGroup.add(valuesRow)
    root.add(PinnedHeight(valuesGroup, 4))

    let progressRow = Row()
    progressRow.add(progressBar)
    progressRow.add(spinner)
    let progressGroup = Group("Progress (the spinner rides an App timer)")
    progressGroup.add(progressRow)
    root.add(progressGroup)

    return root
end function

function InputsAdvanceSpinner() as variant
    spinner.advance()
    return 0
end function

' ---------------------------------------------------------------- Pickers

function MakePickersTab() as variant
    let root = TUIStack("h")

    let dateField = TUIDate("date")
    let calendar = TUIDate("calendar")
    let colorPicker = TUIColor()

    ' Phase 16: Matrix - a grid of cells as one control.
    days = TUIMatrix(4, "highlight", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    daysLabel = TUILabel("highlight mode - Space toggles, arrows move")
    days.onselect("PickersDaysChanged")
    let size = TUIMatrix(4, "radio", "S", "M", "L", "XL")
    size.select(1)

    let left = TUIStack("v")
    let dateGroup = Group("DatePicker - .date (Space drops a month grid)")
    dateGroup.add(dateField)
    left.add(PinnedHeight(dateGroup, 4))

    let sizeRow = Row()
    sizeRow.add(size)
    sizeRow.add(daysLabel)
    let matrixGroup = Group("Matrix - .highlight (days) and .radio (size)")
    matrixGroup.add(days)
    matrixGroup.add(sizeRow)
    left.add(PinnedHeight(matrixGroup, 6))

    let calendarGroup = Group("DatePicker - .calendar")
    calendarGroup.add(calendar)
    left.add(calendarGroup)

    root.add(left)
    let colorGroup = Group("ColorPicker (named / palette / RGB tabs)")
    colorGroup.add(colorPicker)
    root.add(colorGroup)

    return root
end function

function PickersDaysChanged() as variant
    ' days.onSelectionChanged = { daysLabel.text = "selected: \(...)" }
    '
    ' The Swift maps the selected indexes back to day names; a BASIC handler
    ' is handed nothing, and a Matrix's selection cannot be read back, so the
    ' label reports that the selection changed rather than what it is.
    daysLabel.text("selection changed - Space toggles, arrows move")
    return 0
end function
