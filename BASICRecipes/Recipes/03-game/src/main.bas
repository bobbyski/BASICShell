#!/usr/bin/env BASICShell
' {{NAME}} — a game to build on.
'
' A ship that turns, thrusts and fires, and a rock to shoot. Hit the rock
' for points and it jumps somewhere else; let it hit you and you lose a
' ship. That is all there is to it: every part a game needs is here, small,
' with a comment saying what it is for, ready to grow into your own game.
'
' Keys:    Left / Right turn   Up thrusts   Space fires
'          P pauses   Q quits   Enter plays again once the game is over
' Gamepad: d-pad or left stick turns and thrusts, A fires, Menu pauses
' Touch:   a joystick on the right, Fire on the left (iPad and iPhone)
'
' It draws with lines, rectangles, circles and vector text only, so it runs
' interpreted in BASICStudio and BASICShell, and compiled with basicc.

' ---------------------------------------------------------------- the world
' Everything is placed in a fixed world, 640 by 480, and scaled to fit the
' window (see FitView), so the game looks the same at any size.
GLOBAL WORLDWIDTH AS INTEGER = 640
GLOBAL WORLDHEIGHT AS INTEGER = 480
' Frames a second to aim for (see Pace).
GLOBAL FPS AS INTEGER = 30
GLOBAL PI AS DOUBLE = 3.1415927

' ---------------------------------------------------------------- the ship
GLOBAL shipX AS DOUBLE
GLOBAL shipY AS DOUBLE
GLOBAL shipVX AS DOUBLE
GLOBAL shipVY AS DOUBLE
' Which way the nose points, in radians: 0 is right, -PI/2 is up.
GLOBAL shipAngle AS DOUBLE
' Frames left of the blinking start of a new ship, when it cannot be hit.
GLOBAL safeFrames AS INTEGER

GLOBAL TURNSPEED AS DOUBLE = 0.12
GLOBAL THRUSTPOWER AS DOUBLE = 0.25
GLOBAL TOPSPEED AS DOUBLE = 6

' ---------------------------------------------------------------- shots
' A few shots in the air at once, each with a life that runs out.
GLOBAL MAXSHOTS AS INTEGER = 4
GLOBAL SHOTSPEED AS DOUBLE = 9
GLOBAL SHOTFRAMES AS INTEGER = 40
GLOBAL shotLife(4) AS INTEGER
GLOBAL shotX(4) AS DOUBLE
GLOBAL shotY(4) AS DOUBLE
GLOBAL shotVX(4) AS DOUBLE
GLOBAL shotVY(4) AS DOUBLE
GLOBAL fireWait AS INTEGER

' ---------------------------------------------------------------- the rock
' One thing to shoot: it drifts, wraps at the edges like the ship, and
' jumps somewhere else when it is hit.
GLOBAL rockX AS DOUBLE
GLOBAL rockY AS DOUBLE
GLOBAL rockVX AS DOUBLE
GLOBAL rockVY AS DOUBLE
GLOBAL ROCKSIZE AS INTEGER = 26

' ---------------------------------------------------------------- the game
GLOBAL score AS INTEGER
GLOBAL highScore AS INTEGER
GLOBAL lives AS INTEGER
GLOBAL running AS INTEGER
GLOBAL paused AS INTEGER
GLOBAL gameOver AS INTEGER
GLOBAL hudDirty AS INTEGER
GLOBAL message$ AS STRING
GLOBAL messageDirty AS INTEGER

' ---------------------------------------------------------------- input
' What the keys, gamepad and touch controls asked for this frame.
GLOBAL turning AS INTEGER
GLOBAL thrusting AS INTEGER
GLOBAL fireHeld AS INTEGER
' The gamepad, as GamepadChanged last heard it. The touch controls report
' through the same events, so they need nothing of their own.
GLOBAL padLeft AS INTEGER
GLOBAL padRight AS INTEGER
GLOBAL padUp AS INTEGER
GLOBAL padFire AS INTEGER
GLOBAL padPause AS INTEGER

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

' ================================================================= the game loop

' Read the controls, move everything, look for hits, draw, wait: once a
' frame, until Q.
FUNCTION Main() AS VOID
    CLS
    vtg.clear()
    vtg.setDefaultLayer(2)
    SetUpSounds()
    MeasureCanvas()
    PlaceTouchControls()
    NewGame()

    WHILE running = 1
        IF resized = 1 THEN
            resized = 0
            FitView()
        END IF
        ReadControls()

        ' A frame is drawn off screen and shown all at once, so nothing
        ' flickers.
        vtg.startFrame("game")
        IF sceneryDirty = 1 THEN DrawScenery()
        IF paused = 0 AND gameOver = 0 THEN
            MoveShip()
            MoveShots()
            MoveRock()
            CheckHits()
        END IF
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
    PRINT "Final score: "; score
END FUNCTION

FUNCTION NewGame() AS VOID
    score = 0
    lives = 3
    gameOver = 0
    paused = 0
    running = 1
    NewShip()
    PlaceRock()
    ShowMessage("")
    hudDirty = 1
END FUNCTION

' Points, and the best so far.
FUNCTION AddScore(points AS INTEGER) AS VOID
    score = score + points
    IF score > highScore THEN highScore = score
    hudDirty = 1
END FUNCTION

FUNCTION ShowMessage(words$ AS STRING) AS VOID
    message$ = words$
    messageDirty = 1
END FUNCTION

' ================================================================= controls

' Held keys are read with KEYDOWN, every frame; presses with INKEY$, which
' hands over each key once.
FUNCTION ReadControls() AS VOID
    turning = 0
    IF KEYDOWN("LEFT") OR padLeft = 1 THEN turning = turning - 1
    IF KEYDOWN("RIGHT") OR padRight = 1 THEN turning = turning + 1
    thrusting = 0
    IF KEYDOWN("UP") OR padUp = 1 THEN thrusting = 1
    fireHeld = 0
    IF KEYDOWN("SPACE") OR padFire = 1 THEN fireHeld = 1

    LOCAL key$ = INKEY$()
    WHILE key$ <> ""
        IF key$ = "q" OR key$ = "Q" THEN running = 0
        IF key$ = "p" OR key$ = "P" THEN TogglePause()
        IF gameOver = 1 AND (key$ = CHR$(13) OR key$ = CHR$(10)) THEN NewGame()
        key$ = INKEY$()
    WEND
    IF padPause = 1 THEN
        padPause = 0
        TogglePause()
    END IF
    IF gameOver = 1 AND padFire = 1 THEN NewGame()
END FUNCTION

' A game controller in BASICStudio: every button and stick direction comes
' as its own control, with a value from 0 (let go) to 1 (pressed).
FUNCTION GamepadChanged(event AS BASICGamepadEvent)
    LOCAL pressed = 0
    IF event.Value > 0.5 THEN pressed = 1
    LOCAL control$ = event.Control
    IF control$ = "DPAD_LEFT" OR control$ = "LEFT_STICK_LEFT" THEN padLeft = pressed
    IF control$ = "DPAD_RIGHT" OR control$ = "LEFT_STICK_RIGHT" THEN padRight = pressed
    IF control$ = "DPAD_UP" OR control$ = "LEFT_STICK_UP" THEN padUp = pressed
    IF control$ = "A" OR control$ = "RIGHT_TRIGGER" THEN padFire = pressed
    IF control$ = "MENU" AND pressed = 1 THEN padPause = 1
END FUNCTION

' On an iPad or iPhone: a joystick on the right and Fire on the left. They
' report as a gamepad would (LEFT_STICK_…, A), so GamepadChanged reads them.
' Elsewhere these calls do nothing.
FUNCTION PlaceTouchControls() AS VOID
    touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
    touch.Button("fire", "BOTTOMLEFT", 40, 40, 100, "FIRE", "#ff3b30")
    touch.Button("pause", "TOPRIGHT", 16, 16, 56, "II", "#64748b", "MENU")
END FUNCTION

FUNCTION TogglePause() AS VOID
    IF gameOver = 1 THEN RETURN
    IF paused = 1 THEN
        paused = 0
        ShowMessage("")
    ELSE
        paused = 1
        ShowMessage("PAUSED")
    END IF
END FUNCTION

FUNCTION WindowResized(event AS BASICResizeEvent)
    canvasWidth = event.Width
    canvasHeight = event.Height
    resized = 1
END FUNCTION

' ================================================================= moving

FUNCTION NewShip() AS VOID
    shipX = WORLDWIDTH / 2
    shipY = WORLDHEIGHT / 2
    shipVX = 0
    shipVY = 0
    shipAngle = -PI / 2
    safeFrames = 60
END FUNCTION

' Turn, thrust, coast, wrap at the edges, and fire.
FUNCTION MoveShip() AS VOID
    shipAngle = shipAngle + turning * TURNSPEED
    IF thrusting = 1 THEN
        shipVX = shipVX + COS(shipAngle) * THRUSTPOWER
        shipVY = shipVY + SIN(shipAngle) * THRUSTPOWER
    END IF
    ' A little drag, so the ship slows when you let go, and a top speed.
    shipVX = shipVX * 0.99
    shipVY = shipVY * 0.99
    LOCAL speed = SQR(shipVX * shipVX + shipVY * shipVY)
    IF speed > TOPSPEED THEN
        shipVX = shipVX / speed * TOPSPEED
        shipVY = shipVY / speed * TOPSPEED
    END IF
    shipX = WrapX(shipX + shipVX)
    shipY = WrapY(shipY + shipVY)
    IF safeFrames > 0 THEN safeFrames = safeFrames - 1

    IF fireWait > 0 THEN fireWait = fireWait - 1
    IF fireHeld = 1 AND fireWait = 0 THEN
        Fire()
        fireWait = 8
    END IF
END FUNCTION

' A shot from the nose, in the way the ship points, plus the ship's speed.
FUNCTION Fire() AS VOID
    LOCAL s = 0
    FOR s = 0 TO MAXSHOTS - 1
        IF shotLife(s) = 0 THEN
            shotLife(s) = SHOTFRAMES
            shotX(s) = shipX + COS(shipAngle) * 14
            shotY(s) = shipY + SIN(shipAngle) * 14
            shotVX(s) = shipVX + COS(shipAngle) * SHOTSPEED
            shotVY(s) = shipVY + SIN(shipAngle) * SHOTSPEED
            SoundShot()
            RETURN
        END IF
    NEXT s
END FUNCTION

FUNCTION MoveShots() AS VOID
    LOCAL s = 0
    FOR s = 0 TO MAXSHOTS - 1
        IF shotLife(s) > 0 THEN
            shotX(s) = WrapX(shotX(s) + shotVX(s))
            shotY(s) = WrapY(shotY(s) + shotVY(s))
            shotLife(s) = shotLife(s) - 1
            IF shotLife(s) = 0 THEN vtg.delete("shot" + Num$(s))
        END IF
    NEXT s
END FUNCTION

' Somewhere away from the ship, drifting a random way.
FUNCTION PlaceRock() AS VOID
    rockX = WrapX(shipX + WORLDWIDTH / 2 + (RND() - 0.5) * 200)
    rockY = WrapY(shipY + WORLDHEIGHT / 2 + (RND() - 0.5) * 200)
    LOCAL heading = RND() * 2 * PI
    rockVX = COS(heading) * 1.5
    rockVY = SIN(heading) * 1.5
END FUNCTION

FUNCTION MoveRock() AS VOID
    rockX = WrapX(rockX + rockVX)
    rockY = WrapY(rockY + rockVY)
END FUNCTION

' Off one edge, on at the other.
FUNCTION WrapX(x AS DOUBLE) AS DOUBLE
    IF x < 0 THEN RETURN x + WORLDWIDTH
    IF x >= WORLDWIDTH THEN RETURN x - WORLDWIDTH
    RETURN x
END FUNCTION

FUNCTION WrapY(y AS DOUBLE) AS DOUBLE
    IF y < 0 THEN RETURN y + WORLDHEIGHT
    IF y >= WORLDHEIGHT THEN RETURN y - WORLDHEIGHT
    RETURN y
END FUNCTION

' ================================================================= hits

' A shot on the rock scores; the rock on the ship costs a ship.
FUNCTION CheckHits() AS VOID
    LOCAL s = 0
    FOR s = 0 TO MAXSHOTS - 1
        IF shotLife(s) > 0 THEN
            IF Distance(shotX(s), shotY(s), rockX, rockY) < ROCKSIZE THEN
                shotLife(s) = 0
                vtg.delete("shot" + Num$(s))
                AddScore(100)
                SoundHit()
                PlaceRock()
            END IF
        END IF
    NEXT s
    IF safeFrames = 0 AND Distance(shipX, shipY, rockX, rockY) < ROCKSIZE + 8 THEN LoseShip()
END FUNCTION

FUNCTION LoseShip() AS VOID
    SoundCrash()
    lives = lives - 1
    hudDirty = 1
    IF lives <= 0 THEN
        gameOver = 1
        ShowMessage("GAME OVER - ENTER PLAYS AGAIN")
        RETURN
    END IF
    NewShip()
    PlaceRock()
END FUNCTION

FUNCTION Distance(x1 AS DOUBLE, y1 AS DOUBLE, x2 AS DOUBLE, y2 AS DOUBLE) AS DOUBLE
    RETURN SQR((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
END FUNCTION

' ================================================================= sound

' The BBC Micro's ENVELOPE and SOUND. An envelope shapes a sound's pitch and
' loudness over time; SOUND plays a note on a channel through one. Adding 16
' to the channel cuts off whatever it was playing. Channel 0 is noise.
'
'   ENVELOPE n, step, pitch changes x3, step counts x3,
'            attack, decay, sustain, release, attack level, decay level
FUNCTION SetUpSounds() AS VOID
    ' The shot: a quick zip down.
    ENVELOPE 1, 1, -10, 0, 0, 6, 0, 0, 126, -16, 0, -126, 110, 0
    ' A crack of noise, for a hit or a crash.
    ENVELOPE 2, 2, 0, 0, 0, 0, 0, 0, 126, -12, 0, -126, 110, 0
END FUNCTION

FUNCTION SoundShot() AS VOID
    SOUND 17, 1, 170, 2
END FUNCTION

FUNCTION SoundHit() AS VOID
    SOUND 16, 2, 6, 4
END FUNCTION

FUNCTION SoundCrash() AS VOID
    SOUND 16, 2, 3, 12
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
' and vtg.delete takes it away. Layer 1 is the background, 2 the shots, 3
' the ship and rock, 4 the words.

' The background: at the start, and when the window changes size.
FUNCTION DrawScenery() AS VOID
    sceneryDirty = 0
    vtg.clear()
    vtg.rect("space", 0, 0, canvasWidth, canvasHeight, "none", "#000000", 0, 0, "", "", 1)
    vtg.rect("edge", PixelX(0), PixelY(0), PixelLength(WORLDWIDTH), PixelLength(WORLDHEIGHT), "#1e293b", "none", 1, 0, "", "", 1)
    hudDirty = 1
    messageDirty = 1
END FUNCTION

' Everything that moves, every frame; the words only when they change.
FUNCTION DrawFrame() AS VOID
    DrawShip()
    vtg.circle("rock", PixelX(rockX), PixelY(rockY), PixelLength(ROCKSIZE), "#cbd5e1", "#475569", PixelLength(2), 3)
    LOCAL s = 0
    FOR s = 0 TO MAXSHOTS - 1
        IF shotLife(s) > 0 THEN vtg.circle("shot" + Num$(s), PixelX(shotX(s)), PixelY(shotY(s)), PixelLength(2), "none", "#fde047", 0, 2)
    NEXT s
    IF hudDirty = 1 THEN DrawHud()
    IF messageDirty = 1 THEN DrawMessage()
END FUNCTION

' The ship: three lines in a dart shape around its middle, nose first. It
' blinks while it cannot be hit, and is gone once the game is over.
FUNCTION DrawShip() AS VOID
    LOCAL hull$ = "#f8fafc"
    IF gameOver = 1 OR (safeFrames > 0 AND safeFrames MOD 10 < 5) THEN hull$ = "#000000"
    LOCAL noseX = shipX + COS(shipAngle) * 14
    LOCAL noseY = shipY + SIN(shipAngle) * 14
    LOCAL leftX = shipX + COS(shipAngle + 2.5) * 10
    LOCAL leftY = shipY + SIN(shipAngle + 2.5) * 10
    LOCAL rightX = shipX + COS(shipAngle - 2.5) * 10
    LOCAL rightY = shipY + SIN(shipAngle - 2.5) * 10
    LOCAL weight = PixelLength(2)
    vtg.line("ship1", PixelX(noseX), PixelY(noseY), PixelX(leftX), PixelY(leftY), hull$, weight, "", 3)
    vtg.line("ship2", PixelX(noseX), PixelY(noseY), PixelX(rightX), PixelY(rightY), hull$, weight, "", 3)
    vtg.line("ship3", PixelX(leftX), PixelY(leftY), PixelX(rightX), PixelY(rightY), hull$, weight, "", 3)
END FUNCTION

' Score and best along the top, ships left in the corner.
FUNCTION DrawHud() AS VOID
    hudDirty = 0
    vtg.vectorPrint("score", PixelX(16), PixelY(12), PixelLength(14), "SCORE " + Num$(score), "#f8fafc", PixelLength(1), 4)
    vtg.vectorPrint("high", PixelX(400), PixelY(12), PixelLength(14), "HIGH " + Num$(highScore), "#94a3b8", PixelLength(1), 4)
    vtg.vectorPrint("lives", PixelX(16), PixelY(WORLDHEIGHT - 26), PixelLength(12), "SHIPS " + Num$(lives), "#94a3b8", PixelLength(1), 4)
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
