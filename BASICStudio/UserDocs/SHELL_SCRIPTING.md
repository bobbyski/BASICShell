# Shell Scripting

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Running other programs, and using what they print.

Everything here needs `OPTION SHELLMODE ON`. It is off by default, so a
program cannot start processes by accident.

## Running a command and keeping its output

```basic
option shellmode on
exec "/bin/date", "+%Y" to year$
print "the year is "; year$
```

The command comes first, then each argument as its own comma-separated
value. They are passed through exactly as written — nothing is re-split on
spaces, so an argument containing them needs no quoting of its own.

`TO` names a string to catch standard output. `ERRORS TO` catches standard
error, and `STATUS` holds the exit code of the command that just ran:

```basic
exec "/bin/ls", "/nowhere" to out$ errors to err$
if status <> 0 then print "failed ("; status; "): "; err$
```

prints `failed (1): ls: /nowhere: No such file or directory`. Check `STATUS` before using the output: a
command that failed usually printed nothing, and an empty string is not an
error message.

## Chaining commands

`PIPE` feeds each stage into the next:

```basic
pipe "/bin/echo", "a b c" to "/usr/bin/wc", "-w"
```

prints `3`. `TO` separates the stages, and there can be as many as you
like. See [PIPE](PIPE.md) and [EXEC](EXEC.md).

## At the prompt

Typed at the prompt with shell mode on, a command line runs as it would in
any shell, output going straight to the screen:

    /bin/echo hello

`ERRORLEVEL` holds the exit status of the last one. End the line with `&`
to run it in the background and get a job number back — see
[JOBS](JOBS.md).

**This works at the prompt only.** In a program file a bare command line is a
syntax error, because there it would be indistinguishable from a typo in a
BASIC statement. A script runs commands with `EXEC`, `PIPE` or `SYSTEM`.

## Scripts

A file that starts with a `#!` line and is executable runs as a program:

```basic
#!/usr/bin/env basicshell
option shellmode on
exec "/bin/date", "+%Y" to year$
print "the year is "; year$
```

```
chmod +x report.bas
./report.bas
```

A script reads no startup file — see [Startup Files](STARTUP_FILES.md) — so
what it does is the same wherever it runs, which is what a script is for.

There is **no way for a script to read its own command-line arguments**. Pass
what it needs in the environment instead, with `SETENV` before it or
`ENVIRON$` inside it — see [SETENV, EXPORT and UNSETENV](ENVIRONMENT.md).

## Running one command and stopping

`-c` takes the commands as an argument, runs them, and exits — what a
terminal emulator runs for a profile's startup command, and what `sh -c`
does everywhere else.

```
basicshell -c 'print "hello"'
basicshell -c 'option shellmode on
/bin/echo two lines work too'
```

The text is read **one line at a time, exactly as if you had typed it**, so
`cd`, `alias` and a bare external command all work in it — the same reason a
startup file is read that way. Text loaded as a *program* could contain none
of them.

The exit status is the last command's, so `basicshell -c '/bin/ls /nowhere'`
fails like any other shell, and `QUIT n` exits with `n`.

Startup files are **not** read: what `-c` does should not depend on what
happens to be in someone's `~/.BASICrc`. Anything after the command string is
passed on to it rather than read as an option.

## The environment and the directory

`SETENV`, `EXPORT` and `UNSETENV` set what a command inherits;
`ENVIRON$` reads a variable back. [CD](CD.md) changes directory for
everything that follows, and [PUSHD, POPD and DIRS](DIRECTORY_STACK.md) go
somewhere and come back.
