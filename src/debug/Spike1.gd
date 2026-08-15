# Headless spike harness.
#
# Purpose: answer three questions with numbers, not opinion.
#   1. Does the movement budget port unchanged? (PORTCHECK below)
#   2. Does a headless run + the same telemetry work here?
#   3. What do the metrics that mattered in UE look like in this engine?
#
# Distances print in metres. The Angelscript original works in centimetres, so
# every PORTCHECK line below is its value / 100 — the times must match exactly.
#
# Run:  ~/godot4/Godot_v4.7.1-stable_linux.x86_64 --headless --path . --quit-after 900
extends Node3D

const RALLIES := 12
const HZ := 60.0
const BUMP_Y := 1.12

var ball: Ball
var player: Player

# --- telemetry, same shape as the UE MOTIONSTATS line ------------------------
var moving_time := 0.0
var move_flips := 0
var yaw_rate_sum := 0.0
var yaw_rate_samples := 0.0
var yaw_rate_max := 0.0
var yaw_flips := 0
var _prev_vel := Vector3.ZERO
var _prev_yaw := 0.0
var _prev_yaw_rate := 0.0
var _plan_promises := 0
var _plan_kept := 0

func _ready() -> void:
	ball = Ball.new()
	player = Player.new()
	add_child(ball)
	add_child(player)
	_port_check()
	_run_rallies()
	_report()
	get_tree().quit()

# 1) The budget must produce the SAME numbers as the Angelscript original.
# These inputs are hand-checkable against MotionPlan.as: trapezoid travel time,
# its inverse, and the playability margin.
func _port_check() -> void:
	print("PORTCHECK --- movement budget, ported values")
	for d in [1.0, 3.0, 6.0, 12.0]:
		var t := MotionPlan.body_travel_time(d, Player.MOVE_SPEED, Player.GROUND_ACCEL)
		print("  bodyTravelTime dist=%5.1f m -> %.4f s" % [d, t])
	for pair in [[3.0, 1.2], [6.0, 1.5], [6.0, 0.6]]:
		var v := MotionPlan.required_cruise_speed(pair[0], pair[1],
			Player.MOVE_SPEED, Player.GROUND_ACCEL)
		print("  requiredCruise dist=%5.1f m tAvail=%.2f -> %.3f m/s" % [pair[0], pair[1], v])
	# Inverse consistency: running at the speed the inverse asks for must cover
	# the distance in the time it promised. This is the check that would catch a
	# silent porting error in either direction.
	var d2 := 5.0
	var t_avail := 1.4
	var v2 := MotionPlan.required_cruise_speed(d2, t_avail, Player.MOVE_SPEED, Player.GROUND_ACCEL)
	# Was MotionPlan.FIRST_STEP_LAG. The budget constants moved into the Rust
	# tuning block, where they are settable at runtime — and a value you can set
	# cannot also be a GDScript const, which is resolved at parse time.
	var back := MotionPlan.body_travel_time(d2, v2, Player.GROUND_ACCEL) - Tuning.get_first_step_lag()
	print("  INVERSE CHECK dist=5.0 tAvail=1.40 -> v=%.3f, replayed=%.4f s (err %.4f)"
		% [v2, back, absf(back - t_avail)])
	var bt := MotionPlan.ball_time_to_height(Vector3(0.0, 4.0, 0.0), Vector3(2.0, 3.0, 0.0), BUMP_Y)
	print("  ballTimeToHeight y0=4.0 vy=3.0 -> y=1.12 : reached=%s t=%.4f x=%.2f"
		% [bt[0], bt[2], (bt[1] as Vector3).x])
	print("")

# 2) A rally: serve the ball across, let the budget decide how fast to run to
# the intercept, and measure what the body actually did.
func _run_rallies() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for r in RALLIES:
		var from := Vector3(-7.0, 1.5, rng.randf_range(-2.0, 2.0))
		var aim := Vector3(5.0, BUMP_Y, rng.randf_range(-3.0, 3.0))
		var flight := rng.randf_range(1.2, 2.2)
		ball.launch(from, Ball.velocity_for_flight_time(from, aim, flight))
		player.position = Vector3(6.0, Player.PLAYER_HEIGHT, 0.0)
		player.vel = Vector3.ZERO
		player.facing = Vector3.LEFT      # eyes on the incoming ball
		player._sm_want = player.facing
		# Re-seed the telemetry across the cut, or the reset above reads as a
		# single-frame turn of thousands of deg/s and swamps yawRateMax.
		_prev_yaw = rad_to_deg(Player.yaw_of(player.facing))
		_prev_vel = Vector3.ZERO

		var planned := false
		var t := 0.0
		var dt := 1.0 / HZ
		while ball.in_play and t < 6.0:
			# Where will the ball next cross bump height, and can we be there?
			var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, BUMP_Y)
			if bt[0]:
				var contact: Vector3 = bt[1]
				var tau: float = bt[2]
				var flat := Vector3(contact.x - player.position.x, 0.0,
					contact.z - player.position.z)
				var eff_vmax := Player.MOVE_SPEED * player.move_dir_speed_scale(flat)
				var p := MotionPlan.plan(flat.length(), tau, eff_vmax, Player.GROUND_ACCEL)
				if not planned and p["playable"]:
					planned = true
					_plan_promises += 1
				player.move_toward_ground(contact, p["speed_fraction"])
				# Did we make it? Planted within 40cm when the ball arrives.
				if tau < 0.05 and flat.length() < 0.4:
					_plan_kept += 1
			ball.step(dt)
			player.step(dt)
			_sample(dt)
			t += dt

func _sample(dt: float) -> void:
	var v := Vector3(player.vel.x, 0.0, player.vel.z)
	var pv := Vector3(_prev_vel.x, 0.0, _prev_vel.z)
	if v.length() > Player.TELEMETRY_MOVING:
		moving_time += dt
		if pv.length() > Player.TELEMETRY_MOVING and v.dot(pv) < -0.2 * v.length() * pv.length():
			move_flips += 1
	var yaw := rad_to_deg(Player.yaw_of(player.facing))
	var rate := wrapf(yaw - _prev_yaw, -180.0, 180.0) / dt
	if absf(rate) > 20.0:
		yaw_rate_sum += absf(rate)
		yaw_rate_samples += 1.0
		yaw_rate_max = maxf(yaw_rate_max, absf(rate))
	if absf(rate) > 60.0 and absf(_prev_yaw_rate) > 60.0 and rate * _prev_yaw_rate < 0.0:
		yaw_flips += 1
	if absf(rate) > 20.0:
		_prev_yaw_rate = rate
	_prev_yaw = yaw
	_prev_vel = player.vel

func _report() -> void:
	var mean := 0.0
	if yaw_rate_samples > 0.0:
		mean = yaw_rate_sum / yaw_rate_samples
	print("MOTIONSTATS godot-spike moving=%d moveFlips=%d yawFlips=%d yawRateMean=%d yawRateMax=%d"
		% [int(moving_time * 100.0), move_flips, yaw_flips, int(mean), int(yaw_rate_max)])
	print("PLANVA promises=%d kept=%d" % [_plan_promises, _plan_kept])
	print("SPIKE DONE")
