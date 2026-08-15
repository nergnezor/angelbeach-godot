# Match — the rally protocol, ported from AngelBeach/Script/Match/GameMode.as
# and the contact half of VolleyballPlayer.as.
#
# The protocol is enforced IN the contact by team touch count, never by AI
# intent. That distinction is load-bearing: the original spent a pass trying to
# make the AI *choose* correctly and only got reliable rallies once the physics
# guaranteed it — touches 1-2 stay on our side, touch 3 crosses the tape.
extends Node3D

const HZ := 60.0
const COURT_X := 800.0        # net at x=0, back line at |x| = COURT_X
const COURT_Y := 400.0
const BUMP_Z := 112.0         # waist height: where the hands arrive fastest
const SET_Z := 210.0

var ball: Ball
var players: Array = []
var touches := 0
var last_touch_team := 0
var last_toucher: Node = null
var rally_seq := ""
var rally_crossings := 0
var rallies_done := 0
var _done := false
var _prev_ball_x := 0.0
var rally_time := 0.0
var total_time := 0.0
const RALLY_MAX := 25.0

func _ready() -> void:
	ball = Ball.new()
	add_child(ball)
	for i in 4:
		var p := Player.new()
		p.team = 0 if i < 2 else 1
		p.role_front = (i % 2 == 0)
		add_child(p)
		players.append(p)
	_serve()
	# Headless runs the whole match in a tight loop instead of waiting on the
	# physics clock. Both paths use the same fixed 1/60 step, so the numbers are
	# identical — only the wall-clock cost differs, and that difference is the
	# entire reason for being here.
	# DisplayServer, not the command line: Godot consumes --headless before
	# OS.get_cmdline_args() sees it, and OS.has_feature("headless") is false in
	# a headless run (it refers to the export template, not the display driver).
	if DisplayServer.get_name() == "headless":
		_run_headless()
		get_tree().quit()

var headless := false

func _physics_process(dt: float) -> void:
	if not headless:
		_step(dt)

# Headless verification runs the simulation as fast as the CPU allows. Physics
# is a fixed 1/60 step either way, so the numbers are identical to the windowed
# run — only the wall-clock cost differs.
func _run_headless() -> void:
	headless = true
	var dt := 1.0 / HZ
	while not _done:
		_step(dt)

func _step(dt: float) -> void:
	rally_time += dt
	total_time += dt
	if rally_time > RALLY_MAX:
		_end_rally("timeout")
		return
	if total_time > 180.0:
		print("MATCH DONE (sim limit)")
		_done = true
		if not headless:
			get_tree().quit()
		return
	for p in players:
		_drive(p, dt)
		p.step(dt)
	ball.step(dt)
	_check_contacts()
	_check_net_crossing()
	if not ball.in_play:
		_end_rally("floor")

# --- AI: who takes it, and how fast do they need to run? ---------------------
func _drive(p: Player, dt: float) -> void:
	if not ball.in_play:
		p.move_toward_2d(_home(p))
		return
	var mine: bool = _side_of(ball.position.x) == p.team
	if not mine:
		p.move_toward_2d(_home(p))
		return
	# Where does the ball next cross contact height, and can I be there?
	var target_z: float = SET_Z if touches == 1 else BUMP_Z
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, target_z)
	if not bt[0]:
		p.move_toward_2d(_home(p))
		return
	var contact: Vector3 = bt[1]
	var tau: float = bt[2]
	# The digger is not the setter is not the attacker: whoever touched last
	# steps aside. This is what stops double contacts and fourth-touch faults.
	if p == last_toucher:
		p.move_toward_2d(_home(p))
		return
	var mate := _teammate(p)
	if mate != null and mate != last_toucher:
		var my_d := Vector2(contact.x - p.position.x, contact.y - p.position.y).length()
		var their_d := Vector2(contact.x - mate.position.x, contact.y - mate.position.y).length()
		# Sticky role with a dead band, as in the original: a bare comparison
		# had the two players swapping the ball back and forth at tick rate.
		var margin: float = 60.0 if p.is_chasing else -60.0
		p.is_chasing = my_d <= their_d + margin
		if not p.is_chasing:
			p.move_toward_2d(_home(p))
			return
	var flat := Vector3(contact.x - p.position.x, contact.y - p.position.y, 0.0)
	var eff_vmax := Player.MOVE_SPEED * p.move_dir_speed_scale(flat)
	var plan := MotionPlan.plan(flat.length(), tau, eff_vmax, Player.GROUND_ACCEL)
	p.move_toward_2d(contact, plan["speed_fraction"])

func _check_contacts() -> void:
	if not ball.in_play:
		return
	for p in players:
		if p == last_toucher:
			continue
		var d := Vector3(ball.position.x - p.position.x, ball.position.y - p.position.y,
			ball.position.z - (p.position.z + 20.0))
		if d.length() > 95.0:
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
		to = Vector3(_sign(p.team) * 250.0, 0.0, SET_Z)
	elif touches == 2:
		# Set to the partner's approach spot, still our side.
		kind = "Set"
		var mate := _teammate(p)
		var y: float = mate.position.y if mate != null else 0.0
		to = Vector3(_sign(p.team) * 180.0, clampf(y, -COURT_Y + 80.0, COURT_Y - 80.0), SET_Z + 40.0)
	else:
		# Attack: must clear the tape and land in their court.
		kind = "Spike"
		to = Vector3(-_sign(p.team) * 420.0, randf_range(-COURT_Y + 60.0, COURT_Y - 60.0), 0.0)
	ball.vel = Contact.placement_velocity(from, to, touches == 3)
	print("  CONTACT t=%d %s by team%d at (%.0f,%.0f,%.0f) -> (%.0f,%.0f,%.0f)"
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
	var from := Vector3(-COURT_X + 40.0, 0.0, 200.0)
	var to := Vector3(400.0, randf_range(-200.0, 200.0), BUMP_Z)
	ball.launch(from, Contact.ballistic_velocity(from, to, 180.0))
	_prev_ball_x = from.x

func _end_rally(reason: String) -> void:
	rallies_done += 1
	print("RALLY end reason=%s crossings=%d seq=[%s ]" % [reason, rally_crossings, rally_seq])
	for p in players:
		p.emit_motion_stats()
	if rallies_done >= 12:
		print("MATCH DONE")
		_done = true
		if not headless:
			get_tree().quit()
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
	var x: float = _sign(p.team) * (200.0 if p.role_front else 520.0)
	return Vector3(x, 0.0, Player.PLAYER_HEIGHT)
