' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The Lists, Text, and Layout folder tabs.

' -------------------------------------------------------- Lists & trees

function MakeListsTab() as variant
    let root = TUIStack("v")

    let listView = TUIList()
    listView.items("Inbox", "Drafts", "Sent", "Archive", "Spam", "Trash")

    ' TreeView(roots: [TreeNode("Sources", children: [...]), ...])
    '
    ' A BASIC tree is built by adding nodes with a parent rather than by
    ' nesting constructors, because a node cannot hold an array of nodes.
    let tree = TUITree()
    tree.addnode("Sources")
    tree.addnode("TUIKit", "Sources")
    tree.addnode("Charts.swift", "TUIKit")
    tree.addnode("Toolbar.swift", "TUIKit")
    tree.addnode("Tests", "Sources")
    tree.addnode("Docs")
    tree.addnode("Architecture.md", "Docs")

    let table = TUITable()
    table.column("Name")
    table.column("Size", 8)
    table.column("Kind", 10)
    table.addrow("index.html", "12 KB", "html")
    table.addrow("style.css", "48 KB", "css")
    table.addrow("app.js", "214 KB", "js")
    table.addrow("logo.png", "9 KB", "image")

    ' The real disk, twice: an outline and Miller columns.
    let cwd = CURDIR$
    let directory = TUIDirTree(cwd)
    let browser = TUIBrowser(cwd)

    ' Crumbs + favorites: the one-row navigation strips.
    let pathStrip = TUIPath("/Users/bobby/src/frameworks/UILess/Code/TUIKit")
    let favorites = TUIFavorites()
    favorites.additem("TUIKit")
    favorites.additem("RichSwift")
    favorites.additem("VectorTerminal")

    let listsRow = Row()
    let listGroup = Group("ListView")
    listGroup.add(listView)
    listsRow.add(listGroup)
    let treeGroup = Group("TreeView")
    treeGroup.add(tree)
    listsRow.add(treeGroup)
    let tableGroup = Group("TableView")
    tableGroup.add(table)
    listsRow.add(tableGroup)
    root.add(listsRow)

    let diskRow = Row()
    let directoryGroup = Group("DirectoryTree (the real disk)")
    directoryGroup.add(directory)
    diskRow.add(directoryGroup)
    let browserGroup = Group("Browser - Miller columns")
    browserGroup.add(browser)
    diskRow.add(browserGroup)
    root.add(diskRow)

    let stripRow = Row()
    stripRow.add(pathStrip)
    stripRow.add(favorites)
    let stripGroup = Group("PathControl - TUIFavorites")
    stripGroup.add(stripRow)
    root.add(PinnedHeight(stripGroup, 4))
    return root
end function

' ------------------------------------------------------------------ Text

function MakeTextTab() as variant
    ' The R8 lexers, all three at once: markup, a style island, a script
    ' island with a regex literal.
    '
    ' BASIC has no multi-line string literal, so the sample is joined line by
    ' line with CHR$(10). The text is the Swift's, character for character.
    let nl = CHR$(10)
    let sample = "<!doctype html>" + nl
    sample = sample + "<html>" + nl
    sample = sample + "  <head>" + nl
    sample = sample + "    <style>" + nl
    sample = sample + "      body { color: #333; margin: 0; }  /* island: CSS */" + nl
    sample = sample + "    </style>" + nl
    sample = sample + "    <script>" + nl
    sample = sample + "      // island: JavaScript" + nl
    sample = sample + "      const ok = /ab+c/.test(input) && count > 42;" + nl
    sample = sample + "      document.title = `found ${count} items`;" + nl
    sample = sample + "    </script>" + nl
    sample = sample + "  </head>" + nl
    sample = sample + "  <body class=" + CHR$(34) + "main" + CHR$(34) + ">&lt;escaped&gt; &amp; entities</body>" + nl
    sample = sample + "</html>"

    let editor = TUISyntax(sample)
    editor.language("html")

    let textView = TUIText("TextView: focusable, selectable multi-line text." + nl + nl + "Arrow keys move, Shift extends the selection, ^C copies - the same editing engine as the code view, minus the gutter.")

    markdown = TUIMarkdown("# MarkdownView" + nl + nl + "Renders **RichSwift markdown**: headings, lists, quotes, `inline code`." + nl + nl + "- scrolls with arrows and the wheel" + nl + "- soft-wraps to its width")

    let rich = TUIRich("[bold yellow]RichText[/]: inline [cyan]markup[/] via [green]RichSwift[/] - tables, panels and syntax render too.")

    let top = Row()
    let editorGroup = Group("SyntaxTextView - html (script/style islands lex as JS/CSS)")
    editorGroup.add(editor)
    top.add(editorGroup)
    let textGroup = Group("TextView")
    textGroup.add(textView)
    top.add(textGroup)

    ' Phase 16.24: Edit flips the same pane to highlighted source and back.
    editToggle = TUIButton("&Edit source")
    editToggle.onclick("TextToggleEditing")

    let bottom = Row()
    let markdownGroup = Group("MarkdownView - Edit flips to the source editor")
    markdownGroup.add(PinnedHeight(editToggle, 1))
    markdownGroup.add(markdown)
    bottom.add(markdownGroup)
    let richGroup = Group("RichText")
    richGroup.add(rich)
    bottom.add(richGroup)

    ' Phase 16: Link hands its URL over (or opens it); (?) is the same
    ' control in its help-button dress.
    linkResult = TUILabel("links report here")
    let link = TUILink("TUIKit on GitHub", "https://github.com/bobbyski/TUIKit")
    link.onopen("TextLinkOpened")
    let help = TUILink("", "text", "tuikit://help#")
    help.onopen("TextHelpOpened")

    let root = TUIStack("v")
    root.add(top)
    root.add(bottom)
    let linkRow = Row()
    linkRow.add(link)
    linkRow.add(help)
    linkRow.add(linkResult)
    let linkGroup = Group("Link & HelpLink")
    linkGroup.add(linkRow)
    root.add(PinnedHeight(linkGroup, 4))
    return root
end function

function TextToggleEditing() as variant
    markdown.toggleedit()
    ' editToggle.title = markdown.isEditing ? "&Render" : "&Edit source"
    '
    ' `isEditing` cannot be read back, so the button's own title is what says
    ' which way the pane is facing.
    if editToggle.title() = "&Edit source" then
        editToggle.text("&Render")
    else
        editToggle.text("&Edit source")
    end if
    return 0
end function

function TextLinkOpened(url as string) as variant
    linkResult.text("would open: " + url)
    return 0
end function

function TextHelpOpened(url as string) as variant
    linkResult.text("help anchor: " + url)
    return 0
end function

' ---------------------------------------------------------------- Layout

function MakeLayoutTab() as variant
    let root = TUIStack("v")

    ' SplitView with the R7 axis flip, live.
    let first = TUILabel("first pane")
    first.align("c")
    let second = TUILabel("second pane")
    second.align("c")
    splitter = TUISplit("h", first, second)
    ' The divider position is sticky user state; minimums keep it sane
    ' through the zero-size first layout a freshly built tab goes through.
    splitter.minimums(8, 8)

    let flip = TUIButton("&Flip Axis")
    flip.onclick("LayoutFlipAxis")

    ' ScrollView: a document taller than its viewport.
    let document = TUIStack("v")
    for line = 1 to 30
        document.add(PinnedHeight(TUILabel("scrolling line " + STR$(line)), 1))
    next line
    document.contentheight(30)
    let scroll = TUIScroll(document)

    ' Disclosure + divider + ribbon.
    let disclosure = TUIDisclosure("Advanced")
    disclosure.add(TUILabel("hidden until disclosed"))

    let ribbon = TUIRibbon()
    ribbon.group("Clipboard", "Cut", "Copy", "Paste")
    ribbon.group("History", "Undo", "Redo")

    ' Phase 16: StatusBar flash (a timed message owning the row) and
    ' priority (the hint gives way first when the bar is narrow).
    layoutStatus = TUIStatus()
    ' a connected separator would weld into the group's title row
    layoutStatus.addsegment(TUILabel("Ready"), 8, 0, 2)
    layoutStatus.addsegment(TUILabel("low-priority hint - narrows first"), 0, 100, 0)
    layoutStatus.addsegment(TUILabel("Ln 12, Col 4"), 0, 0, 1)
    let flash = TUIButton("&Flash")
    flash.onclick("LayoutFlash")

    ' Phase 16: FlowStack reflows tags to the width; Form sections share
    ' one label column across headers.
    let tags = TUIFlow()
    tags.add(TUIButton("swift"))
    tags.add(TUIButton("terminal"))
    tags.add(TUIButton("tui"))
    tags.add(TUIButton("concurrency"))
    tags.add(TUIButton("testing"))
    tags.add(TUIButton("headless"))
    tags.add(TUIButton("vtg"))
    tags.add(TUIButton("themes"))
    tags.add(TUIButton("gallery"))
    tags.add(TUIButton("wave-b"))

    let nameEntry = TUIField()
    nameEntry.placeholder("your name")
    let emailEntry = TUIField()
    emailEntry.placeholder("you@host")
    let themePick = TUIPopup("Turbo", "Ambiance", "Standard")
    let sectioned = TUIForm()
    sectioned.section("Account")
    sectioned.field("Name", nameEntry)
    sectioned.field("Email", emailEntry)
    sectioned.section("Appearance")
    sectioned.field("Theme", themePick)

    ' Phase 16: Toolbox - an exclusive tool palette.
    toolLabel = TUILabel("tool: Select")
    toolbox = TUIToolbox("Select", "Pen", "Rect", "Ellipse")
    toolbox.onselect("LayoutToolChanged")

    let topRow = Row()
    let ribbonGroup = Group("Ribbon - grouped toolbar, placed like any view")
    ribbonGroup.add(ribbon)
    topRow.add(ribbonGroup)
    let toolboxGroup = Group("Toolbox - one tool at a time")
    toolboxGroup.add(toolbox)
    toolboxGroup.add(toolLabel)
    topRow.add(toolboxGroup)
    root.add(PinnedHeight(topRow, 5))

    let formRow = Row()
    let tagsGroup = Group("FlowStack - tags wrap to the width")
    tagsGroup.add(tags)
    formRow.add(tagsGroup)
    let sectionedGroup = Group("Form - Section headers, one label column")
    sectionedGroup.add(sectioned)
    formRow.add(sectionedGroup)
    root.add(PinnedHeight(formRow, 8))

    let flashRow = Row()
    flashRow.add(PinnedHeight(flash, 1))
    let statusGroup = Group("StatusBar - flash and priority")
    statusGroup.add(layoutStatus)
    statusGroup.add(flashRow)
    root.add(PinnedHeight(statusGroup, 5))

    ' Phase 16: Scroller - a bar of its own, driving the ScrollView beside it
    ' (and following it, when the view scrolls on its own).
    '
    ' The two-way wiring - scroller.onScroll moves the view, and the view's
    ' onOffsetChanged moves the scroller - is not expressible: neither
    ' callback is bound, and a BASIC handler is handed no offset. The bar is
    ' placed beside the view, spanning the same document, but the two do not
    ' follow each other.
    ' Scroller(axis:span:) - the span is fixed at construction: viewport 8
    ' over a document of 30, the same ScrollSpan the Swift gives it.
    let scroller = TUIScroller("v", 8, 30)

    let bottomRow = Row()
    ' Button and split as siblings: nesting them in their own stack
    ' would give the pair a fit-content intrinsic and starve the split.
    let splitGroup = Group("SplitView - Flip Axis is R7")
    splitGroup.add(PinnedHeight(flip, 1))
    splitGroup.add(splitter)
    bottomRow.add(splitGroup)

    let scrollRow = Row()
    scrollRow.add(scroller)
    scrollRow.add(scroll)
    let scrollGroup = Group("Scroller - ScrollView")
    scrollGroup.add(scrollRow)
    bottomRow.add(scrollGroup)

    let discloseGroup = Group("DisclosureGroup + Divider")
    discloseGroup.add(disclosure)
    discloseGroup.add(TUIDivider("h"))
    discloseGroup.add(TUILabel("below the rule"))
    bottomRow.add(discloseGroup)
    root.add(bottomRow)

    return root
end function

function LayoutFlipAxis() as variant
    if splitAxisIsHorizontal = 1 then
        splitter.axis("v")
        splitAxisIsHorizontal = 0
    else
        splitter.axis("h")
        splitAxisIsHorizontal = 1
    end if
    return 0
end function

function LayoutFlash() as variant
    layoutStatus.flash("Saved 3 files - back in 3 seconds")
    return 0
end function

function LayoutToolChanged() as variant
    ' toolLabel.text = "tool: \(toolbox.tools[$0].caption)"
    toolLabel.text("tool: " + toolbox.selectedtitle())
    return 0
end function
