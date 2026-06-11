#!/usr/bin/env BASICShell
' VTG event dashboard.
' This is the visual harness for the generic ON <type> [subtype] CALL event pass.

on resize call ResizeChanged
on mouse move call MouseMoved
on mouse up call MouseUp

global canvasWidth as integer = 1200
global canvasHeight as integer = 720
global headerY as integer = 12
global headerHeight as integer = 60
global headerTextHeight as integer = 50
global lastMove$ as string = "MOUSE MOVE: waiting"
global lastUp$ as string = "MOUSE UP: waiting"
global lastResize$ as string = "RESIZE: waiting"
global clock$ as string = date$() + " " + time$()

let vtg = VectorTerminal()
vtg.clear()
vtg.setDefaultLayer(2)

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
    gosub ReadCanvasSize
    vtg.rect("screen-bg", 0, 0, canvasWidth, canvasHeight, "none", "#050805", 0, 0, 2)
    vtg.line("top-rule", 0, headerY + headerHeight + 14, canvasWidth, headerY + headerHeight + 14, "#16a34a", 2, 2)
    gosub DrawClock
    gosub DrawEventPanels
    vtg.present()
    return

ReadCanvasSize:
    canvas = vtg.queryCurrentCanvas()
    canvasWidth = canvas("width")
    canvasHeight = canvas("height")
    if canvasWidth <= 0 then canvasWidth = 1200
    if canvasHeight <= 0 then canvasHeight = 720
    headerTextHeight = int(canvasWidth / (len(clock$) + 4))
    if headerTextHeight > 50 then headerTextHeight = 50
    if headerTextHeight < 20 then headerTextHeight = 20
    headerHeight = int(headerTextHeight * 1.2)
    return

DrawClock:
    clockX = int((canvasWidth - len(clock$) * headerTextHeight * .6) / 2)
    if clockX < 12 then clockX = 12
    vtg.rect("clock-box", 0, headerY, canvasWidth, headerHeight, "#22c55e", "#071107", 2, 0, 2)
    vtg.vectorPrint("clock-text", clockX, headerY + 6, headerTextHeight, clock$, "#86efac", 2, 2)
    vtg.present()
    return

DrawEventPanels:
    panelY = canvasHeight - 118
    panelHeight = 76
    panelWidth = 330
    centerX = int((canvasWidth - panelWidth) / 2)
    rightX = canvasWidth - panelWidth - 24

    vtg.rect("move-panel", 24, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("move-title", 42, panelY + 18, "LAST MOUSE MOVE", "#86efac", 18, 2)
    vtg.text("move-value", 42, panelY + 46, lastMove$, "#f8fafc", 16, 2)

    vtg.rect("resize-panel", centerX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("resize-title", centerX + 18, panelY + 18, "LAST RESIZE", "#86efac", 18, 2)
    vtg.text("resize-value", centerX + 18, panelY + 46, lastResize$, "#f8fafc", 16, 2)

    vtg.rect("up-panel", rightX, panelY, panelWidth, panelHeight, "#22c55e", "#071107cc", 2, 8, 2)
    vtg.text("up-title", rightX + 18, panelY + 18, "LAST MOUSE UP", "#86efac", 18, 2)
    vtg.text("up-value", rightX + 18, panelY + 46, lastUp$, "#f8fafc", 16, 2)
    return

function ResizeChanged(event as variant)
    lastResize$ = "RESIZE event received"
end function

function MouseMoved(event as variant)
    lastMove$ = "MOVE event received"
end function

function MouseUp(event as variant)
    lastUp$ = "UP event received"
end function
