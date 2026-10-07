#!/usr/bin/env BASICShell
' {{NAME}} — a game to build on.
'
' Someone to move around, four targets to shoot, and a guard on patrol.
' Point the way and they turn to face it and walk; point harder and they
' run. Let go, or bring the stick back to the middle, and they stop. Fire
' shoots the way they face, and a shot flies until it hits something or
' leaves the floor: a target is a point, the guard is ten. The guard walks
' the edge of the floor clockwise, and a new one sets out from the top two
' seconds after one is hit. Let the guard shoot back, and it is a game.
'
' Touch:   the joystick, bottom right. A little lean walks, all the way runs,
'          and every lean between is a speed of its own. Fire, bottom left.
' Keys:    arrows or W A S D walk, hold Shift to run, Space fires,
'          P pauses, Q quits
' Gamepad: d-pad or left stick walks, hold B to run, A fires, Menu pauses
'
' HOW IT IS PUT TOGETHER
'
' Each thing in the game is an object: it keeps its own numbers, and it
' knows how to move and how to show itself. This file makes them and runs
' the game; the others say what each one is.
'
'     main.bas         the numbers to play with, the things in the game,
'                      and the loop that runs it
'     Characters.bas   Walker, someone who walks, and the two kinds of
'                      walker: the Player and the Guard
'     Shooting.bas     Shots and Targets, and what happens when they meet
'     Screen.bas       the View, which fits the game to the window and
'                      draws the floor and the words; the Controls; and
'                      the Inbox, where events wait for the next frame
'
' An object changes only itself. When two things meet (a shot and the
' guard), it is a plain function that decides what happens to each:
' CheckHits, in Shooting.bas.
'
' Events (a button pressed, the window resized) can arrive at any moment,
' even halfway through moving the player. So they do not change the
' objects: they are written down in theInbox, and the loop acts on them at
' the start of the next frame, when nothing is halfway through.
'
' It draws with lines, circles and vector text only, so it runs
' interpreted in BASICStudio and BASICShell, and compiled with basicc.

IMPORT "Characters.bas"
IMPORT "Shooting.bas"
IMPORT "Screen.bas"

' MARK: - The world

' Everything is placed in a fixed world, 640 by 480, and the View scales it
' to fit the window, so it looks the same at any size.
GLOBAL WORLDWIDTH AS INTEGER = 640
GLOBAL WORLDHEIGHT AS INTEGER = 480
' The floor is ruled in squares this size, so you can see how fast you go.
GLOBAL GRIDSIZE AS INTEGER = 40
' Frames a second to aim for (see View.EndFrame).
GLOBAL FPS AS INTEGER = 30
GLOBAL PI AS DOUBLE = 3.1415927

' MARK: - The numbers to play with

' How big someone is, from the middle to the edge.
GLOBAL WALKERSIZE AS INTEGER = 12
' A walk and a run, in world units a frame. At 30 frames a second a walk
' crosses the world in about 14 seconds, and a run in under 4.
GLOBAL WALKSPEED AS DOUBLE = 1.5
GLOBAL RUNSPEED AS DOUBLE = 6
' The most anyone turns in one frame, in radians: a half turn takes about a
' quarter of a second.
GLOBAL TURNSPEED AS DOUBLE = 0.4
' How far the stick has to lean, out of 1, before it counts. A thumb
' resting on the stick is never quite in the middle.
GLOBAL DEADZONE AS DOUBLE = 0.15

' The guard walks this far in from the walls, at this speed, and comes back
' this long after it is hit.
GLOBAL GUARDMARGIN AS INTEGER = 40
GLOBAL GUARDSPEED AS DOUBLE = 2
GLOBAL RESPAWNSECONDS AS INTEGER = 2

' Shots in the air at once (Shots keeps this many places), and how fast
' they fly.
GLOBAL MAXSHOTS AS INTEGER = 8
GLOBAL SHOTSPEED AS DOUBLE = 10
' Targets on the floor (Targets keeps this many), and how big they are.
GLOBAL TARGETCOUNT AS INTEGER = 4
GLOBAL TARGETSIZE AS INTEGER = 18

' What a hit is worth.
GLOBAL TARGETPOINTS AS INTEGER = 1
GLOBAL GUARDPOINTS AS INTEGER = 10

' MARK: - The things in the game

' One of each, made in Main. A CLASS says what a kind of thing is, and the
' name with "the" in front is the one in this game: Player is what a player
' is, thePlayer is the one you move. (BASIC does not tell capitals from
' small letters, so the two could not both be called player.) GLOBAL so
' the event handlers at the bottom can reach them as well as Main.
GLOBAL theView AS View
GLOBAL theControls AS Controls
GLOBAL thePlayer AS Player
GLOBAL theGuard AS Guard
GLOBAL theShots AS Shots
GLOBAL theTargets AS Targets
GLOBAL score AS INTEGER
GLOBAL playing AS INTEGER
GLOBAL paused AS INTEGER

' What the events have said since the last frame (Inbox, in Screen.bas).
' A TYPE, not a CLASS: a record of values with names and no methods.
GLOBAL theInbox AS Inbox

' The terminal's graphics, and the on-screen controls of an iPad or iPhone.
GLOBAL vtg = VectorTerminal()
GLOBAL touch = TouchControls()

' MARK: - The game

' Make everything, then once a frame until Q: read the controls, move
' everything, settle the hits, draw, and wait for the next frame.
FUNCTION Main() AS VOID
    CLS
    vtg.clear()
    vtg.setDefaultLayer(2)

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
        theControls.ReadKeys()
        IF theInbox.QuitPressed = 1 THEN playing = 0
        IF theInbox.PausePressed = 1 THEN
            theInbox.PausePressed = 0
            TogglePause()
        END IF

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

        theTargets.Render()
        thePlayer.Render()
        IF theGuard.Alive = 1 THEN theGuard.Render()
        theShots.Render()
        theView.ShowScore(score, thePlayer.Speed)
        LOCAL slept = AWAIT SLEEP(theView.EndFrame())
    WEND

    touch.Clear()
    vtg.clear()
    vtg.present()
    CLS
    PRINT "Final score: "; score
END FUNCTION

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

FUNCTION GamepadChanged(event AS BASICGamepadEvent)
    NotePadControl(event.Controller, event.Control, event.Value)
END FUNCTION

FUNCTION WindowResized(event AS BASICResizeEvent)
    theInbox.NewWidth = event.Width
    theInbox.NewHeight = event.Height
    theInbox.Resized = 1
END FUNCTION

' MARK: - Start

ON GAMEPAD CALL GamepadChanged
ON RESIZE CALL WindowResized
Main()
