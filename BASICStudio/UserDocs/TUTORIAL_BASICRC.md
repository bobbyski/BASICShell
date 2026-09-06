# BASICrc Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

`~/.BASICrc` is read by every interactive shell before it gives you a prompt.
This is what to put in it, and — mostly — how building a `PATH` differs from
the shell you are used to.

## A working file

```basic
' ~/.BASICrc
option shellmode on

setenv "PATH", ENVIRON$("PATH") + ":" + ENVIRON$("HOME") + "/bin"
setenv "PATH", "/opt/tools/bin:" + ENVIRON$("PATH")

alias ll="ls -la"
prompt "BASIC> "
```

Start a shell and check it:

```basic
which "ll"
print ENVIRON$("PATH")
```

## PATH is a string, and you build it with `+`

There is no `$` substitution in this language. A string is exactly the
characters between its quotes:

```basic
print "$PATH:/opt/tools/bin"
```

prints `$PATH:/opt/tools/bin`. The `$` is a dollar sign.

So the bash habit does not carry over. `PATH="$PATH:/opt/tools/bin"` does not
fail — which is the problem. It succeeds, and sets your `PATH` to the eight
literal characters `$PATH` followed by a colon and a directory. Nothing is
found afterwards, and nothing said why.

Read the old value, add to it, and put it back:

```basic
setenv "PATH", ENVIRON$("PATH") + ":" + ENVIRON$("HOME") + "/bin"
```

`ENVIRON$` reads an environment variable; `+` joins strings; `SETENV` writes
it back. Append by putting the old value first and prepend by putting it
last:

```basic
' searched last
setenv "PATH", ENVIRON$("PATH") + ":/opt/tools/bin"

' searched first — wins over anything already installed
setenv "PATH", "/opt/tools/bin:" + ENVIRON$("PATH")
```

## `~` is not expanded inside a string

```basic
setenv "PATH", ENVIRON$("PATH") + ":~/bin"
```

puts the two characters `~/` on your `PATH`, and no program will be found
there. `~` is expanded where a *path* is expected — `CD "~"` goes home — but
a string being built is just a string. Use `ENVIRON$("HOME")`:

```basic
setenv "PATH", ENVIRON$("PATH") + ":" + ENVIRON$("HOME") + "/bin"
```

## The trap: `EXPORT` means different things in different places

In a **program file**, `EXPORT NAME = value` takes a BASIC expression:

```basic
export PATH = ENVIRON$("PATH") + ":/opt/tools/bin"
```

In a **startup file or at the prompt** the same line is read the way a shell
reads it, and everything after the `=` is *literal text*. Written in
`~/.BASICrc`, that line sets `PATH` to the twenty-nine characters
`ENVIRON$("PATH") + ":/opt/tools/bin"` and your shell can no longer find
anything.

This is the one difference worth remembering, because a startup file is
exactly where a person coming from bash will write it.

**In a startup file, build `PATH` with `SETENV`.** It is a BASIC statement
wherever it appears, so it means the same thing in both places.

The shell-style form is still useful *in a startup file* for a fixed value:

```basic
export EDITOR=vi
```

sets `EDITOR` to `vi` — no quotes needed and none wanted, since they would be
part of the value. The same line in a program file is read as BASIC, where
`vi` is an empty variable, and `EDITOR` comes out as `0`. Reach for `SETENV`
if you want one spelling that works in both.

## An unset variable is an empty string

`ENVIRON$` answers `""` for a variable that is not set, so this:

```basic
setenv "PATH", ENVIRON$("PATH") + ":/opt/tools/bin"
```

produces `:/opt/tools/bin` if `PATH` was somehow empty — and a leading or
doubled colon means *the current directory* to most tools, which is a
security problem rather than a typo. Guard it if you are not sure:

```basic
if ENVIRON$("PATH") = "" then
    setenv "PATH", "/usr/bin:/bin"
end if
```

## You do not need EXPORT for this

`SETENV` already puts the value in the environment that commands inherit:

```basic
setenv "TOOLS", "/opt/tools"
exec "/bin/sh", "-c", "echo $TOOLS" to out$
```

prints `/opt/tools`. `EXPORT` earns its keep for the other job — sending a
BASIC *variable* out:

```basic
release$ = "2026.1"
export release$
```

The child sees `RELEASE`: the name is upper-cased and the `$` type suffix is
dropped, because `$` is not a character an environment variable name may
contain.

## If you would rather interpolate

`OPTION STRING-SUB ON` turns on `${...}` inside string literals. What goes in
the braces is a **BASIC expression**, not a shell variable name:

```basic
option string-sub on
home$ = ENVIRON$("HOME")
setenv "PATH", "${home$}/bin:" + ENVIRON$("PATH")
```

It is the same answer as `+`, spelled differently. `${PATH}` on its own would
be the BASIC variable `PATH`, which is empty — not the environment.

## What else belongs in the file

`OPTION SHELLMODE ON` if you want to run external commands, `ALIAS` for short
names, `PROMPT` for the prompt. See [Startup Files](STARTUP_FILES.md) for
which file is read when, [SETENV, EXPORT and UNSETENV](ENVIRONMENT.md), and
[Shell Scripting](SHELL_SCRIPTING.md) for running commands from a program.

A startup file is fed to the shell one line at a time, exactly as if you had
typed it. That is why `ALIAS` and `PROMPT` work in it although neither is a
statement the parser knows — and it is the same reason `EXPORT` behaves as it
does above.
