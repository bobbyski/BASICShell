# {{NAME}}

A game to build on, written in BASIC with VTG graphics: someone to move
around, four targets to shoot, and a guard walking the edge of the floor.
Point the way and they turn to face it and walk; point harder and they run.
Fire shoots the way they face. A target is a point, the guard is ten, and a
new guard sets out two seconds after one is hit. Let the guard shoot back,
and it is a game.

| | |
|---|---|
| Touch | The joystick, bottom right: a little lean walks, all the way runs. Fire, bottom left. |
| Keys | Arrows or W A S D walk, hold Shift to run, Space fires, P pauses, Q quits. |
| Gamepad | D-pad or left stick walks, hold B to run, A fires, Menu pauses. |

## Running it

It draws with VTG (lines, circles and vector text), so it needs somewhere
that shows VTG graphics:

- **BASICStudio:** open `{{NAME}}.basproj` and press Run.
- **`make`:** builds it with `basicc` and runs it, in a terminal that draws
  VTG graphics. `make build` only builds it, into `Build/{{NAME}}`. Set
  `BASICC=/path/to/basicc` to point the Makefile at a build of `basicc`.
- **A terminal that draws VTG graphics:** the same source runs unchanged in
  the interpreter, `BASICShell src/main.bas`.

## The files

Each thing in the game is an object (a `CLASS`) that keeps its own numbers
and knows how to move and how to draw itself. The files are in three
folders: models for the things in the game, views for what is on the
screen, and controllers for the controls and the loop that runs it all.

| File | What it is |
|---|---|
| `src/main.bas` | The numbers to play with, the things in the game (every `GLOBAL`), and the start. |
| `src/models/Characters.bas` | `Walker`, anyone who walks, and the two kinds of walker: `Player` and `Guard`. |
| `src/models/Shooting.bas` | `Shots` and `Targets`, and `CheckHits`, where they meet. |
| `src/views/GameView.bas` | `View`: fits the world to the window, draws the floor and the words, and paces the frames. |
| `src/controllers/Controls.bas` | `Controls`, which turn keys, gamepad and touch into which way and how fast; the `Inbox`, where events wait for the next frame. |
| `src/controllers/GameLoop.bas` | `RunGame`, the loop that runs the game, and the event handlers. |

Every `GLOBAL` is in `main.bas`, because an imported file's top-level
statements never run, `GLOBAL`s included. The other files only declare
`CLASS`es, `TYPE`s and `FUNCTION`s.

An object changes only itself. When two things meet (a shot and the guard),
a plain function decides what happens to each: `CheckHits`. Events (a
button pressed, the window resized) can arrive at any moment, so they only
write down what happened in `theInbox`, and the loop acts on it at the
start of the next frame.

## How the comments are written

Every `CLASS`, `TYPE`, field, `FUNCTION` and `GLOBAL` has a documentation
comment, in BASIC's own form, which is Swift's (`basiclint` checks it):

```basic
/// How far apart two points are.
///
/// Any discussion goes here, after a `///` line of its own.
///
/// - Parameter x1: The first point, across.
/// - Parameter y1: The first point, down.
/// - Parameter x2: The second point, across.
/// - Parameter y2: The second point, down.
/// - Returns: The straight-line distance between them, in world units.
FUNCTION Distance(x1 AS DOUBLE, y1 AS DOUBLE, x2 AS DOUBLE, y2 AS DOUBLE) AS DOUBLE
```

- `///` lines sit on the lines just above the declaration, with no blank
  line between, or they document nothing.
- The first line is a one-line summary. After a bare `///` line comes any
  discussion, in Markdown.
- `- Parameter name:` for every parameter, spelled as it is written
  (`name$` included), and `- Returns:` for a `FUNCTION` that gives back a
  value. One that is `AS VOID` has no `- Returns:`.

Each file starts with a `'` comment saying what is in it. `' MARK:` lines
divide a file into parts, and comments inside a routine start with `'` and
say what a step does.
