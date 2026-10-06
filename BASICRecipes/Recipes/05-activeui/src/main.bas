' {{NAME}} — a window of its own, made with ActiveUI.
'
' Run it in BASICStudio: the window is the program's, opening beside
' Studio's, and the program runs until it closes. (BASICShell and basicc
' have no windows, and say so.)
'
' A to-do list. Type a task and press Add, or Return; pick one and press
' Done to take it off. The line at the bottom says what happened.
'
' Each control names the FUNCTION that handles it: addButton.onclick("AddTask").
' A handler is always a named FUNCTION, not a closure, because a closure's
' changes would not get out of it. win.run() shows the window and waits,
' running handlers as you work, until the window closes.

' The tasks, kept here: the list on screen shows them, and is filled again
' from here when one is taken off.
GLOBAL MAXTASKS AS INTEGER = 50
GLOBAL task$(50) AS STRING
GLOBAL taskCount AS INTEGER
GLOBAL doneCount AS INTEGER

GLOBAL win = AUIWindow("{{NAME}}")
GLOBAL taskField = AUIField("", "Something to do")
GLOBAL taskList = AUIList()
GLOBAL statusLine = AUILabel("Add a task, or pick one and press Done.")

' Across the top, a row of buttons, where a toolbar would be.
LET tools = AUIStack("horizontal")
LET addButton = AUIButton("Add")
LET doneButton = AUIButton("Done")
LET clearButton = AUIButton("Clear All")
tools.add(addButton)
tools.add(doneButton)
tools.add(clearButton)

' The window, top to bottom: the buttons, the field, the list, the status.
win.add(tools)
win.add(taskField)
win.add(taskList)
win.add(statusLine)

' Who handles what.
addButton.onclick("AddTask")
taskField.onsubmit("AddTask")
doneButton.onclick("FinishTask")
clearButton.onclick("ClearAll")
taskList.onselect("Picked")
win.onclose("Closed")

' A first task, so the list is not empty.
Remember("Try this program")
ShowTasks()

win.run()

' Back here once the window has closed.
PRINT "{{NAME}} closed: "; doneCount; " done, "; taskCount; " still to do."

' ================================================================= handlers

' Add, or Return in the field: the field's text becomes a task.
FUNCTION AddTask()
    LOCAL newTask$ = taskField.text$()
    IF newTask$ = "" THEN
        statusLine.text("Type a task first.")
        RETURN
    END IF
    IF taskCount >= MAXTASKS THEN
        statusLine.text("The list is full.")
        RETURN
    END IF
    Remember(newTask$)
    ShowTasks()
    taskField.text("")
    statusLine.text("Added " + newTask$ + ".")
END FUNCTION

' Done: the picked task comes off the list.
FUNCTION FinishTask()
    LOCAL row = taskList.selectedindex()
    IF row < 0 THEN
        statusLine.text("Pick a task first.")
        RETURN
    END IF
    LOCAL finished$ = task$(row)
    LOCAL i = 0
    FOR i = row TO taskCount - 2
        task$(i) = task$(i + 1)
    NEXT i
    taskCount = taskCount - 1
    doneCount = doneCount + 1
    ShowTasks()
    statusLine.text("Done: " + finished$ + ".")
END FUNCTION

' Clear All, after asking.
FUNCTION ClearAll()
    LOCAL sure = AUIDialog("Clear the list?", "Every task goes.")
    sure.addbutton("Clear")
    sure.addbutton("Cancel")
    IF sure.show() = 0 THEN
        taskCount = 0
        ShowTasks()
        statusLine.text("Cleared.")
    END IF
END FUNCTION

' A row was picked: the event says which.
FUNCTION Picked(event AS BASICAUIEvent)
    statusLine.text("Picked " + event.Text$ + ".")
END FUNCTION

FUNCTION Closed()
    PRINT "Window closed."
END FUNCTION

' ================================================================= the list

FUNCTION Remember(newTask$ AS STRING) AS VOID
    task$(taskCount) = newTask$
    taskCount = taskCount + 1
END FUNCTION

' The list on screen, filled again from the tasks.
FUNCTION ShowTasks() AS VOID
    taskList.clear()
    LOCAL i = 0
    FOR i = 0 TO taskCount - 1
        taskList.add(task$(i))
    NEXT i
END FUNCTION
