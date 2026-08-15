# AngelBeach — beach volleyball (UE5.7, Hazelight Angelscript fork)

A beach volleyball game written almost entirely in Angelscript (`Script/*.as`).
Players are `APawn`s with a Manny skeletal mesh; a custom physics ball bounces off
their arm bones; AI plays structured volleyball (receive → set → attack).

## Build / reload workflow

- **Logic-only changes** (edit a method body): **Soft Reload** (Ctrl+Shift+F11) hot-reloads.
- **New member variable / UPROPERTY / changed spawn layout**: requires a **Full Reload**
  (Ctrl+Alt+F11 or restart editor) — soft reload will NOT pick it up.
- Logs: `Saved/Logs/BeachVolleyball.log`. Angelscript `Log()` lines are prefixed `Angelscript:`.

## Autonomous verification (headless — no human at the editor)

Two debug GameModes in `Script/Debug/` give a closed see-it-yourself loop:

- **PhotoBooth** (`APhotoBoothGameMode`): one player + frozen ball, cycles every hit
  pose, photographs each from 3 camera angles, logs hand-vs-ball / hand-vs-IK-target
  distances (`BOOTH` lines) so images pair with numbers.
- **MatchFilmer** (`AMatchFilmerGameMode`): the real match, one HighResShot every
  0.45s during rallies (`FILM` lines with ball pos/touches), quits after 60 shots.

Launch (screenshots land in `Saved/Screenshots/LinuxEditor/`):

    ~/UnrealEngine-Angelscript/Engine/Binaries/Linux/UnrealEditor BeachVolleyball.uproject \
      "/Game/CourtLevel?game=/Script/Angelscript.PhotoBoothGameMode" \
      -game -RenderOffscreen -resx=1280 -resy=720 -nosplash -unattended \
      -asdebugport=59999 -abslog=/tmp/run.log

Hard-won gotchas:
- **`-asdebugport=59999` is required**: otherwise the VSCode Angelscript debugger
  auto-attaches to the headless run and can pause it indefinitely.
- **A script compile error in `-game` opens a dialog that blocks frame 0 forever**
  (even with `-unattended`). If a run sits at frame `[  0]`, grep the log for
  `Angelscript: Error`. Always wrap runs in `timeout -k 15 <secs>`.
- **`HighResShot` captures ~4 frames AFTER the console command** — don't move the
  camera in that window or every PNG shows the next camera position (PhotoBooth
  holds 0.5s after each shot for this reason).

## Animation architecture (no engine fork)

Angelscript drives `UVolleyballAnimInstance` (in `Player.as`) by writing `BlueprintReadWrite`
properties every frame. An **Animation Blueprint reparented to `UVolleyballAnimInstance`**
(`/Game/Characters/Mannequin/ABP_VolleyballPlayer`) reads them and blends in its AnimGraph.
`Player.as` loads it by path and falls back to the raw anim instance if absent.

### Bone control — READ THIS BEFORE TOUCHING ARM POSES

- **No bone *setter* is bound in this fork.** `SetBoneRotation` / `SetBoneRotationByName` /
  `SetBoneTransformByName` do NOT exist. Only `Mesh.GetBoneTransform(FName)` is bound (read-only,
  used for arm-vs-ball collision in `GetArmContact` and for `LogArmGeometry`).
- Arm gestures are driven via **Full Body IK**: `HandTargetR/L`, `ElbowPoleR/L`, `HandRotR/L`,
  `CrouchAmount` (world-space effector targets computed per hit type in `PlayerIK.as`).
- **The FBIK effectors interpolate toward their targets with limited speed** (node setting
  in the ABP, not script-controllable): fast-moving targets outrun the arms — a 1.15s serve
  toss left the hand half a metre behind its target, and sprinting players can't converge
  mid-run. Choreograph UNHURRIED (serve = 1.9s), give gestures ~0.3s lead time before
  contact, and verify moving-target behavior in MatchFilmer bursts — the PhotoBooth's
  static poses ALWAYS converge and will hide this class of problem.
  The older `ArmRotR/L` + `Transform (Modify) Bone` approach below is SUPERSEDED but the
  bone-space lessons still apply if Modify Bone nodes come back:
- **The Modify Bone nodes are configured: Rotation Mode = `Add to Existing`, Rotation Space =
  `Bone Space`.** This is critical: Pitch/Yaw/Roll are interpreted in the *bone's own* frame,
  NOT component/world space. So "Pitch" does NOT mean "lift in world up" — axes are relative to
  the upperarm bone's local orientation.
- **Confirmed empirically: Pitch ≈ 180 on `upperarm_r` raises the arm straight up.** Pitch is the
  lift axis in this rig's bone space. Calibrate other poses by sweeping Pitch, not by guessing
  Roll/Yaw — pure Roll/Yaw probes produced confusing actor-space results because the measurement
  was in actor space while the rotation is applied in bone space.
- `LogArmGeometry()` logs hand-vs-shoulder offset in **actor space** (fwd=+X, side=+Y, up=+Z).
  Useful, but remember it measures the *result* of a *bone-space* rotation — don't reason about
  the input axes from these numbers directly.
- `bAxisProbe` (set on one player in `GameMode`) cycles probe rotations and logs the outcome —
  the tool for calibrating arm angles. Remove it (and `bDebugAI`/`bDebugHit`) once poses are dialed.

### Mesh / skeleton

- Player mesh: `/Game/Characters/Mannequins/Meshes/SKM_Manny_Simple` (renderable SkeletalMesh).
- **`SK_Mannequin` is the *Skeleton* asset, NOT a mesh.** `Cast<USkeletalMesh>` on it returns
  null → fallback boxes. Load `SKM_Manny_Simple` for the body; the skeleton is referenced by it.
- The full template Manny library (mesh, skeleton, all anim clips incl. Death/dive,
  BS_Idle_Walk_Run, Dash) was copied into `Content/Characters/Mannequins/` (gitignored).
- **Asset version trap:** template assets were saved in UE 5.6 (`++UE5+Release-5.6`); this
  engine is 5.7 (`++UE5+Main`). 5.6 assets fail to load at runtime until re-saved in the 5.7
  editor (Content Browser → folder → Save All upgrades the package format).
- The Anim BP must target this same skeleton or bone driving silently breaks.

## Gameplay

- `Ball.as`: custom Euler physics, procedural sphere mesh. `CheckPlayerCollision()` iterates
  `AVolleyballPlayer`s, gates on `CanContactBall()`, tests arm bones via `GetArmContact()`, and
  lets the player compute the bounce in `OnBallContact()`. Contact model: dig/set with an aim
  are **ballistic placement** (`BallisticVelocity()` solves the arc to the aim spot + 15% of the
  physical reflection); spikes stay reflection + swing impulse. Without ballistic sets the ball
  never reached `SpikeStrikeZ` and the AI could never jump-attack.
- `AIPlayer.as`: state machine. `bIMadeLastTouch` enforces digger ≠ setter ≠ attacker (no double
  contact, no 4th-touch fault). `CanContactBall()` returns `!bIMadeLastTouch`. AI calls `AimAt()`
  (sets `DesiredAim`/`bHasAim`) rather than hitting the ball directly.
- `HumanPlayer.as` extends `AAIPlayer` — AI fallback until gamepad input.

## Git / assets

- **Keep the repo small: no binary assets in git.** `.gitignore` excludes `Content/Characters/`,
  `Content/*.uasset`, `Content/*.umap` (except `CourtLevel.umap`). Mesh/skeleton sources live in
  engine plugins (MoverExamples), not the repo. The Anim BP is authored in-editor and not tracked.

### Commit messages — these become the Play release notes

Write subjects as **Conventional Commits**: `type(scope): subject`. Every push to `main`
publishes to Play Internal Testing, and `scripts/release_notes.py` groups the commit
subjects of that push by type into the "What's new" testers see. The type picks the section:

| type | section | | type | section |
|---|---|---|---|---|
| `feat` | **New** | | `revert` | **Reverted** |
| `fix` | **Fixes** | | `build` `chore` `ci` `docs` `refactor` `style` `test` | **Under the hood** |
| `perf` | **Performance** | | anything unprefixed | **Other** |

- A `!` before the colon (`feat!:`, `fix(ai)!:`) moves the line to a **Breaking** section at the top.
- The type prefix is stripped from gameplay lines (under "Fixes", a leading `fix:` is noise) but
  kept on plumbing ones, so a `ci:` line reads as plumbing rather than as a gameplay change.
- **The subject is player-facing.** Write what changed, not what you touched:
  `fix(court): sand renders as sand instead of a checkerboard`, not `fix: material`.
- Merge commits are skipped, so a merge subject never has to carry meaning.
- Play caps notes at 500 chars; the script trims lowest-priority sections first and appends
  "…and N more" rather than silently dropping commits. Preview any range locally:

      git log --no-merges --format='%s' <from>..<to> | python3 scripts/release_notes.py
