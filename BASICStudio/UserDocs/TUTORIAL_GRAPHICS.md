# Graphics Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

This tutorial draws a box and a circle, then a button, and ends with a
calculator you work by clicking its buttons with the mouse. It is written for
someone who has finished the [Beginner's Guide](TUTORIAL_BEGINNERS.md) and
nothing else. Every line is explained, and every step is a whole program you
can run.

Type each step into the editor (or copy it), run it, and look at what it does
before reading on. Each step builds on the one before, so the new lines are
the only ones you have not met.

The pictures appear in BASICStudio's console. BASICShell draws them too, in a
terminal that can draw, such as VGTerm. An ordinary terminal cannot, and the
first drawing line stops the program with `VectorTerminal graphics are not
supported by this terminal`.

## The idea first

**The screen is a grid of tiny points**, and a program says where to draw by
counting points. Every point has two numbers:

- **x**, how far it is from the left edge;
- **y**, how far it is from the top edge.

The top-left corner is `(0, 0)`. x grows as you go right, and y grows as you
go *down*. That is the opposite of a graph at school, where y goes up, and it
is the one thing here most people trip over.

```text
(0,0) ───────────── x grows this way ──────────▶
  │
  │       (40,60) ┌──────────────────┐ (240,60)
  │               │                  │
  │               │     (140,120)    │
  y               │         ●        │
  grows           │                  │
  this way        └──────────────────┘
  │       (40,180)                     (240,180)
  ▼
```

Sizes are counted in points too. The box in the picture is 200 points wide
(from 40 to 240) and 120 points tall (from 60 to 180).

**A color is written as text**, such as `"#22c55e"`. After the `#` come three
pairs of digits: how much red, how much green and how much blue to mix. Each
pair runs from `00`, none at all, to `ff`, as much as there is. The digits go
past 9: after 9 come a, b, c, d, e and f, which is how one pair can count to
255. So `"#ff0000"` is pure red, `"#000000"` is black and `"#ffffff"` is
white. The colors in this tutorial are:

| Color | Looks like |
|---|---|
| `"#22c55e"` | green |
| `"#60a5fa"` | sky blue |
| `"#0f172a"` | very dark blue, almost black |
| `"#071107"` | almost black, a little green |
| `"#f8fafc"` | almost white |

`LINE` and `CIRCLE`, in Step 1, also take plain names, such as `"red"` or
`"white"`.

**There are two ways to draw.**

1. **Draw and forget.** `LINE` and `CIRCLE` work like paint on paper. Once a
   line is drawn, the program cannot pick it up again: to move it, it would
   have to paint over it and draw it again somewhere else.
2. **Shapes with names.** A *VectorTerminal* keeps every shape it draws,
   under a name the program gives it, like cut-out shapes on a board. The
   program can move a shape, change its color or take it off, just by using
   its name.

A calculator needs the second kind. Its display changes every time you click,
and its buttons have to know when they are clicked. The first two steps show
both ways side by side; the rest of the tutorial uses names.

**Clicking** works by laying invisible rectangles, called *hit regions*, over
the buttons, and naming a function for BASIC to run whenever the mouse is
clicked. Each click comes with the name of the hit region it landed in, so
the function knows which button was pressed. Step 5 is all about this.

## Step 1: A box and a circle

```basic
CLS
PRINT "Press any key to finish."
LINE (40, 60)-(240, 60), "#22c55e"
LINE (240, 60)-(240, 180), "#22c55e"
LINE (240, 180)-(40, 180), "#22c55e"
LINE (40, 180)-(40, 60), "#22c55e"
CIRCLE (140, 120), 40, "#60a5fa"
key$ = INPUT$(1)
CLS
```

Run it. A green box with a blue ring inside it appears under the words.
Press a key, and both go.

**`CLS`** clears the console: the words on it and any pictures. Starting with
it means the picture is not drawn over whatever was there before.

**`PRINT "Press any key to finish."`** goes on the console's top line. The
pictures are drawn *over* the console's words, not behind them, so the
drawing starts at y = 60, below the words, to keep out of their way.

**`LINE (40, 60)-(240, 60), "#22c55e"`** draws a straight green line from the
point `(40, 60)` to the point `(240, 60)`. Both points have the same y, so the
line goes straight across: it is the top of the box. The next three lines are
the right side (from the top-right corner down), the bottom (back to the
left) and the left side (up to where it started). Look at the picture in
[The idea first](#the-idea-first) and follow the four corners round.

**`CIRCLE (140, 120), 40, "#60a5fa"`** draws a blue circle. `(140, 120)` is
its center and 40 is its *radius*, the distance from the center to the edge.
The center is the middle of the box: 140 is halfway between 40 and 240, and
120 is halfway between 60 and 180.

**`key$ = INPUT$(1)`** waits until one key is pressed, and puts that key in
`key$`. Nothing uses `key$` afterwards; the line is there for the waiting.
Without it the program would end the moment it had drawn, and the picture
would hardly be seen. In BASICShell a picture is cleared the moment its
program ends; in BASICStudio it stays on the console, over the prompt.

**`CLS`**, at the end, takes the picture away, so the console is left clean
for whatever comes next.

You may see `SCREEN 1` at the top of graphics programs in older books. Old
BASICs needed it to switch the screen to pictures. This one does not, though
it accepts the line, so those programs still run.

Try changing the numbers: move the circle, make it bigger, change a color.

## Step 2: Shapes with names

```basic
CLS
PRINT "Press any key to finish."
vtg = VectorTerminal()
vtg.rect("box", 40, 60, 200, 120, "#22c55e", "#0f172a", 2)
vtg.circle("ball", 140, 120, 40, "#60a5fa", "#60a5fa")
vtg.present()
key$ = INPUT$(1)
CLS
```

Run it. The same picture, almost: this time the box is filled in dark blue
and the circle is a solid ball.

**`vtg = VectorTerminal()`** makes a new kind of thing. The Beginner's Guide
put numbers and words in variables; this puts an *object* in one. An object
is a thing that can do jobs, and you ask it to do one by writing a dot and the
job's name after it, as the next line does with `vtg.rect`. The jobs an
object can do are called its *methods*. This object is the drawing board:
everything it draws, it keeps, by name.

**`vtg.rect("box", 40, 60, 200, 120, "#22c55e", "#0f172a", 2)`** draws a
rectangle. The values in brackets are, in order:

| Value | Means |
|---|---|
| `"box"` | the shape's name |
| `40, 60` | its top-left corner: x, then y |
| `200, 120` | its width and its height |
| `"#22c55e"` | the color of its outline |
| `"#0f172a"` | the color it is filled with |
| `2` | how thick the outline is, in points |

A rectangle is given by its corner and its size, not by four lines, so this
is the same box as Step 1's.

**`vtg.circle("ball", 140, 120, 40, "#60a5fa", "#60a5fa")`** draws a circle
named `"ball"`, with its center at `(140, 120)`, a radius of 40, a blue
outline and a blue filling. It is drawn after the box, so it is on top of it.

**`vtg.present()`** says "that is the whole picture". BASICStudio and VGTerm
draw each shape the moment it arrives, so leaving the line out changes
nothing you can see there; try it. Keep it all the same. It marks the end of
a picture in your program, and a terminal is allowed to wait for it before it
shows what has changed.

The names, `"box"` and `"ball"`, are what the next step is for. Keep names
to letters, digits, `-` and `_`, with no spaces: some names, as Step 6
shows, are not allowed anything else.

## Step 3: Moving a shape, and taking it away

```basic
CLS
PRINT "Press a key to move the ball."
vtg = VectorTerminal()
vtg.rect("box", 40, 60, 200, 120, "#22c55e", "#0f172a", 2)
FOR x = 80 TO 200 STEP 40
    vtg.circle("ball", x, 120, 20, "#60a5fa", "#60a5fa")
    vtg.present()
    key$ = INPUT$(1)
NEXT x
vtg.delete("ball")
vtg.present()
PRINT "The ball has gone. Press a key to finish."
key$ = INPUT$(1)
CLS
```

Run it. A smaller ball starts at the left of the box. Press a key three
times, and each press moves it along, until it reaches the right side. The
fourth key takes the ball away, and one more finishes.

**`FOR x = 80 TO 200 STEP 40`** counts like the `FOR` in the Beginner's
Guide, but `STEP 40` makes it go up by 40 each time instead of by 1. So `x`
is 80, then 120, then 160, then 200.

**`vtg.circle("ball", x, 120, 20, "#60a5fa", "#60a5fa")`** draws a ball with
its center at `x`. This is the line that matters most in the tutorial: every
time round the loop, it draws a shape called `"ball"`, and **a shape drawn
with a name that is already on the board replaces the one that was there.**
It does not add a second ball. So the ball seems to move: the old one goes,
and the new one appears a little further on.

With `CIRCLE` this would not work. Each `CIRCLE` would add another ring, and
the old ones would stay where they were.

**`vtg.present()`** and **`key$ = INPUT$(1)`**, inside the loop, finish each
picture and wait for a key before the next move.

**`vtg.delete("ball")`** takes the shape called `"ball"` off the board. The
box stays, because it has a different name.

Try making the ball change color as it goes: give it a different color the
last time round, with an `IF x = 200 THEN`.

## Step 4: A button

```basic
CLS
PRINT "Press any key to finish."
vtg = VectorTerminal()
vtg.rect("button", 40, 60, 200, 60, "#22c55e", "#0f172a", 2, 10)
vtg.vectorPrint("caption", 56, 80, 21, "Press me", "#f8fafc", 2)
vtg.hitRegion("button-hit", 40, 60, 200, 60)
vtg.present()
key$ = INPUT$(1)
CLS
```

Run it. A rounded button says *Press me*. Click it: nothing happens yet. The
button is there, but the program is not listening for clicks. That is the
next step.

**`vtg.rect("button", 40, 60, 200, 60, "#22c55e", "#0f172a", 2, 10)`** is a
rectangle like Step 2's, 200 wide and 60 tall, with one more value at the
end: 10 rounds its corners off, with curves 10 points across.

**`vtg.vectorPrint("caption", 56, 80, 21, "Press me", "#f8fafc", 2)`** writes
words on the board, made of straight lines, like the letters on an old arcade
game. The values are the name, the top-left corner of the first letter (x,
then y), how tall the letters are, the words, their color and how thick their
lines are.

Every letter takes up a space as wide as it is tall, which makes words easy
to place. These letters are 21 points tall, so *Press me*, 8 letters with the
space, is 8 × 21 = 168 points across. The button is 200 across, which leaves
32 over: 16 on each side. So the words start 16 in from the button's left
edge, at 40 + 16 = 56. The same sum up and down: the button is 60 tall, the
letters are 21, which leaves 39 over, about 20 above and below, so the top of
the letters is at 60 + 20 = 80.

**`vtg.hitRegion("button-hit", 40, 60, 200, 60)`** lays a hit region over the
button: an invisible rectangle, in exactly the button's place. It is not
drawn; it is how a click knows what it landed on. Its name, `"button-hit"`,
is what a click on it reports.

## Step 5: Listening for clicks

```basic
GLOBAL vtg = VectorTerminal()
GLOBAL clicks = 0

CLS
PRINT "Click the button. Press any key to finish."
vtg.rect("button", 40, 60, 200, 60, "#22c55e", "#0f172a", 2, 10)
vtg.vectorPrint("caption", 56, 80, 21, "Press me", "#f8fafc", 2)
vtg.hitRegion("button-hit", 40, 60, 200, 60)
vtg.present()

ON MOUSE UP CALL Clicked

WHILE INKEY$() = ""
    rested = AWAIT Sleep(20)
WEND
CLS

FUNCTION Clicked(event AS BASICMouseEvent)
    IF event.HitId = "button-hit" THEN
        clicks = clicks + 1
        vtg.vectorPrint("count", 40, 140, 14, "Clicks:" + STR$(clicks), "#f8fafc", 1)
        vtg.present()
    END IF
END FUNCTION
```

Run it, and click the button a few times. *Clicks: 1* appears under it, then
*Clicks: 2*, and so on. Click beside the button, and the count stays as it
is. Press a key to finish.

This step is the important one, so first the idea, then the lines.

Every program so far has run from top to bottom, and when it needed the
person, it stopped at a line and waited, as `INPUT$` does. A click cannot be
caught that way. It can come at any moment, or never, and the person may
press a key instead. So the program does it the other way round. It names a
function and tells BASIC: *whenever the mouse is clicked, call this.* BASIC
remembers that, and the program carries on. When a click comes, BASIC pauses
the program wherever it has got to, calls the function, and then lets the
program carry on from where it was. Something that happens, like a click, is
called an *event*, and a function called when it happens is said to *handle*
it.

Now the lines.

**`GLOBAL vtg = VectorTerminal()`** and **`GLOBAL clicks = 0`** make two
variables that every function in the program shares. `GLOBAL` says so. The
function at the bottom needs `vtg`, to draw with, and `clicks`, to count
with.

The lines after them clear the console, print the instructions and draw the
button, as in Step 4.

**`ON MOUSE UP CALL Clicked`** is the line that says *whenever the mouse is
clicked, call `Clicked`*. `UP` is the moment the mouse button comes back up,
at the end of a click. (`ON MOUSE DOWN` and `ON MOUSE MOVE` exist too.) The
function is named, not called: there are no brackets after `Clicked`. Asking
for mouse events is also what switches the mouse on for the program. You may
see `OPTION MOUSE ON` in other programs; it does the same, explicitly.

**`WHILE INKEY$() = ""`** keeps the program going, and listening, until a key
is pressed. `INKEY$()` looks to see whether a key has been pressed, and gives
it back if so; it does not wait. If none has, it gives back `""`, nothing,
and the loop goes round again.

Why not `INPUT$(1)`, as before? Because `INPUT$` waits so completely that
nothing else can happen while it does: a click is not heard until a key has
been pressed. A loop is different. Each time round, BASIC gets a chance to call
`Clicked` for any click that has come in.

**`rested = AWAIT Sleep(20)`** rests for 20 thousandths of a second each time
round. Without it, the loop would look for a key thousands of times a second,
and keep the computer busy (and its fan going) for nothing. `Sleep(20)` is the
rest; `AWAIT` means *wait here until it is over*, and the 20 it gives back
has to go somewhere, so it goes in `rested`, which nothing uses. The [Async
Programming Tutorial](TUTORIAL_ASYNC.md) explains `AWAIT` properly.

**`FUNCTION Clicked(event AS BASICMouseEvent)`** is the function BASIC calls
for each click. BASIC gives it one value, the *event*: everything about the
click. `AS BASICMouseEvent` says what kind of value that is. The event knows
where the click was, as `event.X` and `event.Y`, and the name of the hit
region it landed in, as `event.HitId`. A click that landed in no hit region
has an `event.HitId` of `""`.

**`IF event.HitId = "button-hit" THEN`** makes only clicks on the button
count.

**`clicks = clicks + 1`** counts the click.

**`vtg.vectorPrint("count", 40, 140, 14, "Clicks:" + STR$(clicks), "#f8fafc", 1)`**
writes the count under the button, in smaller letters, 14 tall. `STR$` turns
the number into text, so that it can be joined to `"Clicks:"`. It puts a
space in front of the number, where a minus sign would go for a number below
zero, and that space is the gap after the colon. The words have the same name,
`"count"`, every time, so each count replaces the one before.

**`vtg.present()`** finishes the change.

The function sits at the end of the program, after `CLS`. That is safe: a
function only runs when something calls it, so the program's own lines never
run into it.

## Step 6: The display and the digits

```basic
GLOBAL vtg = VectorTerminal()
GLOBAL shown$ = "0"

CLS
PRINT "Click the buttons. Press any key to finish."
vtg.rect("display", 40, 50, 270, 60, "#22c55e", "#071107", 2, 8)
ShowNumber()

digits$ = "789456123C0"
FOR i = 0 TO LEN(digits$) - 1
    caption$ = MID$(digits$, i + 1, 1)
    DrawButton(caption$, "key" + caption$, i MOD 3, INT(i / 3))
NEXT i
vtg.present()

ON MOUSE UP CALL Clicked

WHILE INKEY$() = ""
    rested = AWAIT Sleep(20)
WEND
CLS

FUNCTION DrawButton(caption$ AS STRING, id$ AS STRING, column AS INTEGER, row AS INTEGER)
    x = 40 + column * 70
    y = 130 + row * 60
    vtg.rect(id$ + "-box", x, y, 60, 50, "#22c55e", "#0f172a", 2, 8)
    vtg.vectorPrint(id$ + "-caption", x + 20, y + 15, 21, caption$, "#f8fafc", 2)
    vtg.hitRegion(id$, x, y, 60, 50)
END FUNCTION

FUNCTION ShowNumber()
    size = 21
    IF LEN(shown$) * size > 246 THEN size = INT(246 / LEN(shown$))
    vtg.vectorPrint("number", 298 - LEN(shown$) * size, 80 - INT(size / 2), size, shown$, "#f8fafc", 2)
    vtg.present()
END FUNCTION

FUNCTION Clicked(event AS BASICMouseEvent)
    pressed$ = event.HitId
    IF pressed$ = "keyC" THEN
        shown$ = "0"
    ELSEIF pressed$ <> "" THEN
        IF shown$ = "0" THEN
            shown$ = RIGHT$(pressed$, 1)
        ELSE
            shown$ = shown$ + RIGHT$(pressed$, 1)
        END IF
    END IF
    ShowNumber()
END FUNCTION
```

Run it. A display shows 0, with the digit buttons under it. Click 1, 2 and
3, and the display shows 123. Click **C**, and it goes back to 0. If the
calculator is cut off at the bottom, make the console bigger.

**`GLOBAL shown$ = "0"`** is what the display shows. It is kept as text, not
as a number, because the digits are added to the end of it one at a time, as
they are clicked.

**`vtg.rect("display", 40, 50, 270, 60, "#22c55e", "#071107", 2, 8)`** is the
display's box. It is 270 points wide: room above four columns of buttons,
though there are only three in this step. The fourth comes in Step 7.

**`ShowNumber()`** draws the number in the display; the function is below.

**`digits$ = "789456123C0"`** lists the buttons in the order they appear,
reading the way you read a page: 7, 8, 9 across the top row, then 4, 5, 6,
then 1, 2, 3, then C and 0 at the bottom. A calculator's 7 is at the top.

**`FOR i = 0 TO LEN(digits$) - 1`** goes once for each of the 11 buttons.
`LEN` gives the length of a piece of text, 11 here, and the count starts at
0, so it ends at 10.

**`caption$ = MID$(digits$, i + 1, 1)`** takes one letter out of `digits$`.
`MID$(text$, start, how many)` gives `how many` letters of `text$`,
beginning at letter number `start`. The letters are numbered from 1, which
is why it is `i + 1`.

**`DrawButton(caption$, "key" + caption$, i MOD 3, INT(i / 3))`** draws one
button. It is given the caption, a name for the button, and which column and
row it goes in, counting from 0.

- The name is the caption with `key` in front: `"key7"`, `"keyC"`. A name
  can only use letters, digits, `-` and `_`, and starting with `key` makes it
  clear what it is.
- `i MOD 3` is the *remainder* when `i` is divided by 3. As `i` counts up, it
  goes 0, 1, 2, 0, 1, 2, ... round and round, which is just what a column
  number does along a row of three.
- `INT(i / 3)` divides by 3 and drops anything after the point. It goes 0, 0,
  0, 1, 1, 1, 2, ... and moves down a row after every three buttons.

| `i` | button | `i MOD 3` (column) | `INT(i / 3)` (row) |
|---|---|---|---|
| 0, 1, 2 | 7, 8, 9 | 0, 1, 2 | 0 |
| 3, 4, 5 | 4, 5, 6 | 0, 1, 2 | 1 |
| 6, 7, 8 | 1, 2, 3 | 0, 1, 2 | 2 |
| 9, 10 | C, 0 | 0, 1 | 3 |

**`vtg.present()`**, after the loop, finishes the picture. `ON MOUSE UP CALL
Clicked` and the waiting loop are Step 5's.

**`FUNCTION DrawButton(caption$ AS STRING, id$ AS STRING, column AS INTEGER, row AS INTEGER)`**
draws a button from those four values.

- **`x = 40 + column * 70`** and **`y = 130 + row * 60`** turn the column and
  row into points. Buttons are 60 wide with 10 between them, so each column
  is 70 further across; they are 50 tall with 10 between, so each row is 60
  further down. The first row starts at y = 130, under the display.
- **`vtg.rect(id$ + "-box", ...)`** draws the button, named for example
  `"key7-box"`.
- **`vtg.vectorPrint(id$ + "-caption", x + 20, y + 15, 21, caption$, ...)`**
  writes its caption. One letter 21 tall is 21 across, so in a button 60
  wide it starts about 20 in, and in a button 50 tall about 15 down: the same
  sums as Step 4's.
- **`vtg.hitRegion(id$, x, y, 60, 50)`** lays the hit region over it, named
  just `"key7"`. That name is what a click on this button reports.

Each shape on the board needs a name of its own, which is why the box, the
caption and the hit region each add something different to `id$`.

**`FUNCTION ShowNumber()`** draws `shown$` in the display, against its right
edge, the way a calculator does.

- **`size = 21`** is how tall the digits are.
- **`IF LEN(shown$) * size > 246 THEN size = INT(246 / LEN(shown$))`** makes
  the digits smaller if the number is too long to fit. The display is 270
  wide; leave 12 at each end, and 246 is left for the number. A number that
  would be wider than that gets letters just small enough to fit.
- **`vtg.vectorPrint("number", 298 - LEN(shown$) * size, 80 - INT(size / 2), ...)`**
  writes the number. The display's right edge is at 40 + 270 = 310, and 12
  in from it is 298, so the number starts its own width back from there. Its
  middle is the display's middle, 50 + 30 = 80, so its top is half its height
  above that. The name is always `"number"`, so each number replaces the last.

**`FUNCTION Clicked(event AS BASICMouseEvent)`** is called for each click, as
in Step 5.

- **`pressed$ = event.HitId`** is the name of the button clicked: `"key7"`,
  say, or `""` for a click that missed every button.
- **`IF pressed$ = "keyC" THEN shown$ = "0"`** clears the display.
- **`ELSEIF pressed$ <> "" THEN`** is any other button, which in this step is
  a digit. `RIGHT$(pressed$, 1)` is the last letter of its name: the `7` of
  `"key7"`. If the display shows 0, the digit replaces it, because nobody
  writes 07. Otherwise it goes on the end: 12 becomes 123.
- **`ShowNumber()`**, at the end, shows the change.

## Step 7: Sums, and the finished calculator

```basic
GLOBAL vtg = VectorTerminal()
GLOBAL shown$ = "0"
GLOBAL kept = 0
GLOBAL waiting$ = ""
GLOBAL fresh = FALSE

CLS
PRINT "Click the buttons. Press any key to finish."
vtg.rect("display", 40, 50, 270, 60, "#22c55e", "#071107", 2, 8)
ShowNumber()

digits$ = "789456123C0"
FOR i = 0 TO LEN(digits$) - 1
    caption$ = MID$(digits$, i + 1, 1)
    DrawButton(caption$, "key" + caption$, i MOD 3, INT(i / 3))
NEXT i
DrawButton("=", "equals", 2, 3)
DrawButton("/", "divide", 3, 0)
DrawButton("*", "times", 3, 1)
DrawButton("-", "minus", 3, 2)
DrawButton("+", "plus", 3, 3)
vtg.present()

ON MOUSE UP CALL Clicked

WHILE INKEY$() = ""
    rested = AWAIT Sleep(20)
WEND
CLS

FUNCTION DrawButton(caption$ AS STRING, id$ AS STRING, column AS INTEGER, row AS INTEGER)
    x = 40 + column * 70
    y = 130 + row * 60
    vtg.rect(id$ + "-box", x, y, 60, 50, "#22c55e", "#0f172a", 2, 8)
    vtg.vectorPrint(id$ + "-caption", x + 20, y + 15, 21, caption$, "#f8fafc", 2)
    vtg.hitRegion(id$, x, y, 60, 50)
END FUNCTION

FUNCTION ShowNumber()
    size = 21
    IF LEN(shown$) * size > 246 THEN size = INT(246 / LEN(shown$))
    vtg.vectorPrint("number", 298 - LEN(shown$) * size, 80 - INT(size / 2), size, shown$, "#f8fafc", 2)
    vtg.present()
END FUNCTION

FUNCTION Clicked(event AS BASICMouseEvent)
    pressed$ = event.HitId
    IF pressed$ = "keyC" THEN
        shown$ = "0"
        kept = 0
        waiting$ = ""
    ELSEIF pressed$ = "equals" THEN
        Work()
        waiting$ = ""
    ELSEIF pressed$ = "plus" OR pressed$ = "minus" OR pressed$ = "times" OR pressed$ = "divide" THEN
        Work()
        waiting$ = pressed$
    ELSEIF pressed$ <> "" THEN
        Digit(RIGHT$(pressed$, 1))
    END IF
    ShowNumber()
END FUNCTION

FUNCTION Digit(digit$ AS STRING)
    IF fresh OR shown$ = "0" THEN
        shown$ = digit$
    ELSE
        shown$ = shown$ + digit$
    END IF
    fresh = FALSE
END FUNCTION

FUNCTION Work()
    typed = VAL(shown$)
    IF waiting$ = "" THEN kept = typed
    IF waiting$ = "plus" THEN kept = kept + typed
    IF waiting$ = "minus" THEN kept = kept - typed
    IF waiting$ = "times" THEN kept = kept * typed
    IF waiting$ = "divide" THEN kept = kept / typed
    shown$ = STR$(kept)
    fresh = TRUE
END FUNCTION
```

Run it, and work out 12 + 3 × 2: click 1, 2, +, 3, ×, 2, =. The display
shows 30. Then click / 4 = and it shows 7.5.

Most of the program is Step 6's. The new lines are these.

**Three more shared variables** hold what a calculator has to remember while
you type the second number of a sum:

- **`GLOBAL kept = 0`** is the number kept from before: the 12 of 12 + 3,
  while the 3 is being typed.
- **`GLOBAL waiting$ = ""`** is the sum waiting to be done: `"plus"`, say, or
  `""` when there is none.
- **`GLOBAL fresh = FALSE`** says whether the next digit starts a new number.
  `TRUE` and `FALSE` are values of their own, *yes* and *no*. Right after +
  is clicked, the 12 is still on the display, but the next digit must not be
  added to it: it starts the 3. `fresh` is how the program knows.

**Five more `DrawButton` lines** add the `=` button, in the gap Step 6 left
at the bottom right, and a fourth column of `/`, `*`, `-` and `+`. These
buttons are named with words, `"equals"`, `"plus"` and the rest, because the
signs themselves are not allowed in names. `*` is how computers write
"times", and `/` "divided by".

**`Clicked`** now sorts the clicks four ways:

- **C** forgets everything: the display, the kept number and the waiting sum.
- **=** does the waiting sum, with `Work()`, and then there is nothing left
  waiting.
- **+, -, × or /** also does the waiting sum first, then remembers which sum
  to do next. That is what makes 12 + 3 × 2 work: clicking × does the 12 + 3,
  and the display shows 15 while it waits for the 2.
  `pressed$ = "plus" OR pressed$ = "minus"` is true when either side is.
- **Anything else** that hit a button is a digit, and `Digit` deals with it.

**`FUNCTION Digit(digit$ AS STRING)`** is Step 6's digit lines, with one
change. `IF fresh OR shown$ = "0" THEN` starts a new number when `fresh` is
`TRUE`, as well as when the display shows 0. **`fresh = FALSE`** then says
the number has started, so the next digit goes on the end of it.

**`FUNCTION Work()`** does the waiting sum.

- **`typed = VAL(shown$)`** turns the display's text back into a number.
  `VAL` is the opposite of `STR$`.
- **`IF waiting$ = "" THEN kept = typed`** is for the first number of a sum:
  there is nothing to work out yet, so the number is just kept.
- **The next four lines** do whichever sum is waiting, with the kept number
  on the left and the typed one on the right, and keep the answer.
- **`shown$ = STR$(kept)`** puts the answer on the display. `STR$` adds its
  space in front, which cannot be seen at the left of a number.
- **`fresh = TRUE`** makes the next digit start a new number, rather than
  being added to the answer.

Here is 12 + 3 × 2 =, click by click:

| Click | Display | `kept` | `waiting$` | `fresh` |
|---|---|---|---|---|
| 1, 2 | 12 | 0 | | `FALSE` |
| + | 12 | 12 | plus | `TRUE` |
| 3 | 3 | 12 | plus | `FALSE` |
| × | 15 | 15 | times | `TRUE` |
| 2 | 2 | 15 | times | `FALSE` |
| = | 30 | 30 | | `TRUE` |

This calculator works one sum at a time, left to right, like a pocket
calculator. That is why 12 + 3 × 2 is 30 here, and not 18 as it is in
mathematics, where the × is done first.

## Mistakes to try on purpose

Make each change, run the program, and see what happens. Then put it back.

**Leave out `vtg.present()`** in Step 2. In BASICStudio and in VGTerm the
picture looks just the same: both draw each shape as it arrives. Another
terminal may wait for `present()` before it shows anything, so keep it.

**Give two shapes the same name.** In Step 2, call the circle `"box"` too:
`vtg.circle("box", 140, 120, 40, "#60a5fa", "#60a5fa")`. Only the ball is
left. The second shape called `"box"` replaced the first, just as the ball
replaced itself in Step 3.

**Misspell the function's name.** In Step 5, write `ON MOUSE UP CALL Clickd`.
The program stops on that line, with `Function Clickd is not defined`. BASIC
looks for the function as soon as it is named, not when the first click
comes.

**Leave out the event.** In Step 5, write `FUNCTION Clicked()`, with nothing
in the brackets. The program runs, but every click on the button prints
`Runtime error: Function Clicked expects 0 arguments, got 1`, and the count
never moves. BASIC always hands the function the click, so it needs somewhere
to put it. Notice that the program does not stop: a mistake in a function
that handles an event is reported, and the program goes on listening.

**Wait with `INPUT$`.** In Step 5, replace the three lines of the loop with
`key$ = INPUT$(1)`. Click the button as often as you like: the count does
not change. While `INPUT$` waits, nothing else happens; the clicks wait too,
and by the time a key has been pressed, the program is finishing.

**Divide by nothing.** In Step 7, click 5 / 0 =. `Runtime error: Division by
zero` appears at the top of the console, and the display still shows 0: the
sum stopped at the line that divides, before it could show anything. As with
the last mistake, the calculator carries on; click **C** to start again. A
real calculator would show *Error*; see the first idea below.

## Make it your own

Some ideas, from easier to harder:

- **Show *Error*** for a division by 0. In `Work`, before
  the line that divides, check whether `typed` is 0; if it is, set `shown$`
  to `"Error"`, forget the sum (`waiting$ = ""`), and leave the function
  with `EXIT FUNCTION`.
- **Show the sum so far** in a second, smaller line at the top of the
  display, such as `12 +`. After `waiting$` changes in `Clicked`, draw it
  with its own name and letters about 10 tall, starting at `(52, 56)`, and
  move the number down a little to make room.
- **Add a decimal point.** A `.` button needs a name made of letters, such
  as `"point"`. It goes on the end of `shown$`, even when that is 0, but only
  if `shown$` has no point in it yet: `INSTR(shown$, ".")` is 0 when it has
  none.
- **Type with the keyboard as well.** Change the loop to keep the key that
  `INKEY$()` gives back, and do for a typed digit what `Clicked` does for a
  clicked one. Use **q** to finish instead of any key.

## Where to look next

- [Events](EVENTS.md) lists the other things a program can ask to be told
  about, such as the console changing size, a game controller or a timer.
- [LINE](LINE.md), [CIRCLE](CIRCLE.md), [PSET](PSET.md), [PAINT](PAINT.md)
  and [DRAW](DRAW.md) are the draw-and-forget commands.
- [Async Programming Tutorial](TUTORIAL_ASYNC.md) explains `AWAIT` and
  `Sleep`.

## Practical tips

A short reference to the drawing board's methods and habits.

- **`vtg.rect(name, x, y, width, height, outline, fill, thickness, corner)`**,
  **`vtg.circle(name, x, y, radius, outline, fill, thickness)`** and
  **`vtg.line(name, x1, y1, x2, y2, color, thickness)`** draw shapes. Leave
  out the values at the end to take the usual ones; use `"none"` for no
  outline or no fill.
- **`vtg.vectorPrint(name, x, y, height, words, color, thickness)`** writes
  words in letters made of lines; each letter is as wide as it is tall.
  **`vtg.text(name, x, y, words, color, size)`** writes in an ordinary
  typeface instead, whose letters are not all the same width.
- **`vtg.delete(name)`** takes one shape off; **`vtg.clear()`** takes
  everything off. `CLS` does that too, and clears the words.
- **`vtg.hitRegion(name, x, y, width, height)`** lays an invisible hit region;
  **`vtg.clearHitRegions()`** removes them all, before a screen is rebuilt.
- **Names** use letters, digits, `-` and `_`. Draw under a name already in use
  to replace that shape. Every shape needs its own name.
- **Layers.** A shape can be given a *layer*, a number from -1 to 4, as one
  more value after the ones listed above. Higher layers are drawn over lower ones, and layer
  -1 is drawn behind the console's words instead of over them. Shapes go on
  layer 1 unless told otherwise; `vtg.setDefaultLayer(n)` changes that for
  the shapes that follow.
- **`vtg.present()`** after a group of changes, not after each shape.
- **Whole numbers only.** Places and sizes must be whole numbers; wrap a sum
  that might not be in `INT()`, as `ShowNumber` does.
- **`PSET`** draws a single point. It is there for old programs; for a
  picture, use shapes.
- **End with `CLS`**, so the console is left clean.
- When a program stops on a break or an error, BASICStudio hides its graphics
  so the error and the prompt can be read, and RUN or CLS shows them again;
  graphics you hid yourself with View ▸ Show Graphics stay hidden. Turn this
  off in Settings ▸ Console ▸ Graphics.
