# PUSHD, POPD and DIRS Commands

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

A stack of directories, so a program or a session can go somewhere, do something, and come back without having remembered where it was.

| Command | Does |
| --- | --- |
| `PUSHD path` | Remembers where you are, changes to `path`, and prints the stack. |
| `POPD` | Goes back to the last remembered place and drops it. |
| `DIRS` | Prints the stack, current directory first. |

```basic
pwd
pushd "/usr"
dirs
popd
pwd
```

`PUSHD` and `DIRS` both print the stack as one line, most recent first — `/usr /private/tmp`. `CD` changes directory without touching the stack.
