# {{NAME}}

A to-do list in a window of its own, made with ActiveUI and written in
BASIC: New Task, Done, Delete and Clear Done (which asks first) across the
top, a field for a new task, a list with ☐ or ☑ in front of each task, and
a status line ("2 to do · 1 done"). Done and Delete are grayed out until a
task is picked, New Task until something is typed, and Clear Done until a
task is done.

Build it with `basicc`:

```sh
make        # build and run
make build  # just build, into Build/{{NAME}}
```

The tasks are kept in `tasks.txt` in `~/Library/Application Support/{{NAME}}/`,
or in `$APP_DATA_DIR` when that is set.

| File | What it is |
|---|---|
| `src/main.bas` | The program: wires the parts together. |
| `src/models/TodoTask.bas` | `TodoTask`: one task. |
| `src/models/TaskList.bas` | `TaskList`: the tasks, and what can be done with them. |
| `src/models/TaskStore.bas` | `ReadTasks` and `WriteTasks`: `tasks.txt`, in and out. |
| `src/models/TabSeparated.bas` | The file's format: one record a line, fields split by tabs. |
| `src/views/TaskListView.bas` | The New task field and the list. |
| `src/views/StatusBarView.bas` | The status line. |
| `src/controllers/TodoWindowController.bas` | The window, its commands, and every change. |
| `src/app/DataFolder.bas` | Where the app keeps its data. |

## How the comments are written

Every `TYPE`, `CLASS`, field, `FUNCTION` and `GLOBAL` has a documentation
comment: `///` lines on the line just above it, read by Swift's rules
(BASIC's own, from `BASICDocumentation.swift`; `basiclint` checks them):
a one-line summary, then, after a `///` line of its own, any discussion,
then `- Parameter name:` for each parameter and `- Returns:` for what it
gives back. Comments inside a routine start with `'` and say what each step
does. Each file starts with a `'` comment saying what is in it.

## What BASIC's ActiveUI cannot do yet

The same app in Swift has a window toolbar, a Task menu, a checkbox on each
task and done tasks struck through. BASIC's ActiveUI classes have none of
those yet, so the commands are buttons across the top of the window, the
menus are the ones every Mac app has, and ☑ stands in for the checkbox.
Each place this happens has a comment saying so.
