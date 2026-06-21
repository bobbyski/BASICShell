#!/usr/bin/env BASICShell
' VTG event dashboard isolation harness.
' VTG drawing is commented out here so we can re-enable one piece at a time.

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
global drawRevision as integer = 0
global idSuffix$ as string = "-0"

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
    drawRevision = drawRevision + 1
    idSuffix$ = "-" + str$(drawRevision)
    gosub UpdateLayout
    vtg.rect("screen-bg" + idSuffix$, 0, 0, canvasWidth, canvasHeight, "none", "#050805", 0, 0, -1)
    vtg.line("top-rule" + idSuffix$, 0, headerY + headerHeight + 14, canvasWidth, headerY + headerHeight + 14, "#16a34a", 2, 3)
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
    headerHeight = int(headerTextHeight * 1.2)
    return

DrawClock:
    clockWidth = int(len(clock$) * headerTextHeight * 0.62)
    clockX = int((canvasWidth - clockWidth) / 2)
    clockY = headerY + int((headerHeight - headerTextHeight) / 2)
    vtg.rect("clock-box" + idSuffix$, 0, headerY, canvasWidth, headerHeight, "#22c55e", "#071107", 2, 0, 2)
    vtg.vectorPrint("clock-text" + idSuffix$, clockX, clockY, headerTextHeight, clock$, "#86efac", 2, 3)
    'ANSI-OFF: ansiClockX = int((SCREENWIDTH - len(clock$)) / 2) + 1
    'ANSI-OFF: if ansiClockX < 1 then ansiClockX = 1
    'ANSI-OFF: print chr$(27) + "[" + str$(headerY) + ";" + str$(ansiClockX) + "H";
    'ANSI-OFF: print clock$
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

    vtg.rect("move-panel" + idSuffix$, moveX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("move-title" + idSuffix$, moveX + 18, panelY + 18, "LAST MOUSE MOVE", "#86efac", 18, 3)
    vtg.text("move-value" + idSuffix$, moveX + 18, panelY + 46, lastMove$, "#f8fafc", 16, 3)
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY) + ";" + str$(ansiMoveX) + "H";
    'ANSI-OFF: print "MOVE"
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY + 1) + ";" + str$(ansiMoveX) + "H";
    'ANSI-OFF: print left$(lastMove$, ansiPanelWidth)

    vtg.rect("resize-panel" + idSuffix$, resizeX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("resize-title" + idSuffix$, resizeX + 18, panelY + 18, "LAST RESIZE", "#86efac", 18, 3)
    vtg.text("resize-value" + idSuffix$, resizeX + 18, panelY + 46, lastResize$, "#f8fafc", 16, 3)
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY) + ";" + str$(ansiResizeX) + "H";
    'ANSI-OFF: print "RESIZE"
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY + 1) + ";" + str$(ansiResizeX) + "H";
    'ANSI-OFF: print left$(lastResize$, ansiPanelWidth)

    vtg.rect("timer-panel" + idSuffix$, timerX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("timer-title" + idSuffix$, timerX + 18, panelY + 18, "LAST TIMER", "#86efac", 18, 3)
    vtg.text("timer-value" + idSuffix$, timerX + 18, panelY + 46, lastTimer$, "#f8fafc", 16, 3)
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY) + ";" + str$(ansiTimerX) + "H";
    'ANSI-OFF: print "TIMER"
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY + 1) + ";" + str$(ansiTimerX) + "H";
    'ANSI-OFF: print left$(lastTimer$, ansiPanelWidth)

    vtg.rect("up-panel" + idSuffix$, upX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("up-title" + idSuffix$, upX + 18, panelY + 18, "LAST MOUSE UP", "#86efac", 18, 3)
    vtg.text("up-value" + idSuffix$, upX + 18, panelY + 46, lastUp$, "#f8fafc", 16, 3)
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY) + ";" + str$(ansiUpX) + "H";
    'ANSI-OFF: print "MOUSE UP"
    'ANSI-OFF: print chr$(27) + "[" + str$(ansiPanelY + 1) + ";" + str$(ansiUpX) + "H";
    'ANSI-OFF: print left$(lastUp$, ansiPanelWidth)
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
    'VTG-OFF: gosub DrawDashboard
    gosub DrawClock
    gosub DrawEventPanels
    vtg.present()
end function
