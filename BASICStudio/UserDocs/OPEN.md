# OPEN Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Opens a legacy numbered file handle. Sequential text, exact binary reads, and fixed-length random records are supported.

```basic
open "notes.txt" for output as #1
print #1, "HELLO"
close #1
```

```basic
open "notes.txt" for input as #1
line input #1, line$
print line$
close #1
```

`INPUT` fails if the file is missing. `OUTPUT` creates or replaces the file. `APPEND` creates the file if needed and writes at the end.

## Modes

```basic
open path$ for input as #1
open path$ for output as #1
open path$ for append as #1
open path$ for binary as #1
open path$ for random as #1 len = 64
```

Traditional random-file shorthand defaults to `RANDOM`:

```basic
open "people.dat" as #1 len = 64
```

- `BINARY` preserves exact bytes. Read a byte count with `INPUT$(count, #n)` and inspect the byte length with `LOF(n)`.
- `RANDOM` defaults to a record length of 128 bytes when `LEN` is omitted.
- `LEN` must be positive and is only valid for RANDOM files.
- `PRINT#`, `WRITE#`, `INPUT#`, and `LINE INPUT#` are text operations and reject BINARY/RANDOM handles.

See **Random And Binary Files** for `FIELD`, `GET`, `PUT`, positions, and numeric conversions.
