' {{NAME}} — a to-do list, in a window of its own made with ActiveUI.
'
' Build it with basicc: make run builds it and runs it (make build only
' builds it, into Build/). The program is a Mac application with a window
' of its own, and it runs until the window closes.
'
' Type a task and press New Task, or Return; pick one and press Done to
' tick it, or Delete to take it off; Clear Done takes off every done task,
' after asking. The tasks are kept in tasks.txt, in
' ~/Library/Application Support/{{NAME}}/ (or in $APP_DATA_DIR when that is
' set), so they are there the next time it opens.
'
' THE FILES, in the order worth reading them:
'
'   main.bas                              you are here: the parts, wired together
'   models/TodoTask.bas                   one task
'   models/TaskList.bas                   the tasks, and what can be done with them
'   models/TaskStore.bas                  tasks.txt, in and out
'   models/TabSeparated.bas               the file's one-record-a-line format
'   views/TaskListView.bas                the New task field and the list
'   views/StatusBarView.bas               "2 to do · 1 done"
'   controllers/TodoWindowController.bas  the window, its commands, every change
'   app/DataFolder.bas                    where the app keeps its data
'
' The models know nothing of windows, the views never change a task, and
' the controller is the one part that knows both. README.md says how the
' comments are written.

' ---------------------------------------------------------------- the files
'
' IMPORT reads another file's TYPEs, CLASSes and FUNCTIONs into this
' program, from a path relative to this file. Only this file's own
' statements run; an imported file's are declarations.
IMPORT "models/TodoTask.bas"
IMPORT "models/TaskList.bas"
IMPORT "models/TaskStore.bas"
IMPORT "models/TabSeparated.bas"
IMPORT "views/TaskListView.bas"
IMPORT "views/StatusBarView.bas"
IMPORT "controllers/TodoWindowController.bas"
IMPORT "app/DataFolder.bas"

' ---------------------------------------------------------------- the parts
'
' Each part is a GLOBAL, declared here and made below, and the others reach
' it by name. Three things in this BASIC make that the way: an imported
' file's statements do not run (GLOBALs included), an object handed to a
' FUNCTION is a copy (BASIC-35), and the interpreter BASICStudio runs cannot
' yet call a method on an object kept in another object's field.

/// The tasks, read from tasks.txt.
GLOBAL theTasks AS TaskList
/// The New task field and the list.
GLOBAL theTaskListView AS TaskListView
/// The status line.
GLOBAL theStatusBar AS StatusBarView
/// The window's controller, which every control's handler hands its command to.
GLOBAL theWindow AS TodoWindowController

' ------------------------------------------------------------------- start
tasksFile$ = DataFolder$("{{NAME}}") + "/tasks.txt"
theTasks = ReadTasks(tasksFile$)
theTaskListView = NEW TaskListView()
theStatusBar = NEW StatusBarView()
theWindow = NEW TodoWindowController()
theWindow.Start("{{NAME}}", tasksFile$)
theWindow.Run()
