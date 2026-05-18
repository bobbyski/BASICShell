# PROMPT Command

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Sets the interactive prompt template. Use `PROMPT` with no argument to print the current template.

The template supports these tokens:

`${currentdir}` expands to the current BASIC working directory, shortened with `~` for the home directory.
`${gitstatus}` expands to the current git branch, with ahead/behind markers when available.
`${user}` expands to the current macOS user name.
`%cwd` expands to the current BASIC working directory, shortened with `~` for the home directory.
`%git` expands to the current git branch, with ahead/behind markers when available.
`%gitSegment` expands to a full git prompt segment when the working directory is inside a git checkout.
`%nl` inserts a newline.
`%%` inserts a literal percent sign.

```basic
prompt "READY%nl> "
```

```basic
prompt "${user}:${currentdir} ${gitstatus}> "
```

Nerd Font symbols can be used when the selected font supports them.

```basic
prompt "    ${currentdir}    ${gitstatus}  "
```
