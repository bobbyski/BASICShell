# FILEEXISTS() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Answers 1 when there is a file at that path and 0 when there is not.

```basic
if fileexists("/etc/hosts") then print "yes"
print fileexists("/nowhere")
```

It asks and answers; it does not open anything, and it does not fail when the answer is no — which is the point of having it rather than opening a file to find out.

```basic
if not fileexists(path$) then
    print "no such file: "; path$
    end
end if
```
