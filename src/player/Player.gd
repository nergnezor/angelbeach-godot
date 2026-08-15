# Player locomotion, ported from AngelBeach/Script/Player/VolleyballPlayer.as.
# Hand-rolled Euler physics with an acceleration-limited velocity, exactly as in
# the original — no CharacterBody helpers, so the numbers stay comparable.
extends Node3D
class_name Player

# --- Tuning, identical to the Angelscript originals --------------------------
const MOVE_SPEED := 585.0        # 420 + Difficulty(0.75) * 220
const GROUND_ACCEL := 2400.0     # 0 -> full in ~0.2s
const GROUND_DECEL := 3400.0     # full -> 0 in ~0.13s, ~30cm slide
const AIR_ACCEL := 350.0         # weak on purpose: no mid-jump swimming
const BACKPEDAL_SCALE := 0.62    # anisotropy floor; sideways lands at ~0.81
const JUMP_VELOCITY := 520.0
const GRAVITY := -1900.0         # ~2x earth: snappy, athletic jumps
const PLAYER_HEIGHT := 90.0
const BODY_MAX_TURN_RATE := 450.0  # deg/s ceiling, from this session's fix
const FACING_TARGET_RATE := 300.0  # deg/s on the TARGET

var vel := Vector3.ZERO
var move_input := Vector2.ZERO
var team := 0
var role_front := true
var is_chasing := false
var grounded := true
var floor_z := 0.0
var facing := Vector3.FORWARD
var _sm_want := Vector3.FORWARD

# Legs drive hardest along the facing: backpedalling keeps the eyes on the ball
# at ~62% of forward speed, shuffling sideways ~81%. The planner reads the same
# scale, so budget and sim can never disagree.
func move_dir_speed_scale(dir: Vector3) -> float:
	if dir.length_squared() < 0.01:
		return 1.0
	var dot := facing.normalized().dot(dir.normalized())
	return lerpf(BACKPEDAL_SCALE, 1.0, (dot + 1.0) * 0.5)

func step(dt: float) -> void:
	_apply_move_input(dt)
	vel.z += GRAVITY * dt
	position += vel * dt
	if position.z <= floor_z + PLAYER_HEIGHT:
		position.z = floor_z + PLAYER_HEIGHT
		vel.z = 0.0
		grounded = true
	else:
		grounded = false
	_update_facing(dt)
	sample_motion(dt)

func _apply_move_input(dt: float) -> void:
	var cur := Vector3(vel.x, vel.y, 0.0)
	var in_dir := Vector3(move_input.x, move_input.y, 0.0)
	var target := in_dir * (MOVE_SPEED * move_dir_speed_scale(in_dir))
	var rate: float
	if not grounded:
		rate = AIR_ACCEL
	elif target.length_squared() > cur.length_squared() + 1.0:
		rate = GROUND_ACCEL
	else:
		rate = GROUND_DECEL
	var delta := target - cur
	var max_step := rate * dt
	if delta.length() > max_step:
		delta = delta.normalized() * max_step
	vel.x = cur.x + delta.x
	vel.y = cur.y + delta.y

# One rate-limited target that every source feeds through, then a proportional
# approach with an athletic ceiling — both from this session's yaw fix, which
# took the measured peak from 1536 deg/s down to 450.
func _update_facing(dt: float) -> void:
	var raw := Vector3(vel.x, vel.y, 0.0)
	if raw.length() < 30.0:
		return
	raw = raw.normalized()
	var cur_yaw := atan2(_sm_want.y, _sm_want.x)
	var new_yaw := atan2(raw.y, raw.x)
	var w_step := clampf(wrapf(new_yaw - cur_yaw, -PI, PI),
		-deg_to_rad(FACING_TARGET_RATE) * dt, deg_to_rad(FACING_TARGET_RATE) * dt)
	var sm_yaw := cur_yaw + w_step
	_sm_want = Vector3(cos(sm_yaw), sin(sm_yaw), 0.0)

	var face_yaw := atan2(facing.y, facing.x)
	var delta := wrapf(sm_yaw - face_yaw, -PI, PI)
	var step_r := delta * clampf(8.0 * dt, 0.0, 1.0)
	var max_r := deg_to_rad(BODY_MAX_TURN_RATE) * dt
	step_r = clampf(step_r, -max_r, max_r)
	var out := face_yaw + step_r
	facing = Vector3(cos(out), sin(out), 0.0)

func move_toward_2d(target: Vector3, speed_cap: float = 1.0) -> void:
	var d := Vector3(target.x - position.x, target.y - position.y, 0.0)
	var dist := d.length()
	# Stop zone must exceed braking distance or the player shakes on the spot.
	if dist <= 25.0:
		move_input = Vector2.ZERO
		return
	var scale: float = minf(clampf(dist / 150.0, 0.25, 1.0), speed_cap)
	var n := d.normalized()
	move_input = Vector2(n.x * scale, n.y * scale)


# --- telemetry, same shape and thresholds as the UE MOTIONSTATS line ---------
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
	var v := Vector3(vel.x, vel.y, 0.0)
	var pv := Vector3(_prev_v.x, _prev_v.y, 0.0)
	if v.length() > 60.0:
		_mv_time += dt
		if pv.length() > 60.0 and v.dot(pv) < -0.2 * v.length() * pv.length():
			_move_flips += 1
	var yaw := rad_to_deg(atan2(facing.y, facing.x))
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
