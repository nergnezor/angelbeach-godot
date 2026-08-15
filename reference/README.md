# Reference — the Unreal/Angelscript original

Read-only. This is the source the Godot port is being made from, kept only
until the port is complete. It is not built, not run, and not maintained.

Nothing here is engine-neutral by accident: the parts worth carrying over are
the *reasoning* in the comments, not the UE API calls. Five passes of tuning are
recorded in them — the movement budget's measured constants, why contacts are
ballistic placement rather than reflection, why every boolean that feeds a pose
has hysteresis, and the long autopsies of the failures that led to each.

## Coordinates: convert at the door, every time

Unreal is centimetres, Z up, left-handed, with the sidelines on Y. Godot is
metres, Y up, right-handed, with the sidelines on Z. Everything under `src/` is
in GODOT space; no UE units survive past the port. The mapping is

    godot.x =  ue.x / 100      across the net, net plane still at x = 0
    godot.y =  ue.z / 100      up
    godot.z = -ue.y / 100      along the net

The sign on the last line is not optional — it is what keeps the handedness
right, and it means the Godot court is the MIRROR IMAGE of the Unreal one. A
mirrored volleyball court plays identically, so this costs nothing, but an A/B
against the original has to expect it: the seeded run in `src/match/Match.gd`
reproduces the Angelscript build to the centimetre only under that mapping.

Yaw follows Godot: `atan2(-z, x)`, which is exactly `Basis(Vector3.UP, yaw)`
applied to +X, so a facing vector can drive a model's basis directly. See
`Player.yaw_of` / `Player.dir_of` — use them rather than open-coding an atan2,
which is how the first port ended up reading a Z-up yaw out of a Y-up vector.

Still to port (line counts at the time of the move):

    Script/AI/AIPlayer.as             1465   state machine, spike approach,
                                             block, dive, split step
    Script/Player/VolleyballPlayer.as 1872   contact model, jumps, dive,
                                             crouch channels, telemetry
    Script/Player/PlayerIK.as          560   gesture engine: bump, set, spike,
                                             block, serve; MinJerk/EaseIn/
                                             EaseOut time profiles; ArcAround
    Script/Match/GameMode.as           566   match rules, scoring, serving
    Script/World/Court.as              530   court, net, sand deformation
    Script/World/Environment.as        212   sky, sun, the measured light gains

Already ported, and verified numerically identical:

    Script/AI/MotionPlan.as       -> rust/src/lib.rs  (MotionPlan)
    Script/World/Ball.as          -> rust/src/lib.rs  (BallSim, Contact)
                                     + src/world/Ball.gd (the node)
    locomotion + facing           -> src/player/Player.gd

## What is in Rust, and why that line

`rust/` holds the part of the sim with no engine in it: ballistics, kinematics,
the movement budget, the ball integrator. Everything that touches a node, a
skeleton, the scene tree, the RNG or stdout stays in GDScript. The split is not
about speed — it is that those functions are pure, so they can be moved with a
comparison that either matches to the byte or does not.

Two rules make that comparison possible, and breaking either loses it silently:

**Precision is part of the contract.** GDScript mixes widths without meaning to:
a Vector3 stores f32 components, but every scalar GDScript computes with is f64.
Reading `pos.y` widens, the maths runs in f64, storing narrows. The Rust side
mirrors this deliberately — `f()` widens in, `v3()` narrows out. It is not
uniform, either: in `BallSim::step`, `vel.y += GRAVITY * h` runs in f64 while
`position += vel * h` runs entirely in f32, because `Vector3 * float` narrows
its operand first. Running the whole crate in f64 would be more accurate and
would quietly invalidate every number below.

**The RNG stays in GDScript.** The seeded baseline rests on `seed(12345)` against
Godot's global RNG and the two `randf_range` draws in `_do_contact` and
`_serve`. Moving them into Rust changes the sequence and the baseline has to be
rebuilt from nothing.

**Tuning is not compiled in.** `MOVE_SPEED`, `GROUND_DECEL`, `BRAKE`,
`NET_CLEAR_MARGIN` and the rest of the measured budget live in the `Tuning`
block, settable at runtime and authorable as a `TuningResource`. The one cost:
a value you can set cannot also be a GDScript `const`, which is resolved at
parse time — so `MotionPlan.FIRST_STEP_LAG` became `Tuning.get_first_step_lag()`.

Still in GDScript on purpose: `FootLock.gd` (a SkeletonModifier3D running every
frame, and where the tuning lives), all of `src/debug/`, and `Spike1.gd`, which
calls MotionPlan, Player and Ball from the outside — if it keeps producing the
same numbers, the Rust API is usable from GDScript.

Still to move: the integrator in `Player.gd`, and `Match.gd`, which is the one
that would actually gain wall-clock but is also the most grown-together with
`get_tree()`, `DisplayServer` and the prints.

## Acceptance test

    godot --headless --path . res://src/match/Match.tscn

Seeded, so it reproduces exactly. Compare stdout against the previous build:
165 contacts, 330 printed vectors, 7 RALLY lines, 28 MOTIONSTATS lines. The
MotionPlan/Contact move was verified byte-identical this way, as was BallSim.

The full history, including the Android/Play pipeline and CI, is at
https://github.com/nergnezor/AngelBeach (pushed through commit 4cc4830).

CLAUDE-ue5.md is the original project guide, kept for the hard-won engine
gotchas it records — most are UE-specific and do not apply here.
