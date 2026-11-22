# {{NAME}}

A BASIC project. Open `{{NAME}}.basproj` in BASICStudio and press Run, or
build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

The same source runs unchanged in the interpreter:

```sh
BASICShell src/main.bas
```

`project.json` names the file the program starts with (`entry`); its
modules sit beside it in `src/`.

`basicc` builds from the BASICCompiler package in the BASICShell repo
(`swift build --package-path Code/BASICCompiler`), or installs with
that package's `buildAndInstall.sh`. Set `BASICC=/path/to/basicc` to
point the Makefile at a build.

## How the comments are written

Every `FUNCTION`, `TYPE`, `CLASS`, field and `GLOBAL` (and `DIM`med array
the whole program shares) has a documentation comment: `///` lines on the
line just above it, read by Swift's rules (BASIC's own, from
`BASICDocumentation.swift`; `basiclint` checks them): a one-line summary,
then, after a `///` line of its own, any discussion, then
`- Parameter name:` for each parameter and `- Returns:` for what it gives
back. Other comments start with `'` and say what each step does.
