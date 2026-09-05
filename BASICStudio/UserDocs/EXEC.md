# EXEC Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Runs an external command and captures what it wrote.

```basic
option shellmode on
exec "/bin/echo", "hello" to out$
print out$
```

The command comes first and each argument after it, separated by commas — they are passed through as they are, so nothing is re-split on spaces and no quoting is needed for an argument that contains them.

`TO` names a string to take standard output. Add `ERRORS TO` for standard error, and read `STATUS` for the exit code:

```basic
exec "/bin/ls", "/nowhere" to out$ errors to err$
if status <> 0 then print "failed: "; err$
```

`EXEC` needs `OPTION SHELLMODE ON`.

## Running a command without capturing it

Typed at the prompt with shell mode on, a command line runs as it would in any shell, with its output going to the screen. Ending it with `&` runs it in the background — see [JOBS](JOBS.md).
