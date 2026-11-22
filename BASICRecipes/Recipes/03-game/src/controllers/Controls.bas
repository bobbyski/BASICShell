' Controls.bas — the controls, and the Inbox where events wait.
'
' The Controls turn the keys, a gamepad, and the on-screen joystick and
' buttons into the few things the game asks: which way, how fast, and was
' Fire pressed. The Inbox is where events write down what happened until
' the next frame. NotePadControl writes a gamepad's news into it, and
' SpeedForLean turns how far the touch joystick leans into a speed.
'
' This file only declares. The GLOBALs these use (theInbox, touch, the
' speeds and DEADZONE) are in main.bas, because an imported file's
' top-level statements never run.

' MARK: - Inbox

/// What the events have said since the last frame.
///
/// Events can arrive at any moment, even halfway through a frame, so they
/// write down what happened here, and the loop acts on it at the start of
/// the next frame. A TYPE, not a CLASS: a record of values with names and
/// no methods.
TYPE Inbox
    ' Presses waiting for the next frame. Presses arrive as events, so even
    ' a tap too quick for a frame to see is kept, and holding a button down
    ' is one press. The loop sets each back to 0 once it has used it.
    /// 1 when Fire has been pressed.
    FirePressed AS INTEGER
    /// 1 when pause has been pressed.
    PausePressed AS INTEGER
    /// 1 when Q has been pressed.
    QuitPressed AS INTEGER
    ' The gamepad, as its events last said: 1 while a direction is held.
    /// 1 while left is held.
    PadLeft AS INTEGER
    /// 1 while right is held.
    PadRight AS INTEGER
    /// 1 while up is held.
    PadUp AS INTEGER
    /// 1 while down is held.
    PadDown AS INTEGER
    /// 1 while B, which runs, is held.
    PadRun AS INTEGER
    ' The window's new size, when it has changed.
    /// 1 when the window has changed size since the last frame.
    Resized AS INTEGER
    /// The window's new width, in pixels.
    NewWidth AS INTEGER
    /// The window's new height, in pixels.
    NewHeight AS INTEGER
END TYPE

' MARK: - Controls

/// The keys, a gamepad and the touch controls, turned into which way to go and how fast.
CLASS Controls
    ' What the controls ask for this frame: a way to go (WantX, WantY) and
    ' how fast. A speed of 0 means stand still.
    /// How much of the way to go is across: below 0 is left, above 0 is right.
    PUBLIC WantX AS DOUBLE
    /// How much of the way to go is down: below 0 is up, above 0 is down.
    PUBLIC WantY AS DOUBLE
    /// How fast to go, in world units a frame; 0 means stand still.
    PUBLIC WantSpeed AS DOUBLE

    /// Puts the touch controls on the screen.
    ///
    /// On an iPad or iPhone: the joystick under the right thumb, Fire under
    /// the left, and a pause button. Fire and pause report as a gamepad's A
    /// and Menu buttons, so NotePadControl hears them. Elsewhere these calls
    /// do nothing.
    FUNCTION PlaceOnScreen() AS VOID
        touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 170)
        touch.Button("fire", "BOTTOMLEFT", 50, 50, 100, "FIRE", "#ff3b30")
        touch.Button("pause", "TOPRIGHT", 16, 16, 56, "II", "#64748b", "MENU")
    END FUNCTION

    /// Reads the controls for this frame.
    ///
    /// Every control comes down to the same two answers: which way, and how
    /// fast. The touch joystick says how far it leans, so it can ask for any
    /// speed from a walk to a run. Keys and gamepad buttons are only on or
    /// off, so they walk, and run while Shift or B is held.
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

' MARK: - Gamepad and joystick

/// Writes down a game controller's change in theInbox.
///
/// A game controller: every button and stick direction comes as its own
/// control, with a value from 0 (let go) to 1 (pressed), and is written down
/// in theInbox. The touch joystick reports here as well, as controller -1,
/// but only as on or off; ReadKeys asks it how far it leans instead.
///
/// - Parameter controller: Which controller it is; -1 for the touch controls.
/// - Parameter control$: The button or stick direction, such as "A" or "DPAD_LEFT".
/// - Parameter value: From 0 (let go) to 1 (pressed).
FUNCTION NotePadControl(controller AS INTEGER, control$ AS STRING, value AS DOUBLE) AS VOID
    LOCAL pressed = 0
    IF value > 0.5 THEN pressed = 1
    IF control$ = "MENU" AND pressed = 1 THEN theInbox.PausePressed = 1
    ' A, or the touch Fire button, which reports as A: a press fires.
    IF (control$ = "A" OR control$ = "RIGHT_TRIGGER") AND pressed = 1 THEN theInbox.FirePressed = 1
    ' Directions held, from a real controller only: the touch joystick's are
    ' read in ReadKeys.
    IF controller <> -1 THEN
        IF control$ = "DPAD_LEFT" OR control$ = "LEFT_STICK_LEFT" THEN theInbox.PadLeft = pressed
        IF control$ = "DPAD_RIGHT" OR control$ = "LEFT_STICK_RIGHT" THEN theInbox.PadRight = pressed
        IF control$ = "DPAD_UP" OR control$ = "LEFT_STICK_UP" THEN theInbox.PadUp = pressed
        IF control$ = "DPAD_DOWN" OR control$ = "LEFT_STICK_DOWN" THEN theInbox.PadDown = pressed
        IF control$ = "B" THEN theInbox.PadRun = pressed
    END IF
END FUNCTION

/// The speed for how far the touch joystick leans.
///
/// How far the stick leans picks a speed between a walk and a run, on a
/// scale that is even in the logarithm of the speed rather than in the speed
/// itself: every step of lean multiplies the speed by the same amount. With
/// a run four times a walk:
///
///     lean    0.15 (just past the dead zone)   0.575 (halfway)    1 (all the way)
///     speed   1.5, a walk                      3, twice a walk    6, a run
///
/// In a straight line, halfway would already be 3.75, most of a run. Spread
/// this way, more of the stick is spent at the slow end, where small changes
/// show and fine control matters.
///
/// - Parameter lean: How far the stick leans, from 0 (the middle) to 1 (all the way).
/// - Returns: The speed, in world units a frame; 0 inside the dead zone.
FUNCTION SpeedForLean(lean AS DOUBLE) AS DOUBLE
    IF lean <= DEADZONE THEN RETURN 0
    ' How far past the dead zone, from 0 to 1.
    LOCAL t = (lean - DEADZONE) / (1 - DEADZONE)
    IF t > 1 THEN t = 1
    RETURN EXP(LN(WALKSPEED) + t * (LN(RUNSPEED) - LN(WALKSPEED)))
END FUNCTION
