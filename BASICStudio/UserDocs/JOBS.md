# JOBS, FG, BG, KILL and WAIT Commands

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Job control, for commands started in the background. It needs `OPTION SHELLMODE ON` and a shell to type at.

End a command with `&` to start it in the background. The shell answers with a job number and a process id:

```basic
option shellmode on
/bin/sleep 30 &
```

prints `[1] 20789`.

| Command | Does |
| --- | --- |
| `JOBS` | Lists the background jobs and what each is doing. |
| `FG n` | Brings job `n` to the foreground and waits for it. |
| `BG n` | Lets a stopped job carry on in the background. |
| `KILL n` | Sends a job a signal. |
| `WAIT` | Waits until the background jobs have finished. |

```basic
jobs
```

prints `[1] Running  /bin/sleep 30`.

A job that finishes while you are typing is reported before the next prompt rather than interrupting the line you are on.
