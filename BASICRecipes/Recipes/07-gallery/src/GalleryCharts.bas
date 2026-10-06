' (no import line: BASIC reaches TUIKit through the TUI* pseudo classes)

' The Charts tab: every chart TWICE, side by side - the left copy renders
' vector graphics on a VTG terminal, the right copy sets
' `suppressesVectorChrome` so it always renders ANSI cells. On a plain
' terminal the two columns are identical by design; the caption says so.
' Taller than the window on purpose: the whole tab lives in a ScrollView.

' One chart beside its cells-pinned twin, each in a titled panel.
'
' `sideBySide(_:height:make:)` takes a closure and calls it twice. BASIC
' cannot pass a builder, so the two copies are built by the caller and
' handed in; everything the helper actually does - the two panels, their
' VTG/ANSI titles, the nochrome on the right copy, the pinned height - is
' here, once, as in the Swift.
function SideBySide(title as string, height as integer, vector as variant, cells as variant) as variant
    cells.nochrome(1)

    ' vector.anchors = .fill(); vectorPanel.content.addSubview(vector)
    '
    ' `fill`, not `add`: a panel's `add` stacks its children in a padded
    ' column, which is right for a group of controls and wrong for one chart
    ' that should own the panel - the extra layer and its one-column inset
    ' change the rect the chart is measured and clipped against, and a chart
    ' that is not wholly inside the clip drops its vector rendering.
    let vectorPanel = TUIPanel(title + " - VTG")
    vectorPanel.fill(vector)

    let cellsPanel = TUIPanel(title + " - ANSI")
    cellsPanel.fill(cells)

    let pair = Row()
    pair.add(vectorPanel)
    pair.add(cellsPanel)
    return PinnedHeight(pair, height)
end function

' private final class ChartsColumn: StackView { var contentHeight }
'
' A stack whose scroll height is declared, so the ScrollView can size the
' document (pinned rows carry no intrinsic of their own). A BASIC vertical
' TUIStack is that class already - `contentheight` is its declared height.

function MakeChartsTab() as variant
    let column = TUIStack("v")
    let totalHeight = 0

    ' func addRow(_ row: TUIView, _ height: Int) - adds the row and keeps the
    ' running total the column is sized by.
    column.add(SideBySide("Sparkline", 3, MakeSparkline(), MakeSparkline()))
    totalHeight = totalHeight + 3

    column.add(SideBySide("BarChart", 9, MakeBarChart(), MakeBarChart()))
    totalHeight = totalHeight + 9

    column.add(SideBySide("TimelineChart", 7, MakeTimelineChart(), MakeTimelineChart()))
    totalHeight = totalHeight + 7

    column.add(SideBySide("ScatterChart", 9, MakeScatterChart(), MakeScatterChart()))
    totalHeight = totalHeight + 9

    column.add(SideBySide("LineChart (heap fills its area)", 10, MakeLineChart(), MakeLineChart()))
    totalHeight = totalHeight + 10

    ' The pie sits last: its cell disc is the coarsest thing on the tab,
    ' and the charts above it deserve the first screenful.
    column.add(SideBySide("PieChart (donut 0.55)", 8, MakePieChart(), MakePieChart()))
    totalHeight = totalHeight + 8

    let note = TUILabel("If the two columns look the same, this terminal has no VTG graphics.")
    note.align("c")
    column.add(PinnedHeight(note, 1))
    totalHeight = totalHeight + 1

    column.contentheight(totalHeight)

    let scroll = TUIScroll(column)
    return scroll
end function

' Every builder below calls its chart `chart` in the Swift. BASIC fixes a
' name's type at its first assignment and that type is not scoped to the
' function, so a second `let chart = TUILineChart()` is rejected as an
' assignment of the wrong object. Each builder names its own.

function MakeSparkline() as variant
    return TUISparkline(2, 3, 3, 4, 5, 7, 8, 8, 9, 11, 14, 13, 15, 18, 17, 19, 22, 21, 24, 26)
end function

function MakeBarChart() as variant
    let barChart = TUIBarChart()
    barChart.categories("Mon", "Tue", "Wed", "Thu", "Fri")
    barChart.series("builds", 12, 17, 9, 21, 14)
    barChart.series("deploys", 4, 6, 3, 8, 5)
    barChart.legend(1)
    return barChart
end function

function MakeTimelineChart() as variant
    let timelineChart = TUITimeline()
    ' TimelineRow(label:, segments: [.init(start:duration:kind:)])
    '
    ' A track opens a row; its segments follow, each carrying its own kind -
    ' which is what colours style.css's wait and track.js's failure
    ' differently from the rest.
    timelineChart.track("index.html")
    timelineChart.segment(0, 210, "active")
    timelineChart.track("style.css")
    timelineChart.segment(60, 180, "waiting")
    timelineChart.segment(240, 380, "active")
    timelineChart.track("logo.png")
    timelineChart.segment(120, 30, "active")
    timelineChart.track("track.js")
    timelineChart.segment(150, 260, "waiting")
    timelineChart.segment(410, 90, "failed")
    timelineChart.domain(0, 800)
    ' chart.tickFormatter = { "\(Int($0))ms" } - a unit suffix, which is the
    ' part of a formatting closure BASIC can hand over.
    timelineChart.tickformat("ms")
    return timelineChart
end function

function MakeScatterChart() as variant
    let scatterChart = TUIScatter()
    scatterChart.series("cache hit", 2, 11, 5, 14, 7, 13, 11, 17, 14, 16, 17, 21, 21, 20, 24, 24)
    scatterChart.series("cache miss", 3, 4, 8, 7, 12, 5, 16, 9, 20, 7, 25, 11)
    scatterChart.legend(1)
    return scatterChart
end function

function MakeLineChart() as variant
    let lineChart = TUILineChart()
    lineChart.series("resident", 8, 9, 9, 10, 12, 12, 14, 17, 16, 18, 21, 22, 22, 25, 28)
    lineChart.series("heap", 3, 3, 4, 5, 5, 6, 8, 7, 8, 10, 10, 12, 12, 13, 15)
    ' `fillsArea: true` on the heap series - named after the fact, because a
    ' series is added by label and the flag cannot ride in with the values.
    lineChart.fillarea("heap")
    lineChart.legend(1)
    lineChart.yformat("MB")
    lineChart.domain(0, 180)
    lineChart.xformat("s")
    return lineChart
end function

function MakePieChart() as variant
    let pieChart = TUIPieChart()
    pieChart.slice("rent", 42)
    pieChart.slice("food", 33)
    pieChart.slice("transit", 17)
    pieChart.slice("misc", 8)
    pieChart.donut(0.55)
    return pieChart
end function
