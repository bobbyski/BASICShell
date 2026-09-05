# ALIAS and UNALIAS Commands

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

A short name for a longer command line, for use at the prompt.

```basic
option shellmode on
alias ll="ls -la"
ll
```

`ALIAS` on its own lists what is defined, one per line and in name order:

    alias gs='git status'
    alias la='ls -A'
    alias ll='ls -la'

`UNALIAS` removes one.

```basic
unalias ll
```

Aliases expand at the start of a command line only, so they name commands rather than arbitrary text. Put them in `~/.BASICrc` to have them in every session.
