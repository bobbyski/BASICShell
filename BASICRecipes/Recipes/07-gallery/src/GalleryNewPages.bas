' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The Phase 16 controls, each family on a page of its own (Bobby): fields,
' data views, the wizard, gauges, and drawing.

' ---------------------------------------------------------------- Fields

function MakeFieldsTab() as variant
    let root = TUIStack("v")

    searchResult = TUILabel("search reports here")
    search = TUISearch()
    search.onsearch("FieldsSearchChanged")
    search.oncommit("FieldsSearchCommitted")
    let paste = TUIPaste()
    paste.onclick("FieldsPasted")
    paste.onempty("FieldsPasteEmpty")

    let recipients = TUITokens("add a team, Return mints", "ops")
    let teamCompletions = TUICompletions(recipients)
    teamCompletions.items("ops", "dev", "design", "docs", "qa", "security")
    ' teamCompletions.onAccept = { recipients.mint($0) } - the binding wires
    ' accepting to minting when the completion list is attached to a token
    ' field, which is the one thing the Swift closure does.
    let themeEntry = TUIField()
    themeEntry.placeholder("type a theme name...")
    let themeCompletions = TUICompletions(themeEntry)
    ' themeCompletions.items = TUIKit.Theme.builtIn.map(\.name)
    '
    ' `items` takes the names one by one, so the list is walked rather than
    ' mapped. Same fifteen names, same order.
    for themeIndex = 0 to app.themecount() - 1
        themeCompletions.additem(app.themename(themeIndex))
    next themeIndex

    let ticked = TUISlider(50, 0, 100)
    ticked.ticks(5, 1)
    span = TUIRange(20, 60, 0, 100, 10)
    spanLabel = TUILabel("20...60 - Space switches thumbs")
    span.onchange("FieldsSpanChanged")

    let searchRow = Row()
    searchRow.add(search)
    searchRow.add(paste)
    let searchGroup = Group("SearchField - PasteButton - Esc/x clear, live and committed reports")
    searchGroup.add(searchRow)
    searchGroup.add(searchResult)
    root.add(PinnedHeight(searchGroup, 5))

    let tokenRow = Row()
    tokenRow.add(recipients)
    tokenRow.add(themeEntry)
    let tokenGroup = Group("TokenField + CompletionList - type 'd', down, Return - a second list on a plain field")
    tokenGroup.add(tokenRow)
    root.add(PinnedHeight(tokenGroup, 4))

    let sliderRow = Row()
    sliderRow.add(ticked)
    sliderRow.add(span)
    sliderRow.add(spanLabel)
    let sliderGroup = Group("Slider ticks that snap - RangeSlider")
    sliderGroup.add(sliderRow)
    root.add(PinnedHeight(sliderGroup, 4))

    return root
end function

' The Swift closures receive the text; a BASIC search handler is handed
' nothing, so each reads the field it belongs to.
function FieldsSearchChanged() as variant
    let text = search.text()
    if text = "" then
        searchResult.text("search cleared")
    else
        searchResult.text("searching: " + text)
    end if
    return 0
end function

function FieldsSearchCommitted() as variant
    searchResult.text("committed: " + search.text())
    return 0
end function

function FieldsPasted() as variant
    ' PasteButton { searchResult.text = "pasted: \($0)" } - the pasted text
    ' is not handed to a BASIC handler, so the report says that a paste
    ' happened rather than what arrived.
    searchResult.text("pasted")
    return 0
end function

function FieldsPasteEmpty() as variant
    searchResult.text("nothing to paste - copy something first (^C in a field)")
    return 0
end function

function FieldsSpanChanged() as variant
    ' span.onValuesChanged = { spanLabel.text = "\($0.lowerBound)...\($0.upperBound) ..." }
    spanLabel.text(STR$(span.lower()) + "..." + STR$(span.upper()) + " - Space switches thumbs")
    return 0
end function

' ------------------------------------------------------------------ Data

function MakeDataTab() as variant
    let root = TUIStack("v")

    ' MasterDetail at full width, so the split form shows; narrow the
    ' window below 60 columns to watch it collapse onto a navigator.
    let masterDetail = TUIMasterDetail()
    masterDetail.additem("=", "Inbox", "12 unread")
    masterDetail.additem("*", "Starred", "3 flagged")
    masterDetail.additem("~", "Drafts", "1 draft")
    masterDetail.additem("<", "Trash", "empty")

    ' The Swift builds each detail pane in a closure from the row's own
    ' title and subtitle; BASIC hands the finished pane over per row.
    masterDetail.detail(0, MakeFolderDetail("Inbox", "12 unread"))
    masterDetail.detail(1, MakeFolderDetail("Starred", "3 flagged"))
    masterDetail.detail(2, MakeFolderDetail("Drafts", "1 draft"))
    masterDetail.detail(3, MakeFolderDetail("Trash", "empty"))

    ' `let files = CollectionView(...)` - renamed: FILES is a reserved word,
    ' and using it as a variable ends the statement early.
    let fileGrid = TUICollection()
    fileGrid.section("Recent")
    fileGrid.additem("report.pdf")
    fileGrid.additem("notes.md")
    fileGrid.additem("photo.png")
    fileGrid.additem("deck.key")
    fileGrid.additem("todo.txt")
    fileGrid.section("Shared")
    fileGrid.additem("budget.xlsx")
    fileGrid.additem("plan.md")
    fileGrid.additem("logo.svg")

    let masterGroup = Group("MasterDetail - list drives detail; collapses to a navigator below 60 columns")
    masterGroup.add(masterDetail)
    root.add(PinnedHeight(masterGroup, 11))

    let filesGroup = Group("CollectionView - sections; arrows walk the grid")
    filesGroup.add(fileGrid)
    root.add(filesGroup)

    return root
end function

function MakeFolderDetail(title as string, subtitle as string) as variant
    let detail = TUIStack("v")
    detail.add(PinnedHeight(TUILabel("  " + title), 1))
    detail.add(PinnedHeight(TUILabel("  " + subtitle + " - the detail pane for this folder"), 1))
    return detail
end function

' ---------------------------------------------------------------- Wizard

function MakeWizardTab() as variant
    let root = TUIStack("v")

    wizardName = TUIField()
    wizardName.placeholder("user name (required)")
    let expressSkip = TUICheck("Express - skip the account step")
    let welcome = TUIStack("v")
    welcome.add(PinnedHeight(TUILabel("Welcome to the setup wizard."), 1))
    welcome.add(PinnedHeight(expressSkip, 1))
    wizardDone = TUILabel("setup has not finished yet")

    let wizard = TUIWizard()
    wizard.step("welcome", "Welcome", welcome)
    wizard.step("account", "Account", wizardName)
    wizard.step("done", "All set", TUILabel("Press Finish to complete the setup."))
    ' The `validate` and `next` closures are not bound: a step cannot refuse
    ' Next on an empty name, and Express does not branch past the account
    ' step. The steps and the trail are the Swift's; the two closures that
    ' make it interesting are what BASIC cannot yet say.
    wizard.onfinish("WizardFinished")

    let wizardGroup = Group("Wizard - validation blocks Next; Express branches past a step; Back walks the trail")
    wizardGroup.add(wizard)
    wizardGroup.add(wizardDone)
    root.add(PinnedHeight(wizardGroup, 12))

    return root
end function

function WizardFinished() as variant
    let entered = wizardName.text()
    if entered = "" then
        wizardDone.text("setup finished for (express)")
    else
        wizardDone.text("setup finished for " + entered)
    end if
    return 0
end function

' ---------------------------------------------------------------- Gauges

function MakeGaugesTab() as variant
    let root = TUIStack("v")

    ' func gauges(_ style: Gauge.Style) -> TUIView is a nested function taking
    ' the style; in BASIC it is GaugeRow below, called once per style.
    let levelIndicator = TUILevel(4, 5)
    levelIndicator.editable(1)
    levelIndicator.thresholds(4, 5)
    let stars = TUILevel(3, 5, "rating")
    stars.editable(1)

    root.add(SideBySideGauges("Gauge .ring - 0.7 warning, 0.9 critical", 9, "ring"))
    root.add(SideBySideGauges("Gauge .dial", 9, "dial"))

    let barGroup = Group("Gauge .bar - the form every terminal draws")
    barGroup.add(GaugeRow("bar"))
    root.add(PinnedHeight(barGroup, 3))

    let levelRow = Row()
    levelRow.add(levelIndicator)
    levelRow.add(stars)
    let levelGroup = Group("LevelIndicator - warning at 4, critical at 5 (left/right change it) - rating")
    levelGroup.add(levelRow)
    root.add(PinnedHeight(levelGroup, 3))

    return root
end function

function GaugeRow(style as string) as variant
    ' `let row = HStack(spacing: 2)` - renamed twice over: ROW is this file's
    ' own helper, `bar` is the toolbar in GalleryWindow.bas, and BASIC is
    ' case-insensitive, so `gaugeRow` would collide with GaugeRow itself.
    let styleRow = Row()
    let cpu = TUIGauge(42, style, "CPU")
    cpu.thresholds(0.7, 0.9)
    styleRow.add(cpu)
    let ram = TUIGauge(76, style, "RAM")
    ram.thresholds(0.7, 0.9)
    styleRow.add(ram)
    let disk = TUIGauge(93, style, "Disk")
    disk.thresholds(0.7, 0.9)
    styleRow.add(disk)
    return styleRow
end function

' sideBySide(title, height:) { make() } takes a *closure* that builds the
' view twice - once for the VTG panel, once for the ANSI one. BASIC has no
' closure to pass, so each caller has its own side-by-side that calls its
' own builder twice. Everything else - the two panels, their titles, the
' nochrome on the right copy, the pinned height - is shared in SideBySide.
function SideBySideGauges(title as string, height as integer, style as string) as variant
    return SideBySide(title, height, GaugeRow(style), GaugeRow(style))
end function

' --------------------------------------------------------------- Drawing

function MakeDrawingTab() as variant
    let root = TUIStack("v")

    ' Canvas.drawChrome and .drawCells are drawing closures - a Canvas paints
    ' through (Chrome, Rect) -> Void and (Painter, Rect) -> Void, and BASIC
    ' has no way to supply either. The two canvases are placed, side by side
    ' as in the Swift, and draw nothing.
    root.add(SideBySide("Canvas - chrome-only draw closure (the ANSI side is the honest placeholder)", 7, TUICanvas(), TUICanvas()))
    root.add(SideBySide("Canvas - with a cell closure too (no placeholder needed)", 5, TUICanvas(), TUICanvas()))

    ' The TUIKit logo from Docs, bundled as a resource; the generated
    ' gradient stands in if the bundle is missing.
    '
    ' Neither is reachable: BASIC cannot read the Swift package's bundle, and
    ' the gradient is a base64 literal decoded into Data. TUIImage takes a
    ' caption and draws its own placeholder.
    root.add(SideBySide("ImageView - right-click or long-press for Open in Viewer / Copy / Paste", 18, TUIImage("TUIKitLogo.png"), TUIImage("TUIKitLogo.png")))

    return root
end function
