# CD Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Changes the current working directory used by relative file paths. `LOAD`, `SAVE`, `FILES`, the `File` class, and `SYSTEM` all use this location.

In BASICShell, `CD` changes the shell process directory. In BASICStudio, `CD` changes Studio's persisted BASIC working directory, which can also be selected from File > Set Working Directory.

Use `CD` with no path to print the current working directory.

```basic
cd
```

```basic
cd "/Users/bobby/Desktop"

let file = File("notes.txt", WRITE, TEXT, false)
file.write("HELLO")
file.close

system "cat notes.txt"
```

