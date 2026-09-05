# SETENV, EXPORT and UNSETENV Commands

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

The environment a program was started with, and the one it hands to anything it starts.

| Command | Does |
| --- | --- |
| `SETENV "NAME", "value"` | Sets a variable. |
| `EXPORT NAME` | Marks a variable to be passed to commands this session runs. |
| `UNSETENV "NAME"` | Removes it. |

Read one back with `ENVIRON$`:

```basic
setenv "GREETING", "hello"
print environ$("GREETING")
export GREETING
unsetenv "GREETING"
print "["; environ$("GREETING"); "]"
```

prints `hello` and then `[]` — a name that is not set reads as the empty string rather than failing.

`EXPORT` takes the name as a bare word, not a string, because it names a variable rather than carrying its value.
