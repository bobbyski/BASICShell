# File Class And Directory API

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Creates and works with host-backed files. The API is shared by BASICStudio and BASICShell.

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

## Access And Types

| Value | Meaning |
|---|---|
| `READ` | Open an existing file for reading. |
| `WRITE` | Create or replace a file for writing. |
| `BOTH` | Read and write, creating the file when needed. |
| `TEXT` | Character-oriented text. |
| `RAW` | Exact bytes stored in a data-backed BASIC string. |
| `JSON` | Whole-document JSON values. |

`read(max)` counts characters in `TEXT` mode and bytes in `RAW` mode. In RAW mode, `write` preserves every byte, including NUL and values above 127. `size()` always reports bytes.

```basic
let output = File("bytes.bin", WRITE, RAW, false)
output.write(chr$(65) + chr$(0) + chr$(255))
print output.size()
output.close

let input = File("bytes.bin", READ, RAW, false)
data$ = input.read()
input.close
```

Properties and no-argument methods may be read while debugging:

- `path$()` / `path$`
- `access$()` / `access$`
- `type$()` / `type$`
- `size()` / `size`
- `position`
- `eof`
- `open`
- `error$`

## Shared Path Operations

```basic
File.Mkdir "work"
File.ChDir "work"
print File.Cwd$()
print File.Exists("report.json")
print File.IsDir(".")

let names as variant = File.Files$(".")
print len(names)

File.Rename "old.txt", "new.txt"
File.Rm "new.txt"
```

`File.Mkdir` creates parent directories when needed. `File.Rm` removes a file or an empty directory; it never recursively deletes a directory tree.

For small whole-file operations, shared helpers avoid constructing a File object:

```basic
File.WriteText "message.txt", "HELLO"
print File.ReadText$("message.txt")

File.WriteBytes "payload.bin", chr$(65) + chr$(0)
File.AppendBytes "payload.bin", chr$(255)
payload$ = File.ReadBytes$("payload.bin")
```

`File.WriteText` never adds a newline. `File.ReadBytes$`, `File.WriteBytes`, and `File.AppendBytes` preserve exact bytes in data-backed BASIC strings.

Whole-document JSON convenience methods are also available without constructing a File object:

```basic
let value as variant = FromJsonString('{"ready":true}', true)
File.WriteJson("state.json", value, true)
let restored as variant = File.ReadJson("state.json")
print restored("ready")
```

In the Studio debugger, expand **Files** to inspect modern File objects and numbered files. In BASICShell, use `OPENFILES` while a program is paused.
