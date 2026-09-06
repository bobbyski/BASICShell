# TUIKit Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Windows, menus and buttons on a terminal. This builds one small application
from nothing — every line of it runs.

## The whole program

```basic
GLOBAL app = TUIApp()
GLOBAL shell AS VARIANT
GLOBAL greeting AS VARIANT

FUNCTION Main() AS INTEGER
    shell = TUIShell()

    let bar = TUIMenu()
    bar.menu("&File")
    bar.item("&Quit", "QuitGreeter")
    shell.add(bar)

    let strip = TUIStatus()
    strip.addsegment(TUILabel(" Greeter"), 12)
    strip.addsegment(TUILabel("Esc quits"), 0, 100)
    shell.add(strip)

    let win = TUIFloatWindow("Greeter")
    win.frame(4, 3, 40, 9)

    let column = TUIStack("v")
    greeting = TUILabel("Press the button.")
    column.add(greeting)
    let go = TUIButton("Greet me")
    go.onclick("SayHello")
    column.add(go)
    win.add(column)

    app.present(win)
    app.run(shell)
    print "Restored terminal."
    return 0
END FUNCTION

FUNCTION SayHello() AS INTEGER
    greeting.text("Hello from BASIC.")
    return 0
END FUNCTION

FUNCTION QuitGreeter() AS INTEGER
    app.stop()
    return 0
END FUNCTION

Main()
```

Run it, press Tab to reach the button, press Return, and the label changes.
Esc closes the application and the terminal comes back as it was.

## The pieces

**`TUIApp()`** is the application. It takes no driver — where to draw is
settled when it is made. `app.run(shell)` starts the event loop and does not
return until `app.stop()`; `app.present(window)` puts a window on the
desktop.

**`TUIShell()`** is the backdrop: the menu row across the top, the status
row along the bottom, and the desktop between them where windows float.
`shell.add` knows what it is given — a `TUIMenu` takes the first row and
owns Esc, a `TUIStatus` takes the last.

**`TUIFloatWindow(title)`** is a window. `frame(x, y, width, height)`
places it; `minsize` and `maximizeinsets` bound how it resizes.

**`TUIStack("v")`** stacks what it is given, vertically here and
horizontally with `"h"`. This is the piece to reach for first: adding two
controls straight to a window puts them in the same place, one drawn over the
other, which looks like a drawing bug and is a layout mistake.

## Handlers are names

A Swift closure captures what it needs. A BASIC handler cannot, so a control
is given the **name** of a function to call:

```basic
go.onclick("SayHello")
```

The function is found by that name when the button is pressed, so it must be
a `FUNCTION` at file level, and anything it needs to reach — the label it
rewrites, the application it stops — has to be `GLOBAL`. That is why
`greeting` and `app` are globals here and `column` is not.

A menu item takes a handler the same way, and can carry one argument with it:

```basic
bar.item("&Quit", "QuitGreeter")
bar.item(themeName, "ApplyThemeNamed", themeName)
```

One handler can then serve fifteen menu items, because the value it needs
travels with the call rather than being captured.

## Where to look next

`basicPrograms/demos/gallery` is every control there is, one file per group,
and is the place to find the call you want. Start it with:

```basic
basicshell basicPrograms/demos/gallery/main.bas
```

A GLOBAL declared in an IMPORTed file does not reach the file that imported
it — functions cross that boundary, state does not — so a program split
across files declares its globals in the entry file. The gallery does exactly
this, and says so where it does it.
