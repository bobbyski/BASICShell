# BASICrc Tutorial

![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen) ![BASICStudio](https://img.shields.io/badge/BASICStudio-not%20read-lightgray)

This tutorial writes a *startup file* for BASICShell: a short list of
instructions it carries out every time it starts, so that you never have to
type them again. It is written for someone who has finished the
[Beginner's Guide](TUTORIAL_BEGINNERS.md) and has never used a terminal.
Every line is explained, and at the end you have a working file of your own.

Only BASICShell reads this file; BASICStudio does not. [In BASICStudio](#in-basicstudio),
near the end, says which parts still apply there.

## The idea first

**A terminal** is a window where you type instructions and the computer
answers in text. On a Mac it is the app called Terminal, in Applications ▸
Utilities. Nothing in it is clicked: everything is typed, a line at a time.

**A shell** is the program inside the terminal that reads what you type and
carries it out. Its main job is starting other programs: you type a
program's name, and the shell runs it. **BASICShell** is a shell whose
language is BASIC. You type BASIC at it, just as at BASICStudio's console,
and you can also type the names of other programs, which it runs.

**Your home folder** is the folder the computer keeps for you, with your
Documents, Desktop and Downloads in it. On a Mac it is `/Users/` followed by
your name. A shell writes it as `~`, a single wavy line, so `~/Documents`
means the Documents folder in your home folder.

**A startup file** is a text file in your home folder called `.BASICrc`.
Every time BASICShell starts, before it shows you anything, it reads that
file a line at a time and carries out each line exactly as if you had typed
it. The dot at the front of the name makes it a *hidden* file, one that Finder
does not show; that is the custom for files like this, which set things up
and are otherwise left alone. "rc" is an old name for them, from *run
commands*.

What goes in it are the things you would otherwise set up by hand each time:
how the prompt looks, short names for commands you use a lot, and where the
shell looks for programs. This tutorial adds one of each, a line at a time.

## Getting started

Open Terminal. It shows a line ending in `%`: that is Terminal's own shell,
waiting. Type `basicshell` and press Return.

```text
BASICShell
Type HELP for commands. Type QUIT to exit.
  ~  Ready
```

The last line is the *prompt*: BASICShell is ready for a line. It shows the
folder you are in, `~` to start with, and the word Ready. Type a line of
BASIC:

```text
  ~  Ready  print 2 + 2
4
```

Type `QUIT` and press Return to leave BASICShell. You are back at the `%`,
and `basicshell` starts it again. You will do that after every step, because
the startup file is read only when BASICShell starts.

## Two kinds of lines

BASICShell understands two kinds of line. A line of BASIC, like
`print 2 + 2`, it runs itself. A line that is not BASIC, it hands to the
computer's own shell, which treats the first word as the name of a program
and runs it. Try these:

```text
  ~  Ready  date
Thu Oct  8 09:30:00 EDT 2026
  ~  Ready  ls
Desktop    Documents    Downloads    Library    Movies    Music    Pictures
```

`date` is a program that prints the date and time; `ls` is a program that
lists the files in the folder you are in (its name is short for *list*). Each
is a separate program, stored somewhere on the computer.

Handing on what is not BASIC is called *shell mode*, and BASICShell starts
with it on. `OPTION SHELLMODE OFF` turns it off and `OPTION SHELLMODE ON` back
on; you will see what off does in [the mistakes](#mistakes-to-try-on-purpose).

`WHICH` asks where a program is stored:

```text
  ~  Ready  which "ls"
/bin/ls
```

`/bin/ls` means the file `ls` in the folder `bin`, at the top of the disk. The
`/` between names is how a shell writes "inside".

## Step 1: The file, and a prompt

The file is written with a *text editor*, a program for typing plain text.
Most Macs have one called `nano` that runs inside the terminal. At the
BASICShell prompt, type:

```text
  ~  Ready  nano ~/.BASICrc
```

The window fills with nano: an empty page, with a list of keys along the
bottom. `^` there means the Control key, so `^X Exit` means hold Control and
press X. Type these two lines into it:

```basic
' Read by BASICShell every time it starts.
prompt "BASIC> "
```

Then press **Control-X** to leave. nano asks whether to save what you typed:
press **Y**, then **Return** to keep the name it suggests. The BASICShell
prompt comes back.

Nothing has changed yet: the file is read when BASICShell starts. Type
`QUIT`, then `basicshell`, and look at the prompt:

```text
BASICShell
Type HELP for commands. Type QUIT to exit.
BASIC>
```

**`' Read by BASICShell every time it starts.`** is a comment, as in any BASIC
program: the `'` and everything after it is for the person reading. A line
saying what the file is for saves a puzzled moment later.

**`prompt "BASIC> "`** sets the prompt to the text in the quotes. The space
after the `>` keeps what you type from running into it. `PROMPT` can also put
the folder you are in, or the time, into the prompt; type `HELP PROMPT` to see
how.

You could also type a `PROMPT` line straight at the prompt. BASICShell would
remember it, and BASICStudio's console would use it too. A `PROMPT` in the
startup file is BASICShell's alone, and it is set every time BASICShell
starts, so the file always has the last word.

## Step 2: An alias

Open the file again with `nano ~/.BASICrc`, and add a third line, so that it
reads:

```basic
' Read by BASICShell every time it starts.
prompt "BASIC> "
alias ll="ls -la"
```

Save it, `QUIT`, start `basicshell`, and type `ll`:

```text
BASIC> ll
total 16
drwxr-x---+  12 ada  staff   384 Oct  8 09:30 .
drwxr-xr-x    5 root admin   160 Oct  1 12:00 ..
-rw-r--r--    1 ada  staff    68 Oct  8 09:31 .BASICrc
drwx------+   4 ada  staff   128 Oct  1 12:00 Desktop
...
```

**`alias ll="ls -la"`** makes `ll` short for `ls -la`. An *alias* is a short
name for a longer command. Whenever a line starts with `ll`, BASICShell
replaces it with `ls -la` before it does anything else.

`ls -la` is `ls` with two *options*, `l` and `a`, written after a `-`. Options
change what a program does: `l` asks for the long form, one file to a line
with its size and date, and `a` asks for all the files, the hidden ones too.
That is why `.BASICrc` is in the list.

Type `alias` on its own to list the aliases you have. An alias only counts at
the start of a line, so it names a command; it is not replaced anywhere else.

## Step 3: An environment variable

The *environment* is a set of named values, *environment variables*, that a
program is given when it starts, and hands on to every program it starts in
turn. They are how settings reach programs without anyone typing them in.
`ENVIRON$` reads one:

```text
BASIC> print ENVIRON$("HOME")
/Users/ada
BASIC> print ENVIRON$("USER")
ada
```

`HOME` is your home folder and `USER` is your name on the computer. Add a
line to the file to set one of your own:

```basic
' Read by BASICShell every time it starts.
prompt "BASIC> "
alias ll="ls -la"
setenv "EDITOR", "nano"
```

Save, `QUIT`, start `basicshell` again, and read it back:

```text
BASIC> print ENVIRON$("EDITOR")
nano
```

**`setenv "EDITOR", "nano"`** sets the environment variable `EDITOR` to
`nano`. The first value is the variable's name, the second is what to set it
to, and there is a comma between them. `EDITOR` is the variable that programs
ask when they want you to write something, such as a note to go with a change
you are saving, so this one line makes them all open nano.

`SETENV` writes and `ENVIRON$` reads. A variable that is not set reads as
`""`, empty, rather than stopping with an error.

## Step 4: PATH, and a command of your own

When you type `date`, how does the shell know where the program `date` is?
It looks in a list of folders, kept in the environment variable `PATH`:

```text
BASIC> print ENVIRON$("PATH")
/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Yours may be longer. The folders are separated by `:`. When you type a
program's name, the folders are searched in that order, and the first one
with a program of that name wins. A program in a folder that is not on the
list is not found at all.

So, to make a command of your own, make a folder for it, put the program in
it, and add the folder to `PATH`. The folder is usually called `bin`, short
for *binaries*, an old word for programs.

First, the folder. `mkdir` is the program that makes one:

```text
BASIC> mkdir ~/bin
```

Then the program, which can be written in BASIC. Open a new file in it,
`nano ~/bin/hello`, type these two lines, and save it:

```basic
#!/usr/bin/env basicshell
PRINT "Hello from my own command."
```

**`#!/usr/bin/env basicshell`** tells the computer which program runs this
file: BASICShell. The `#!` at the front is what makes it that kind of line.
**`PRINT "Hello from my own command."`** is the program itself.

A file has to be marked as a program before it can be run as one. The
program `chmod` does that; `+x` means *may be run*:

```text
BASIC> chmod +x ~/bin/hello
BASIC> hello
/bin/sh: hello: command not found
```

Not found: `~/bin` is not on the list yet. Add one more line to the startup
file, so that it is the whole file:

```basic
' Read by BASICShell every time it starts.
prompt "BASIC> "
alias ll="ls -la"
setenv "EDITOR", "nano"
setenv "PATH", ENVIRON$("PATH") + ":" + ENVIRON$("HOME") + "/bin"
```

Save, `QUIT`, start `basicshell`, and try again:

```text
BASIC> hello
Hello from my own command.
BASIC> which "hello"
/Users/ada/bin/hello
```

**`setenv "PATH", ENVIRON$("PATH") + ":" + ENVIRON$("HOME") + "/bin"`** sets
`PATH` to a new list made from the old one. Reading it from the left:

- `ENVIRON$("PATH")` is the list as it was;
- `":"` is the separator between folders;
- `ENVIRON$("HOME") + "/bin"` is your `bin` folder, `/Users/ada/bin`;
- `+` joins the three pieces of text into one, as it does anywhere in BASIC.

So the new list is the old one with your folder added at the end.

**Why at the end?** The folders are searched in order, so a folder at the end
is searched last. If you ever give a program of yours the same name as one the
computer already has, the computer's still wins, and nothing you rely on
changes by accident. To have yours win instead, put your folder at the front:

```text
setenv "PATH", ENVIRON$("HOME") + "/bin:" + ENVIRON$("PATH")
```

That is your startup file, finished. Every BASICShell you start from now on
has your prompt, your alias, your editor and your own commands.

## Mistakes to try on purpose

Make each change in the startup file, start a new `basicshell`, and see what
happens. Then put the line back. If a mistake leaves BASICShell unusable,
[When the file goes wrong](#when-the-file-goes-wrong) says how to get back.

**Write `$PATH` inside the quotes.** Change the last line to:

```text
setenv "PATH", "$PATH:" + ENVIRON$("HOME") + "/bin"
```

Then:

```text
BASIC> print ENVIRON$("PATH")
$PATH:/Users/ada/bin
BASIC> which "ls"
ls not found
```

The list now begins with the five characters `$PATH`. Text in quotes is
exactly what is between the quotes, and `$` is just a dollar sign. The old
list is gone, so `WHICH` cannot find `ls` any more. A command you type may
still run, because the computer's own shell, which runs it, adds the usual
folders back for itself; a BASIC program looking for a program cannot. Read
the old list with `ENVIRON$("PATH")`, as the real line does.

**Write `~` inside the quotes.** Change the last line to:

```text
setenv "PATH", ENVIRON$("PATH") + ":~/bin"
```

Then `print ENVIRON$("PATH")` ends with `~/bin`, as written, and
`which "hello"` says `hello not found`. `~` means the home folder only where a
shell reads a folder's name, as in `nano ~/.BASICrc`; inside quotes it is a
wavy line. Use `ENVIRON$("HOME")`, which is the real name.

**Misspell the alias.** Change it to `alias ll="sl -la"`, then type `ll`:

```text
BASIC> ll
/bin/sh: sl: command not found
```

The alias did its job: `ll` became `sl -la`. There is no program called `sl`,
and the computer's shell, `/bin/sh`, says so.

**Leave out a comma.** Change the `EDITOR` line to `setenv "EDITOR" "nano"`.
As BASICShell starts, before the prompt, it prints:

```text
/bin/sh: setenv: command not found
```

Without the comma the line is not BASIC, so BASICShell hands it on, as it does
any line that is not, and the computer's shell has no program called
`setenv`. `print ENVIRON$("EDITOR")` prints an empty line: nothing was set.

**Turn shell mode off.** Add `option shellmode off` to the file, then type
`date`:

```text
BASIC> date
date
    ^
Syntax error: Expected =
```

With shell mode off, BASICShell treats every line as BASIC. `date` on its own
looks to BASIC like the start of `date = ...`, a variable being given a value,
so it asks where the `=` is.

**Make the file close the shell.** Add a line that says just `quit`. Start
`basicshell`, and it is gone again at once, back to the `%`: the file told it
to quit, as you would. The next part is how to get out of that.

## When the file goes wrong

A startup file that stops BASICShell working is mended without it. Start it
like this, and it does not read the file:

```text
basicshell --no-rc
```

Then `nano ~/.BASICrc`, put the line right or take it out, save, `QUIT`, and
start `basicshell` the usual way. nano also works from Terminal's own `%`
prompt, without BASICShell at all.

## In BASICStudio

BASICStudio does not read `~/.BASICrc`. The lines in it work at BASICStudio's
console as well, typed there, but only until BASICStudio quits:

- `SETENV` and `ENVIRON$` work the same, in the console and in programs.
- `PROMPT` typed at either prompt is remembered by both; the startup file's
  `PROMPT` is BASICShell's alone.
- Shell mode is off in BASICStudio's console, so a program's name typed
  there is read as BASIC, and is a syntax error, until you turn it on with
  `OPTION SHELLMODE ON`. Aliases are for running commands, so they belong
  with BASICShell.

This page is not in the manual on iPhone and iPad, where there is no shell.

## For readers who know bash

If you have written a `.bashrc` or `.zshrc`, these are the differences that
catch people. The file is BASIC, read a line at a time as if typed.

**There is no `$` substitution.** `"$PATH:/opt/tools/bin"` is those exact
characters, as the first mistake shows. Build a value with `+` and
`ENVIRON$`:

```text
' searched last
setenv "PATH", ENVIRON$("PATH") + ":/opt/tools/bin"
' searched first: wins over anything already installed
setenv "PATH", "/opt/tools/bin:" + ENVIRON$("PATH")
```

**`~` is not expanded inside a string**, only where a path is expected:
`CD "~"` goes home, but `":~/bin"` is three characters. Use `ENVIRON$("HOME")`.

**`EXPORT` means different things in different places.** In a program file,
`EXPORT NAME = value` takes a BASIC expression. In a startup file or at the
prompt the same line is read the way a shell reads it, and everything after
the `=` is literal text: `export PATH = ENVIRON$("PATH") + ":/opt/tools/bin"`
there sets `PATH` to the characters `ENVIRON$("PATH") + ":/opt/tools/bin"`,
and nothing is found afterwards. **In a startup file, build values with
`SETENV`**, which is a BASIC statement wherever it appears. The shell-style
form is still handy there for a fixed value: `export EDITOR=vi` sets `EDITOR`
to `vi`, with no quotes needed and none wanted.

**You do not need `EXPORT` to hand a variable on.** `SETENV` already puts it in
the environment every command inherits. `EXPORT` is for sending a BASIC
*variable* out: after `release$ = "2026.1"` and `export release$`, a command
sees `RELEASE`, upper-cased and without the `$`, which an environment
variable's name may not contain.

**An unset variable is `""`.** So `ENVIRON$("PATH") + ":/opt/tools/bin"` gives
`:/opt/tools/bin` if `PATH` was somehow empty, and an empty entry in `PATH`
means the current folder to most tools, which is a security problem rather
than a typo. Guard it if you are not sure:

```text
if ENVIRON$("PATH") = "" then setenv "PATH", "/usr/bin:/bin"
```

**`${...}` interpolation is on** at the BASICShell prompt and in its startup
files (`OPTION STRING-SUB`), but what goes in the braces is a BASIC
expression, not a variable of the environment: `"${home$}/bin"` uses the BASIC
variable `home$`, and `${PATH}` on its own is the BASIC variable `PATH`, which
is empty.

**Which file is read when:** `/etc/BASICrc` by every shell first, `~/.BASICrc`
by an interactive shell, `~/.BASICprofile` by a login shell
(`basicshell --login`), and none by a script (`basicshell program.bas`),
which should do the same on every machine. `HOME=/tmp/sandbox basicshell`
reads `/tmp/sandbox/.BASICrc`, which is how to try a file without touching
your own. See [Startup Files](STARTUP_FILES.md).

## Where to look next

- [Startup Files](STARTUP_FILES.md): which file is read when.
- [ALIAS](ALIAS.md), [PROMPT](PROMPT.md) and
  [SETENV, EXPORT and UNSETENV](ENVIRONMENT.md).
- [Shell Scripting](SHELL_SCRIPTING.md): running programs from a BASIC
  program, and using what they print.
- [OPTION](OPTION.md): `OPTION GRAPHICS-ON-STOP` is another line people keep
  in the file, for what happens to a program's graphics when it stops on an
  error.
