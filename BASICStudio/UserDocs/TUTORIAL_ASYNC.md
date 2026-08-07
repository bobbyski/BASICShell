# Async Programming Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Async functions let a BASIC program start work, continue doing something else, and wait for the result only when it is needed. BASICShell represents running work with an opaque `TASK` value.

## Start With An Async Function

Prefix a normal function declaration with `ASYNC`. Calling it starts a child task immediately and returns a task handle.

```basic
global calculation as task = AddLater(20, 22)
print "The task is "; taskstatus$(calculation)

answer = await calculation
print "The answer is "; answer

async function AddLater(a as integer, b as integer) as integer
    return a + b
end function
```

`AWAIT` returns the task's value. Local variables and function frames survive while a task is suspended.

## Do Other Work Before Awaiting

Keeping the handle lets the caller run ordinary BASIC statements before waiting.

```basic
global timer as task = Sleep(250)
print "Timer started"
print "This runs before the timer completes"
elapsed = await timer
print "Timer completed after "; elapsed; " ms"
```

`SLEEP(milliseconds)` is asynchronous. The host remains able to process UI, terminal, debugger, and other task events while the BASIC task waits.

## Launch Intentional Background Work

Discarding an async result by accident is an error. Use `BACKGROUND` when a task is intentionally fire-and-forget.

```basic
background RecordTelemetry()
print "The caller does not wait"

async function RecordTelemetry()
    ignored = await Sleep(10)
    print "Background work completed"
end function
```

A retained task that is never awaited, joined, cancelled, inspected, or marked as background produces an end-of-run warning.

## Check, Join, Or Cancel A Task

```basic
global job as task = Sleep(1000)
print taskstatus$(job)

cancel job
print taskstatus$(job)
print taskerror$(job)
```

`JOIN task` waits for completion without returning its value. `AWAIT task` waits and returns the value. `CANCEL task` requests cooperative cancellation. `TASKSTATUS$()` reports `READY`, `RUNNING`, `SUSPENDED`, `COMPLETED`, `CANCELLED`, or `FAILED`; `TASKERROR$()` returns failure details.

Ctrl-C in BASICShell and Stop in BASICStudio cancel the foreground program and its complete child-task tree. Debugger breakpoints and stepping pause resumable async frames instead of cancelling them.

## Read And Write Files

Async file operations use the same file host as ordinary BASIC file commands.

```basic
global readTask as task = ReadFileAsync("input.txt")
contents$ = await readTask

global writeTask as task = WriteFileAsync("output.txt", contents$ + chr$(10))
bytesWritten = await writeTask
print bytesWritten; " bytes written"
```

`READFILEASYNC(path)` returns a string. `WRITEFILEASYNC(path,text)` returns the number of UTF-8 bytes written.

## Fetch HTTP Data

`HTTPGETASYNC(url)` returns a dictionary after it is awaited.

```basic
global request as task = HttpGetAsync("https://example.com/")
response = await request
headers = response("HEADERS")

print "Status: "; response("STATUS")
print "Final URL: "; response("URL")
print "Content-Type: "; headers("Content-Type")
print response("BODY")
```

The response dictionary contains `STATUS`, `BODY`, `URL`, and `HEADERS`.

## Handle Async Errors

An async failure is reported at the `AWAIT` statement, so normal BASIC error handling applies.

```basic
on error goto Failed
global request as task = HttpGetAsync("https://example.invalid/")
response = await request
print response("BODY")
end

Failed:
    print "ERR="; err
    print taskerror$(request)
```

## Shared Data Rules

Async function arguments and globals are captured when the task launches. Ordinary globals are copied into the task's isolated runtime. This makes the default deterministic: changing a global in the caller does not race with a child task.

Mutable cross-task state must use an explicit synchronized captured cell. Prefer returning a value from the async function whenever possible.

## Debug Tasks

BASICStudio's debugger lists logical tasks, their parent/child relationships, state, source location, wait reason, suspended frames, locals, captured globals, results, and errors. Selecting a suspended task makes Continue and Step operate on that task.

BASICShell provides the same runtime information through `TASKS`, `TASKS DETAIL`, and `TASK <id>`.
