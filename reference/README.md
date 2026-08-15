# Reference — the Unreal/Angelscript original

Read-only. This is the source the Godot port is being made from, kept only
until the port is complete. It is not built, not run, and not maintained.

Nothing here is engine-neutral by accident: the parts worth carrying over are
the *reasoning* in the comments, not the UE API calls. Five passes of tuning are
recorded in them — the movement budget's measured constants, why contacts are
ballistic placement rather than reflection, why every boolean that feeds a pose
has hysteresis, and the long autopsies of the failures that led to each.

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

    Script/AI/MotionPlan.as       -> src/ai/MotionPlan.gd
    Script/World/Ball.as          -> src/world/Ball.gd  + src/world/Contact.gd
    locomotion + facing           -> src/player/Player.gd

The full history, including the Android/Play pipeline and CI, is at
https://github.com/nergnezor/AngelBeach (pushed through commit 4cc4830).

CLAUDE-ue5.md is the original project guide, kept for the hard-won engine
gotchas it records — most are UE-specific and do not apply here.
