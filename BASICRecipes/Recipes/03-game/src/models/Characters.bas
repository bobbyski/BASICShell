' Characters.bas — the people in the game: Walker, Player and Guard.
'
' A Walker is anyone who walks: where they are, which way they face, how
' fast they go, and how to draw them. The Player and the Guard are both
' walkers (INHERITS Walker), so they get all of that, and each adds only
' what is its own: the Player goes where the controls say, the Guard walks
' its patrol. At the bottom are the plain functions they share for
' directions and distances.
'
' This file only declares. The GLOBALs these use (theView, vtg, PI, the
' speeds and sizes) are in main.bas, because an imported file's top-level
' statements never run.

' MARK: - Walker

/// Anyone who walks: where they are, which way they face, how fast they go, and how to draw them.
///
/// The Player and the Guard are both walkers (INHERITS Walker), so they get
/// all of this, and each adds only what is its own.
CLASS Walker
    ' Where they are in the world.
    /// How far across the world they are, from the left edge.
    PUBLIC X AS DOUBLE
    /// How far down the world they are, from the top edge.
    PUBLIC Y AS DOUBLE
    /// Which way they face, in radians.
    ///
    /// 0 is right, PI/2 is down (screen y runs down), PI is left and -PI/2
    /// is up.
    PUBLIC Facing AS DOUBLE
    /// How fast they are going, in world units a frame.
    ///
    /// 0 is standing still.
    PUBLIC Speed AS DOUBLE
    /// Where the feet are in their stride.
    ///
    /// Once around is a step with each foot.
    PUBLIC Stride AS DOUBLE
    ' The start of each of their shapes' names, so two walkers' shapes are
    ' their own ("playerBody", "guardBody"), and their colors.
    /// The start of each of their shapes' names, such as "player".
    PUBLIC Who$ AS STRING
    /// The color of the rim around their body.
    PUBLIC Rim$ AS STRING
    /// The color their body is filled with.
    PUBLIC Fill$ AS STRING

    /// Makes a walker standing at (startX, startY), facing up.
    ///
    /// NEW Player("player", 320, 240, "#bfdbfe", "#2563eb") calls this.
    ///
    /// - Parameter name$: The start of each of their shapes' names, such as "player".
    /// - Parameter startX: Where they start, across the world.
    /// - Parameter startY: Where they start, down the world.
    /// - Parameter rimColor$: The color of the rim around their body.
    /// - Parameter fillColor$: The color their body is filled with.
    FUNCTION New(name$ AS STRING, startX AS DOUBLE, startY AS DOUBLE, rimColor$ AS STRING, fillColor$ AS STRING) AS VOID
        ME.Who$ = name$
        ME.X = startX
        ME.Y = startY
        ME.Rim$ = rimColor$
        ME.Fill$ = fillColor$
        ME.Facing = -PI / 2
    END FUNCTION

    /// Turns to face `way`, a little each frame.
    ///
    /// Turn toward `way`, the short way around, and no more than TURNSPEED
    /// in one frame, so a change of direction is quick and still seen.
    ///
    /// - Parameter way: The direction to face, in radians, measured the way Facing is.
    FUNCTION TurnToward(way AS DOUBLE) AS VOID
        ' Unwind keeps the turn between -PI and PI, so it goes the short way.
        LOCAL turn = Unwind(way - ME.Facing)
        IF turn > TURNSPEED THEN turn = TURNSPEED
        IF turn < -TURNSPEED THEN turn = -TURNSPEED
        ME.Facing = Unwind(ME.Facing + turn)
    END FUNCTION

    /// One step: stepX across and stepY down.
    ///
    /// The step's length is the speed, and faster means quicker steps as
    /// well as longer ones.
    ///
    /// - Parameter stepX: How far to step across, in world units.
    /// - Parameter stepY: How far to step down, in world units.
    FUNCTION Walk(stepX AS DOUBLE, stepY AS DOUBLE) AS VOID
        ME.X = ME.X + stepX
        ME.Y = ME.Y + stepY
        ME.Speed = SQR(stepX * stepX + stepY * stepY)
        ME.Stride = ME.Stride + 0.17 * SQR(ME.Speed)
    END FUNCTION

    /// Where the nose is: a shot leaves from there.
    ///
    /// - Returns: How far across the world the nose is.
    FUNCTION NoseX() AS DOUBLE
        RETURN ME.X + COS(ME.Facing) * WALKERSIZE
    END FUNCTION

    /// Where the nose is, down the world: the partner of NoseX.
    ///
    /// - Returns: How far down the world the nose is.
    FUNCTION NoseY() AS DOUBLE
        RETURN ME.Y + SIN(ME.Facing) * WALKERSIZE
    END FUNCTION

    /// Draws them where they are.
    ///
    /// Seen from above: two feet that swing as they go, a round body over
    /// them, and a nose on the side they face.
    FUNCTION Render() AS VOID
        ' Out to each side: a quarter turn from the way they face.
        LOCAL sideX = COS(ME.Facing + PI / 2) * 9
        LOCAL sideY = SIN(ME.Facing + PI / 2) * 9
        ' How far a foot is ahead (or, for the other foot, behind): it
        ' swings with the stride, and farther at a run.
        LOCAL swing = SIN(ME.Stride) * (1 + ME.Speed * 1.5)
        LOCAL aheadX = COS(ME.Facing) * swing
        LOCAL aheadY = SIN(ME.Facing) * swing
        LOCAL foot = theView.Pixels(5)
        vtg.circle(ME.Who$ + "FootLeft", theView.PixelX(ME.X + sideX + aheadX), theView.PixelY(ME.Y + sideY + aheadY), foot, "none", "#94a3b8", 0, 2)
        vtg.circle(ME.Who$ + "FootRight", theView.PixelX(ME.X - sideX - aheadX), theView.PixelY(ME.Y - sideY - aheadY), foot, "none", "#94a3b8", 0, 2)

        vtg.circle(ME.Who$ + "Body", theView.PixelX(ME.X), theView.PixelY(ME.Y), theView.Pixels(WALKERSIZE), ME.Rim$, ME.Fill$, theView.Pixels(2), 3)
        vtg.circle(ME.Who$ + "Nose", theView.PixelX(ME.NoseX()), theView.PixelY(ME.NoseY()), theView.Pixels(4), "none", "#facc15", 0, 4)
    END FUNCTION

    /// Off the screen: the terminal forgets their shapes.
    FUNCTION Remove() AS VOID
        vtg.delete(ME.Who$ + "Body")
        vtg.delete(ME.Who$ + "Nose")
        vtg.delete(ME.Who$ + "FootLeft")
        vtg.delete(ME.Who$ + "FootRight")
    END FUNCTION
END CLASS

' MARK: - Player

/// The one you move: a Walker that goes where the controls say.
CLASS Player
    INHERITS Walker

    /// Moves the player one frame's worth, the way the controls ask.
    ///
    /// Go the way the controls ask, at the speed they ask, and turn to face
    /// it. No stick and no keys is a speed of 0: they stop where they are.
    /// The edges of the world are walls.
    ///
    /// - Parameter wantX: How much of the way is across: below 0 is left, above 0 is right.
    /// - Parameter wantY: How much of the way is down: below 0 is up, above 0 is down.
    /// - Parameter wantSpeed: How fast, in world units a frame; 0 to stand still.
    FUNCTION MoveAsAsked(wantX AS DOUBLE, wantY AS DOUBLE, wantSpeed AS DOUBLE) AS VOID
        IF wantSpeed = 0 THEN
            ME.Speed = 0
            ME.Stride = 0
        ELSE
            ' A direction and a speed make a step: COS gives the part
            ' across, SIN the part down.
            LOCAL way = DirectionOf(wantX, wantY)
            ME.TurnToward(way)
            ME.Walk(COS(way) * wantSpeed, SIN(way) * wantSpeed)
        END IF
        ME.X = Clamp(ME.X, WALKERSIZE, WORLDWIDTH - WALKERSIZE)
        ME.Y = Clamp(ME.Y, WALKERSIZE, WORLDHEIGHT - WALKERSIZE)
    END FUNCTION
END CLASS

' MARK: - Guard

/// The guard: a Walker that walks the edge of the floor, clockwise.
///
/// A guard that is hit leaves the floor, and a new one sets out from the
/// top RESPAWNSECONDS later.
CLASS Guard
    INHERITS Walker
    ' The way it is walking: right (1, 0), down (0, 1), left (-1, 0) or up
    ' (0, -1).
    /// The part of the way it is walking that is across: 1, 0 or -1.
    PUBLIC DX AS DOUBLE
    /// The part of the way it is walking that is down: 1, 0 or -1.
    PUBLIC DY AS DOUBLE
    /// 1 on patrol; 0 from a hit until it comes back, Wait frames later.
    PUBLIC Alive AS INTEGER
    /// How many more frames until a guard that was hit comes back.
    PUBLIC Wait AS INTEGER

    /// Starts a new guard on its patrol.
    ///
    /// A new guard at the top of the floor, in the middle, setting out to
    /// the right: clockwise.
    FUNCTION Spawn() AS VOID
        ME.X = WORLDWIDTH / 2
        ME.Y = GUARDMARGIN
        ME.DX = 1
        ME.DY = 0
        ME.Facing = 0
        ME.Speed = GUARDSPEED
        ME.Stride = 0
        ME.Alive = 1
    END FUNCTION

    /// Moves the guard one frame along its patrol.
    ///
    /// Walk on; at a corner, turn a quarter turn to the right, which on this
    /// path is always clockwise. A guard that has been hit counts down its
    /// wait instead, and comes back when it runs out.
    FUNCTION Patrol() AS VOID
        IF ME.Alive = 0 THEN
            ME.Wait = ME.Wait - 1
            IF ME.Wait <= 0 THEN ME.Spawn()
            RETURN
        END IF
        ME.Walk(ME.DX * GUARDSPEED, ME.DY * GUARDSPEED)
        LOCAL rightSide = WORLDWIDTH - GUARDMARGIN
        LOCAL bottomSide = WORLDHEIGHT - GUARDMARGIN
        IF ME.X > rightSide OR ME.X < GUARDMARGIN OR ME.Y > bottomSide OR ME.Y < GUARDMARGIN THEN
            ' Past a corner: back onto it, and turn.
            ME.X = Clamp(ME.X, GUARDMARGIN, rightSide)
            ME.Y = Clamp(ME.Y, GUARDMARGIN, bottomSide)
            ME.TurnRight()
        END IF
        ME.Facing = DirectionOf(ME.DX, ME.DY)
    END FUNCTION

    /// Turns a quarter turn to the right.
    ///
    /// A quarter turn to the right, on the screen, where y runs down: right
    /// becomes down, down becomes left, left becomes up, up becomes right.
    FUNCTION TurnRight() AS VOID
        LOCAL wasDX = ME.DX
        ME.DX = -ME.DY
        ME.DY = wasDX
    END FUNCTION

    /// Whether a shot at (shotX, shotY) hits it.
    ///
    /// A hit takes it off the floor, and a new guard comes back
    /// RESPAWNSECONDS later.
    ///
    /// - Parameter shotX: Where the shot is, across the world.
    /// - Parameter shotY: Where the shot is, down the world.
    /// - Returns: 1 for a hit, 0 for a miss (and always 0 while it is off the floor).
    FUNCTION IsHitBy(shotX AS DOUBLE, shotY AS DOUBLE) AS INTEGER
        IF ME.Alive = 0 THEN RETURN 0
        IF Distance(shotX, shotY, ME.X, ME.Y) >= WALKERSIZE THEN RETURN 0
        ME.Alive = 0
        ME.Wait = RESPAWNSECONDS * FPS
        ME.Remove()
        RETURN 1
    END FUNCTION
END CLASS

' MARK: - Directions and distances

/// Which way (x, y) points, in radians.
///
/// The direction from the middle to (x, y), in radians, measured the way
/// Facing is. ATN alone gives only the right half of the circle, from -PI/2
/// to PI/2; a point to the left is half a turn around from that.
///
/// - Parameter x: How far across the point is from the middle.
/// - Parameter y: How far down the point is from the middle.
/// - Returns: The direction, between -PI and PI.
FUNCTION DirectionOf(x AS DOUBLE, y AS DOUBLE) AS DOUBLE
    IF x > 0 THEN RETURN ATN(y / x)
    IF x < 0 THEN RETURN Unwind(ATN(y / x) + PI)
    ' Straight up or straight down, where y / x would divide by zero.
    IF y < 0 THEN RETURN -PI / 2
    RETURN PI / 2
END FUNCTION

/// Brings an angle into the range -PI to PI.
///
/// The same direction, written between -PI and PI. A turn from just above
/// -PI to just below PI is a small one, and this is what makes it come out
/// that way rather than nearly a full circle.
///
/// - Parameter angle: Any angle, in radians.
/// - Returns: The same direction, between -PI and PI.
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

/// Keeps `amount` between `lowest` and `highest`.
///
/// - Parameter amount: The number to keep in range.
/// - Parameter lowest: The smallest it may be.
/// - Parameter highest: The largest it may be.
/// - Returns: `amount`, or the nearer limit when it is outside them.
FUNCTION Clamp(amount AS DOUBLE, lowest AS DOUBLE, highest AS DOUBLE) AS DOUBLE
    IF amount < lowest THEN RETURN lowest
    IF amount > highest THEN RETURN highest
    RETURN amount
END FUNCTION

/// How far apart two points are.
///
/// - Parameter x1: The first point, across.
/// - Parameter y1: The first point, down.
/// - Parameter x2: The second point, across.
/// - Parameter y2: The second point, down.
/// - Returns: The straight-line distance between them, in world units.
FUNCTION Distance(x1 AS DOUBLE, y1 AS DOUBLE, x2 AS DOUBLE, y2 AS DOUBLE) AS DOUBLE
    RETURN SQR((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
END FUNCTION
