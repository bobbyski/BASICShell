#!/usr/bin/env BASICShell
' VTG event dashboard.
' Incremental redraws replace retained objects by stable IDs.

on resize call ResizeChanged
on mouse move call MouseMoved
on mouse up call MouseUp

global canvasWidth as integer = 1200
global canvasHeight as integer = 720
global headerY as integer = 2
global headerHeight as integer = 3
global headerTextHeight as integer = 1
global lastMove$ as string = "MOUSE MOVE: waiting"
global lastUp$ as string = "MOUSE UP: waiting"
global lastResize$ as string = "RESIZE: waiting"
global lastTimer$ as string = "TIMER: waiting"
global clock$ as string = date$() + " " + time$()
global clockDrawn as boolean = false
global clockColorIndex as integer = 0
global clockColor$ as string = "#86efac"

let vtg = VectorTerminal()
let timer = SecondsTimer(1)
timer.repeating = true
timer.start()
on timer(5) gosub TimerTick

vtg.clear()
vtg.setDefaultLayer(2)

gosub ReadCanvasSize
gosub DrawDashboard

MainLoop:
    key$ = inkey$()
    if key$ = "q" then Done
    if key$ = "Q" then Done
    yield
    goto MainLoop

Done:
    cls
    vtg.clear()
    vtg.present()
    end

DrawDashboard:
    cls
    vtg.clear()
    clockDrawn = false
    gosub UpdateLayout
    vtg.rect("screen-bg", 0, 0, canvasWidth, canvasHeight, "none", "#050805", 0, 0, "", "", -1)
    vtg.line("top-rule", 0, headerY + headerHeight + 14, canvasWidth, headerY + headerHeight + 14, "#16a34a", 2, "", 3)
    gosub DrawClock
    gosub DrawEventPanels
    vtg.present()
    return

ReadCanvasSize:
    canvas = vtg.queryCurrentCanvas(0)
    canvasWidth = canvas("width")
    canvasHeight = canvas("height")
    if canvasWidth <= 0 then canvasWidth = 1200
    if canvasHeight <= 0 then canvasHeight = 720
    gosub UpdateLayout
    return

UpdateLayout:
    headerTextHeight = int(canvasWidth / (len(clock$) + 4))
    if headerTextHeight > 50 then headerTextHeight = 50
    if headerTextHeight < 20 then headerTextHeight = 20
    headerHeight = int(headerTextHeight * 1.7)
    return

DrawClock:
    clockSize = vtg.vectorTextSize(headerTextHeight, clock$)
    clockWidth = int(clockSize("width"))
    clockHeight = int(clockSize("height"))
    clockX = int((canvasWidth - clockWidth) / 2)
    clockY = headerY + int((headerHeight - clockHeight) / 2)
    if clockX < 0 then clockX = 0
    if clockY < headerY then clockY = headerY
    clockClearMargin = int(headerTextHeight * 1.0)
    if clockClearMargin < 12 then clockClearMargin = 12
    clockClearY = headerY - clockClearMargin
    if clockClearY < 0 then clockClearY = 0
    clockClearHeight = headerHeight + (clockClearMargin * 2)
    vtg.rect("clock-box", 0, headerY, canvasWidth, headerHeight, "#22c55e", "#071107", 2, 0, "", "", 2)
    if clockDrawn then vtg.delete("clock-text")
    vtg.clearRect("clock-text-clear", 0, clockClearY, canvasWidth, clockClearHeight, 3)
    clockColorIndex = clockColorIndex + 1
    if clockColorIndex > 10 then clockColorIndex = 1
    clockColor$ = "#86efac"
    if clockColorIndex = 2 then clockColor$ = "#f87171"
    if clockColorIndex = 3 then clockColor$ = "#60a5fa"
    if clockColorIndex = 4 then clockColor$ = "#facc15"
    if clockColorIndex = 5 then clockColor$ = "#c084fc"
    if clockColorIndex = 6 then clockColor$ = "#fb923c"
    if clockColorIndex = 7 then clockColor$ = "#22d3ee"
    if clockColorIndex = 8 then clockColor$ = "#f472b6"
    if clockColorIndex = 9 then clockColor$ = "#a3e635"
    if clockColorIndex = 10 then clockColor$ = "#ffffff"
    vtg.vectorPrint("clock-text", clockX, clockY, headerTextHeight, clock$, clockColor$, 2, 3)
    clockDrawn = true
    return

DrawEventPanels:
    panelY = canvasHeight - 118
    panelHeight = 76
    panelGap = 24
    panelWidth = int((canvasWidth - (panelGap * 5)) / 4)
    if panelWidth < 220 then panelWidth = 220
    moveX = panelGap
    resizeX = moveX + panelWidth + panelGap
    timerX = resizeX + panelWidth + panelGap
    upX = timerX + panelWidth + panelGap
    ansiPanelY = SCREENHEIGHT - 3
    if ansiPanelY < 6 then ansiPanelY = 6
    ansiPanelGap = 3
    ansiPanelWidth = int((SCREENWIDTH - (ansiPanelGap * 5)) / 4)
    if ansiPanelWidth < 12 then ansiPanelWidth = 12
    ansiMoveX = ansiPanelGap
    ansiResizeX = ansiMoveX + ansiPanelWidth + ansiPanelGap
    ansiTimerX = ansiResizeX + ansiPanelWidth + ansiPanelGap
    ansiUpX = ansiTimerX + ansiPanelWidth + ansiPanelGap

    vtg.rect("move-panel", moveX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, "", "", 2)
    vtg.text("move-title", moveX + 18, panelY + 18, "LAST MOUSE MOVE", "#86efac", 18, 3)
    vtg.text("move-value", moveX + 18, panelY + 46, lastMove$, "#f8fafc", 16, 3)

    vtg.rect("resize-panel", resizeX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, "", "", 2)
    vtg.text("resize-title", resizeX + 18, panelY + 18, "LAST RESIZE", "#86efac", 18, 3)
    vtg.text("resize-value", resizeX + 18, panelY + 46, lastResize$, "#f8fafc", 16, 3)

    vtg.rect("timer-panel", timerX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, "", "", 2)
    vtg.text("timer-title", timerX + 18, panelY + 18, "LAST TIMER", "#86efac", 18, 3)
    vtg.text("timer-value", timerX + 18, panelY + 46, lastTimer$, "#f8fafc", 16, 3)

    vtg.rect("up-panel", upX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, "", "", 2)
    vtg.text("up-title", upX + 18, panelY + 18, "LAST MOUSE UP", "#86efac", 18, 3)
    vtg.text("up-value", upX + 18, panelY + 46, lastUp$, "#f8fafc", 16, 3)
    return

function ResizeChanged(event as variant)
    eventWidth = int(event("width"))
    eventHeight = int(event("height"))
    canvasWidth = eventWidth
    canvasHeight = eventHeight
    if canvasWidth <= 0 then canvasWidth = SCREENWIDTH
    if canvasHeight <= 0 then canvasHeight = SCREENHEIGHT
    if canvasWidth <= 0 then canvasWidth = 80
    if canvasHeight <= 0 then canvasHeight = 25
    lastResize$ = "RESIZE " + str$(canvasWidth) + " x " + str$(canvasHeight)
    gosub DrawDashboard
end function

function MouseMoved(event as variant)
    lastMove$ = "MOVE " + str$(int(event("x"))) + "," + str$(int(event("y")))
    gosub DrawEventPanels
    vtg.present()
end function

function MouseUp(event as variant)
    lastUp$ = "UP button " + str$(int(event("button"))) + " at " + str$(int(event("x"))) + "," + str$(int(event("y")))
    gosub DrawEventPanels
    vtg.present()
end function

function TimerTick(event as variant)
    clock$ = date$() + " " + time$()
    lastTimer$ = "TIMER " + str$(int(event("sequence"))) + " interval " + str$(int(event("interval")))
    gosub UpdateLayout
    gosub DrawClock
    gosub DrawEventPanels
    vtg.present()
end function
