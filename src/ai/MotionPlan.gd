# MotionPlan — the first-principles movement budget, ported from
# AngelBeach/Script/AI/MotionPlan.as.
#
# This file is the point of the spike. In the Angelscript original it is 263
# lines with ZERO engine calls — pure ballistics and kinematics. If the port is
# cheap, it should come across almost word for word, and the numbers it produces
# must match the original exactly. Anything that drifts here is a real porting
# cost; anything that doesn't is work we keep for free.
#
# Every "how do I play this ball" decision is a race between three clocks:
#   BALL TIME  tau(z) — when the flight next descends through height z
#   BODY TIME        — first-step lag + acceleration-limited run to the spot
#   HAND TIME        — the IK effectors converging the last arm's length
# A contact is playable iff tau >= body + hand + margin.
class_name MotionPlan

# --- Measured rig/sim constants (identical to the Angelscript originals) ------
const FIRST_STEP_LAG := 0.12      # MB_FirstStepLag
const HAND_SPEED := 250.0         # MB_HandSpeed, cm/s
const HAND_TRAVEL := 90.0         # MB_HandTravel, cm
const GESTURE_LEAD := 1.15        # MB_GestureLead
const MARGIN := 0.08              # MB_Margin
const SETTLE_TIME := 0.45         # MB_SettleTime
const BRAKE := 3400.0             # MB_Brake — MUST mirror the player's ground decel
const BALL_GRAVITY := -980.0      # the ball keeps real gravity

# Time for the ball to next descend through height z, solved analytically.
# Returns [reached: bool, position: Vector3, time: float].
static func ball_time_to_height(pos: Vector3, vel: Vector3, target_z: float) -> Array:
	# z(t) = z0 + vz*t + 0.5*g*t^2  ->  solve for the LATER root (descending).
	var a := 0.5 * BALL_GRAVITY
	var b := vel.z
	var c := pos.z - target_z
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return [false, pos, 0.0]
	var sq := sqrt(disc)
	# Two roots; we want the smallest strictly-positive one on the way DOWN.
	var t1 := (-b + sq) / (2.0 * a)
	var t2 := (-b - sq) / (2.0 * a)
	var t := -1.0
	for cand in [min(t1, t2), max(t1, t2)]:
		if cand > 0.001:
			t = cand
			break
	if t < 0.0:
		return [false, pos, 0.0]
	var hit := Vector3(pos.x + vel.x * t, pos.y + vel.y * t, target_z)
	return [true, hit, t]

# TRAPEZOID PROFILE: every approach both accelerates AND brakes to a stop — a
# contact demands a planted body, so a travel time that ignores braking lies
# exactly when it matters.
static func body_travel_time(dist: float, vmax: float, accel: float) -> float:
	if dist <= 1.0:
		return 0.0
	var inv_sum := 1.0 / accel + 1.0 / BRAKE
	var ramp_dist := 0.5 * vmax * vmax * inv_sum
	var t: float
	if dist <= ramp_dist:
		# Triangle: never reaches vmax. Peak from D = v^2/2*(1/a+1/b).
		var peak := sqrt(2.0 * dist / inv_sum)
		t = peak * inv_sum
	else:
		t = dist / vmax + 0.5 * vmax * inv_sum
	return FIRST_STEP_LAG + t

# The inverse: the exact cruise speed that covers dist in t_avail arriving
# stopped. Smaller root — the larger wastes speed and brakes longer.
static func required_cruise_speed(dist: float, t_avail: float, vmax: float, accel: float) -> float:
	if dist <= 1.0:
		return 0.0
	if t_avail <= 0.05:
		return vmax
	var inv_sum := 1.0 / accel + 1.0 / BRAKE
	var disc := t_avail * t_avail - 2.0 * inv_sum * dist
	if disc <= 0.0:
		return vmax
	return clampf((t_avail - sqrt(disc)) / inv_sum, 0.0, vmax)

# Hand time: the effectors cannot track from a sprinting body, so most of this
# must come after the body has largely arrived.
static func hand_time() -> float:
	return HAND_TRAVEL / HAND_SPEED

# Is this contact playable, and how fast must the body run to make it?
# Returns { playable, speed_fraction, body_time, hand_time, slack }.
static func plan(dist: float, tau: float, vmax: float, accel: float) -> Dictionary:
	var body_t := body_travel_time(dist, vmax, accel)
	var hand_t := hand_time()
	var slack := tau - (body_t + hand_t + MARGIN)
	if slack < 0.0:
		return {"playable": false, "speed_fraction": 1.0, "body_time": body_t,
				"hand_time": hand_t, "slack": slack}
	# Run exactly as fast as the budget demands, planted SETTLE_TIME before
	# contact — efficiency means no WASTED speed, not zero cushion.
	var avail: float = maxf(tau - SETTLE_TIME - FIRST_STEP_LAG, 0.05)
	var need := required_cruise_speed(dist, avail, vmax, accel)
	var frac := clampf((need / vmax) * 1.15, 0.35, 1.0)
	return {"playable": true, "speed_fraction": frac, "body_time": body_t,
			"hand_time": hand_t, "slack": slack}
