# ASYNC, AWAIT, And TASK

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

`ASYNC FUNCTION` declares a function whose call starts a logical BASIC task and immediately returns an opaque `TASK` value.

```basic
global work as task = Compute(21)
result = await work

async function Compute(value as integer) as integer
    return value * 2
end function
```

## Statements And Functions

- `AWAIT expression` suspends the current BASIC task until the task completes, then produces its result.
- `BACKGROUND expression` explicitly launches a task without retaining or awaiting it.
- `JOIN task` waits for completion and discards the result.
- `CANCEL task` requests cooperative cancellation.
- `TASKSTATUS$(task)` returns the current task state.
- `TASKERROR$(task)` returns failure details, or an empty string when no failure is recorded.
- `SLEEP(milliseconds)` returns a timer task.
- `READFILEASYNC(path)` returns a file-read task.
- `WRITEFILEASYNC(path,text)` returns a file-write task.
- `HTTPGETASYNC(url)` returns an HTTP response task.

`AWAIT` is valid in loaded programs and direct mode. Async calls whose result is discarded must use `BACKGROUND`; retained but unobserved child tasks produce an end-of-run warning.

Task values are not numbers. They can be assigned only to `TASK` or compatible `VARIANT` storage and passed to task operations.

## HTTP Response

Awaiting `HTTPGETASYNC` produces a dictionary with `STATUS`, `BODY`, `URL`, and a nested `HEADERS` dictionary.

## Cancellation And Errors

Cancellation is cooperative and wakes suspended waits. Cancelling an owning foreground program also cancels its descendant tree. Failed task errors surface at `AWAIT` or `JOIN` and can be handled with `ON ERROR GOTO`.
