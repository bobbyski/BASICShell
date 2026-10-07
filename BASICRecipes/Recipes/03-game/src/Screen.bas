' Screen.bas — what is on the screen, and the controls.
'
' The View fits the game's fixed world to the window, draws the floor and
' the words, and keeps the frames coming at an even pace. The Controls
' turn the keys, a gamepad, and the on-screen joystick and buttons into
' the few things the game asks: which way, how fast, and was Fire pressed.
' The Inbox is where events write down what happened until the next frame.

' MARK: - Inbox

TYPE Inbox
    ' Presses waiting for the next frame. Presses arrive as events, so even
    ' a tap too quick for a frame to see is kept, and holding a button down
    ' is one press. The loop sets each back to 0 once it has used it.
    FirePressed AS INTEGER
    PausePressed AS INTEGER
    QuitPressed AS INTEGER
    ' The gamepad, as its events last said: 1 while a direction is held.
    PadLeft AS INTEGER
    PadRight AS INTEGER
    PadUp AS INTEGER
    PadDown AS INTEGER
    PadRun AS INTEGER
    ' The window's new size, when it has changed.
    Resized AS INTEGER
    NewWidth AS INTEGER
    NewHeight AS INTEGER
END TYPE

' MARK: - View

CLASS View
    ' The window's size in pixels, and how the world fits in it: Scale
    ' pixels to a world unit, and the world's top left at (OffsetX, OffsetY).
    PUBLIC CanvasWidth AS INTEGER
    PUBLIC CanvasHeight AS INTEGER
    PUBLIC Scale AS DOUBLE
    PUBLIC OffsetX AS DOUBLE
    PUBLIC OffsetY AS DOUBLE
    ' Set when the floor needs drawing.
    PUBLIC NeedsFloor AS INTEGER
    ' The words as last drawn, so they are drawn again only when they change:
    ' vector text takes longer to draw than a circle.
    PUBLIC Hud$ AS STRING
    PUBLIC Message$ AS STRING
    PUBLIC MessageChanged AS INTEGER
    ' Pacing: how long to sleep after each frame, steered once a second.
    PUBLIC SleepMs AS DOUBLE
    PUBLIC FramesThisSecond AS INTEGER
    PUBLIC LastSecond$ AS STRING
    PUBLIC SecondsSeen AS INTEGER

    ' The window's size, asked once at the start; theInbox hears after that.
    FUNCTION Measure() AS VOID
        ME.SleepMs = 30
        LOCAL measured AS VARIANT = vtg.queryCurrentCanvas(250)
        IF measured <> EMPTY THEN
            ME.CanvasWidth = measured("width")
            ME.CanvasHeight = measured("height")
        END IF
        ME.Fit()
    END FUNCTION

    ' The world, as large as fits, in the middle of the window.
    FUNCTION Fit() AS VOID
        IF ME.CanvasWidth < 320 OR ME.CanvasHeight < 240 THEN
            ME.CanvasWidth = WORLDWIDTH
            ME.CanvasHeight = WORLDHEIGHT
        END IF
        ME.Scale = ME.CanvasWidth / WORLDWIDTH
        IF ME.CanvasHeight / WORLDHEIGHT < ME.Scale THEN ME.Scale = ME.CanvasHeight / WORLDHEIGHT
        ME.OffsetX = (ME.CanvasWidth - WORLDWIDTH * ME.Scale) / 2
        ME.OffsetY = (ME.CanvasHeight - WORLDHEIGHT * ME.Scale) / 2
        ME.NeedsFloor = 1
    END FUNCTION

    ' World positions and lengths to window pixels. VTG wants whole
    ' numbers, so these round.
    FUNCTION PixelX(x AS DOUBLE) AS INTEGER
        RETURN INT(ME.OffsetX + x * ME.Scale)
    END FUNCTION

    FUNCTION PixelY(y AS DOUBLE) AS INTEGER
        RETURN INT(ME.OffsetY + y * ME.Scale)
    END FUNCTION

    FUNCTION Pixels(amount AS DOUBLE) AS INTEGER
        LOCAL scaled = INT(amount * ME.Scale + 0.5)
        IF scaled < 1 THEN scaled = 1
        RETURN scaled
    END FUNCTION

    ' A frame is drawn off screen and shown all at once, so nothing
    ' flickers. It starts here: fitting the world again if the window has
    ' changed size, and drawing the floor when it needs it.
    FUNCTION StartFrame() AS VOID
        IF theInbox.Resized = 1 THEN
            theInbox.Resized = 0
            ME.CanvasWidth = theInbox.NewWidth
            ME.CanvasHeight = theInbox.NewHeight
            ME.Fit()
        END IF
        vtg.startFrame("game")
        IF ME.NeedsFloor = 1 THEN ME.LayFloor()
    END FUNCTION

    ' The floor, ruled in squares, its edge, and a hint for the controls.
    ' Shapes are kept by the terminal under a name: drawing a name again
    ' moves it, and vtg.delete takes it away. Layer 1 is the floor, 2 the
    ' targets and the feet, 3 the bodies and the shots, 4 the noses and the
    ' words.
    FUNCTION LayFloor() AS VOID
        ME.NeedsFloor = 0
        vtg.clear()
        vtg.rect("floor", 0, 0, ME.CanvasWidth, ME.CanvasHeight, "none", "#000000", 0, 0, "", "", 1)
        LOCAL x = 0
        FOR x = GRIDSIZE TO WORLDWIDTH - GRIDSIZE STEP GRIDSIZE
            vtg.line("across" + Num$(x), ME.PixelX(x), ME.PixelY(0), ME.PixelX(x), ME.PixelY(WORLDHEIGHT), "#1e293b", 1, "", 1)
        NEXT x
        LOCAL y = 0
        FOR y = GRIDSIZE TO WORLDHEIGHT - GRIDSIZE STEP GRIDSIZE
            vtg.line("down" + Num$(y), ME.PixelX(0), ME.PixelY(y), ME.PixelX(WORLDWIDTH), ME.PixelY(y), "#1e293b", 1, "", 1)
        NEXT y
        vtg.rect("edge", ME.PixelX(0), ME.PixelY(0), ME.Pixels(WORLDWIDTH), ME.Pixels(WORLDHEIGHT), "#475569", "none", ME.Pixels(2), 0, "", "", 1)

        LOCAL hint$ = "ARROWS OR WASD WALK - SHIFT RUNS - SPACE FIRES"
        IF touch.Available THEN hint$ = "A LITTLE LEAN WALKS - ALL THE WAY RUNS"
        vtg.vectorPrint("hint", ME.PixelX(16), ME.PixelY(WORLDHEIGHT - 24), ME.Pixels(10), hint$, "#64748b", ME.Pixels(1), 4)
        ' Everything on the floor was cleared with it: draw the words again.
        ME.Hud$ = ""
        ME.MessageChanged = 1
    END FUNCTION

    ' The score, the speed in world units a second, and what that is called.
    ' From twice a walk up, it counts as a run.
    FUNCTION ShowScore(points AS INTEGER, speed AS DOUBLE) AS VOID
        LOCAL gait$ = "STANDING"
        IF speed > 0 THEN gait$ = "WALKING"
        IF speed >= 2 * WALKSPEED THEN gait$ = "RUNNING"
        LOCAL words$ = "SCORE " + Num$(points) + "   SPEED " + Num$(INT(speed * FPS + 0.5)) + "  " + gait$
        IF words$ <> ME.Hud$ THEN
            ME.Hud$ = words$
            vtg.vectorPrint("hud", ME.PixelX(16), ME.PixelY(12), ME.Pixels(14), words$, "#f8fafc", ME.Pixels(1), 4)
        END IF
        IF ME.MessageChanged = 1 THEN ME.DrawMessage()
    END FUNCTION

    ' Words in the middle of the floor, such as PAUSED; "" for none.
    FUNCTION ShowMessage(words$ AS STRING) AS VOID
        ME.Message$ = words$
        ME.MessageChanged = 1
    END FUNCTION

    ' Vector text is erased by printing nothing over it.
    FUNCTION DrawMessage() AS VOID
        ME.MessageChanged = 0
        IF ME.Message$ = "" THEN
            vtg.vectorPrint("message", 0, 0, 10, "", "#000000", 1, 4)
            RETURN
        END IF
        LOCAL height = ME.Pixels(20)
        vtg.vectorPrint("message", ME.PixelX(WORLDWIDTH / 2) - LEN(ME.Message$) * height / 2, ME.PixelY(WORLDHEIGHT / 2 - 10), height, ME.Message$, "#facc15", ME.Pixels(2), 4)
    END FUNCTION

    ' Shows the frame, and answers how long to sleep before the next one.
    '
    ' A frame is its work plus a sleep. The work takes longer interpreted
    ' than compiled, so the sleep is steered: each second, the frames counted
    ' in the second before say how long a frame really took, and the sleep
    ' moves most of the way toward making it 1/FPS of a second.
    FUNCTION EndFrame() AS INTEGER
        vtg.endFrame("game")
        vtg.present()
        ME.FramesThisSecond = ME.FramesThisSecond + 1
        LOCAL now$ = TIME$()
        IF now$ <> ME.LastSecond$ THEN
            IF ME.SecondsSeen >= 2 THEN
                LOCAL took = 1000 / ME.FramesThisSecond
                ME.SleepMs = ME.SleepMs + (1000 / FPS - took) * 0.7
                IF ME.SleepMs < 1 THEN ME.SleepMs = 1
                IF ME.SleepMs > 60 THEN ME.SleepMs = 60
            END IF
            ME.SecondsSeen = ME.SecondsSeen + 1
            ME.LastSecond$ = now$
            ME.FramesThisSecond = 0
        END IF
        RETURN INT(ME.SleepMs)
    END FUNCTION
END CLASS

' MARK: - Controls

CLASS Controls
    ' What the controls ask for this frame: a way to go (WantX, WantY) and
    ' how fast. A speed of 0 means stand still.
    PUBLIC WantX AS DOUBLE
    PUBLIC WantY AS DOUBLE
    PUBLIC WantSpeed AS DOUBLE

    ' On an iPad or iPhone: the joystick under the right thumb, Fire under
    ' the left, and a pause button. Fire and pause report as a gamepad's A
    ' and Menu buttons, so NotePadControl hears them. Elsewhere these calls
    ' do nothing.
    FUNCTION PlaceOnScreen() AS VOID
        touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 170)
        touch.Button("fire", "BOTTOMLEFT", 50, 50, 100, "FIRE", "#ff3b30")
        touch.Button("pause", "TOPRIGHT", 16, 16, 56, "II", "#64748b", "MENU")
    END FUNCTION

    ' Every control comes down to the same two answers: which way, and how
    ' fast. The touch joystick says how far it leans, so it can ask for any
    ' speed from a walk to a run. Keys and gamepad buttons are only on or
    ' off, so they walk, and run while Shift or B is held.
    FUNCTION ReadKeys() AS VOID
        ME.WantX = 0
        ME.WantY = 0
        ME.WantSpeed = 0

        ' The touch joystick is asked where it is: X and Y run from -1 to 1,
        ' and 0, 0 is the middle, where it springs back when the finger
        ' lifts. How far it leans is the distance from the middle.
        LOCAL stickX = touch.X("stick")
        LOCAL stickY = touch.Y("stick")
        LOCAL lean = SQR(stickX * stickX + stickY * stickY)
        IF lean > DEADZONE THEN
            ME.WantX = stickX
            ME.WantY = stickY
            ME.WantSpeed = SpeedForLean(lean)
        ELSE
            ' Keys and the gamepad: each direction held adds its part, so
            ' two at once is a diagonal.
            IF KEYDOWN("LEFT") OR KEYDOWN("A") OR theInbox.PadLeft = 1 THEN ME.WantX = ME.WantX - 1
            IF KEYDOWN("RIGHT") OR KEYDOWN("D") OR theInbox.PadRight = 1 THEN ME.WantX = ME.WantX + 1
            IF KEYDOWN("UP") OR KEYDOWN("W") OR theInbox.PadUp = 1 THEN ME.WantY = ME.WantY - 1
            IF KEYDOWN("DOWN") OR KEYDOWN("S") OR theInbox.PadDown = 1 THEN ME.WantY = ME.WantY + 1
            IF ME.WantX <> 0 OR ME.WantY <> 0 THEN
                ME.WantSpeed = WALKSPEED
                IF KEYDOWN("SHIFT") OR theInbox.PadRun = 1 THEN ME.WantSpeed = RUNSPEED
            END IF
        END IF

        ' Presses, as opposed to keys held, come through INKEY$, once each,
        ' and go in the inbox with the gamepad's.
        LOCAL key$ = INKEY$()
        WHILE key$ <> ""
            IF key$ = " " THEN theInbox.FirePressed = 1
            IF key$ = "p" OR key$ = "P" THEN theInbox.PausePressed = 1
            IF key$ = "q" OR key$ = "Q" THEN theInbox.QuitPressed = 1
            key$ = INKEY$()
        WEND
    END FUNCTION
END CLASS

' A game controller: every button and stick direction comes as its own
' control, with a value from 0 (let go) to 1 (pressed), and is written down
' in theInbox. The touch joystick reports here as well, as controller -1,
' but only as on or off; ReadKeys asks it how far it leans instead.
FUNCTION NotePadControl(controller AS INTEGER, control$ AS STRING, value AS DOUBLE) AS VOID
    LOCAL pressed = 0
    IF value > 0.5 THEN pressed = 1
    IF control$ = "MENU" AND pressed = 1 THEN theInbox.PausePressed = 1
    ' A, or the touch Fire button, which reports as A: a press fires.
    IF (control$ = "A" OR control$ = "RIGHT_TRIGGER") AND pressed = 1 THEN theInbox.FirePressed = 1
    IF controller <> -1 THEN
        IF control$ = "DPAD_LEFT" OR control$ = "LEFT_STICK_LEFT" THEN theInbox.PadLeft = pressed
        IF control$ = "DPAD_RIGHT" OR control$ = "LEFT_STICK_RIGHT" THEN theInbox.PadRight = pressed
        IF control$ = "DPAD_UP" OR control$ = "LEFT_STICK_UP" THEN theInbox.PadUp = pressed
        IF control$ = "DPAD_DOWN" OR control$ = "LEFT_STICK_DOWN" THEN theInbox.PadDown = pressed
        IF control$ = "B" THEN theInbox.PadRun = pressed
    END IF
END FUNCTION

' How far the stick leans picks a speed between a walk and a run, on a
' scale that is even in the logarithm of the speed rather than in the speed
' itself: every step of lean multiplies the speed by the same amount. With
' a run four times a walk:
'
'     lean    0.15 (just past the dead zone)   0.575 (halfway)    1 (all the way)
'     speed   1.5, a walk                      3, twice a walk    6, a run
'
' In a straight line, halfway would already be 3.75, most of a run. Spread
' this way, more of the stick is spent at the slow end, where small changes
' show and fine control matters.
FUNCTION SpeedForLean(lean AS DOUBLE) AS DOUBLE
    IF lean <= DEADZONE THEN RETURN 0
    LOCAL t = (lean - DEADZONE) / (1 - DEADZONE)
    IF t > 1 THEN t = 1
    RETURN EXP(LOG(WALKSPEED) + t * (LOG(RUNSPEED) - LOG(WALKSPEED)))
END FUNCTION

' A whole number with no space in front, where STR$ leaves one.
FUNCTION Num$(value AS INTEGER) AS STRING
    LOCAL digits$ = STR$(value)
    IF LEFT$(digits$, 1) = " " THEN RETURN MID$(digits$, 2)
    RETURN digits$
END FUNCTION
