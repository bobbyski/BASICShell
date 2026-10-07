' Characters.bas — the people in the game.
'
' A Walker is anyone who walks: where they are, which way they face, how
' fast they go, and how to draw them. The Player and the Guard are both
' walkers (INHERITS Walker), so they get all of that, and each adds only
' what is its own: the Player goes where the controls say, the Guard walks
' its patrol.

' MARK: - Walker

CLASS Walker
    ' Where they are in the world.
    PUBLIC X AS DOUBLE
    PUBLIC Y AS DOUBLE
    ' Which way they face, in radians: 0 is right, PI/2 is down (screen y
    ' runs down), PI is left and -PI/2 is up.
    PUBLIC Facing AS DOUBLE
    ' How fast they are going, in world units a frame. 0 is standing still.
    PUBLIC Speed AS DOUBLE
    ' Where the feet are in their stride: once round is a step with each foot.
    PUBLIC Stride AS DOUBLE
    ' The start of each of their shapes' names, so two walkers' shapes are
    ' their own ("playerBody", "guardBody"), and their colors.
    PUBLIC Who$ AS STRING
    PUBLIC Rim$ AS STRING
    PUBLIC Fill$ AS STRING

    ' NEW Player("player", 320, 240, "#bfdbfe", "#2563eb") calls this.
    FUNCTION New(name$ AS STRING, startX AS DOUBLE, startY AS DOUBLE, rimColor$ AS STRING, fillColor$ AS STRING) AS VOID
        ME.Who$ = name$
        ME.X = startX
        ME.Y = startY
        ME.Rim$ = rimColor$
        ME.Fill$ = fillColor$
        ME.Facing = -PI / 2
    END FUNCTION

    ' Turn toward `way`, the short way round, and no more than TURNSPEED in
    ' one frame, so a change of direction is quick and still seen.
    FUNCTION TurnToward(way AS DOUBLE) AS VOID
        LOCAL turn = Unwind(way - ME.Facing)
        IF turn > TURNSPEED THEN turn = TURNSPEED
        IF turn < -TURNSPEED THEN turn = -TURNSPEED
        ME.Facing = Unwind(ME.Facing + turn)
    END FUNCTION

    ' One step: stepX across and stepY down. The step's length is the speed,
    ' and faster means quicker steps as well as longer ones.
    FUNCTION Walk(stepX AS DOUBLE, stepY AS DOUBLE) AS VOID
        ME.X = ME.X + stepX
        ME.Y = ME.Y + stepY
        ME.Speed = SQR(stepX * stepX + stepY * stepY)
        ME.Stride = ME.Stride + 0.17 * SQR(ME.Speed)
    END FUNCTION

    ' Where the nose is: a shot leaves from there.
    FUNCTION NoseX() AS DOUBLE
        RETURN ME.X + COS(ME.Facing) * WALKERSIZE
    END FUNCTION

    FUNCTION NoseY() AS DOUBLE
        RETURN ME.Y + SIN(ME.Facing) * WALKERSIZE
    END FUNCTION

    ' Seen from above: two feet that swing as they go, a round body over
    ' them, and a nose on the side they face.
    FUNCTION Render() AS VOID
        ' Out to each side: a quarter turn from the way they face.
        LOCAL sideX = COS(ME.Facing + PI / 2) * 9
        LOCAL sideY = SIN(ME.Facing + PI / 2) * 9
        ' How far a foot is ahead (or, for the other foot, behind): it
        ' swings with the stride, and further at a run.
        LOCAL swing = SIN(ME.Stride) * (1 + ME.Speed * 1.5)
        LOCAL aheadX = COS(ME.Facing) * swing
        LOCAL aheadY = SIN(ME.Facing) * swing
        LOCAL foot = theView.Pixels(5)
        vtg.circle(ME.Who$ + "FootLeft", theView.PixelX(ME.X + sideX + aheadX), theView.PixelY(ME.Y + sideY + aheadY), foot, "none", "#94a3b8", 0, 2)
        vtg.circle(ME.Who$ + "FootRight", theView.PixelX(ME.X - sideX - aheadX), theView.PixelY(ME.Y - sideY - aheadY), foot, "none", "#94a3b8", 0, 2)

        vtg.circle(ME.Who$ + "Body", theView.PixelX(ME.X), theView.PixelY(ME.Y), theView.Pixels(WALKERSIZE), ME.Rim$, ME.Fill$, theView.Pixels(2), 3)
        vtg.circle(ME.Who$ + "Nose", theView.PixelX(ME.NoseX()), theView.PixelY(ME.NoseY()), theView.Pixels(4), "none", "#facc15", 0, 4)
    END FUNCTION

    ' Off the screen: the terminal forgets their shapes.
    FUNCTION Remove() AS VOID
        vtg.delete(ME.Who$ + "Body")
        vtg.delete(ME.Who$ + "Nose")
        vtg.delete(ME.Who$ + "FootLeft")
        vtg.delete(ME.Who$ + "FootRight")
    END FUNCTION
END CLASS

' MARK: - Player

CLASS Player
    INHERITS Walker

    ' Go the way the controls ask, at the speed they ask, and turn to face
    ' it. No stick and no keys is a speed of 0: they stop where they are.
    ' The edges of the world are walls.
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

CLASS Guard
    INHERITS Walker
    ' The way it is walking: right (1, 0), down (0, 1), left (-1, 0) or up
    ' (0, -1).
    PUBLIC DX AS DOUBLE
    PUBLIC DY AS DOUBLE
    ' 1 on patrol; 0 from a hit until it comes back, Wait frames later.
    PUBLIC Alive AS INTEGER
    PUBLIC Wait AS INTEGER

    ' A new guard at the top of the floor, in the middle, setting out to
    ' the right: clockwise.
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

    ' Walk on; at a corner, turn a quarter turn to the right, which on this
    ' path is always clockwise. A guard that has been hit counts down its
    ' wait instead, and comes back when it runs out.
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

    ' A quarter turn to the right, on the screen, where y runs down: right
    ' becomes down, down becomes left, left becomes up, up becomes right.
    FUNCTION TurnRight() AS VOID
        LOCAL wasDX = ME.DX
        ME.DX = -ME.DY
        ME.DY = wasDX
    END FUNCTION

    ' Whether a shot at (shotX, shotY) hits it. A hit takes it off the
    ' floor, and a new guard comes back RESPAWNSECONDS later.
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

' The direction from the middle to (x, y), in radians, measured the way
' Facing is. ATN alone gives only the right half of the circle, from -PI/2
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

FUNCTION Distance(x1 AS DOUBLE, y1 AS DOUBLE, x2 AS DOUBLE, y2 AS DOUBLE) AS DOUBLE
    RETURN SQR((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
END FUNCTION
