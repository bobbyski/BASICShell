# {{NAME}}

A master/detail app in a window of its own, made with ActiveUI and written
in BASIC: a searchable list of items on the left, Favorites first, and the
chosen item's title and notes on the right, or a note that none is chosen.
New Item, Favorite and Delete are across the top; Favorite and Delete are
grayed out until an item is chosen. Edits are saved as you type.

Build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

The items are kept in `items.txt` in `~/Library/Application Support/{{NAME}}/`,
or in `$APP_DATA_DIR` when that is set.

| File | What it is |
|---|---|
| `src/main.bas` | The program: wires the parts together. |
| `src/models/Item.bas` | `Item`: one item, and searching it. |
| `src/models/ItemList.bas` | `ItemList`: the items, and what can be done with them. |
| `src/models/ItemStore.bas` | `ReadItems` and `WriteItems`: `items.txt`, in and out. |
| `src/models/TabSeparated.bas` | The file's format: one record a line, fields split by tabs. |
| `src/views/ItemSidebarView.bas` | The search field and the list, in two sections. |
| `src/views/ItemDetailView.bas` | The chosen item, or the empty state. |
| `src/controllers/ItemsWindowController.bas` | The window, its commands, and every change. |
| `src/app/DataFolder.bas` | Where the app keeps its data. |

## How the comments are written

Every `TYPE`, `CLASS`, field, `FUNCTION` and `GLOBAL` has a documentation
comment: `///` lines on the line just above it, read by Swift's rules
(BASIC's own, from `BASICDocumentation.swift`; `basiclint` checks them):
a one-line summary, then, after a `///` line of its own, any discussion,
then `- Parameter name:` for each parameter and `- Returns:` for what it
gives back. Comments inside a routine start with `'` and say what each step
does. Each file starts with a `'` comment saying what is in it.

## What BASIC's ActiveUI cannot do yet

The same app in Swift is ActiveUI's own `AUIMasterDetailView`, with a
sidebar list of real sections and symbols, a window toolbar with the
sidebar button, File and View menus, a large title and a notes editor of
many lines. BASIC's ActiveUI classes have none of those yet, so two stacks
sit side by side, the sections are heading rows in a list, the commands are
buttons across the top, and the notes are one line. Each place this happens
has a comment saying so.
