' GameView.bas — what is on the screen: the View, and Num$.
'
' The View fits the game's fixed world to the window, draws the floor and
' the words, and keeps the frames coming at an even pace. Each thing in the
' game draws itself (its Render), asking the View where on the window a
' place in the world is. Num$ writes a number for a shape's name or the
' score line.
'
' This file only declares. The GLOBALs these use (theInbox, vtg, touch, the
' world's size) are in main.bas, because an imported file's top-level
' statements never run.

' MARK: - View

/// The game's fixed world, fitted to the window: the floor, the words, and the pace of the frames.
///
/// The world is always WORLDWIDTH by WORLDHEIGHT; the View scales it to fit
/// the window, so it looks the same at any size.
CLASS View
    ' The window's size in pixels, and how the world fits in it: Scale
    ' pixels to a world unit, and the world's top left at (OffsetX, OffsetY).
    /// The window's width, in pixels.
    PUBLIC CanvasWidth AS INTEGER
    /// The window's height, in pixels.
    PUBLIC CanvasHeight AS INTEGER
    /// How many pixels a world unit is.
    PUBLIC Scale AS DOUBLE
    /// Where the world's left edge is in the window, in pixels.
    PUBLIC OffsetX AS DOUBLE
    /// Where the world's top edge is in the window, in pixels.
    PUBLIC OffsetY AS DOUBLE
    /// Set when the floor needs drawing.
    PUBLIC NeedsFloor AS INTEGER
    ' The words as last drawn, so they are drawn again only when they change:
    ' vector text takes longer to draw than a circle.
    /// The score line, as last drawn.
    PUBLIC Hud$ AS STRING
    /// The words in the middle of the floor, such as PAUSED; "" for none.
    PUBLIC Message$ AS STRING
    /// 1 when Message$ has changed and needs drawing again.
    PUBLIC MessageChanged AS INTEGER
    ' Pacing: how long to sleep after each frame, steered once a second.
    /// How long to sleep after each frame, in milliseconds.
    PUBLIC SleepMs AS DOUBLE
    /// The frames shown since the clock last moved on a second.
    PUBLIC FramesThisSecond AS INTEGER
    /// The time, as TIME$ gave it, when the clock last moved on a second.
    PUBLIC LastSecond$ AS STRING
    /// How many seconds have gone by: the first two are not used to steer.
    PUBLIC SecondsSeen AS INTEGER

    /// Asks the window's size and fits the world to it.
    ///
    /// The window's size, asked once at the start; theInbox hears after that.
    FUNCTION Measure() AS VOID
        ME.SleepMs = 30
        ' Waits up to 250 milliseconds for the terminal to answer.
        LOCAL measured AS VARIANT = vtg.queryCurrentCanvas(250)
        IF measured <> EMPTY THEN
            ME.CanvasWidth = measured("width")
            ME.CanvasHeight = measured("height")
        END IF
        ME.Fit()
    END FUNCTION

    /// The world, as large as fits, in the middle of the window.
    FUNCTION Fit() AS VOID
        ' No answer, or a window too small to play in: use the world's size.
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
    /// Where a place across the world is in the window.
    ///
    /// - Parameter x: How far across the world, in world units.
    /// - Returns: The window's pixel column for it.
    FUNCTION PixelX(x AS DOUBLE) AS INTEGER
        RETURN INT(ME.OffsetX + x * ME.Scale)
    END FUNCTION

    /// Where a place down the world is in the window.
    ///
    /// - Parameter y: How far down the world, in world units.
    /// - Returns: The window's pixel row for it.
    FUNCTION PixelY(y AS DOUBLE) AS INTEGER
        RETURN INT(ME.OffsetY + y * ME.Scale)
    END FUNCTION

    /// How long a length in the world is in the window.
    ///
    /// - Parameter amount: The length, in world units.
    /// - Returns: The length in pixels, rounded, and never less than 1.
    FUNCTION Pixels(amount AS DOUBLE) AS INTEGER
        LOCAL scaled = INT(amount * ME.Scale + 0.5)
        IF scaled < 1 THEN scaled = 1
        RETURN scaled
    END FUNCTION

    /// Starts a frame.
    ///
    /// A frame is drawn off screen and shown all at once, so nothing
    /// flickers. It starts here: fitting the world again if the window has
    /// changed size, and drawing the floor when it needs it.
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

    /// The floor, ruled in squares, its edge, and a hint for the controls.
    ///
    /// Shapes are kept by the terminal under a name: drawing a name again
    /// moves it, and vtg.delete takes it away. Layer 1 is the floor, 2 the
    /// targets and the feet, 3 the bodies and the shots, 4 the noses and the
    /// words.
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

    /// The score, the speed in world units a second, and what that is called.
    ///
    /// From twice a walk up, it counts as a run.
    ///
    /// - Parameter points: The score.
    /// - Parameter speed: How fast the player is going, in world units a frame.
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

    /// Words in the middle of the floor, such as PAUSED; "" for none.
    ///
    /// - Parameter words$: The words to show, or "" to take them away.
    FUNCTION ShowMessage(words$ AS STRING) AS VOID
        ME.Message$ = words$
        ME.MessageChanged = 1
    END FUNCTION

    /// Draws the message in the middle of the floor, or erases it.
    ///
    /// Vector text is erased by printing nothing over it.
    FUNCTION DrawMessage() AS VOID
        ME.MessageChanged = 0
        IF ME.Message$ = "" THEN
            vtg.vectorPrint("message", 0, 0, 10, "", "#000000", 1, 4)
            RETURN
        END IF
        ' Centered, taking each letter to be about as wide as it is tall.
        LOCAL height = ME.Pixels(20)
        vtg.vectorPrint("message", ME.PixelX(WORLDWIDTH / 2) - LEN(ME.Message$) * height / 2, ME.PixelY(WORLDHEIGHT / 2 - 10), height, ME.Message$, "#facc15", ME.Pixels(2), 4)
    END FUNCTION

    /// Shows the frame, and answers how long to sleep before the next one.
    ///
    /// A frame is its work plus a sleep. The work takes longer interpreted
    /// than compiled, so the sleep is steered: each second, the frames counted
    /// in the second before say how long a frame really took, and the sleep
    /// moves most of the way toward making it 1/FPS of a second.
    ///
    /// - Returns: How long to sleep before the next frame, in milliseconds.
    FUNCTION EndFrame() AS INTEGER
        vtg.endFrame("game")
        vtg.present()
        ME.FramesThisSecond = ME.FramesThisSecond + 1
        LOCAL now$ = TIME$()
        IF now$ <> ME.LastSecond$ THEN
            ' The first two seconds are still starting up: count them, but
            ' do not steer by them.
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

' MARK: - Numbers as words

/// A whole number with no space in front, where STR$ leaves one.
///
/// - Parameter value: The number to write.
/// - Returns: Its digits, with a minus sign in front when it is negative.
FUNCTION Num$(value AS INTEGER) AS STRING
    LOCAL digits$ = STR$(value)
    IF LEFT$(digits$, 1) = " " THEN RETURN MID$(digits$, 2)
    RETURN digits$
END FUNCTION
