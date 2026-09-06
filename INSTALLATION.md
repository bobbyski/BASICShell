# Installation

Where every part of BASIC goes, how each one is found at run time, and why.

Everything installs under a single **prefix**, `/usr/local` by default:

```sh
cd Code/BASICShell && ./buildtosystem.sh                 # /usr/local
PREFIX=/opt/basic ./buildtosystem.sh                     # somewhere else
cd Code/BASICShell && ./buildtosystem.sh --skip-tests    # faster
```

That one script builds and installs the shell **and** the compiler, because
they have to be the same age — see [Why together](#why-together).

---

## The layout

```
<prefix>/bin/basicshell                         the shell
<prefix>/bin/BASICShell                     ->  basicshell (case-sensitive volumes)
<prefix>/bin/basicc                             the compiler
<prefix>/bin/basictest                          the conformance runner
<prefix>/bin/basiclint                          the linter
<prefix>/bin/*.bundle                       ->  ../lib/basicshell/*.bundle

<prefix>/lib/basicshell/BASICShell_BASICShell.bundle/Demos/*.bas
<prefix>/lib/basicshell/UserDocs.zip            the manual HELP opens
<prefix>/lib/libBASICRTHost.a                   the runtime basicc links
<prefix>/share/basicc/BASICRT/                  runtime sources (fallback)
<prefix>/share/basicc/BASICRTHostStubs/
```

Nothing is installed outside the prefix. There is no step that writes to
`/etc`, `/Library`, or a user's home.

---

## How each part is found

None of these is a path compiled into the code. Every one is derived at run
time, from the prefix the binary is actually in or from the environment.

| Thing | Found by | Override |
| --- | --- | --- |
| `basicc`, from the shell's `JIT` | `PATH` | `BASICC` |
| The runtime archive, from `basicc` | `../lib/` relative to the running `basicc` | `BASICC_RT_LIB` |
| Runtime sources, when there is no archive | `../share/basicc/` relative to `basicc` | `BASICC_RT_DIR` |
| The manual, from `HELP` | the shell's resource bundle, then `../lib/basicshell/UserDocs.zip` | `BASIC_USERDOCS` |
| Demo programs | the shell's resource bundle beside the executable | — |

The two relative lookups are why the layout above is not a convention you may
vary: `basicc` finds its runtime by walking up from wherever it was started.
Move the binary without the `lib` beside it and it compiles nothing.

`PATH` is the whole of how the shell finds the compiler. A shell installed
without one interprets and refuses to compile, saying so — it does not guess
at install prefixes, and it never did find a compiler you had not put on your
path.

---

## Why together

`JIT` shells out to whichever `basicc` is on `PATH`. That makes an
independently-installed compiler a version skew waiting to happen: a program
that `RUN` interprets correctly and `JIT` compiles against a runtime from
another month behaves like a build from that month, and reads as a live bug
in whatever you are working on now. It has already cost a day here.

So `buildtosystem.sh` builds both and installs both, and verifies two things
that a broken install otherwise hides until much later:

- the installed `basicc` compiles a program with the environment cleared —
  proving it finds *its own* runtime rather than one that happened to be in
  the shell that ran the installer;
- the installed shell resolves `basicc` on `PATH` — the lookup `JIT` performs,
  asked in the same words.

---

## What is not installed

**BASICStudio** is an application bundle, not a command. It is built with
`swift build` in `Code/BASICStudio` and run from there or from Xcode; it has
no installer and needs none — it carries its own copy of `UserDocs.zip` as a
bundle resource.

**The runtime archive is not a system library.** It is a static archive that
`basicc` links into the programs it builds, so it belongs beside the compiler
that links it, not on a library search path. Two places it cannot go:

- `/usr/lib` — protected by System Integrity Protection. Not even `root` can
  write there (`touch /usr/lib/x` → *Operation not permitted*). `/usr/local/lib`
  is the writable, conventional equivalent, and is where a default install
  puts it.
- `/opt/homebrew` — that prefix belongs to Homebrew. Hand-installed binaries
  in it are indistinguishable from packages Homebrew manages, and `brew`
  will not know about them.

If you want the archive somewhere of your own, `BASICC_RT_LIB` points at it
directly and takes precedence over everything.

---

## Uninstalling

The compiler brings its own:

```sh
cd Code/BASICCompiler && ./buildAndInstall.sh --prefix /usr/local --uninstall
```

The shell has no uninstall step yet; its files are the ones listed above
under `bin/` and `lib/basicshell/`.

---

## Running without installing

Nothing here has to be installed to be used. From a built tree:

```sh
Code/BASICShell/.build/debug/BASICShell            # the shell
Code/BASICCompiler/.build/release/basicc build x.bas -o x
```

For `JIT` to work from an uninstalled shell, point it at an uninstalled
compiler:

```sh
BASICC=$PWD/Code/BASICCompiler/.build/release/basicc Code/BASICShell/.build/debug/BASICShell
```

`basicc` run from inside its own package finds the runtime in
`.build/release/` and rebuilds it when the runtime sources have changed, so a
development tree needs no install at all.
