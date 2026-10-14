# CHAIN, COMMON and RUN file$

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

`CHAIN` runs another program in this one's place: GW-BASIC's way to split a program too big for memory, and still a tidy way to hand over from one program to the next.

```basic
CHAIN file$ [, [start] [, [ALL]]]
CHAIN MERGE file$ [, [start] [, [ALL] [, DELETE range]]]
COMMON name [, name ...]
RUN file$ [, R]
LOAD file$, R
```

- **`file$`** is found beside the program doing the chaining. Without an extension, `.bas` is assumed.
- **`start`** is a line number, which may be computed, or a label. Without one the next program starts at its first line.
- **What survives** is only what `COMMON` names, with arrays written `name()`. With `ALL`, every variable survives. Everything else starts fresh: `GOSUB` and `FOR` frames, `ON ERROR`, `DATA` (a fresh `RESTORE`), event traps and timers.
- **`RUN file$`** carries nothing and closes open files; **`RUN file$, R`** and **`LOAD file$, R`** keep them open.

```basic
' first.bas
COMMON total, name$
total = 42: name$ = "Ada"
CHAIN "second", 200
```

```basic
' second.bas
100 PRINT "from the top"
200 PRINT name$; total
```

## CHAIN MERGE

`CHAIN MERGE` keeps the running program and lays the file's lines over it: a line whose number the program has is replaced, and the rest go in by number. `DELETE range` first removes lines, usually the last overlay's: `40`, `40-100`, `-40` (from the start) or `40-` (to the end). Both programs need a number on every line. Variables survive as for `CHAIN`.

```basic
1010 CHAIN MERGE "overlay2", 1000, ALL, DELETE 1000-1999
```

## Compiled programs

`basicc` builds each program a `CHAIN` names, when the name is written as a literal, beside the program. A compiled `CHAIN` then runs that program's binary in its place, handing over what survives. A name computed while the program runs has to be built there too. Open files cannot pass from one binary to the next, so they are closed. `CHAIN MERGE` is the interpreter's alone: a compiled program has no lines to lay others over.
