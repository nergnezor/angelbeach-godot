# Player locomotion, ported from AngelBeach/Script/Player/VolleyballPlayer.as.
# Hand-rolled Euler physics with an acceleration-limited velocity, exactly as in
# the original — no CharacterBody helpers, so the numbers stay comparable.
#
# Godot space, not Unreal's: metres, Y up, ground plane XZ. The Angelscript
# constants were centimetres and Z-up; each one below carries its original value
# in the comment so the port stays checkable against the source.
extends Node3D
class_name Player

# --- Tuning, the Angelscript originals converted cm -> m ---------------------
const MOVE_SPEED := 5.85         # 585 cm/s = 420 + Difficulty(0.75) * 220
const GROUND_ACCEL := 24.0       # 0 -> full in ~0.2s
const GROUND_DECEL := 34.0       # full -> 0 in ~0.13s, ~30cm slide
const AIR_ACCEL := 3.5           # weak on purpose: no mid-jump swimming
const BACKPEDAL_SCALE := 0.62    # anisotropy floor; sideways lands at ~0.81
const JUMP_VELOCITY := 5.2
const GRAVITY := -19.0           # ~2x earth: snappy, athletic jumps
const PLAYER_HEIGHT := 0.9       # origin rides at hip height, as in the original
const BODY_MAX_TURN_RATE := 450.0  # deg/s ceiling, from this session's fix
const FACING_TARGET_RATE := 300.0  # deg/s on the TARGET
const MOVE_EPSILON := 0.3        # m/s below which motion cannot steer facing

var vel := Vector3.ZERO
var move_input := Vector3.ZERO   # ground plane, y always 0
var team := 0
var role_front := true
var is_chasing := false
var grounded := true
var floor_y := 0.0
# Set explicitly at serve time. The Angelscript port had these at
# Vector3.FORWARD, which is (0,0,-1) — a horizontal direction in Godot but
# straight DOWN in the source's Z-up space, so the anisotropy dot product read
# zero and every player started pinned to the 0.81 sideways scale.
var facing := Vector3.RIGHT
var _sm_want := Vector3.RIGHT

# Yaw about +Y, the Godot convention: 0 looks down +X, +90deg looks down -Z.
static func yaw_of(v: Vector3) -> float:
	return atan2(-v.z, v.x)

static func dir_of(yaw: float) -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))

# Legs drive hardest along the facing: backpedalling keeps the eyes on the ball
# at ~62% of forward speed, shuffling sideways ~81%. The planner reads the same
# scale, so budget and sim can never disagree.
func move_dir_speed_scale(dir: Vector3) -> float:
	if dir.length_squared() < 0.0001:
		return 1.0
	var dot := facing.normalized().dot(dir.normalized())
	return lerpf(BACKPEDAL_SCALE, 1.0, (dot + 1.0) * 0.5)

# --- visuals -----------------------------------------------------------------
# The sim node's origin rides at hip height, so the model hangs PLAYER_HEIGHT
# below it to put the feet on the sand.
#
# The rig faces +Z at identity — measured, not assumed: rendered with no
# rotation it looks straight down the camera at +Z. A yaw about +Y maps
# (0,0,1) to (sin, 0, cos), and `facing` is (cos yaw, 0, -sin yaw), so the
# model's turn is yaw + 90 degrees. It was -90 first, which pointed every
# player backwards and posed their arms against a body facing the other way.
const MODEL_YAW_OFFSET := PI * 0.5
# Measured in Spike2: the authored run cycle carries 151.5 cm/s at rate 1.0.
const CYCLE_SPEED := 1.515
const RUN_THRESHOLD := 0.35
# The rig's chest is 0.83 m across and 0.56 m deep on a body 1.45 m tall —
# two and a half times a human torso at that height, and the reason four
# players on a court read as flying slabs rather than athletes. Measured per
# bone with src/debug/Bones.tscn, not eyeballed. 0.6 takes the chest to
# 0.50 x 0.34 x 0.34, which is still broad-shouldered against a 0.33 m hip.
const TORSO_SCALE := 0.6

var human := false
var view: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var foot_lock: FootLock
var gesture: GestureIK

# --- stroke state ------------------------------------------------------------
# Set by Match, read by GestureIK. Purely presentational: none of it feeds the
# rules, so a headless run leaves all of it at rest.
const SWING_TIME := 0.35         # seconds for a through-swing to play out
const BLEND_TIME := 0.25         # seconds to reach a full contact pose

var hit_type := GestureIK.HIT_NONE
var gesture_blend := 0.0
var swing := 0.0
var serve_phase := 0.0
var aim := Vector3.ZERO
var has_aim := false
var meet := Vector3.ZERO
var has_meet := false
var ball_pos := Vector3.ZERO
var ball_live := false
var extra_crouch := 0.0
var face_target := Vector3.ZERO
var has_face_target := false
var _swing_t := -1.0

# Someone else took the ball, or it went to the other side. Drop the stroke —
# unless the swing is already going, in which case the follow-through owns the
# arms until it finishes.
func release_stroke() -> void:
	if _swing_t >= 0.0:
		return
	hit_type = GestureIK.HIT_NONE
	has_aim = false
	has_meet = false

# The moment the ball is actually struck. Everything before this is the windup;
# the follow-through plays off this envelope, so a whiff retracts along the
# windup instead of finishing a swing that never connected.
func trigger_hit() -> void:
	_swing_t = 0.0

func update_gesture(dt: float) -> void:
	if _swing_t >= 0.0:
		_swing_t += dt
		swing = clampf(_swing_t / SWING_TIME, 0.0, 1.0)
		if swing >= 1.0:
			# Follow-through done: back to the ready pose.
			_swing_t = -1.0
			swing = 0.0
			hit_type = GestureIK.HIT_NONE
			has_aim = false
			has_meet = false
	else:
		swing = 0.0
	var target := 1.0 if hit_type != GestureIK.HIT_NONE else 0.0
	gesture_blend = move_toward(gesture_blend, target, dt / BLEND_TIME)

func setup_view(scene: PackedScene) -> void:
	view = scene.instantiate()
	view.position = Vector3(0.0, -PLAYER_HEIGHT, 0.0)
	add_child(view)
	skel = _find(view, "Skeleton3D") as Skeleton3D
	anim = _find(view, "AnimationPlayer") as AnimationPlayer
	if skel != null:
		# Before the gesture solver, which measures the arm off the live pose:
		# reshape first and it measures the body it is actually going to drive.
		_slim_torso()
		# Order matters: the gesture's crouch channel moves the hips, and the
		# feet have to be planted after that. Modifiers run in child order.
		gesture = GestureIK.new()
		gesture.setup(skel, self)
		skel.add_child(gesture)
		foot_lock = FootLock.new()
		foot_lock.setup(skel)
		skel.add_child(foot_lock)
	if anim != null:
		anim.play("idle")

# Resize the chest. One skinned mesh, so there is no torso node to scale — the
# handle is the bone, exactly as with the collapsed head in GestureIK.
#
# A one-off write, not a per-frame one: none of the rig's eight animations keys
# a scale track, and none keys a position track for anything hanging off the
# chest (checked with src/debug/Bones.tscn — they key rotation, plus the hip's
# and the head's position), so nothing overwrites any of this afterwards.
#
# Uniform, because a non-uniform parent scale shears every child whose rest is
# rotated off-axis, which the arms are in every frame of every animation.
#
# Everything hanging off the chest — the two arms and the neck — is then pinned
# back to where it sits at rest, by the reciprocal on both the offset and the
# scale. That is what makes the knob mean "the torso, and only the torso":
# shoulders stay at their own width and height, arms keep their length and a
# volleyball player's reach with it, and at scale zero the chest leaves without
# taking the arms with it.
func _slim_torso() -> void:
	var chest := skel.find_bone("chest")
	if chest < 0:
		return
	# Not exactly zero: a degenerate basis makes the skinning matrix
	# non-invertible, the same reason the collapsed head stops at 0.001.
	var s := maxf(TORSO_SCALE, 0.001)
	skel.set_bone_pose_scale(chest, Vector3.ONE * s)
	for b in skel.get_bone_count():
		if skel.get_bone_parent(b) != chest:
			continue
		skel.set_bone_pose_position(b, skel.get_bone_rest(b).origin / s)
		skel.set_bone_pose_scale(b, Vector3.ONE / s)
	skel.force_update_all_bone_transforms()

# Four identical rigs on a beige court is unreadable — tint yours so you can
# find yourself without hunting.
func mark_as_human() -> void:
	if view == null:
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.20, 0.55, 0.95)
	m.roughness = 0.7
	_tint(view, m)

func _tint(n: Node, m: Material) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = m
	for c in n.get_children():
		_tint(c, m)

func _find(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null

func _update_view() -> void:
	if view == null:
		return
	view.rotation.y = yaw_of(facing) + MODEL_YAW_OFFSET
	if anim == null:
		return
	var speed := Vector3(vel.x, 0.0, vel.z).length()
	if speed > RUN_THRESHOLD:
		if anim.current_animation != "run":
			anim.play("run")
		# Rate-matching alone leaves 354 cm/s of skate (Spike2); FootLock is what
		# actually plants the foot. Both are on, for the same reason as Spike3 C.
		anim.speed_scale = clampf(speed / CYCLE_SPEED, 0.1, 6.0)
	elif anim.current_animation != "idle":
		anim.play("idle")
		anim.speed_scale = 1.0

# --- Jumps, dives and the two crouch channels --------------------------------
# Ported from VolleyballPlayer.as. The split between the channels is the part
# worth keeping straight, and the source spells out why: ExtraCrouch is written
# by FRAME-RATE transients (split step, dive, jump load, landing absorb, air
# tuck) and decays every frame, so it releases the instant its envelope ends.
# HeldCrouch is written by the AI's TICK-RATE stance requests and is held across
# the reaction gap, because clearing it per frame made poses sawtooth between
# ticks. One lifetime each; a transient peak must not get frozen at the held
# rate.
const LOADED_JUMP_VELOCITY := 6.6   # 660 cm/s: ~115 cm of rise
const JUMP_LOAD_DURATION := 0.16
const JUMP_LOAD_BRAKE := 0.25       # the gather turns momentum into height
const DIVE_DURATION := 0.42
const DIVE_RECOVERY := 0.75
const DIVE_SPEED_MUL := 1.75
const DIVE_HOP := 2.0               # the lunge leaves the ground for a beat
const CROUCH_DECAY := 2.5
const CROUCH_HOLD := 0.25

# Nobody crosses the net. The source clamps each player to their own half with a
# 5 cm buffer at the plane, which is the rule that keeps a block on its own side.
const HALF_MIN_X := 0.05
const HALF_MAX_X := 9.0
const HALF_Z := 4.5

var court: Node = null              # set when there is a court to dent
var jump_load_t := 0.0
var dive_t := 0.0
var dive_recover_t := 0.0
var dive_dir := Vector3.RIGHT
var held_crouch := 0.0
var _crouch_hold_t := 0.0
var _land_absorb_t := 0.0
var _land_absorb_depth := 0.5
var _step_timer := 0.0

# --- Split step ---------------------------------------------------------------
# The signature read-and-react habit of elite defenders: a quick loading dip with
# planted feet the instant the OPPONENT strikes, then explode toward the read.
#
# Two things the source learned the hard way. It fires ONCE, on the attacker's
# swing, not on every touch of their possession — firing on their receive and set
# and attack stacked three dips in a row and read as the body shaking up and down
# before we ever dug the ball. And it is cancelled the moment we commit to a
# reach, because letting the rise phase overlap the dig produced a fast up-down
# bob right at the meet: a real player with no time to gather simply skips the
# hop.
# --- Reaction: the AI does not think every frame ------------------------------
# Two timers, and the source keeps them separate on purpose. PERCEPTION_LATENCY
# is human visual reaction to an unanticipated EVENT — it fires once, when the
# ball's state changes under us. reaction_delay is the decision CADENCE: how
# often the AI re-decides at all. Difficulty picks it, lerp(0.35, 0.04), so a
# weaker player is not worse at running, they are later to know.
#
# The split step is deliberately NOT gated by either: the read has to land on the
# opponent's strike, and a dip that arrives a tick late is not a read.
const PERCEPTION_LATENCY := 0.16

# Difficulty drives three things at once, and that is the whole idea: a weaker
# opponent runs a little slower, decides a little later, and aims a little
# looser. It is one number, not three sliders that can disagree.
var difficulty := 0.75
var move_speed := MOVE_SPEED
var reaction_delay := 0.1175      # lerp(0.35, 0.04, difficulty 0.75)

func set_difficulty(d: float) -> void:
	difficulty = clampf(d, 0.0, 1.0)
	move_speed = 4.20 + difficulty * 2.20     # 420 + Difficulty * 220 cm/s
	reaction_delay = lerpf(0.35, 0.04, difficulty)
var reaction_t := 0.0
var perception_t := 0.0
var percept_stamp := -12345
# The last decision, held between ticks. Movement continues toward it every
# frame — a player who has decided keeps running while they think about the next
# thing.
var plan_goal := Vector3.ZERO
var plan_speed := 1.0
var has_plan := false

const SPLIT_STEP_DURATION := 0.26
const SPLIT_STEP_MOVE_SCALE := 0.12   # feet are planted; only a shuffle

var split_step_t := 0.0
var is_reaching := false

func start_split_step() -> void:
	if is_reaching:
		return
	split_step_t = SPLIT_STEP_DURATION

func _update_split_step(dt: float) -> void:
	if is_reaching:
		split_step_t = 0.0
		return
	if split_step_t > 0.0:
		split_step_t -= dt
		# Sink and rise across the duration — half a sine, so it returns to
		# standing on its own rather than needing a release.
		var prog := 1.0 - split_step_t / SPLIT_STEP_DURATION
		extra_crouch = maxf(extra_crouch, 0.5 * sin(prog * PI))

func is_diving() -> bool:
	return dive_t > 0.0

func can_dive() -> bool:
	return grounded and dive_t <= 0.0 and dive_recover_t <= 0.0

func is_jump_loading() -> bool:
	return jump_load_t > 0.0

func jump() -> void:
	if grounded:
		vel.y = JUMP_VELOCITY
		grounded = false

func start_loaded_jump() -> void:
	if not grounded or jump_load_t > 0.0:
		return
	# The plant brakes the run: momentum becomes height, and the small residue
	# drifts the body into the contact during the ascent.
	vel.x *= JUMP_LOAD_BRAKE
	vel.z *= JUMP_LOAD_BRAKE
	jump_load_t = JUMP_LOAD_DURATION

func start_dive(world_dir: Vector3) -> void:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)
	if flat.length_squared() < 0.01:
		return
	dive_dir = flat.normalized()
	dive_t = DIVE_DURATION
	vel.y = DIVE_HOP
	grounded = false

# Held across the AI's reaction gap, unlike extra_crouch.
func request_crouch(amount: float) -> void:
	held_crouch = maxf(held_crouch, amount)
	_crouch_hold_t = CROUCH_HOLD

func crouch_amount() -> float:
	return clampf(maxf(extra_crouch, held_crouch), 0.0, 1.0)

func _update_dive(dt: float) -> void:
	if dive_t > 0.0:
		dive_t -= dt
		# The dive owns the velocity and the facing while it is active.
		vel.x = dive_dir.x * move_speed * DIVE_SPEED_MUL
		vel.z = dive_dir.z * move_speed * DIVE_SPEED_MUL
		face_target = position + dive_dir
		has_face_target = true
		extra_crouch = 1.0
		if dive_t <= 0.0:
			dive_recover_t = DIVE_RECOVERY
	elif dive_recover_t > 0.0:
		dive_recover_t -= dt
		# Getting up: still low, easing back to standing.
		extra_crouch = maxf(extra_crouch, 0.85 * (dive_recover_t / DIVE_RECOVERY))

func _update_jump_load(dt: float) -> void:
	if jump_load_t <= 0.0:
		return
	if not grounded:
		jump_load_t = 0.0        # knocked airborne: cancel
		return
	# Sink through the load, deepest right before the explosion.
	extra_crouch = maxf(extra_crouch, 0.65 * (1.0 - jump_load_t / JUMP_LOAD_DURATION))
	jump_load_t -= dt
	if jump_load_t <= 0.0:
		vel.y = LOADED_JUMP_VELOCITY
		grounded = false

func step(dt: float) -> void:
	# Both crouch channels decay first, so anything that re-asserts this frame
	# writes over a falling value rather than a stale peak.
	extra_crouch = maxf(0.0, extra_crouch - CROUCH_DECAY * dt)
	_crouch_hold_t -= dt
	if _crouch_hold_t <= 0.0:
		held_crouch = maxf(0.0, held_crouch - CROUCH_DECAY * dt)

	_update_split_step(dt)
	_update_dive(dt)
	_update_jump_load(dt)
	if not is_diving():
		_apply_move_input(dt)

	if not grounded:
		vel.y += GRAVITY * dt
	var was_grounded := grounded
	var fall_speed := -vel.y
	position += vel * dt
	if position.y <= floor_y + PLAYER_HEIGHT:
		position.y = floor_y + PLAYER_HEIGHT
		vel.y = 0.0
		grounded = true
	else:
		grounded = false

	# Own half only, and never through the net plane.
	var s := -1.0 if team == 0 else 1.0
	position.x = clampf(position.x, minf(s * HALF_MIN_X, s * HALF_MAX_X),
		maxf(s * HALF_MIN_X, s * HALF_MAX_X))
	position.z = clampf(position.z, -HALF_Z, HALF_Z)

	_landing_and_footsteps(dt, was_grounded, fall_speed)
	_update_facing(dt)
	sample_motion(dt)

# Sand FX and landing absorption: knees flex on touchdown, deeper after a bigger
# fall — a stiff-legged landing is both unphysical and unreadable.
func _landing_and_footsteps(dt: float, was_grounded: bool, fall_speed: float) -> void:
	var feet := Vector3(position.x, floor_y, position.z)
	if grounded and not was_grounded and fall_speed > 1.2:
		var strength := clampf(fall_speed / 6.0, 0.3, 1.6)
		if court != null:
			court.deform_sand(feet, 0.24, 0.04 + strength * 0.06)
		_land_absorb_t = 0.3
		_land_absorb_depth = clampf(fall_speed / 9.0, 0.3, 0.7)
	if _land_absorb_t > 0.0:
		_land_absorb_t -= dt
		extra_crouch = maxf(extra_crouch, _land_absorb_depth * (_land_absorb_t / 0.3))

	# Airborne attack tuck: knees come up through the ascent of a spike or block
	# jump and release on the way down — the legs trail dead otherwise.
	if not grounded and vel.y > -1.0 \
			and (hit_type == GestureIK.HIT_SPIKE or hit_type == GestureIK.HIT_BLOCK):
		extra_crouch = maxf(extra_crouch, 0.35)

	if grounded:
		var hspeed := Vector2(vel.x, vel.z).length()
		if hspeed > 0.8:
			_step_timer += dt
			if _step_timer >= clampf(1.2 / hspeed, 0.18, 0.5):
				_step_timer = 0.0
				if court != null:
					court.deform_sand(feet, 0.16, 0.03)
		else:
			_step_timer = 0.0

func _apply_move_input(dt: float) -> void:
	var cur := Vector3(vel.x, 0.0, vel.z)
	var in_dir := Vector3(move_input.x, 0.0, move_input.z)
	var target := in_dir * (move_speed * move_dir_speed_scale(in_dir))
	var rate: float
	if not grounded:
		rate = AIR_ACCEL
	elif target.length_squared() > cur.length_squared() + 0.0001:
		rate = GROUND_ACCEL
	else:
		rate = GROUND_DECEL
	var delta := target - cur
	var max_step := rate * dt
	if delta.length() > max_step:
		delta = delta.normalized() * max_step
	vel.x = cur.x + delta.x
	vel.z = cur.z + delta.z

# One rate-limited target that every source feeds through, then a proportional
# approach with an athletic ceiling — both from this session's yaw fix, which
# took the measured peak from 1536 deg/s down to 450.
func _update_facing(dt: float) -> void:
	# Watch the ball you are going to play. Everything downstream still goes
	# through the same rate-limited target, so this cannot outrun the turn
	# ceiling — and it feeds move_dir_speed_scale, which is the point: a player
	# who backpedals to a ball is meant to be slower than one who runs at it.
	var raw: Vector3
	if has_face_target:
		raw = Vector3(face_target.x - position.x, 0.0, face_target.z - position.z)
		if raw.length() < 0.05:
			return
	else:
		raw = Vector3(vel.x, 0.0, vel.z)
		if raw.length() < MOVE_EPSILON:
			return
	raw = raw.normalized()
	var cur_yaw := yaw_of(_sm_want)
	var new_yaw := yaw_of(raw)
	var w_step := clampf(wrapf(new_yaw - cur_yaw, -PI, PI),
		-deg_to_rad(FACING_TARGET_RATE) * dt, deg_to_rad(FACING_TARGET_RATE) * dt)
	var sm_yaw := cur_yaw + w_step
	_sm_want = dir_of(sm_yaw)

	var face_yaw := yaw_of(facing)
	var delta := wrapf(sm_yaw - face_yaw, -PI, PI)
	var step_r := delta * clampf(8.0 * dt, 0.0, 1.0)
	var max_r := deg_to_rad(BODY_MAX_TURN_RATE) * dt
	step_r = clampf(step_r, -max_r, max_r)
	facing = dir_of(face_yaw + step_r)

func move_toward_ground(target: Vector3, speed_cap: float = 1.0) -> void:
	var d := Vector3(target.x - position.x, 0.0, target.z - position.z)
	var dist := d.length()
	# Stop zone must exceed braking distance or the player shakes on the spot.
	if dist <= 0.25:
		move_input = Vector3.ZERO
		return
	var scale: float = minf(clampf(dist / 1.5, 0.25, 1.0), speed_cap)
	# Feet planted through the read: only a shuffle is allowed until the dip
	# releases.
	if split_step_t > 0.0:
		scale *= SPLIT_STEP_MOVE_SCALE
	move_input = d.normalized() * scale


# --- telemetry, same shape and thresholds as the UE MOTIONSTATS line ---------
const TELEMETRY_MOVING := 0.6    # m/s; 60 cm/s in the original
var _mv_time := 0.0
var _move_flips := 0
var _yaw_flips := 0
var _yaw_sum := 0.0
var _yaw_n := 0.0
var _yaw_max := 0.0
var _prev_v := Vector3.ZERO
var _prev_yaw := 0.0
var _prev_rate := 0.0

func sample_motion(dt: float) -> void:
	var v := Vector3(vel.x, 0.0, vel.z)
	var pv := Vector3(_prev_v.x, 0.0, _prev_v.z)
	if v.length() > TELEMETRY_MOVING:
		_mv_time += dt
		if pv.length() > TELEMETRY_MOVING and v.dot(pv) < -0.2 * v.length() * pv.length():
			_move_flips += 1
	var yaw := rad_to_deg(yaw_of(facing))
	var rate := wrapf(yaw - _prev_yaw, -180.0, 180.0) / dt
	if absf(rate) > 20.0:
		_yaw_sum += absf(rate)
		_yaw_n += 1.0
		_yaw_max = maxf(_yaw_max, absf(rate))
	if absf(rate) > 60.0 and absf(_prev_rate) > 60.0 and rate * _prev_rate < 0.0:
		_yaw_flips += 1
	if absf(rate) > 20.0:
		_prev_rate = rate
	_prev_yaw = yaw
	_prev_v = vel

func emit_motion_stats() -> void:
	var mean := 0.0
	if _yaw_n > 0.0:
		mean = _yaw_sum / _yaw_n
	print("MOTIONSTATS %s moving=%d moveFlips=%d yawFlips=%d yawRateMean=%d yawRateMax=%d"
		% [name, int(_mv_time * 100.0), _move_flips, _yaw_flips, int(mean), int(_yaw_max)])
	_mv_time = 0.0
	_move_flips = 0
	_yaw_flips = 0
	_yaw_sum = 0.0
	_yaw_n = 0.0
	_yaw_max = 0.0
