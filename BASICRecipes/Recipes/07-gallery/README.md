# {{NAME}}

The TUIKit Gallery: every TUIKit control in one full-screen BASIC
application, one file per group of them, to copy from.

Run it in a terminal, or build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

The files are laid out as they are on purpose: the gallery is a file-for-file
translation of TUIKit's Swift gallery (each `Gallery….bas` beside the
`.swift` file it translates, its functions in the same order), which
`Scripts/gallery-parity.sh` reads side by side. So it keeps that one folder
rather than models, views and controllers. It is a copy of the demo
`tui/gallery.basproj`, which is the original.

## How the comments are written

Every `TYPE`, `RECORD`, field, `FUNCTION` and `GLOBAL` has a documentation
comment: `///` lines on the line just above it, read by Swift's rules
(BASIC's own, from `BASICDocumentation.swift`; `basiclint` checks them):
a one-line summary, then, after a `///` line of its own, any discussion,
then `- Parameter name:` for each parameter and `- Returns:` for what it
gives back. Comments inside a routine start with `'` and say what each step
does. Each file starts with a `'` comment saying what is in it.
