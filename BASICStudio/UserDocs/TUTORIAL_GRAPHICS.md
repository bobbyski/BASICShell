# Graphics Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

This tutorial builds up a small calculator-style graphics program. It starts with the classic BASIC graphics commands, then adds retained VTG objects and mouse hit regions for an interactive user interface.

BASICShell graphics require a VTG-capable terminal. BASICStudio includes VTG graphics in the built-in console.

## Start A Graphics Program

Use `SCREEN` to mark the program as graphical, `CLS` to clear text and graphics, and `COLOR` to choose the current drawing color.

```basic
cls
screen 1
color "#22c55e"

line (40,40)-(360,40)
line (360,40)-(360,220)
line (360,220)-(40,220)
line (40,220)-(40,40)

circle (200,130), 42, "#60a5fa"

locate screenheight - 2, 1
print "Press any key to exit.";
wait$ = input$(1)
cls
end
```

`SCREEN` is accepted for source compatibility. In the current VTG implementation it does not switch to an old fixed-size PC graphics mode. Coordinates are native VTG canvas coordinates.

## Use Vector Drawing Commands

Use the classic commands when you want portable BASIC syntax:

- `PSET` and `PRESET` draw individual pixels. They work, but are best for small compatibility cases.
- `POINT(x,y)` reads the semantic palette color at a pixel.
- `LINE` draws lines and rectangles.
- `CIRCLE` draws circles and aspect-ratio ellipses.
- `PAINT` fills bounded regions.
- `DRAW` uses compact motion strings.

For a graphical app, prefer larger vector operations such as `LINE`, `CIRCLE`, `PAINT`, and `DRAW` instead of thousands of individual `PSET` calls.

## Use The VTG Wrapper For UI Objects

The `VectorTerminal()` object gives you retained graphics objects. Retained objects have ids, so later draws can replace or delete the same object without redrawing everything manually.

```basic
cls
screen 1

let vtg = VectorTerminal()
vtg.clear()
vtg.setDefaultLayer(2)

vtg.rect("display", 40, 40, 320, 70, "#22c55e", "#071107", 2, 8, "", "", 2)
vtg.vectorPrint("display-text", 60, 78, 28, "0", "#f8fafc", 2, 3)

vtg.rect("key-7", 40, 130, 70, 52, "#22c55e", "#0f172a", 2, 8, "", "", 2)
vtg.vectorPrint("label-7", 68, 149, 22, "7", "#f8fafc", 2, 3)

vtg.present()

locate screenheight - 2, 1
print "Press any key to exit.";
wait$ = input$(1)
cls
vtg.clear()
vtg.present()
end
```

The last number on `rect` and `text` is the graphics layer. Higher layers draw above lower layers.

## Add Mouse Hit Regions

Use `OPTION MOUSE ON` when the program needs mouse events. Add `ON MOUSE UP CALL` to receive clicks. A hit region gives the event a target string that tells the program which UI object was clicked.

```basic
option mouse on
on mouse up call MouseUp

let vtg = VectorTerminal()
vtg.clear()
vtg.clearHitRegions()

vtg.rect("key-7", 40, 130, 70, 52, "#22c55e", "#0f172a", 2, 8, "", "", 2)
vtg.vectorPrint("label-7", 68, 149, 22, "7", "#f8fafc", 2, 3)
vtg.hitRegion("hit-7", 40, 130, 70, 52, 2, "key:7")
vtg.present()

MainLoop:
    key$ = inkey$()
    if key$ = "q" then Done
    if key$ = "Q" then Done
    yield
    goto MainLoop

function MouseUp(event as variant)
    target$ = event("target")
    if target$ = "key:7" then print "Seven clicked"
end function

Done:
    cls
    vtg.clear()
    vtg.present()
    end
```

The `yield` statement lets queued timer, mouse, resize, and other host events run while your main loop is waiting.

## Complete Calculator Example

This is a small four-function calculator UI. It is intentionally simple: it keeps one pending operator, one stored value, and one display string.

```basic
cls
screen 1
option mouse on
on mouse up call MouseUp

global display$ as string = "0"
global storedValue as double = 0
global pendingOp$ as string = ""
global resetDisplay as boolean = false

let vtg = VectorTerminal()
vtg.clear()
vtg.setDefaultLayer(2)

gosub DrawCalculator

MainLoop:
    key$ = inkey$()
    if key$ = "q" then Done
    if key$ = "Q" then Done
    yield
    goto MainLoop

DrawCalculator:
    vtg.clear()
    vtg.clearHitRegions()
    vtg.rect("calc-bg", 30, 30, 330, 420, "#22c55e", "#050805", 2, 12, "", "", 1)
    gosub DrawDisplay

    buttonID$ = "7": buttonText$ = "7": buttonX = 50: buttonY = 140: gosub DrawButton
    buttonID$ = "8": buttonText$ = "8": buttonX = 125: buttonY = 140: gosub DrawButton
    buttonID$ = "9": buttonText$ = "9": buttonX = 200: buttonY = 140: gosub DrawButton
    buttonID$ = "/": buttonText$ = "/": buttonX = 275: buttonY = 140: gosub DrawButton

    buttonID$ = "4": buttonText$ = "4": buttonX = 50: buttonY = 205: gosub DrawButton
    buttonID$ = "5": buttonText$ = "5": buttonX = 125: buttonY = 205: gosub DrawButton
    buttonID$ = "6": buttonText$ = "6": buttonX = 200: buttonY = 205: gosub DrawButton
    buttonID$ = "*": buttonText$ = "*": buttonX = 275: buttonY = 205: gosub DrawButton

    buttonID$ = "1": buttonText$ = "1": buttonX = 50: buttonY = 270: gosub DrawButton
    buttonID$ = "2": buttonText$ = "2": buttonX = 125: buttonY = 270: gosub DrawButton
    buttonID$ = "3": buttonText$ = "3": buttonX = 200: buttonY = 270: gosub DrawButton
    buttonID$ = "-": buttonText$ = "-": buttonX = 275: buttonY = 270: gosub DrawButton

    buttonID$ = "C": buttonText$ = "C": buttonX = 50: buttonY = 335: gosub DrawButton
    buttonID$ = "0": buttonText$ = "0": buttonX = 125: buttonY = 335: gosub DrawButton
    buttonID$ = "=": buttonText$ = "=": buttonX = 200: buttonY = 335: gosub DrawButton
    buttonID$ = "+": buttonText$ = "+": buttonX = 275: buttonY = 335: gosub DrawButton

    locate screenheight - 2, 1
    print "Click buttons or press Q to exit.";
    vtg.present()
    return

DrawDisplay:
    vtg.rect("display", 50, 55, 290, 60, "#22c55e", "#071107", 2, 8, "", "", 2)
    displaySize = vtg.vectorTextSize(26, display$)
    displayTextWidth = int(displaySize("width"))
    displayTextHeight = int(displaySize("height"))
    displayTextX = 50 + 290 - displayTextWidth - 16
    if displayTextX < 64 then displayTextX = 64
    displayTextY = 55 + int((60 - displayTextHeight) / 2)
    vtg.vectorPrint("display-text", displayTextX, displayTextY, 26, display$, "#f8fafc", 2, 3)
    return

DrawButton:
    vtg.rect("button-" + buttonID$, buttonX, buttonY, 58, 48, "#22c55e", "#0f172a", 2, 8, "", "", 2)
    labelSize = vtg.vectorTextSize(20, buttonText$)
    labelWidth = int(labelSize("width"))
    labelHeight = int(labelSize("height"))
    labelX = buttonX + int((58 - labelWidth) / 2)
    labelY = buttonY + int((48 - labelHeight) / 2)
    vtg.vectorPrint("label-" + buttonID$, labelX, labelY, 20, buttonText$, "#f8fafc", 2, 3)
    vtg.hitRegion("hit-" + buttonID$, buttonX, buttonY, 58, 48, 2, "key:" + buttonID$)
    return

function MouseUp(event as variant)
    target$ = event("target")
    if left$(target$, 4) <> "key:" then exit function
    button$ = mid$(target$, 5)

    if button$ = "C" then
        display$ = "0"
        storedValue = 0
        pendingOp$ = ""
        resetDisplay = false
    else
        if button$ = "+" then OperatorClicked(button$)
        if button$ = "-" then OperatorClicked(button$)
        if button$ = "*" then OperatorClicked(button$)
        if button$ = "/" then OperatorClicked(button$)
        if button$ = "=" then EqualsClicked()
        if button$ = "0" then DigitClicked(button$)
        if button$ = "1" then DigitClicked(button$)
        if button$ = "2" then DigitClicked(button$)
        if button$ = "3" then DigitClicked(button$)
        if button$ = "4" then DigitClicked(button$)
        if button$ = "5" then DigitClicked(button$)
        if button$ = "6" then DigitClicked(button$)
        if button$ = "7" then DigitClicked(button$)
        if button$ = "8" then DigitClicked(button$)
        if button$ = "9" then DigitClicked(button$)
    end if

    gosub DrawDisplay
    vtg.present()
end function

function DigitClicked(digit$ as string)
    if resetDisplay then
        display$ = digit$
        resetDisplay = false
    else
        if display$ = "0" then
            display$ = digit$
        else
            display$ = display$ + digit$
        end if
    end if
end function

function OperatorClicked(op$ as string)
    if pendingOp$ <> "" then EqualsClicked()
    storedValue = val(display$)
    pendingOp$ = op$
    resetDisplay = true
end function

function EqualsClicked()
    rightValue = val(display$)
    if pendingOp$ = "+" then storedValue = storedValue + rightValue
    if pendingOp$ = "-" then storedValue = storedValue - rightValue
    if pendingOp$ = "*" then storedValue = storedValue * rightValue
    if pendingOp$ = "/" then
        if rightValue <> 0 then storedValue = storedValue / rightValue
    end if
    display$ = str$(storedValue)
    pendingOp$ = ""
    resetDisplay = true
end function

Done:
    cls
    vtg.clear()
    vtg.present()
    end
```

## Practical Tips

- Call `vtg.present()` after a group of drawing updates. This keeps redraws smoother than presenting after every object.
- Use stable object ids such as `"display-text"` or `"button-7"` when you intend to replace an object.
- Use `vtg.clearHitRegions()` before rebuilding a clickable screen.
- Use `OPTION MOUSE OFF` in programs that do not need mouse events.
- Keep `PSET` for compatibility and small pixel details. Prefer vector commands and retained VTG objects for application UI.
- End graphical programs with `CLS`, `vtg.clear()`, and `vtg.present()` so the terminal is left clean.
