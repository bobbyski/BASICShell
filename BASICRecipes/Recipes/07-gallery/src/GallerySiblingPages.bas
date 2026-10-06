' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The sibling packages' pages: a kanban board, a diagram, and a terminal.

' ---------------------------------------------------------------- Boards

function MakeBoardsTab() as variant
    let root = TUIStack("v")

    boardMoved = TUILabel("left/right columns - up/down cards - Space picks up and drops - drag with the mouse - -/+ fold")

    let board = TUIBoard()
    ' A card joins the column most recently opened, so the nesting the Swift
    ' writes as an array of columns each holding its cards is written here as
    ' a column followed by its cards.
    board.column("todo", "To do")
    board.card("1", "Write the spec", "docs")
    board.card("2", "Port the charts", "TUIKit")
    board.card("3", "Ship 1.0", "release")
    board.column("doing", "Doing", 2)
    board.card("4", "Fix the donut seam", "VTG")
    board.card("5", "Soak harness", "driver")
    board.card("6", "Idle lockup", "driver")
    board.column("review", "Review")
    board.card("7", "Parity doc", "Phase 16")
    board.column("done", "Done")
    board.card("8", "Wave A", "10 controls")
    board.card("9", "Wave B", "15 controls")
    ' `isCollapsed: true` on Done is not carried: the column is built open.
    board.onmove("BoardCardMoved")

    let boardGroup = Group("TUIBoards - BoardView: WIP limit on Doing (2), Done folded")
    boardGroup.add(board)
    root.add(boardGroup)
    root.add(PinnedHeight(boardMoved, 1))
    return root
end function

function BoardCardMoved() as variant
    ' board.onCardMoved = { card, _, to, _ in moved.text = "moved ... to column \(to + 1)" }
    '
    ' The card and the destination column are not handed to a BASIC handler,
    ' so the label reports the move rather than naming the card.
    boardMoved.text("a card moved")
    return 0
end function

' --------------------------------------------------------------- Diagram

function MakeDiagramTab() as variant
    let root = TUIStack("v")

    diagramSelected = TUILabel("arrows walk the layers - Enter activates - click selects")

    let diagram = TUIDiagram()
    diagram.node("sources", "Sources")
    diagram.node("parse", "Parse")
    diagram.node("check", "Type check")
    diagram.node("lint", "Lint")
    diagram.node("emit", "Emit")
    diagram.node("link", "Link")
    diagram.node("test", "Test")
    diagram.node("ship", "Ship")
    diagram.edge("sources", "parse")
    diagram.edge("parse", "check")
    diagram.edge("parse", "lint")
    diagram.edge("check", "emit")
    diagram.edge("lint", "emit", "warnings")
    diagram.edge("emit", "link")
    diagram.edge("link", "test")
    diagram.edge("test", "ship")
    diagram.onselect("DiagramSelectionChanged")
    ' diagram.onActivate = { selected.text = "activated: \($0)" } - one
    ' selection handler is bound, so Enter reports as a selection does.

    let scroll = TUIScroll(diagram)

    let diagramGroup = Group("TUIDiagram - DiagramView: a build pipeline, laid out by the layering algorithm (rounded boxes and polylines under VTG)")
    diagramGroup.add(scroll)
    root.add(diagramGroup)
    root.add(PinnedHeight(diagramSelected, 1))
    return root
end function

function DiagramSelectionChanged() as variant
    ' The selected node's id is not handed over, so the label reports that
    ' the selection moved rather than which node it landed on.
    diagramSelected.text("selection changed")
    return 0
end function

' -------------------------------------------------------------- Terminal
'
' func makeTerminalTab(live: Bool) is deliberately absent, with WebBrowser:
' both drive a live subprocess. GalleryWindow leaves the tab out of the
' page list, and Scripts/gallery-parity.sh counts it as skipped.
