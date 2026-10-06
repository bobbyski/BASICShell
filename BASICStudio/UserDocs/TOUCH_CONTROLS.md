# TouchControls: On-Screen Joystick, D-Pad, Wheel and Buttons

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-stubbed-yellow)

Puts game controls on the screen of an iPad or iPhone: a joystick, a d-pad, a wheel, and buttons. They are drawn over the program's graphics, and each one takes its own finger, so a player can steer and fire at once.

Where there is no touch screen (BASICStudio on the Mac, BASICShell, a compiled program) every call is accepted and does nothing, and `Available` is FALSE. One program runs everywhere unchanged.

```basic
touch = TouchControls()
touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
touch.Button("zap", "BOTTOMLEFT", 150, 90, 70, "ZAP", "#ffd60a", "B")

while running
    x = x + touch.X("stick") * 6
    if touch.Held("fire") then Fire()
    ...
wend
```

## Placing a control

| Call | Places |
|---|---|
| `Joystick(id, anchor, offsetX, offsetY, size [, reportsAs])` | A thumb pad that springs back to the middle. |
| `DPad(id, anchor, offsetX, offsetY, size [, reportsAs])` | Four directions and the diagonals between them. |
| `Wheel(id, anchor, offsetX, offsetY, size [, reportsAs])` | A spinner: how far it is turned, not where it points. |
| `Button(id, anchor, offsetX, offsetY, size, label, color [, reportsAs])` | A round button with a label, in a color such as `"#ff3b30"`. |

- **`id`** names the control. Placing another with the same id replaces it.
- **`anchor`** is the side or corner it sits against: `TOPLEFT`, `TOP`, `TOPRIGHT`, `LEFT`, `CENTER`, `RIGHT`, `BOTTOMLEFT`, `BOTTOM` or `BOTTOMRIGHT`.
- **`offsetX` and `offsetY`** are measured in from that side, in points. Along a centered axis they shift it right or down.
- **`size`** is its width, in points. A thumb is about 40 points across, so 140 to 180 suits a joystick or wheel, and 70 to 90 a button.

Controls stay where they are anchored when the screen rotates or the window changes size. They are taken away when the program ends. `touch.Remove(id)` takes one away, and `touch.Clear()` takes them all.

`touch.Directions(id, mode)` limits a joystick or d-pad:

| Mode | Joystick | D-pad |
|---|---|---|
| `"ALL"` (the default) | Any direction, with analog axes | Diagonals included |
| `"8"` | Snapped to eight directions | Diagonals included |
| `"4"` | Up, down, left or right, never two at once | No diagonals |
| `"HORIZONTAL"` | Left and right only: a paddle | Left and right only |
| `"VERTICAL"` | Up and down only | Up and down only |

## Reading them: polling

| Call | Returns |
|---|---|
| `touch.X(id)` | Across, from -1 (left) to 1 (right). A d-pad gives -1, 0 or 1. |
| `touch.Y(id)` | Down, from -1 (up) to 1 (down): the way screen and VTG coordinates run. |
| `touch.Held(id)` | TRUE while a finger is on it. |
| `touch.Turn(id)` | How far a wheel has turned since the last call, in degrees, clockwise positive. |
| `touch.Available` | TRUE where controls can be shown, so a program can show a hint only where they apply. |

## Reading them: as a game controller

Every control also reports the way a game controller does, through [ON GAMEPAD](EVENTS.md), as controller -1. A game written for a gamepad therefore works with the on-screen controls with no changes.

| Control | Reports as |
|---|---|
| Joystick | `LEFT_STICK_LEFT`, `LEFT_STICK_RIGHT`, `LEFT_STICK_UP`, `LEFT_STICK_DOWN`: value 1 when it leans past halfway, 0 when it comes back |
| D-pad | `DPAD_LEFT`, `DPAD_RIGHT`, `DPAD_UP`, `DPAD_DOWN` |
| Button | `A`: value 1 when pressed, 0 when released |
| Wheel | Subtype `WHEEL`, control `WHEEL`, and the degrees turned since its last event as the value |

The last argument, `reportsAs`, changes the name. A second button can be `"B"`, a second joystick `"RIGHT_STICK"`, and a d-pad can report as `"LEFT_STICK"`. Each press also reaches [INKEY$](INKEY.md), as `[GP:A`, the same way a real controller's does.

```basic
on gamepad call Pad

function Pad(event as BASICGamepadEvent)
    if event.Control = "A" and event.Value > 0.5 then Fire()
    if event.Subtype = "WHEEL" then angle = angle + event.Value
end function
```

See `input-events/touch-controls.bas` in the Examples for every control at once.
