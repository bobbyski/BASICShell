' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The Navigation folder tab: the Phase 16 structural pieces - pages,
' accordion sections, a layout that degrades, and (16.1) the navigator.

function MakeNavigationTab() as variant
    let root = TUIStack("v")

    ' ViewThatFits: the same intent at three sizes. The narrow group is
    ' capped, so the same control picks a shorter candidate there.
    let narrow = Group("ViewThatFits - narrow")
    narrow.add(SaveChoices())
    ' narrow.maximumSize = Size(width: 22, height: Int.max) - a maximum width
    ' is not bound, so the narrow group is as wide as the row gives it and
    ' both copies pick the same candidate.

    ' PageView: three pages, dots and arrows.
    pageLabel = TUILabel("page 1 of 3 - left/right turn, or click the dots")
    ' PageView(pages: [...]) - the pages are fixed at construction, as they
    ' are in the Swift, so they are passed rather than added.
    pages = TUIPages(TUILabel("Welcome - the first page."), TUILabel("Features - the second page."), TUILabel("Finish - the last page."))
    pages.onselect("NavigationPageChanged")

    ' Accordion: two sections with more options than fit, two with a line
    ' or two. The sections do NOT scroll themselves - the accordion sits in
    ' a ScrollView and is scrolled as a whole, its open section at its
    ' natural height.
    let accordion = TUIAccordion()
    accordion.section("General - 30 options", NavigationOptions("General", 30), 1)
    accordion.section("Appearance - 24 options", NavigationOptions("Appearance", 24))
    accordion.section("Shortcuts - one item", TUILabel("Cmd-K opens the command palette"))
    let about = TUIStack("v")
    about.add(PinnedHeight(TUILabel("TUIKit Gallery"), 1))
    about.add(PinnedHeight(TUILabel("the control showroom"), 1))
    accordion.section("About - two items", about)
    let accordionScroll = TUIScroll(accordion)

    ' Navigator: a drill-down menu two levels deep. Esc or Back returns.
    let menu = TUIStack("v")
    navigator = TUINavigator(menu, "Settings")
    depthLabel = TUILabel("level 1 - Enter a row to drill in")
    navigator.ondepth("NavigationDepthChanged")

    ' for (title, body) in [("Appearance", ...), ("Network", ...)]
    '
    ' The Swift closure captures its title and body and builds the page when
    ' the row is pressed; a BASIC handler is a name, so there is one handler
    ' per row and it builds the same page.
    let appearanceRow = TUIButton("Appearance >")
    appearanceRow.onclick("NavigationPushAppearance")
    menu.add(PinnedHeight(appearanceRow, 1))
    let networkRow = TUIButton("Network >")
    networkRow.onclick("NavigationPushNetwork")
    menu.add(PinnedHeight(networkRow, 1))

    let fitsRow = Row()
    let wideGroup = Group("ViewThatFits - wide")
    wideGroup.add(SaveChoices())
    fitsRow.add(wideGroup)
    fitsRow.add(narrow)
    root.add(PinnedHeight(fitsRow, 4))

    let middleRow = Row()
    let pagesGroup = Group("PageView")
    pagesGroup.add(pages)
    pagesGroup.add(pageLabel)
    middleRow.add(pagesGroup)
    let navigatorGroup = Group("Navigator - drill in, Esc back")
    navigatorGroup.add(navigator)
    navigatorGroup.add(depthLabel)
    middleRow.add(navigatorGroup)
    root.add(PinnedHeight(middleRow, 7))

    let accordionGroup = Group("Accordion - exclusive; Space on a header; the whole accordion scrolls")
    accordionGroup.add(accordionScroll)
    root.add(accordionGroup)

    return root
end function

' func saveChoices() -> ViewThatFits - a nested function in the Swift,
' called twice so each group gets its own copy.
function SaveChoices() as variant
    ' Candidates widest-first, at construction, as ViewThatFits takes them.
    return TUIViewThatFits("h", TUIButton("Save the document to disk"), TUIButton("Save document"), TUIButton("Save"))
end function

' func options(_ prefix: String, count: Int) -> TUIView
function NavigationOptions(prefix as string, count as integer) as variant
    let list = TUIStack("v")
    for index = 1 to count
        list.add(PinnedHeight(TUICheck(prefix + " option " + STR$(index)), 1))
    next index
    return list
end function

function NavigationPageChanged() as variant
    pageLabel.text("page " + STR$(pages.selected() + 1) + " of 3 - left/right turn, or click the dots")
    return 0
end function

function NavigationDepthChanged(depth as integer) as variant
    depthLabel.text("level " + STR$(depth) + " - Esc, Backspace or Back returns")
    return 0
end function

function NavigationPushAppearance() as variant
    navigator.push(NavigationPage("Appearance", "theme, colours, fonts", "NavigationPushAdvancedAppearance"), "Appearance")
    return 0
end function

function NavigationPushNetwork() as variant
    navigator.push(NavigationPage("Network", "proxies and timeouts", "NavigationPushAdvancedNetwork"), "Network")
    return 0
end function

function NavigationPage(title as string, body as string, advancedHandler as string) as variant
    let page = TUIStack("v")
    page.add(PinnedHeight(TUILabel(body), 1))
    let advanced = TUIButton("Advanced " + title + " >")
    advanced.onclick(advancedHandler)
    page.add(PinnedHeight(advanced, 1))
    return page
end function

function NavigationPushAdvancedAppearance() as variant
    navigator.push(TUILabel("the deep end of Appearance"), "Advanced Appearance")
    return 0
end function

function NavigationPushAdvancedNetwork() as variant
    navigator.push(TUILabel("the deep end of Network"), "Advanced Network")
    return 0
end function
