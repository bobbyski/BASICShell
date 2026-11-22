# {{NAME}}

The click counter, in a window of its own made with ActiveUI and written in
BASIC: a label that counts, a Click me button, and Reset, which takes the
count back to zero and is grayed out while there is nothing to reset.

Build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

| File | What it is |
|---|---|
| `src/main.bas` | The program: wires the parts together. |
| `src/models/Counter.bas` | `Counter`: the count. |
| `src/views/CounterView.bas` | The label and the Click me button. |
| `src/controllers/CounterWindowController.bas` | The window, Reset, and each count. |

## How the comments are written

Every `CLASS`, field, `FUNCTION` and `GLOBAL` has a documentation comment:
`///` lines on the line just above it, read by Swift's rules (BASIC's own,
from `BASICDocumentation.swift`; `basiclint` checks them): a one-line
summary, then, after a `///` line of its own, any discussion, then
`- Parameter name:` for each parameter and `- Returns:` for what it gives
back. Comments inside a routine start with `'` and say what each step does.
Each file starts with a `'` comment saying what is in it.

## What BASIC's ActiveUI cannot do yet

The same app in Swift has Reset in a window toolbar and a Counter menu.
BASIC's ActiveUI classes have no toolbar and cannot add menus yet, so Reset
is a button above the count and the menus are the ones every Mac app has.
Each place this happens has a comment saying so.
