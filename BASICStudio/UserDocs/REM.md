# REM Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Adds a comment. `REM` ignores the rest of the physical line, including characters that would otherwise be parsed as BASIC syntax. Apostrophe and `//` can also start trailing comments. `#` is accepted only at the start of a physical line, which keeps room for dialects where `#` is part of an identifier.

```basic
rem This is a comment
rem print "This ; never runs"
' apostrophe comment
# shell-style comment
// slash comment
print "RUNS" ' trailing apostrophe comment
print "ALSO RUNS" // trailing slash comment
print "COMMENTS ARE IGNORED"
```

## MARK: groups in the editor's function menu

In BASICStudio, the ribbon across the top of the editor names the function the caret is in. Click it for every function and class in the file, and choose one to go straight to it.

A `MARK:` comment names a group in that menu, the way Xcode's does. A `-` before the name draws a line above it, and a `-` after it a line below:

```basic
' MARK: - Drawing -
function DrawPlayer() as void
end function

' MARK: - Sound
function Beep() as void
end function
```

`' MARK: -` alone is just a line. `REM MARK:`, `// MARK:` and `# MARK:` work the same.
