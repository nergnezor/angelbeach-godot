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

# Shrink the chest. One skinned mesh, so there is no torso node to scale — the
# handle is the bone, exactly as with the collapsed head in GestureIK.
#
# A one-off write, not a per-frame one: none of the rig's eight animations keys
# a scale track (checked with src/debug/Bones.tscn — they key rotation, plus the
# hip's position), so nothing overwrites this afterwards.
#
# Uniform, because a non-uniform parent scale shears every child whose rest is
# rotated off-axis, which the arms are in every frame of every animation. The
# arms are then scaled back up by the reciprocal so that only the torso shrinks:
# the shoulders come inboard and down with the chest, but the arms keep their
# length, and a volleyball player's reach with it.
func _slim_torso() -> void:
	var chest := skel.find_bone("chest")
	if chest < 0:
		return
	skel.set_bone_pose_scale(chest, Vector3.ONE * TORSO_SCALE)
	for n in ["r-arm", "l-arm"]:
		var b := skel.find_bone(n)
		if b >= 0:
			skel.set_bone_pose_scale(b, Vector3.ONE / TORSO_SCALE)
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

func step(dt: float) -> void:
	_apply_move_input(dt)
	vel.y += GRAVITY * dt
	position += vel * dt
	if position.y <= floor_y + PLAYER_HEIGHT:
		position.y = floor_y + PLAYER_HEIGHT
		vel.y = 0.0
		grounded = true
	else:
		grounded = false
	_update_facing(dt)
	sample_motion(dt)

func _apply_move_input(dt: float) -> void:
	var cur := Vector3(vel.x, 0.0, vel.z)
	var in_dir := Vector3(move_input.x, 0.0, move_input.z)
	var target := in_dir * (MOVE_SPEED * move_dir_speed_scale(in_dir))
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
