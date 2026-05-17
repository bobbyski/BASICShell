# File Class

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Creates and works with host-backed files. `File` is AIBasic's first built-in system class.

Open a file directly with the constructor, or create a closed file object and open it later.

```basic
let file = File("notes.txt", WRITE, TEXT, true)
file.write("HELLO" + chr$(10))
print file.size()
file.close
```

```basic
let file = File()
file.open("notes.txt", READ, TEXT, false)
print file.read()
file.close
```

Access constants are `READ`, `WRITE`, and `BOTH`. File type constants are `RAW`, `TEXT`, and `JSON`. `requireNew = TRUE` fails with `File Already Exists` if the file is already present. `READ` fails with `File Not Found` if the file is missing.

JSON files are text files that are read and written atomically.

```basic
record Report
    Title as string json name "title"
end record

let report as Report
report.Title = "Quarterly"

let output = File("report.json", WRITE, JSON, true)
output.writeJson(report, true)
output.close

let input = File("report.json", READ, JSON, false)
let loaded as Report
loaded = input.json()
input.close

print loaded.Title
```
