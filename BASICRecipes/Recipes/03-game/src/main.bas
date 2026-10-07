#!/usr/bin/env BASICShell
' {{NAME}} — a game to build on.
'
' Someone to move around. Point the way and they turn to face it and walk;
' point harder and they run. Let go, or bring the stick back to the middle,
' and they stop. Moving well is the first thing every game needs, so that is
' all this does, small enough to read in one sitting, with a comment saying
' what each part is for. Add something to chase, something to avoid and a
' score, and it is a game.
'
' Touch:   the joystick, bottom left. A little lean walks, all the way runs,
'          and every lean between is a speed of its own (iPad and iPhone).
' Keys:    arrows or W A S D walk, hold Shift to run, P pauses, Q quits
' Gamepad: d-pad or left stick walks, hold B to run, Menu pauses
'
' It draws with lines, circles and vector text only, so it runs
' interpreted in BASICStudio and BASICShell, and compiled with basicc.

' ---------------------------------------------------------------- the world
' Everything is placed in a fixed world, 640 by 480, and scaled to fit the
' window (see FitView), so it looks the same at any size.
GLOBAL WORLDWIDTH AS INTEGER = 640
GLOBAL WORLDHEIGHT AS INTEGER = 480
' The floor is ruled in squares this size, so you can see how fast you go.
GLOBAL GRIDSIZE AS INTEGER = 40
' Frames a second to aim for (see Pace).
GLOBAL FPS AS INTEGER = 30
GLOBAL PI AS DOUBLE = 3.1415927

' ---------------------------------------------------------------- the player
GLOBAL playerX AS DOUBLE
GLOBAL playerY AS DOUBLE
' Which way they face, in radians: 0 is right, PI/2 is down (screen y runs
' down), PI is left and -PI/2 is up.
GLOBAL facing AS DOUBLE
' How fast they are going, in world units a frame. 0 is standing still.
GLOBAL speed AS DOUBLE
' Where the feet are in their stride: once round is a step with each foot.
GLOBAL stride AS DOUBLE

GLOBAL PLAYERSIZE AS INTEGER = 12
' A walk and a run, in world units a frame. At 30 frames a second a walk
' crosses the world in about 14 seconds, and a run in under 4.
GLOBAL WALKSPEED AS DOUBLE = 1.5
GLOBAL RUNSPEED AS DOUBLE = 6
' The most they turn in one frame, in radians: a half turn takes about a
' quarter of a second.
GLOBAL TURNSPEED AS DOUBLE = 0.4
' How far the stick has to lean, out of 1, before it counts. A thumb
' resting on the stick is never quite in the middle.
GLOBAL DEADZONE AS DOUBLE = 0.15

' ---------------------------------------------------------------- input
' What the controls asked for this frame: a way to go (wantX, wantY) and
' how fast. A speed of 0 means stand still.
GLOBAL wantX AS DOUBLE
GLOBAL wantY AS DOUBLE
GLOBAL wantSpeed AS DOUBLE
' The gamepad, as GamepadChanged last heard it.
GLOBAL padLeft AS INTEGER
GLOBAL padRight AS INTEGER
GLOBAL padUp AS INTEGER
GLOBAL padDown AS INTEGER
GLOBAL padRun AS INTEGER
GLOBAL padPause AS INTEGER

' ---------------------------------------------------------------- the game
GLOBAL playing AS INTEGER
GLOBAL paused AS INTEGER
GLOBAL message$ AS STRING
GLOBAL messageDirty AS INTEGER
' The speed line as it was last drawn (see DrawHud).
GLOBAL hud$ AS STRING

' ---------------------------------------------------------------- the view
GLOBAL canvasWidth AS INTEGER
GLOBAL canvasHeight AS INTEGER
GLOBAL viewScale AS DOUBLE
GLOBAL viewX AS DOUBLE
GLOBAL viewY AS DOUBLE
GLOBAL resized AS INTEGER
GLOBAL sceneryDirty AS INTEGER

' ---------------------------------------------------------------- pacing
GLOBAL sleepMs AS DOUBLE = 30
GLOBAL framesThisSecond AS INTEGER
GLOBAL lastSecond$ AS STRING
GLOBAL secondsSeen AS INTEGER

GLOBAL vtg = VectorTerminal()
GLOBAL touch = TouchControls()

' ================================================================= the loop

' Read the controls, move, draw, wait: once a frame, until Q.
FUNCTION Main() AS VOID
    CLS
    vtg.clear()
    vtg.setDefaultLayer(2)
    MeasureCanvas()
    PlaceTouchControls()
    playerX = WORLDWIDTH / 2
    playerY = WORLDHEIGHT / 2
    facing = -PI / 2
    playing = 1

    WHILE playing = 1
        IF resized = 1 THEN
            resized = 0
            FitView()
        END IF
        ReadControls()

        ' A frame is drawn off screen and shown all at once, so nothing
        ' flickers.
        vtg.startFrame("game")
        IF sceneryDirty = 1 THEN DrawScenery()
        IF paused = 0 THEN MovePlayer()
        DrawFrame()
        vtg.endFrame("game")
        vtg.present()

        Pace()
        LOCAL slept = AWAIT SLEEP(INT(sleepMs))
    WEND

    touch.Clear()
    vtg.clear()
    vtg.present()
    CLS
END FUNCTION

FUNCTION ShowMessage(words$ AS STRING) AS VOID
    message$ = words$
    messageDirty = 1
END FUNCTION

FUNCTION TogglePause() AS VOID
    IF paused = 1 THEN
        paused = 0
        ShowMessage("")
    ELSE
        paused = 1
        ShowMessage("PAUSED")
    END IF
END FUNCTION

' ================================================================= controls

' Every control comes down to the same two answers: which way, and how
' fast. The touch joystick says how far it leans, so it can ask for any
' speed from a walk to a run. Keys and gamepad buttons are only on or off,
' so they walk, and run while Shift or B is held.
FUNCTION ReadControls() AS VOID
    wantX = 0
    wantY = 0
    wantSpeed = 0

    ' The touch joystick is asked where it is: X and Y run from -1 to 1,
    ' and 0, 0 is the middle, where it springs back when the finger lifts.
    ' How far it leans is the distance from the middle.
    LOCAL stickX = touch.X("stick")
    LOCAL stickY = touch.Y("stick")
    LOCAL lean = SQR(stickX * stickX + stickY * stickY)
    IF lean > DEADZONE THEN
        wantX = stickX
        wantY = stickY
        wantSpeed = SpeedForLean(lean)
    ELSE
        ' Keys and the gamepad: each direction held adds its part, so two
        ' at once is a diagonal.
        IF KEYDOWN("LEFT") OR KEYDOWN("A") OR padLeft = 1 THEN wantX = wantX - 1
        IF KEYDOWN("RIGHT") OR KEYDOWN("D") OR padRight = 1 THEN wantX = wantX + 1
        IF KEYDOWN("UP") OR KEYDOWN("W") OR padUp = 1 THEN wantY = wantY - 1
        IF KEYDOWN("DOWN") OR KEYDOWN("S") OR padDown = 1 THEN wantY = wantY + 1
        IF wantX <> 0 OR wantY <> 0 THEN
            wantSpeed = WALKSPEED
            IF KEYDOWN("SHIFT") OR padRun = 1 THEN wantSpeed = RUNSPEED
        END IF
    END IF

    ' Presses, as opposed to keys held, come through INKEY$, once each.
    LOCAL key$ = INKEY$()
    WHILE key$ <> ""
        IF key$ = "q" OR key$ = "Q" THEN playing = 0
        IF key$ = "p" OR key$ = "P" THEN TogglePause()
        key$ = INKEY$()
    WEND
    IF padPause = 1 THEN
        padPause = 0
        TogglePause()
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

' A game controller in BASICStudio: every button and stick direction comes
' as its own control, with a value from 0 (let go) to 1 (pressed). A stick's
' directions come as on or off too, so the gamepad walks and runs the way
' the keys do.
FUNCTION GamepadChanged(event AS BASICGamepadEvent)
    LOCAL pressed = 0
    IF event.Value > 0.5 THEN pressed = 1
    LOCAL control$ = event.Control
    IF control$ = "MENU" AND pressed = 1 THEN padPause = 1
    ' The touch joystick reports here as well, as controller -1, but only
    ' as on or off. ReadControls asks it how far it leans instead.
    IF event.Controller <> -1 THEN
        IF control$ = "DPAD_LEFT" OR control$ = "LEFT_STICK_LEFT" THEN padLeft = pressed
        IF control$ = "DPAD_RIGHT" OR control$ = "LEFT_STICK_RIGHT" THEN padRight = pressed
        IF control$ = "DPAD_UP" OR control$ = "LEFT_STICK_UP" THEN padUp = pressed
        IF control$ = "DPAD_DOWN" OR control$ = "LEFT_STICK_DOWN" THEN padDown = pressed
        IF control$ = "B" THEN padRun = pressed
    END IF
END FUNCTION

' On an iPad or iPhone: a joystick bottom left, and a pause button. The
' pause button reports as a gamepad's Menu button, so GamepadChanged reads
' it. Elsewhere these calls do nothing.
FUNCTION PlaceTouchControls() AS VOID
    touch.Joystick("stick", "BOTTOMLEFT", 40, 40, 170)
    touch.Button("pause", "TOPRIGHT", 16, 16, 56, "II", "#64748b", "MENU")
END FUNCTION

FUNCTION WindowResized(event AS BASICResizeEvent)
    canvasWidth = event.Width
    canvasHeight = event.Height
    resized = 1
END FUNCTION

' ================================================================= moving

' Go the way asked for, at the speed asked for, and turn to face it. They
' move the new way at once but turn toward it over a few frames, so a
' change of direction is quick and you still see them turn. No stick and
' no keys is a speed of 0: they stop where they are.
FUNCTION MovePlayer() AS VOID
    speed = wantSpeed
    IF speed = 0 THEN
        stride = 0
    ELSE
        LOCAL way = DirectionOf(wantX, wantY)
        ' The shortest way round, and no more than TURNSPEED in a frame.
        LOCAL turn = Unwind(way - facing)
        IF turn > TURNSPEED THEN turn = TURNSPEED
        IF turn < -TURNSPEED THEN turn = -TURNSPEED
        facing = Unwind(facing + turn)

        ' A direction and a speed make a step: COS gives the part across,
        ' SIN the part down.
        playerX = playerX + COS(way) * speed
        playerY = playerY + SIN(way) * speed

        ' Faster means quicker steps as well as longer ones.
        stride = stride + 0.17 * SQR(speed)
    END IF

    ' The edges of the world are walls.
    playerX = Clamp(playerX, PLAYERSIZE, WORLDWIDTH - PLAYERSIZE)
    playerY = Clamp(playerY, PLAYERSIZE, WORLDHEIGHT - PLAYERSIZE)
END FUNCTION

' The direction from the middle to (x, y), in radians, measured the way
' facing is. ATN alone gives only the right half of the circle, from -PI/2
' to PI/2; a point to the left is half a turn round from that.
FUNCTION DirectionOf(x AS DOUBLE, y AS DOUBLE) AS DOUBLE
    IF x > 0 THEN RETURN ATN(y / x)
    IF x < 0 THEN RETURN Unwind(ATN(y / x) + PI)
    IF y < 0 THEN RETURN -PI / 2
    RETURN PI / 2
END FUNCTION

' The same direction, written between -PI and PI. A turn from just above
' -PI to just below PI is a small one, and this is what makes it come out
' that way rather than nearly a full circle.
FUNCTION Unwind(angle AS DOUBLE) AS DOUBLE
    LOCAL a = angle
    WHILE a > PI
        a = a - 2 * PI
    WEND
    WHILE a < -PI
        a = a + 2 * PI
    WEND
    RETURN a
END FUNCTION

FUNCTION Clamp(amount AS DOUBLE, lowest AS DOUBLE, highest AS DOUBLE) AS DOUBLE
    IF amount < lowest THEN RETURN lowest
    IF amount > highest THEN RETURN highest
    RETURN amount
END FUNCTION

' ================================================================= pacing

' A frame is its work plus a sleep. The work takes longer interpreted than
' compiled, so the sleep is steered: each second, the frames counted in the
' second before say how long a frame really took, and the sleep moves most
' of the way toward making it 1/FPS of a second.
FUNCTION Pace() AS VOID
    framesThisSecond = framesThisSecond + 1
    LOCAL now$ = TIME$()
    IF now$ = lastSecond$ THEN RETURN
    IF secondsSeen >= 2 THEN
        LOCAL took = 1000 / framesThisSecond
        sleepMs = sleepMs + (1000 / FPS - took) * 0.7
        IF sleepMs < 1 THEN sleepMs = 1
        IF sleepMs > 60 THEN sleepMs = 60
    END IF
    secondsSeen = secondsSeen + 1
    lastSecond$ = now$
    framesThisSecond = 0
END FUNCTION

' ================================================================= the view

' The window's size, asked once at the start; ON RESIZE tells us after that.
FUNCTION MeasureCanvas() AS VOID
    LOCAL measured = vtg.queryCurrentCanvas(250)
    IF measured <> EMPTY THEN
        canvasWidth = measured("width")
        canvasHeight = measured("height")
    END IF
    FitView()
END FUNCTION

' The world, as large as fits, in the middle of the window.
FUNCTION FitView() AS VOID
    IF canvasWidth < 320 OR canvasHeight < 240 THEN
        canvasWidth = WORLDWIDTH
        canvasHeight = WORLDHEIGHT
    END IF
    viewScale = canvasWidth / WORLDWIDTH
    IF canvasHeight / WORLDHEIGHT < viewScale THEN viewScale = canvasHeight / WORLDHEIGHT
    viewX = (canvasWidth - WORLDWIDTH * viewScale) / 2
    viewY = (canvasHeight - WORLDHEIGHT * viewScale) / 2
    sceneryDirty = 1
END FUNCTION

' World positions to window pixels. VTG wants whole numbers, so these round.
FUNCTION PixelX(x AS DOUBLE) AS INTEGER
    RETURN INT(viewX + x * viewScale)
END FUNCTION

FUNCTION PixelY(y AS DOUBLE) AS INTEGER
    RETURN INT(viewY + y * viewScale)
END FUNCTION

FUNCTION PixelLength(length AS DOUBLE) AS INTEGER
    LOCAL scaled = INT(length * viewScale + 0.5)
    IF scaled < 1 THEN scaled = 1
    RETURN scaled
END FUNCTION

' ================================================================= drawing
'
' Shapes are kept by the terminal under an id: drawing an id again moves it,
' and vtg.delete takes it away. Layer 1 is the floor, 2 the feet, 3 the
' body, 4 the nose and the words.

' The floor: at the start, and when the window changes size.
FUNCTION DrawScenery() AS VOID
    sceneryDirty = 0
    vtg.clear()
    vtg.rect("floor", 0, 0, canvasWidth, canvasHeight, "none", "#000000", 0, 0, "", "", 1)
    LOCAL x = 0
    FOR x = GRIDSIZE TO WORLDWIDTH - GRIDSIZE STEP GRIDSIZE
        vtg.line("across" + Num$(x), PixelX(x), PixelY(0), PixelX(x), PixelY(WORLDHEIGHT), "#1e293b", 1, "", 1)
    NEXT x
    LOCAL y = 0
    FOR y = GRIDSIZE TO WORLDHEIGHT - GRIDSIZE STEP GRIDSIZE
        vtg.line("down" + Num$(y), PixelX(0), PixelY(y), PixelX(WORLDWIDTH), PixelY(y), "#1e293b", 1, "", 1)
    NEXT y
    vtg.rect("edge", PixelX(0), PixelY(0), PixelLength(WORLDWIDTH), PixelLength(WORLDHEIGHT), "#475569", "none", PixelLength(2), 0, "", "", 1)

    LOCAL hint$ = "ARROWS OR WASD WALK - SHIFT RUNS - P PAUSES"
    IF touch.Available THEN hint$ = "LEAN THE STICK - A LITTLE WALKS - ALL THE WAY RUNS"
    vtg.vectorPrint("hint", PixelX(16), PixelY(WORLDHEIGHT - 24), PixelLength(10), hint$, "#64748b", PixelLength(1), 4)
    hud$ = ""
    messageDirty = 1
END FUNCTION

' Everything that moves, every frame; the words only when they change.
FUNCTION DrawFrame() AS VOID
    DrawPlayer()
    DrawHud()
    IF messageDirty = 1 THEN DrawMessage()
END FUNCTION

' Seen from above: two feet that swing as they go, a round body over them,
' and a nose on the side they face.
FUNCTION DrawPlayer() AS VOID
    ' Out to each side: a quarter turn from the way they face.
    LOCAL sideX = COS(facing + PI / 2) * 9
    LOCAL sideY = SIN(facing + PI / 2) * 9
    ' How far a foot is ahead (or, for the other foot, behind): it swings
    ' with the stride, and further at a run.
    LOCAL swing = SIN(stride) * (1 + speed * 1.5)
    LOCAL aheadX = COS(facing) * swing
    LOCAL aheadY = SIN(facing) * swing
    LOCAL foot = PixelLength(5)
    vtg.circle("footLeft", PixelX(playerX + sideX + aheadX), PixelY(playerY + sideY + aheadY), foot, "none", "#94a3b8", 0, 2)
    vtg.circle("footRight", PixelX(playerX - sideX - aheadX), PixelY(playerY - sideY - aheadY), foot, "none", "#94a3b8", 0, 2)

    vtg.circle("body", PixelX(playerX), PixelY(playerY), PixelLength(PLAYERSIZE), "#bfdbfe", "#2563eb", PixelLength(2), 3)
    LOCAL noseX = playerX + COS(facing) * PLAYERSIZE
    LOCAL noseY = playerY + SIN(facing) * PLAYERSIZE
    vtg.circle("nose", PixelX(noseX), PixelY(noseY), PixelLength(4), "none", "#facc15", 0, 4)
END FUNCTION

' How fast, in world units a second, and what that is called. From the
' middle of the stick's scale up, twice a walk, it counts as a run. Drawn
' only when it changes: vector text takes longer to draw than a circle.
FUNCTION DrawHud() AS VOID
    LOCAL gait$ = "STANDING"
    IF speed > 0 THEN gait$ = "WALKING"
    IF speed >= 2 * WALKSPEED THEN gait$ = "RUNNING"
    LOCAL words$ = "SPEED " + Num$(INT(speed * FPS + 0.5)) + "  " + gait$
    IF words$ = hud$ THEN RETURN
    hud$ = words$
    vtg.vectorPrint("hud", PixelX(16), PixelY(12), PixelLength(14), words$, "#f8fafc", PixelLength(1), 4)
END FUNCTION

' The message in the middle, or none. Vector text is erased by printing
' nothing over it.
FUNCTION DrawMessage() AS VOID
    messageDirty = 0
    IF message$ = "" THEN
        vtg.vectorPrint("message", 0, 0, 10, "", "#000000", 1, 4)
        RETURN
    END IF
    LOCAL height = PixelLength(20)
    vtg.vectorPrint("message", PixelX(WORLDWIDTH / 2) - LEN(message$) * height / 2, PixelY(WORLDHEIGHT / 2 - 10), height, message$, "#facc15", PixelLength(2), 4)
END FUNCTION

' A whole number with no space in front, where STR$ leaves one.
FUNCTION Num$(value AS INTEGER) AS STRING
    LOCAL digits$ = STR$(value)
    IF LEFT$(digits$, 1) = " " THEN RETURN MID$(digits$, 2)
    RETURN digits$
END FUNCTION

' ================================================================= start
ON GAMEPAD CALL GamepadChanged
ON RESIZE CALL WindowResized
Main()
