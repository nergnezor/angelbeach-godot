# Match — the rally protocol, ported from AngelBeach/Script/Match/GameMode.as
# and the contact half of VolleyballPlayer.as.
#
# The protocol is enforced IN the contact by team touch count, never by AI
# intent. That distinction is load-bearing: the original spent a pass trying to
# make the AI *choose* correctly and only got reliable rallies once the physics
# guaranteed it — touches 1-2 stay on our side, touch 3 crosses the tape.
#
# Court axes, Godot space: X runs across the net (net plane at x = 0, back line
# at |x| = COURT_X), Z runs along the net, Y is up. Metres throughout. The
# Angelscript original is centimetres with Z up and the sidelines on Y.
extends Node3D

const HZ := 60.0
const COURT_X := 8.0          # 800 cm
const COURT_Z := 4.0          # 400 cm, half-width along the net
const BUMP_Y := 1.12          # waist height: where the hands arrive fastest
const SET_Y := 2.10
const REACH := 0.95           # contact envelope around the hands
const CHEST_OFFSET := 0.20    # hands sit this far above the body origin
const ROLE_DEAD_BAND := 0.6   # sticky chaser hysteresis, 60 cm

var ball: Ball
var players: Array = []
var touches := 0
var last_touch_team := 0
var last_toucher: Node = null
var rally_seq := ""
var rally_crossings := 0
var rallies_done := 0
var headless := false
var _done := false
var _prev_ball_x := 0.0
var rally_time := 0.0
var total_time := 0.0
const RALLY_MAX := 25.0

func _ready() -> void:
	# DisplayServer, not the command line: Godot consumes --headless before
	# OS.get_cmdline_args() sees it, and OS.has_feature("headless") is false in
	# a headless run (it refers to the export template, not the display driver).
	headless = DisplayServer.get_name() == "headless"
	# A verification run has to be reproducible or an A/B tells you nothing.
	# The windowed game keeps its randomness.
	if headless:
		seed(12345)
	ball = Ball.new()
	add_child(ball)
	for i in 4:
		var p := Player.new()
		p.team = 0 if i < 2 else 1
		p.role_front = (i % 2 == 0)
		add_child(p)
		players.append(p)
	if not headless:
		_build_presentation()
	_serve()
	# Headless runs the whole match in a tight loop instead of waiting on the
	# physics clock. Both paths use the same fixed 1/60 step, so the numbers are
	# identical — only the wall-clock cost differs, and that difference is the
	# entire reason for being here.
	if headless:
		_run_headless()
		get_tree().quit()

# --- presentation ------------------------------------------------------------
# Everything below exists only when there is a screen. The headless sim must
# stay byte-identical to the seeded baseline, so nothing here may touch the
# rules, the RNG or the step order.

const HUMAN_INDEX := 0            # team 0's front player is yours

var camera: Camera3D
var hud: Label
var score := [0, 0]

func _build_presentation() -> void:
	add_child(Court.new())
	ball.setup_view()

	var model := load("res://assets/player.glb") as PackedScene
	for i in players.size():
		var p: Player = players[i]
		p.setup_view(model)
		p.human = (i == HUMAN_INDEX)
		if p.human:
			p.mark_as_human()

	camera = Camera3D.new()
	# Three-quarter view from behind your own corner. Straight down the long
	# axis lines all four players up and hides the depth that the whole movement
	# budget is about; from the corner you can see who is going to reach a ball.
	camera.position = Vector3(-13.5, 7.5, 9.5)
	camera.look_at_from_position(camera.position, Vector3(0.5, 1.2, 0.0), Vector3.UP)
	camera.fov = 58.0
	add_child(camera)

	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(24, 18)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_color", Color(1, 1, 1))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	add_child(layer)
	_update_hud()

func _update_hud() -> void:
	if hud == null:
		return
	hud.text = "YOU %d  —  %d CPU\ntouch %d/3\n\narrows / WASD to move, space to jump" % [
		score[0], score[1], touches]

# Your player takes the stick; the other three keep the budget-driven AI.
# Input is camera-relative and derived from the camera's own basis rather than
# hard-coded axes, so moving the camera cannot silently invert your controls.
func _human_drive(p: Player) -> void:
	var iv := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if camera == null:
		p.move_input = Vector3.ZERO
		return
	var fwd := -camera.global_basis.z
	var right := camera.global_basis.x
	fwd.y = 0.0
	right.y = 0.0
	var dir := fwd.normalized() * -iv.y + right.normalized() * iv.x
	if dir.length() > 1.0:
		dir = dir.normalized()
	p.move_input = dir
	if Input.is_action_pressed("ui_accept") and p.grounded:
		p.vel.y = Player.JUMP_VELOCITY

func _physics_process(dt: float) -> void:
	if not headless:
		_step(dt)

# Headless verification runs the simulation as fast as the CPU allows. Physics
# is a fixed 1/60 step either way, so the numbers are identical to the windowed
# run — only the wall-clock cost differs.
func _run_headless() -> void:
	var dt := 1.0 / HZ
	while not _done:
		_step(dt)

func _step(dt: float) -> void:
	rally_time += dt
	total_time += dt
	if rally_time > RALLY_MAX:
		_end_rally("timeout")
		return
	if headless and total_time > 180.0:
		print("MATCH DONE (sim limit)")
		_done = true
		return
	for p in players:
		_drive(p, dt)
		p.step(dt)
		if not headless:
			p._update_view()
	ball.step(dt)
	_check_contacts()
	_check_net_crossing()
	if not headless:
		_update_hud()
	if not ball.in_play:
		_end_rally("floor")

# --- AI: who takes it, and how fast do they need to run? ---------------------
func _drive(p: Player, dt: float) -> void:
	if p.human:
		_human_drive(p)
		return
	if not ball.in_play:
		p.move_toward_ground(_home(p))
		return
	var mine: bool = _side_of(ball.position.x) == p.team
	if not mine:
		p.move_toward_ground(_home(p))
		return
	# Where does the ball next cross contact height, and can I be there?
	var target_y: float = SET_Y if touches == 1 else BUMP_Y
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, target_y)
	if not bt[0]:
		p.move_toward_ground(_home(p))
		return
	var contact: Vector3 = bt[1]
	var tau: float = bt[2]
	# The digger is not the setter is not the attacker: whoever touched last
	# steps aside. This is what stops double contacts and fourth-touch faults.
	if p == last_toucher:
		p.move_toward_ground(_home(p))
		return
	var mate := _teammate(p)
	if mate != null and mate != last_toucher:
		var my_d := Vector2(contact.x - p.position.x, contact.z - p.position.z).length()
		var their_d := Vector2(contact.x - mate.position.x, contact.z - mate.position.z).length()
		# Sticky role with a dead band, as in the original: a bare comparison
		# had the two players swapping the ball back and forth at tick rate.
		var margin: float = ROLE_DEAD_BAND if p.is_chasing else -ROLE_DEAD_BAND
		p.is_chasing = my_d <= their_d + margin
		if not p.is_chasing:
			p.move_toward_ground(_home(p))
			return
	var flat := Vector3(contact.x - p.position.x, 0.0, contact.z - p.position.z)
	var eff_vmax := Player.MOVE_SPEED * p.move_dir_speed_scale(flat)
	var plan := MotionPlan.plan(flat.length(), tau, eff_vmax, Player.GROUND_ACCEL)
	p.move_toward_ground(contact, plan["speed_fraction"])

func _check_contacts() -> void:
	if not ball.in_play:
		return
	for p in players:
		if p == last_toucher:
			continue
		var d := Vector3(ball.position.x - p.position.x,
			ball.position.y - (p.position.y + CHEST_OFFSET),
			ball.position.z - p.position.z)
		if d.length() > REACH:
			continue
		_do_contact(p)
		return

func _do_contact(p: Player) -> void:
	if p.team != last_touch_team:
		touches = 0
	touches += 1
	last_touch_team = p.team
	last_toucher = p
	if touches > 3:
		_end_rally("four_touches")
		return

	var from := ball.position
	var to: Vector3
	var kind: String
	if touches == 1:
		# Dig to the setter zone on our own side.
		kind = "Bump"
		to = Vector3(_sign(p.team) * 2.5, SET_Y, 0.0)
	elif touches == 2:
		# Set to the partner's approach spot, still our side.
		kind = "Set"
		var mate := _teammate(p)
		var z: float = mate.position.z if mate != null else 0.0
		to = Vector3(_sign(p.team) * 1.8, SET_Y + 0.4, clampf(z, -COURT_Z + 0.8, COURT_Z - 0.8))
	else:
		# Attack: must clear the tape and land in their court.
		kind = "Spike"
		to = Vector3(-_sign(p.team) * 4.2, 0.0, randf_range(-COURT_Z + 0.6, COURT_Z - 0.6))
	ball.vel = Contact.placement_velocity(from, to, touches == 3)
	print("  CONTACT t=%d %s by team%d at (%.2f,%.2f,%.2f) -> (%.2f,%.2f,%.2f)"
		% [touches, kind, p.team, from.x, from.y, from.z, to.x, to.y, to.z])
	rally_seq += " %s%d:%s" % ["A" if p.team == 0 else "B", touches, kind]

func _check_net_crossing() -> void:
	if not ball.in_play:
		return
	if sign(ball.position.x) != sign(_prev_ball_x) and _prev_ball_x != 0.0:
		rally_crossings += 1
	_prev_ball_x = ball.position.x

func _serve() -> void:
	touches = 0
	last_touch_team = -1
	last_toucher = null
	rally_seq = ""
	rally_crossings = 0
	rally_time = 0.0
	for i in players.size():
		var p: Player = players[i]
		p.position = _home(p)
		p.vel = Vector3.ZERO
		p.is_chasing = false
		# Eyes across the net, so the first step's anisotropy is meaningful.
		p.facing = Vector3(-_sign(p.team), 0.0, 0.0)
		p._sm_want = p.facing
	var from := Vector3(-COURT_X + 0.4, 2.0, 0.0)
	var to := Vector3(4.0, BUMP_Y, randf_range(-2.0, 2.0))
	ball.launch(from, Contact.ballistic_velocity(from, to, 1.8))
	_prev_ball_x = from.x

func _end_rally(reason: String) -> void:
	rallies_done += 1
	print("RALLY end reason=%s crossings=%d seq=[%s ]" % [reason, rally_crossings, rally_seq])
	for p in players:
		p.emit_motion_stats()
	# Scoring is windowed-only on purpose: the headless run's stdout is the
	# acceptance baseline, and a score line in it would break the comparison.
	if not headless:
		if reason == "floor":
			# The ball is down. The point goes to the side it did NOT land on.
			score[1 - _side_of(ball.position.x)] += 1
		_update_hud()
		_serve()
		return
	if rallies_done >= 12:
		print("MATCH DONE")
		_done = true
		return
	_serve()

# --- helpers -----------------------------------------------------------------
func _sign(team: int) -> float:
	return -1.0 if team == 0 else 1.0

func _side_of(x: float) -> int:
	return 0 if x < 0.0 else 1

func _teammate(p: Player) -> Player:
	for q in players:
		if q != p and q.team == p.team:
			return q
	return null

func _home(p: Player) -> Vector3:
	# Staggered, not stacked. The port carried the Angelscript home spots over
	# with both teammates on z = 0, which put one directly behind the other:
	# they occluded each other on screen and, worse, the sticky-chaser dead band
	# had to break a tie between two players at identical depth on every ball.
	var x: float = _sign(p.team) * (2.6 if p.role_front else 5.6)
	var z: float = -1.6 if p.role_front else 1.6
	return Vector3(x, Player.PLAYER_HEIGHT, z)
