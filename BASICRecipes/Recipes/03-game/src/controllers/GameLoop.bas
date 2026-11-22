' GameLoop.bas — the loop that runs the game, and the event handlers.
'
' RunGame makes everything, then once a frame reads the controls, moves
' everything, settles the hits and draws. TogglePause pauses it and carries
' it on. GamepadChanged and WindowResized are the event handlers: main.bas
' hands them to ON GAMEPAD and ON RESIZE, and each writes its news down in
' theInbox for the next frame.
'
' This file only declares. The GLOBALs these use (theView, thePlayer,
' theInbox and the rest) are in main.bas, because an imported file's
' top-level statements never run.

' MARK: - The game

/// Runs the game until Q is pressed.
///
/// Make everything, then once a frame until Q: read the controls, move
/// everything, settle the hits, draw, and wait for the next frame.
FUNCTION RunGame() AS VOID
    CLS
    vtg.clear()
    vtg.setDefaultLayer(2)

    ' Make one of each thing in the game.
    theView = NEW View
    theView.Measure()
    theControls = NEW Controls
    theControls.PlaceOnScreen()
    thePlayer = NEW Player("player", WORLDWIDTH / 2, WORLDHEIGHT / 2, "#bfdbfe", "#2563eb")
    theGuard = NEW Guard("guard", WORLDWIDTH / 2, GUARDMARGIN, "#fed7aa", "#ea580c")
    theGuard.Spawn()
    theShots = NEW Shots
    theTargets = NEW Targets
    theTargets.PlaceFour()
    playing = 1

    WHILE playing = 1
        ' Read the controls, and act on what the events left in theInbox.
        theControls.ReadKeys()
        IF theInbox.QuitPressed = 1 THEN playing = 0
        IF theInbox.PausePressed = 1 THEN
            theInbox.PausePressed = 0
            TogglePause()
        END IF

        ' Move everything, unless paused.
        theView.StartFrame()
        IF paused = 0 THEN
            thePlayer.MoveAsAsked(theControls.WantX, theControls.WantY, theControls.WantSpeed)
            theGuard.Patrol()
            IF theInbox.FirePressed = 1 THEN theShots.Fire(thePlayer.NoseX(), thePlayer.NoseY(), thePlayer.Facing)
            theShots.Fly()
            CheckHits()
            theTargets.Fade()
        END IF
        ' A press is used once: in this frame, or not at all while paused.
        theInbox.FirePressed = 0

        ' Draw, show the frame, and sleep until the next one.
        theTargets.Render()
        thePlayer.Render()
        IF theGuard.Alive = 1 THEN theGuard.Render()
        theShots.Render()
        theView.ShowScore(score, thePlayer.Speed)
        LOCAL slept = AWAIT SLEEP(theView.EndFrame())
    WEND

    ' Q was pressed: take everything off the screen and say the score.
    touch.Clear()
    vtg.clear()
    vtg.present()
    CLS
    PRINT "Final score: "; score
END FUNCTION

/// Pauses the game, or carries it on when it is paused.
FUNCTION TogglePause() AS VOID
    IF paused = 1 THEN
        paused = 0
        theView.ShowMessage("")
    ELSE
        paused = 1
        theView.ShowMessage("PAUSED")
    END IF
END FUNCTION

' MARK: - Events

' BASICStudio calls these when something happens outside the program: a
' gamepad button, or the window changing size. Each writes the news down in
' theInbox, for the next frame.

/// Hands a gamepad's change to NotePadControl, which writes it down in theInbox.
///
/// - Parameter event: Which controller, which button or stick direction, and its value.
FUNCTION GamepadChanged(event AS BASICGamepadEvent)
    NotePadControl(event.Controller, event.Control, event.Value)
END FUNCTION

/// Writes the window's new size down in theInbox.
///
/// - Parameter event: The window's new width and height, in pixels.
FUNCTION WindowResized(event AS BASICResizeEvent)
    theInbox.NewWidth = event.Width
    theInbox.NewHeight = event.Height
    theInbox.Resized = 1
END FUNCTION
