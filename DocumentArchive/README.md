# DocumentArchive

Reading documents out of a zip, in process, with no dependencies.

An application that ships a manual, a set of templates, or a pack of samples
wants them as **one file** it can put in its bundle — one thing to install,
one thing to sign, and no directory of a hundred small files that can arrive
half-copied. It also wants a page out of that file in microseconds, without
writing anything to disk.

That is all this does. It reads; it cannot write. An archive that ships
inside an application is built once by the build, and a reader that cannot
write cannot corrupt what it was given.

## Reading an archive

```swift
import DocumentArchive

let archive = try ZipArchive(url: url)
for entry in archive.entries where !entry.isDirectory {
    print(entry.path, entry.size)
}
let page = try archive.text(at: "PRINT.md")
```

Entries are decompressed on demand and checked against the CRC the archive
stores for them, so a damaged archive is a clear error rather than a puzzling
one somewhere later.

## Reading a set of documents

`DocumentLibrary` is the layer most callers want. It takes a list of places
to look and uses the first that has anything in it:

```swift
let library = try DocumentLibrary(
    searching: [
        .archive(bundledZip),                 // what shipped
        .directory(sourceFolder),             // what someone is editing
    ],
    extension: "md"
)

for document in library.documents {
    print(document.name, document.text.count)
}
```

Which of the two it found is not in the API by design: shipping code reads
the archive in the bundle, a developer editing the documents points at the
directory, and the code that displays them cannot tell and does not need to.
A source that is missing, unreadable or empty is passed over rather than
being an error; only finding nothing anywhere throws.

## What it handles

- Stored (method 0) and deflated (method 8) entries.
- Archives with a trailing comment.
- Entries inside folders, read by their full path, with an optional `prefix`
  to read just one folder.
- The `__MACOSX` folder and `._` files that Finder's Compress adds, which
  `DocumentLibrary` skips so they do not arrive as duplicate documents.

## What it does not

- **Writing.** Build archives with `zip`.
- **Zip64.** An archive over 4 GB, or with more than 65535 entries, is
  refused by name rather than misread.
- **Encryption**, and compression methods other than the two above. Both are
  refused with a message naming the method.

The whole file is held in memory, which is the right trade for a manual read
repeatedly and the wrong one for a multi-gigabyte archive — unpack that to
disk instead.

## Requirements

macOS 13+. Deflate comes from the system `Compression` framework; the CRC and
the format parsing are here.
