# {{NAME}}

A full-screen terminal application made with TUIKit and written in BASIC:
a menu bar (File ▸ Quit, Greeting ▸ Greet), a window with a toolbar (Greet,
Quit), a field for a name, a list of languages, and a status line along the
bottom. Esc and the window's close box quit too, through the same command.

Run it in a terminal, or build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

| File | What it is |
|---|---|
| `src/main.bas` | The program: wires the parts together. |
| `src/models/LanguageList.bas` | `LanguageList`: the languages to pick from. |
| `src/models/Greeting.bas` | What the program says back. |
| `src/views/GreetingView.bas` | The banner, the name field and the list. |
| `src/views/StatusLine.bas` | The status line. |
| `src/controllers/MainWindowController.bas` | The window, its toolbar, and every command. |
| `src/app/AppMenus.bas` | The menu bar. |

## How the comments are written

Every `CLASS`, field, `FUNCTION` and `GLOBAL` has a documentation comment:
`///` lines on the line just above it, read by Swift's rules (BASIC's own,
from `BASICDocumentation.swift`; `basiclint` checks them): a one-line
summary, then, after a `///` line of its own, any discussion, then
`- Parameter name:` for each parameter and `- Returns:` for what it gives
back. Comments inside a routine start with `'` and say what each step does.
Each file starts with a `'` comment saying what is in it.

## What BASIC's TUIKit cannot do yet

A toolbar item or menu item cannot be grayed out, so Greet stays enabled
with no name typed and says what to do instead.
