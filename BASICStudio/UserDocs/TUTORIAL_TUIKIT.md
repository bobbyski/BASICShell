# TUIKit Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

This tutorial builds a small program with a menu, a window and a button, the
kind of program you use every day. It is written for someone who has finished
the [Beginner's Guide](TUTORIAL_BEGINNERS.md) and nothing else. Every line is
explained, and every step is a whole program you can run.

Type each step into the editor (or copy it), run it, and look at what it does
before reading on. Each step builds on the one before, so the new lines are
the only ones you have not met.

## The idea first

The programs in the Beginner's Guide run from top to bottom. They print, they
ask a question with `INPUT`, and the person answers. The program is in charge
and the person waits for it.

A program with windows works the other way round. It does its work in two
parts:

1. **It builds the screen.** It makes a menu, a window, a button and a line
   of text, and says where each one goes. Nothing shows yet.
2. **It hands the screen to the person.** From then on the person is in
   charge. They press keys, click buttons and choose from menus whenever they
   like, in any order. The program waits.

While the program waits, it has told each button what to do when it is
pressed: *run this function*. So when the person presses the button, the
program wakes up, runs that function, and goes back to waiting. That is the
whole idea. The rest of this tutorial is how to say it in BASIC.

TUIKit is the part of BASIC that draws windows like these. The windows are
made of the same letters, lines and boxes as the console, so they work in
BASICStudio and in a terminal with BASICShell.

## Step 1: An empty application

```basic
GLOBAL app = TUIApp()
GLOBAL shell AS VARIANT

FUNCTION Main() AS INTEGER
    shell = TUIShell()
    app.run(shell)
    PRINT "The program has ended."
    RETURN 0
END FUNCTION

Main()
```

Run it. The console clears and goes blank: that blank screen is your
application. It is waiting for you. Press **Esc**, and the console comes back
with `The program has ended.` printed on it.

Now each line.

**`GLOBAL app = TUIApp()`** makes the *application*. Think of it as the
person in charge of the screen: it owns the screen and the keyboard, decides
which window gets your key presses, and keeps everything drawn. A program has
exactly one.

`TUIApp()` is a new kind of thing. The Beginner's Guide put numbers and text
in variables; this puts an *object* in one. An object is a thing that can do
jobs, and you ask it to do one with a dot and the job's name, as you will see
two lines down with `app.run`. The jobs an object can do are called its
*methods*.

`GLOBAL` makes the variable reachable from everywhere in the program,
including from inside every `FUNCTION`. A variable made without it inside a
function belongs to that function alone. `app` has to be global, because
later a function will need to reach it to stop the program.

**`GLOBAL shell AS VARIANT`** makes a second global variable, but does not put
anything in it yet. `AS VARIANT` says it can hold any kind of value, which is
what you need for an object that will be made later. The shell is made
inside `Main`, below; it is declared out here, with `GLOBAL`, so that every
function can reach it once it has been made.

**`FUNCTION Main() AS INTEGER`** starts a function called `Main`. It does
nothing until something calls it. You met functions in the Beginner's Guide;
this one is the program's starting point. Putting the program's work in a
function called `Main` is a habit from many languages, and it keeps the
start of the program in one place you can find. `AS INTEGER` says it gives
back a whole number, which `RETURN 0`, below, provides. 0 is the traditional
way for a program to say "finished, and all went well".

**`shell = TUIShell()`** makes the *shell*: the background of the whole
application. It is the screen-sized window everything else sits on: a menu
row across the top, a status row along the bottom, and an empty desktop in
between, where windows float. Right now it has no menu and no status row, so
it is blank.

**`app.run(shell)`** is the moment the program hands the screen over. `run`
puts the shell on the screen and then waits, for as long as the application
is open, while the person uses it. **The line after `app.run` does not run
until the application has stopped.** That is how waiting looks in a program:
one line that takes a long time to finish.

Esc stops the application, because a shell treats Esc as "quit". Then
`app.run` finishes, the console comes back, and the program carries on with
the next line.

**`PRINT "The program has ended."`** runs after the application has stopped.
While the application is open, the screen belongs to it, so a program prints
after `run`, not during it.

**`RETURN 0`** ends `Main` and gives back 0, and **`END FUNCTION`** marks the
end of the function.

**`Main()`**, on the last line, is what actually starts everything. The lines
above it only *describe* the function; this line *calls* it. Without it, the
program would make `app`, make `shell` empty, and stop, having shown nothing.

## Step 2: A menu

```basic
GLOBAL app = TUIApp()
GLOBAL shell AS VARIANT

FUNCTION Main() AS INTEGER
    shell = TUIShell()

    let bar = TUIMenu()
    bar.menu("&File")
    bar.item("&Quit", "QuitGreeter")
    shell.add(bar)

    app.run(shell)
    PRINT "The program has ended."
    RETURN 0
END FUNCTION

FUNCTION QuitGreeter() AS INTEGER
    app.stop()
    RETURN 0
END FUNCTION

Main()
```

Run it. A menu row appears across the top with **File** in it. Click **File**
(or press **Alt-F**), then choose **Quit**, and the program ends just as Esc
ended it.

**`let bar = TUIMenu()`** makes a menu row and calls it `bar`. `let` makes a
variable that belongs only to `Main`. Nothing outside `Main` needs the menu
row once it is built, so it does not need to be global.

**`bar.menu("&File")`** adds a menu called **File** to the row. The `&` is not
shown: it marks the letter after it as the menu's shortcut, which is why
**Alt-F** opens it. The letter is underlined on the screen.

**`bar.item("&Quit", "QuitGreeter")`** adds an item called **Quit** to the
File menu, with **Q** as its shortcut once the menu is open. The second part,
`"QuitGreeter"`, is the important new idea, so it gets its own heading below.

**`shell.add(bar)`** puts the menu row into the shell. A shell knows where a
menu row goes, across the top, so you do not have to say.

### A function named in quotes

Look at `"QuitGreeter"` again. It is in quotes: it is the *name* of a
function, written as text. The program does not call `QuitGreeter` here. It
tells the menu item, *when the person chooses you, call the function with this
name*. Then the program carries on building.

Later, while `app.run` is waiting, the person chooses Quit. The application
looks up the function called `QuitGreeter` and calls it. Your program never
calls that function itself; the application does, at the moment the person
asks for it. A function that is called like this, because something happened
on the screen, is called a *handler*: it handles the thing that happened.

**`FUNCTION QuitGreeter() AS INTEGER`** is that handler. It sits outside
`Main`, at the top level of the program, because the application has to be
able to find it by its name.

**`app.stop()`** asks the application to stop: the same thing Esc does. `app`
can be used here because it is `GLOBAL`. This is why it had to be.

## Step 3: A status row

```basic
GLOBAL app = TUIApp()
GLOBAL shell AS VARIANT

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

    app.run(shell)
    PRINT "The program has ended."
    RETURN 0
END FUNCTION

FUNCTION QuitGreeter() AS INTEGER
    app.stop()
    RETURN 0
END FUNCTION

Main()
```

Run it. A row now runs along the bottom of the screen that says ` Greeter`
on the left and `Esc quits` after it.

**`let strip = TUIStatus()`** makes a status row: the line along the bottom
of a window that tells the person where they are and what they can do.

**`TUILabel(" Greeter")`** makes a *label*, a piece of text on the screen
that the person can read but not change.

**`strip.addsegment(TUILabel(" Greeter"), 12)`** puts that label in the
status row as its first part, or *segment*. The `12` is the narrowest the
segment may be, counted in characters: it always keeps room for 12 of them,
even when there is not much space.

**`strip.addsegment(TUILabel("Esc quits"), 0, 100)`** adds a second segment.
`0` asks for no particular width, and `100` says it gets 100 percent of the
room left over after the other segments. So the first segment keeps its 12
characters and this one stretches to fill the rest of the row.

**`shell.add(strip)`** puts the status row into the shell, which knows a
status row goes along the bottom.

## Step 4: A window

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
    greeting = TUILabel("Press the button.")
    win.add(greeting)
    app.present(win)

    app.run(shell)
    PRINT "The program has ended."
    RETURN 0
END FUNCTION

FUNCTION QuitGreeter() AS INTEGER
    app.stop()
    RETURN 0
END FUNCTION

Main()
```

Run it. A window with a border and the title **Greeter** floats on the
desktop, with `Press the button.` inside it. (There is no button yet; that is
the next step.) Press **Esc** once: the window closes. Press it again: with no
window left to close, the shell takes it and the program ends.

**`GLOBAL greeting AS VARIANT`**, near the top, is a new global for the label
in the window. It is global for the same reason as `app`: in the next step a
handler will change what the label says, and a handler can only reach what
is global.

**`let win = TUIFloatWindow("Greeter")`** makes a *floating window*, one that
sits on the desktop and can be moved, with **Greeter** as its title.

**`win.frame(4, 3, 40, 9)`** says where the window goes and how big it is.
The four numbers are its left edge, its top edge, its width and its height,
all counted in character cells, the same squares each letter on the screen
sits in. Counting from the top-left corner of the screen, which is 0, 0:

```text
   0         1         2         3         4
   0123456789012345678901234567890123456789012345
 0 File
 1
 2
 3     ┌─ Greeter ────────────────────────────┐
 4     │Press the button.                     │
 5     │                                      │
 6     │                                      │
 7     │                                      │
 8     │                                      │
 9     │                                      │
10     │                                      │
11     └──────────────────────────────────────┘
```

It starts 4 cells in from the left and 3 rows down, and is 40 cells wide and
9 rows tall, border included.

**`greeting = TUILabel("Press the button.")`** makes the label and puts it in
the global `greeting`. It is made here, inside `Main`, where the rest of the
screen is built, and kept in a global so that it can be found later.

**`win.add(greeting)`** puts the label inside the window.

**`app.present(win)`** puts the window on the desktop. *Present* means
*show*: hand it to the application to put on the screen. Because the
application has not started yet, it keeps the window and shows it the moment
`app.run` begins.

## Step 5: A button that does something

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
    PRINT "The program has ended."
    RETURN 0
END FUNCTION

FUNCTION SayHello() AS INTEGER
    greeting.text("Hello from BASIC.")
    RETURN 0
END FUNCTION

FUNCTION QuitGreeter() AS INTEGER
    app.stop()
    RETURN 0
END FUNCTION

Main()
```

Run it. The window now has a **Greet me** button under the label. Press
**Tab** to move to the button, then **Return** to press it (or click it), and
the label changes to `Hello from BASIC.`

**`let column = TUIStack("v")`** makes a *stack*: a holder that lines up what
you put in it, one under another. The `"v"` means *vertical*; `"h"` would
line them up side by side. A window holds one thing; to put two things in a
window, you put them in a stack and put the stack in the window. (To see why,
try the second mistake below.)

**`column.add(greeting)`** puts the label into the stack, first, so it is on
top.

**`let go = TUIButton("Greet me")`** makes a button with **Greet me** on it.

**`go.onclick("SayHello")`** is the same idea as the menu item in step 2, and
the most important line in this tutorial. It does not say hello. It tells the
button: *when someone presses you, call the function called `SayHello`*. Then
the program carries on building the window. Nothing has been greeted yet.

Later, while `app.run` is waiting, the person presses the button. Only then
does the application find `SayHello` and call it. The program describes what
should happen; the person decides when.

**`column.add(go)`** puts the button into the stack, under the label.

**`win.add(column)`** puts the whole stack, label and button together, into
the window.

**`FUNCTION SayHello() AS INTEGER`** is the button's handler.

**`greeting.text("Hello from BASIC.")`** changes what the label says. `text`
is one of a label's methods. The handler can reach the label because
`greeting` is global. If `greeting` had been made with `let` inside `Main`,
`SayHello` would have no way to find it.

## What the keys do

While a TUIKit program is running:

| Key | What it does |
|---|---|
| **Tab** | moves to the next thing you can use (a button, a field) |
| **Shift-Tab** | moves back to the one before |
| **Return** | presses the button you are on |
| **Esc** | closes the window in front; with no window left, quits a shell |
| **Alt** and a letter | opens the menu with that letter marked by `&`: **Alt-F** for File |
| Arrow keys | move around an open menu |
| Mouse | click a button, a menu or a window, wherever a mouse works |

The thing that Tab has moved to is said to *have the focus*: it is the one
your keys go to. A button with the focus is drawn highlighted.

## Mistakes to try on purpose

Making a mistake on purpose, and seeing what it does, is the quickest way to
understand why a line is there. Try each of these on the program from step 5,
then put the line back.

**Leave out `app.run(shell)`.** Delete that line and run. Nothing appears,
and `The program has ended.` is printed straight away. Everything was built,
the menu, the window, the button, but nothing was handed to the screen, so
the program went straight on to the end. Building a screen is not showing
it.

**Leave out the stack.** Replace the stack lines with two lines that add the
label and the button straight to the window:

```basic
    greeting = TUILabel("Press the button.")
    win.add(greeting)
    let go = TUIButton("Greet me")
    go.onclick("SayHello")
    win.add(go)
```

Run it, and the label is gone: the button sits where the label was. A window
puts each thing you add to it in the same place, filling the window, so the
second thing is drawn on top of the first. It looks like a bug in the drawing,
but it is a layout mistake, and a stack is what fixes it.

**Misspell the handler's name.** Change `go.onclick("SayHello")` to
`go.onclick("SayHelo")` and run. The window looks exactly the same: nothing is
checked while the screen is built, because a name in quotes is just text.
Press the button, and nothing happens. The application looked for a function
called `SayHelo`, found none, and kept the error for later, because while it
is running the screen is its own. Quit (Esc twice), and instead of
`The program has ended.` BASIC stops with that error. So when a button seems
to do nothing, check that the name in quotes matches the `FUNCTION`
exactly.

## Step 6: Grow it

Now make the program ask for a name. Change the middle of `Main`, where the
window is filled, and `SayHello`:

```basic
GLOBAL app = TUIApp()
GLOBAL shell AS VARIANT
GLOBAL greeting AS VARIANT
GLOBAL who AS VARIANT

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
    greeting = TUILabel("Type your name, then press the button.")
    column.add(greeting)
    who = TUIField("your name")
    column.add(who)
    let go = TUIButton("Greet me")
    go.onclick("SayHello")
    column.add(go)
    win.add(column)

    app.present(win)
    app.run(shell)
    PRINT "The program has ended."
    RETURN 0
END FUNCTION

FUNCTION SayHello() AS INTEGER
    LOCAL typed$ = who.value$()
    IF typed$ = "" THEN
        greeting.text("Type your name first.")
    ELSE
        greeting.text("Hello, " + typed$ + ".")
    END IF
    RETURN 0
END FUNCTION

FUNCTION QuitGreeter() AS INTEGER
    app.stop()
    RETURN 0
END FUNCTION

Main()
```

Run it. Press **Tab** to reach the field, type your name, press **Tab** again
to reach the button, and press **Return**. The label says hello to you by
name. Press the button with the field empty and it asks you to type your
name first.

**`GLOBAL who AS VARIANT`** is a global for the field, because `SayHello`
needs to read it.

**`who = TUIField("your name")`** makes a *field*, a box the person types
into. The words in brackets are shown in gray while the field is empty, as a
hint about what to type; they are not part of the answer.

**`column.add(who)`** puts the field into the stack, between the label and
the button.

**`LOCAL typed$ = who.value$()`** reads what is in the field. `value$` is the
field's method for that, and the `$` says, as it does for variables, that it
gives back text. `LOCAL` makes `typed$` belong to `SayHello` alone, like
`let` in `Main`.

The `IF` is the one from the Beginner's Guide: an empty field gets one
message, and a name gets the other, joined together with `+`.

Some ideas for making it your own:

- Add a second item to the File menu, **Clear**, whose handler empties the
  field (`who.text("")`) and puts the first message back in the label.
- Add a second button, side by side with the first: put both buttons in a
  `TUIStack("h")`, and add that stack to the column.
- Count how many times the person has been greeted, in a global number, and
  show the count in the label.

## Every line, in one place

The program from step 6 is the whole tutorial. Here is what each part is for:

| Lines | What they do |
|---|---|
| `GLOBAL app = TUIApp()` | makes the application, which owns the screen |
| `GLOBAL shell`, `greeting`, `who AS VARIANT` | globals for the things handlers need to reach, filled in `Main` |
| `FUNCTION Main() AS INTEGER` | the program's starting point |
| `shell = TUIShell()` | the background: menu row, desktop, status row |
| `TUIMenu`, `menu`, `item`, `shell.add(bar)` | the File menu, and what Quit calls |
| `TUIStatus`, `addsegment`, `shell.add(strip)` | the row along the bottom |
| `TUIFloatWindow`, `frame` | the window, and where it goes |
| `TUIStack("v")`, `column.add` | lines up the label, field and button |
| `TUILabel`, `TUIField`, `TUIButton` | the text, the box to type in, the button |
| `go.onclick("SayHello")` | which function the button calls |
| `win.add(column)`, `app.present(win)` | fills the window and shows it |
| `app.run(shell)` | hands the screen to the person, and waits |
| `PRINT`, `RETURN 0` | runs after the application has stopped |
| `FUNCTION SayHello` | reads the field and changes the label |
| `FUNCTION QuitGreeter` | stops the application |
| `Main()` | starts it all |

## Handlers can carry a value

A menu item can hand its handler one value as well as calling it:

```basic
bar.item(themeName, "ApplyThemeNamed", themeName)
```

So one handler can serve many menu items, because the value it needs travels
with the call. The handler takes it as a parameter:
`FUNCTION ApplyThemeNamed(name$ AS STRING) AS INTEGER`.

## Programs in more than one file

A program split across several files with `IMPORT` declares its globals in
the file it starts from. A `GLOBAL` declared in an imported file does not
reach the file that imported it: functions cross that boundary, but
variables do not.

## Where to look next

`basicPrograms/demos/tui/gallery.basproj` uses every control there is, one
file per group, and is the place to find the call you want. In BASICStudio it
is under **Examples ▸ TUI**. In a terminal, start it with:

```basic
basicshell basicPrograms/demos/tui/gallery.basproj/main.bas
```

`basicPrograms/demos/tui/tui-controls.bas` is a shorter list of the common
controls (fields, lists, tables, check boxes), each with a comment.

For real windows instead of ones drawn in the terminal, the
[ActiveUI Tutorial](TUTORIAL_ACTIVEUI.md) builds a to-do list the same way:
build, show, then wait while the person uses it.
