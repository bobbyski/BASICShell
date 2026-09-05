# READFILEASYNC, WRITEFILEASYNC and HTTPGETASYNC

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

File and network work that runs while the program gets on with something else. Each answers a `TASK`; `AWAIT` collects the result.

```basic
t = writefileasync("/tmp/notes.txt", "hello from async")
finished = await t

r = readfileasync("/tmp/notes.txt")
print await r
```

prints `hello from async`.

| Function | Answers a task that |
| --- | --- |
| `READFILEASYNC(path)` | Reads the file and answers its text. |
| `WRITEFILEASYNC(path, text)` | Writes the text to the file. |
| `HTTPGETASYNC(url)` | Fetches the URL and answers the response. |

The point is to start several and wait once:

```basic
a = readfileasync("/tmp/one.txt")
b = readfileasync("/tmp/two.txt")
print await a
print await b
```

Both reads are under way before either is waited on. Awaiting each one as you start it gives all of the cost and none of the benefit.

`AWAIT` is an expression, so it goes on the right of an assignment or inside `PRINT` — not on a line of its own. See [ASYNC and AWAIT](ASYNC_AWAIT.md) for tasks in general and [HTTPClient](HTTPCLIENT.md) for the fuller HTTP interface.
