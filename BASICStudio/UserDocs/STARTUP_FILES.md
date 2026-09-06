# Startup Files

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

What BASICShell reads before it gives you a prompt.

| File | Read by |
| --- | --- |
| `/etc/BASICrc` | Every shell, before anything else. |
| `~/.BASICrc` | An interactive shell that is not a login shell. |
| `~/.BASICprofile` | A login shell. |

There is no `~/BASICShellrc` and no `~/.basicshellrc`. The names above are
the ones read.

```basic
' ~/.BASICrc
option shellmode on
alias ll="ls -la"
prompt "BASIC> "
```

## A script reads neither

A program run from a file — `basicshell program.bas`, or a script with a
`#!` line — reads no startup file at all. That is deliberate: a script
should do the same thing on every machine, and one that picked up whatever
aliases and options happened to be in a person's `~/.BASICrc` would not.

## Line by line, not as a program

A startup file is fed to the shell one line at a time, through exactly the
path a typed line takes. That is what lets it contain `alias`, which the
shell understands when a person types it but the parser does not know as a
statement — a file read as a *program* could not have one in it.

Multi-line blocks still work: `FOR`/`NEXT` and the rest are buffered
across lines as they are at the prompt.

`HOME` decides where `~` is here, so `HOME=/tmp/sandbox basicshell`
reads `/tmp/sandbox/.BASICrc` — which is how to test one without touching
your own.
