' TodoWindowController.bas — the window, its commands, and every change.
'
'     New Task   ──► NewTask   ──► Tasks.Add       ──► Save ──► Refresh
'     Done       ──► MarkDone  ──► Tasks.MarkDone  ──► Save ──► Refresh
'     Delete     ──► DeleteTask ─► Tasks.Remove    ──► Save ──► Refresh
'     Clear Done ──► ClearDone ──► (asks) ─► Tasks.ClearDone ─► Save ─► Refresh
'                                                    Refresh ──► list, status, commands
'
' It is the only part that knows both the tasks and the views. The views
' report what the person did; the controller changes the tasks, saves them,
' and shows the result. Each command is one method, and a command that has
' nothing to do is grayed out.
'
' Where this differs from Swift's To-Do List, because BASIC's ActiveUI
' classes cannot do it yet:
' - The commands are a row of buttons across the top of the window, in the
'   toolbar's place: an AUIWindow has no toolbar, and no flexible space to
'   push Clear Done to the trailing end.
' - There is no Task menu and no File ▸ New Task: built with basicc, the
'   program has the menu bar every Mac app has (the app menu, File with Close
'   and Quit, Edit, Window), and BASIC cannot add to it yet. When it can,
'   each menu item names the same handler its button names.

/// The window and the commands across its top, over the app's tasks and
/// views.
///
/// It works on `theTasks`, `theTaskListView` and `theStatusBar`, the parts
/// main.bas makes (see there for why they are GLOBALs). Every control names
/// a plain FUNCTION as its handler (the handlers at the end of this file),
/// because ActiveUI calls a handler by name and a method has none it can
/// call. Each handler hands its command to `theWindow`, this controller.
CLASS TodoWindowController
    /// The window.
    PUBLIC Window AS VARIANT
    /// New Task: adds what the New task field holds.
    PUBLIC NewTaskButton AS VARIANT
    /// Done: marks the picked task as done.
    PUBLIC DoneButton AS VARIANT
    /// Delete: takes the picked task off the list.
    PUBLIC DeleteButton AS VARIANT
    /// Clear Done: asks, then takes every done task off the list.
    PUBLIC ClearDoneButton AS VARIANT
    /// The file the tasks are kept in.
    PUBLIC TasksFile AS STRING
    /// The picked task's row, or -1 for none.
    PUBLIC PickedRow AS INTEGER

    /// Builds the window over the tasks, with nothing picked.
    ///
    /// - Parameter title: The window's title: the app's name.
    /// - Parameter tasksFile: The file the tasks are kept in, written after
    ///   every change.
    FUNCTION Start(title AS STRING, tasksFile AS STRING) AS VOID
        ME.TasksFile = tasksFile
        ME.PickedRow = -1

        ' Top to bottom: the commands, the field and the list, the status.
        ME.Window = AUIWindow(title)
        ME.BuildCommands()
        theTaskListView.Build(ME.Window)
        theStatusBar.Build(ME.Window)

        ' Who handles what: Return in the field is New Task, and picking a
        ' row or typing in the field brings the commands up to date.
        theTaskListView.NewTaskField.onsubmit("NewTaskPressed")
        theTaskListView.NewTaskField.onchange("NewTaskTextChanged")
        theTaskListView.Rows.onselect("TaskPicked")

        ' Swift's window is 420 by 460 points.
        ME.Window.size(420, 460)

        ' A button starts enabled, and nothing asks again until the first
        ' change, so everything is brought up to date before the window
        ' opens: Done and Delete start grayed out, as nothing is picked.
        ME.Refresh()
    END FUNCTION

    /// Makes the command buttons, in the toolbar's place across the top.
    FUNCTION BuildCommands() AS VOID
        LOCAL bar = AUIStack("horizontal")
        ME.NewTaskButton = AUIButton("New Task")
        ME.DoneButton = AUIButton("Done")
        ME.DeleteButton = AUIButton("Delete")
        ME.ClearDoneButton = AUIButton("Clear Done")
        bar.add(ME.NewTaskButton)
        bar.add(ME.DoneButton)
        bar.add(ME.DeleteButton)
        bar.add(ME.ClearDoneButton)
        ME.Window.add(bar)

        ME.NewTaskButton.onclick("NewTaskPressed")
        ME.DoneButton.onclick("DonePressed")
        ME.DeleteButton.onclick("DeletePressed")
        ME.ClearDoneButton.onclick("ClearDonePressed")
    END FUNCTION

    /// Shows the window and waits until it is closed.
    FUNCTION Run() AS VOID
        ME.Window.run()
    END FUNCTION

    ' ------------------------------------------------------------ commands

    /// The New Task command: adds what the New task field holds.
    FUNCTION NewTask() AS VOID
        LOCAL title$ = theTaskListView.NewTaskText$()
        IF title$ = "" OR NOT theTasks.HasRoom() THEN RETURN
        theTasks.Add(title$, FALSE)
        theTaskListView.ClearField()
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// The Done command: marks the picked task as done.
    FUNCTION MarkDone() AS VOID
        IF NOT theTasks.CanMarkDone(ME.PickedRow) THEN RETURN
        theTasks.MarkDone(ME.PickedRow)
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// The Delete command: takes the picked task off the list.
    FUNCTION DeleteTask() AS VOID
        IF NOT theTasks.HasRow(ME.PickedRow) THEN RETURN
        theTasks.Remove(ME.PickedRow)
        ' The row is gone, so nothing is picked now.
        ME.PickedRow = -1
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// The Clear Done command: asks first, then takes every done task off.
    FUNCTION ClearDone() AS VOID
        IF NOT theTasks.HasDone() THEN RETURN
        ' show() waits for an answer and gives back the button's number.
        LOCAL question = AUIDialog("Clear completed tasks?", "The done tasks are removed. This cannot be undone.")
        question.addbutton("Clear")
        question.addbutton("Cancel")
        IF question.show() <> 0 THEN RETURN
        theTasks.ClearDone()
        ME.PickedRow = -1
        ME.Save()
        ME.Refresh()
    END FUNCTION

    /// Picks a task, as a click on its row does.
    ///
    /// - Parameter row: The task's row, or -1 for none.
    FUNCTION Pick(row AS INTEGER) AS VOID
        ME.PickedRow = row
        IF NOT theTasks.HasRow(row) THEN ME.PickedRow = -1
        ME.RefreshCommands()
    END FUNCTION

    ' -------------------------------------------------------------- showing

    /// Brings the whole window up to date with the tasks.
    FUNCTION Refresh() AS VOID
        theTaskListView.Show(theTasks, ME.PickedRow)
        theStatusBar.Show(theTasks)
        ME.RefreshCommands()
    END FUNCTION

    /// Grays out each command that has nothing to do.
    FUNCTION RefreshCommands() AS VOID
        ME.NewTaskButton.enabled(ME.CanAddTask())
        ME.DoneButton.enabled(theTasks.CanMarkDone(ME.PickedRow))
        ME.DeleteButton.enabled(theTasks.HasRow(ME.PickedRow))
        ME.ClearDoneButton.enabled(theTasks.HasDone())
    END FUNCTION

    /// Whether New Task has something to add.
    ///
    /// - Returns: TRUE when the field holds text and the list has room.
    FUNCTION CanAddTask() AS BOOLEAN
        IF theTaskListView.NewTaskText$() = "" THEN RETURN FALSE
        RETURN theTasks.HasRoom()
    END FUNCTION

    /// Writes the tasks to their file.
    FUNCTION Save() AS VOID
        WriteTasks(ME.TasksFile, theTasks)
    END FUNCTION
END CLASS

' ================================================================ handlers
'
' What each control calls. Each one hands its command to the controller,
' so a command is carried out in one place, whichever control asked.

/// New Task, or Return in the New task field.
FUNCTION NewTaskPressed() AS VOID
    theWindow.NewTask()
END FUNCTION

/// Done.
FUNCTION DonePressed() AS VOID
    theWindow.MarkDone()
END FUNCTION

/// Delete.
FUNCTION DeletePressed() AS VOID
    theWindow.DeleteTask()
END FUNCTION

/// Clear Done.
FUNCTION ClearDonePressed() AS VOID
    theWindow.ClearDone()
END FUNCTION

/// A row of the list was picked.
///
/// - Parameter event: Which row: `event.Index`, from 0.
FUNCTION TaskPicked(event AS BASICAUIEvent) AS VOID
    theWindow.Pick(event.Index)
END FUNCTION

/// The New task field's text changed, so New Task may gray out or not.
FUNCTION NewTaskTextChanged() AS VOID
    theWindow.RefreshCommands()
END FUNCTION
