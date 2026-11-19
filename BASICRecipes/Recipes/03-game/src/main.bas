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
' knows how to move and how to show itself. The files are in three
' folders: models for the things in the game, views for what is on the
' screen, and controllers for the controls and the loop that runs it all.
' This file holds the numbers to play with and the things in the game,
' and starts it.
'
'     main.bas                   the numbers to play with, the things in
'                                the game, and the start
'     models/Characters.bas      Walker, someone who walks, and the two
'                                kinds of walker: the Player and the Guard
'     models/Shooting.bas        Shots and Targets, and what happens when
'                                they meet
'     views/GameView.bas         the View, which fits the game to the
'                                window and draws the floor and the words
'     controllers/Controls.bas   the Controls, and the Inbox, where events
'                                wait for the next frame
'     controllers/GameLoop.bas   RunGame, the loop that runs the game, and
'                                the event handlers
'
' An object changes only itself. When two things meet (a shot and the
' guard), it is a plain function that decides what happens to each:
' CheckHits, in models/Shooting.bas.
'
' Events (a button pressed, the window resized) can arrive at any moment,
' even halfway through moving the player. So they do not change the
' objects: they are written down in theInbox, and the loop acts on them at
' the start of the next frame, when nothing is halfway through.
'
' It draws with lines, circles and vector text only, so it runs
' interpreted in BASICStudio and BASICShell, and compiled with basicc.
' README.md says how the comments are written.

' MARK: - The files

' IMPORT reads another file's CLASSes, TYPEs and FUNCTIONs into this
' program, from a path relative to this file.
IMPORT "models/Characters.bas"
IMPORT "models/Shooting.bas"
IMPORT "views/GameView.bas"
IMPORT "controllers/Controls.bas"
IMPORT "controllers/GameLoop.bas"

' Every GLOBAL in the game is below, in this file, and none is in the files
' it imports: an imported file's top-level statements never run, GLOBALs
' included, so a GLOBAL written in one of them would never be made. The
' imported files only declare; the CLASSes and FUNCTIONs in them use these.

' MARK: - The world

' Everything is placed in a fixed world, 640 by 480, and the View scales it
' to fit the window, so it looks the same at any size.
/// How wide the world is, in world units.
GLOBAL WORLDWIDTH AS INTEGER = 640
/// How tall the world is, in world units.
GLOBAL WORLDHEIGHT AS INTEGER = 480
/// The floor is ruled in squares this size, so you can see how fast you go.
GLOBAL GRIDSIZE AS INTEGER = 40
/// Frames a second to aim for (see View.EndFrame).
GLOBAL FPS AS INTEGER = 30
/// Half a turn, in radians.
GLOBAL PI AS DOUBLE = 3.1415927

' MARK: - The numbers to play with

/// How big someone is, from the middle to the edge.
GLOBAL WALKERSIZE AS INTEGER = 12
' A walk and a run, in world units a frame. At 30 frames a second a walk
' crosses the world in about 14 seconds, and a run in under 4.
/// A walk, in world units a frame.
GLOBAL WALKSPEED AS DOUBLE = 1.5
/// A run, in world units a frame.
GLOBAL RUNSPEED AS DOUBLE = 6
/// The most anyone turns in one frame, in radians.
///
/// A half turn takes about a quarter of a second.
GLOBAL TURNSPEED AS DOUBLE = 0.4
/// How far the stick has to lean, out of 1, before it counts.
///
/// A thumb resting on the stick is never quite in the middle.
GLOBAL DEADZONE AS DOUBLE = 0.15

' The guard walks this far in from the walls, at this speed, and comes back
' this long after it is hit.
/// How far in from the walls the guard walks, in world units.
GLOBAL GUARDMARGIN AS INTEGER = 40
/// How fast the guard walks, in world units a frame.
GLOBAL GUARDSPEED AS DOUBLE = 2
/// How long after it is hit a new guard sets out, in seconds.
GLOBAL RESPAWNSECONDS AS INTEGER = 2

' Shots in the air at once (Shots keeps this many places), and how fast
' they fly.
/// The most shots in the air at once.
///
/// Shots keeps a place for each, and its arrays are sized for 8: make them
/// bigger to raise this past that.
GLOBAL MAXSHOTS AS INTEGER = 8
/// How fast a shot flies, in world units a frame.
GLOBAL SHOTSPEED AS DOUBLE = 10
' Targets on the floor (Targets keeps this many), and how big they are.
/// How many targets are on the floor.
///
/// Targets keeps this many, its arrays are sized for 4, and PlaceFour
/// places four: change those as well to change this.
GLOBAL TARGETCOUNT AS INTEGER = 4
/// How big a target is, from the middle to the edge.
GLOBAL TARGETSIZE AS INTEGER = 18

' What a hit is worth.
/// The points for hitting a target.
GLOBAL TARGETPOINTS AS INTEGER = 1
/// The points for hitting the guard.
GLOBAL GUARDPOINTS AS INTEGER = 10

' MARK: - The things in the game

' One of each, made in RunGame. A CLASS says what a kind of thing is, and
' the name with "the" in front is the one in this game: Player is what a
' player is, thePlayer is the one you move. (BASIC does not tell capitals
' from small letters, so the two could not both be called player.) GLOBAL
' so the event handlers can reach them as well as RunGame (all of them in
' controllers/GameLoop.bas).
/// What is on the screen: it fits the world to the window and draws the floor and the words.
GLOBAL theView AS View
/// The keys, the gamepad and the touch controls.
GLOBAL theControls AS Controls
/// The one you move.
GLOBAL thePlayer AS Player
/// The guard on patrol.
GLOBAL theGuard AS Guard
/// Every shot in the air.
GLOBAL theShots AS Shots
/// The four targets.
GLOBAL theTargets AS Targets
/// The points scored so far.
GLOBAL score AS INTEGER
/// 1 while the game runs; 0 once Q is pressed.
GLOBAL playing AS INTEGER
/// 1 while the game is paused.
GLOBAL paused AS INTEGER

/// What the events have said since the last frame (Inbox, in controllers/Controls.bas).
///
/// A TYPE, not a CLASS: a record of values with names and no methods.
GLOBAL theInbox AS Inbox

' The terminal's graphics, and the on-screen controls of an iPad or iPhone.
/// The terminal's graphics.
GLOBAL vtg = VectorTerminal()
/// The on-screen controls of an iPad or iPhone.
GLOBAL touch = TouchControls()

' MARK: - Start

' The event handlers, in controllers/GameLoop.bas, then the game itself.
ON GAMEPAD CALL GamepadChanged
ON RESIZE CALL WindowResized
RunGame()
