# {{NAME}}

The Contact Book: a full-screen TUIKit application in BASIC that keeps an
address book in a JSON file. Open, Save and New Contact are on the toolbar
and in the File menu; the list on the left picks a contact and the form on
the right edits it; quitting with unsaved edits asks Save, Discard or Cancel.

Run it in a terminal, or build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

The book is kept in `contacts.json` in
`~/Library/Application Support/Contact Book/`, or in `$APP_DATA_DIR` when that
is set; the toolbar's field names another file to open or save.

| File | What it is |
|---|---|
| `src/main.bas` | The shared state, and the start. |
| `src/models/ContactModel.bas` | What a contact is, and the list of them. |
| `src/models/ContactStorage.bas` | The JSON file, in and out. |
| `src/views/ContactWindow.bas` | The window: toolbar, list, edit form. |
| `src/views/ContactDialogs.bas` | The dialogs, and the unsaved-changes gate. |
| `src/app/ContactApp.bas` | Theme, menu bar, status strip, start-up. |
| `src/app/DataFolder.bas` | Where the app keeps its data. |

It is a copy of the demo `apps/contacts.basproj`, which is the original.

## How the comments are written

Every `TYPE`, `RECORD`, field, `FUNCTION` and `GLOBAL` has a documentation
comment: `///` lines on the line just above it, read by Swift's rules
(BASIC's own, from `BASICDocumentation.swift`; `basiclint` checks them):
a one-line summary, then, after a `///` line of its own, any discussion,
then `- Parameter name:` for each parameter and `- Returns:` for what it
gives back. Comments inside a routine start with `'` and say what each step
does. Each file starts with a `'` comment saying what is in it.
