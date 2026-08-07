# Random And Binary Files

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Legacy RANDOM files divide a byte file into fixed-length records. `FIELD` maps slices of the current record to fixed-width string variables.

```basic
open "people.dat" as #1 len = 24
field #1, 16 as name$, 8 as code$

lset name$ = "ADA"
rset code$ = "7"
put #1, 1

get #1, 1
print "["; name$; "]["; code$; "]"
close #1
```

`LSET` left-aligns and space-pads a FIELD value. `RSET` right-aligns it. Values longer than the field are truncated to the field width.

`GET #n, record` loads a record and updates all FIELD variables. `PUT #n, record` writes all FIELD variables. Omitting the record number uses the next record. Record numbers are one-based.

## Position Functions

- `LOF(n)` returns the file size in bytes.
- `LOC(n)` returns the last record read or written for RANDOM files. For other modes it returns the current zero-based stream position.
- `SEEK(n)` returns the next one-based record or byte position.
- `SEEK #n, position` moves to a one-based record or byte position.
- `EOF(n)` reports whether the current position is at the end.

## Numeric Byte Conversions

The conversion functions use little-endian byte order:

| Encode | Decode | Size |
|---|---|---:|
| `MKI$(integer)` | `CVI(bytes$)` | 2 bytes |
| `MKS$(number)` | `CVS(bytes$)` | 4-byte IEEE single |
| `MKD$(number)` | `CVD(bytes$)` | 8-byte IEEE double |

```basic
field #1, 20 as name$, 2 as ageBytes$
lset name$ = "GRACE"
lset ageBytes$ = mki$(85)
put #1, 1

get #1, 1
print cvi(ageBytes$)
```

Physical device names such as `COM1:`, `LPT1:`, `KYBD:`, and `SCRN:` are not part of the current file implementation. Attempts to open them fail with `Runtime error: Unsupported file device`.
