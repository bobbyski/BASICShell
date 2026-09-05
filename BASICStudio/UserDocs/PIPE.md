# PIPE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Runs external commands with the output of each feeding the next, as a shell pipeline does.

```basic
option shellmode on
pipe "/bin/echo", "a b c" to "/usr/bin/wc", "-w"
```

prints `3`.

Each stage is a command followed by its arguments, separated by commas; `TO` joins one stage to the next, and there can be as many stages as you like. A pipeline needs at least two.

`PIPE` needs `OPTION SHELLMODE ON`. To run a single command and capture its output rather than chain several, use [EXEC](EXEC.md).
