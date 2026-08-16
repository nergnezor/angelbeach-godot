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

# The rules, ported from GameState.as. In BOTH paths on purpose: scoring used to
# be windowed-only so the headless stdout stayed comparable, but nothing here
# prints, and the serving team is now a function of who scored — so a headless
# run that did not score would serve from the wrong side and stop being evidence
# about the game.
var state := MatchState.new()

# A serve has to go directly over. From the moment it leaves the hand until it
# clears the tape it is still "a serve", and landing or hitting the net in that
# window is a service fault rather than an ordinary rally end.
var _serve_phase := false
var _serving_team_this_serve := 0

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
# Players that armed a stroke this step. Anyone missing from it is no longer
# the designated contact, and a stroke nobody clears freezes the pose forever —
# players stood holding a bump platform for whole rallies.
var _armed := {}

func _build_presentation() -> void:
	var court := Court.new()
	add_child(court)
	ball.setup_view()
	# The sand only exists when there is a screen, so the footprints do too —
	# handing the players a null court in a headless run is what keeps the
	# deformation out of the acceptance path entirely.
	for p in players:
		p.court = court

	var model := load("res://assets/player.glb") as PackedScene
	for i in players.size():
		var p: Player = players[i]
		p.setup_view(model)
		p.human = (i == HUMAN_INDEX)
		if p.human:
			p.mark_as_human()

	camera = Camera3D.new()
	# Behind your own base line, 3 m up: a player's-eye view down the court.
	# Low enough that the net reads as a wall you have to clear rather than a
	# line on a plan, which is the whole point of the third touch.
	camera.position = Vector3(-COURT_X - 5.0, 3.0, 0.0)
	camera.look_at_from_position(camera.position, Vector3(0.0, 1.6, 0.0), Vector3.UP)
	camera.fov = 60.0
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
	var serve_mark := "*" if state.serving_team == MatchState.Team.A else " "
	hud.text = "YOU %d%s —  %d CPU   set %d   %s\ntouch %d/3\n\narrows / WASD to move, space to jump" % [
		state.score_a, serve_mark, state.score_b, state.current_set,
		state.sets_string(), touches]

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
	# You get the same stroke shaping the AI does. Without this the one player
	# under human control is the only one on court with no arms.
	if ball.in_play and _side_of(ball.position.x) == p.team:
		var target_y: float = SET_Y if touches == 1 else BUMP_Y
		var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, target_y)
		if bt[0]:
			_arm_stroke(p, bt[1], bt[2])
			_armed[p] = true
			p.face_target = bt[1]
			p.has_face_target = true

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
	if serving:
		_step_serve(dt)
	_armed.clear()
	for p in players:
		_drive(p, dt)
		p.step(dt)
		if not headless:
			p.update_gesture(dt)
			p._update_view()
	ball.step(dt)
	_check_contacts()
	_check_net_crossing()
	if not headless:
		_arm_blocks()
		for p in players:
			if not _armed.has(p):
				p.release_stroke()
		_update_hud()
	# `serving` guards the windup, where the ball is deliberately not in play yet
	# and would otherwise read as having hit the sand on the first frame.
	if not ball.in_play and not serving:
		_on_ball_hit_floor()

# OnBallHitFloor, ported. Which team scores is not simply "the other side": a
# serve that comes down without ever clearing the tape is a service fault, and
# the point goes to the receivers regardless of where it landed.
func _on_ball_hit_floor() -> void:
	var pos := ball.position
	if _serve_phase:
		_serve_phase = false
		_end_rally("serve_fault_floor", 1 - _serving_team_this_serve)
	elif pos.x < 0.0:
		_end_rally("floor_A x=%.2f z=%.2f" % [pos.x, pos.z], 1)
	else:
		_end_rally("floor_B x=%.2f z=%.2f" % [pos.x, pos.z], 0)

# --- AI: who takes it, and how fast do they need to run? ---------------------
func _drive(p: Player, dt: float) -> void:
	if p.human:
		_human_drive(p)
		return
	if not ball.in_play:
		p.has_face_target = false
		p.move_toward_ground(_home(p))
		return
	var mine: bool = _side_of(ball.position.x) == p.team
	if not mine:
		p.has_face_target = false
		p.move_toward_ground(_home(p))
		return
	# Where does the ball next cross contact height, and can I be there?
	var target_y: float = SET_Y if touches == 1 else BUMP_Y
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, target_y)
	if not bt[0]:
		p.has_face_target = false
		p.move_toward_ground(_home(p))
		return
	var contact: Vector3 = bt[1]
	var tau: float = bt[2]
	# The digger is not the setter is not the attacker: whoever touched last
	# steps aside. This is what stops double contacts and fourth-touch faults.
	if p == last_toucher:
		p.has_face_target = false
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
			p.has_face_target = false
			p.move_toward_ground(_home(p))
			return
	# The third touch is an attack, and an attack is a jump. Only if the set
	# actually reaches strike height — otherwise fall through and play it over
	# from the ground.
	if touches == 2 and p.grounded and _approach_for_spike(p):
		return
	var flat := Vector3(contact.x - p.position.x, 0.0, contact.z - p.position.z)
	var eff_vmax := Player.MOVE_SPEED * p.move_dir_speed_scale(flat)
	var plan := MotionPlan.plan(flat.length(), tau, eff_vmax, Player.GROUND_ACCEL)
	p.move_toward_ground(contact, plan["speed_fraction"])
	p.face_target = contact
	p.has_face_target = true
	if not headless:
		_arm_stroke(p, contact, tau)
		_armed[p] = true

# ApproachForSpike, ported from AIPlayer.as. Returns false when there is no jump
# attack available, so the caller can play the ball off the ground instead.
#
# The strike height is derived, not chosen: it is where the hands reach at the
# top of a loaded jump. Rise = v^2/2g = 6.6^2 / 38 = 1.15 m, plus the hip origin
# at 0.9 and 1.23 m of reach above it.
const SPIKE_STRIKE_Y := Player.PLAYER_HEIGHT \
	+ (Player.LOADED_JUMP_VELOCITY * Player.LOADED_JUMP_VELOCITY) / (2.0 * 19.0) + 1.23
const APPROACH_BACK := 2.0        # the run-up starts this far behind the plant
const PLANT_OFFSET := 0.35        # plant our-side of the strike, so contact is
                                  # in front of the shoulder, not on the head
const JUMP_RADIUS := 0.90
const JUMP_EPS := 0.05

func _approach_for_spike(p: Player) -> bool:
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, SPIKE_STRIKE_Y)
	if not bt[0]:
		return false
	var strike: Vector3 = bt[1]
	var tau: float = bt[2]
	if absf(strike.x) > COURT_X or absf(strike.z) > COURT_Z:
		return false
	var time_to_apex: float = Player.LOADED_JUMP_VELOCITY / 19.0
	var plant := Vector3(strike.x + _sign(p.team) * PLANT_OFFSET,
		Player.PLAYER_HEIGHT, strike.z)
	var to_plant := Vector3(plant.x - p.position.x, 0.0, plant.z - p.position.z)
	var dist := to_plant.length()
	var eff_vmax := Player.MOVE_SPEED * p.move_dir_speed_scale(to_plant)
	var sprint_time := dist / maxf(eff_vmax, 0.01) + Tuning.get_first_step_lag()

	p.face_target = ball.position
	p.has_face_target = true

	if tau > sprint_time + time_to_apex + 0.25:
		# Early. Wait coiled at the approach start behind the plant, eyes on the
		# ball — a hitter who drifts onto the plant early has nothing left to
		# convert into height.
		var start := Vector3(plant.x + _sign(p.team) * APPROACH_BACK,
			Player.PLAYER_HEIGHT, plant.z)
		p.move_toward_ground(start, 0.8)
		p.request_crouch(0.25)
		return true

	# GO. Sprint only outside the jump radius: driving at full speed through the
	# plant made the hitter overshoot and shuttle back and forth over it while
	# waiting for the jump window.
	p.move_toward_ground(plant, 1.0 if dist > JUMP_RADIUS else 0.35)
	# Leave the ground one apex-time before the ball arrives, and the gather
	# happens BEFORE takeoff so the decision fires one load earlier. The margin
	# is deliberately tiny and late-biased: an early jump tops out while the ball
	# is still above the hands, which is a guaranteed whiff, where a late one
	# meets it a touch lower but still inside the envelope.
	if dist < JUMP_RADIUS and tau <= time_to_apex + Player.JUMP_LOAD_DURATION + JUMP_EPS:
		p.move_input = Vector3.ZERO
		p.start_loaded_jump()
	return true

# Which stroke is this player about to play, and where is it aimed? The stroke
# follows the same touch count the protocol enforces, so the pose can never
# disagree with what the contact will actually do to the ball.
func _arm_stroke(p: Player, contact: Vector3, tau: float) -> void:
	p.ball_pos = ball.position
	p.ball_live = ball.in_play
	p.meet = contact
	p.has_meet = true
	# The windup starts when the ball is close enough that a real player would
	# already be shaping the stroke, not the instant they start running.
	if tau > 1.2:
		return
	if p.swing > 0.0:
		return                                  # mid follow-through, leave it alone
	if touches == 1:
		p.hit_type = GestureIK.HIT_SET
		p.aim = Vector3(_sign(p.team) * 1.8, SET_Y + 0.4, p.position.z)
	elif touches == 2:
		# Third touch crosses: it is an attack, and above the tape it is a spike.
		p.hit_type = GestureIK.HIT_SPIKE
		p.aim = Vector3(-_sign(p.team) * 4.2, 0.0, p.position.z)
	else:
		p.hit_type = GestureIK.HIT_BUMP
		p.aim = Vector3(_sign(p.team) * 2.5, SET_Y, 0.0)
	p.has_aim = true

# A blocker is the front player on the DEFENDING side, at the net, while the
# other team is on their third touch. No new AI: it reads the same touch count
# and side the rules already track, and only changes the pose.
func _arm_blocks() -> void:
	var attacking := _side_of(ball.position.x)
	for p in players:
		if p.team == attacking or not p.role_front:
			continue
		if p.swing > 0.0:
			continue
		var at_net: bool = absf(p.position.x) < 2.2
		if touches == 2 and ball.in_play and at_net:
			p.hit_type = GestureIK.HIT_BLOCK
			p.ball_pos = ball.position
			p.ball_live = true
			p.aim = Vector3(_sign(p.team) * 4.0, 0.0, p.position.z)
			p.has_aim = true
			_armed[p] = true

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
	# RegisterTouch owns the count now, so the rule lives in one place and the
	# fourth touch reads as a rules decision rather than a local counter.
	var legal := state.register_touch(p.team as MatchState.Team)
	touches = state.touches_this_rally
	last_touch_team = p.team
	last_toucher = p
	if not legal:
		_end_rally("touches_A" if p.team == 0 else "touches_B", 1 - p.team)
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
		# The set has to be JUMPABLE. It aimed at 2.50 m while a loaded jump puts
		# the hands at 3.28, so the ball never once reached strike height and the
		# attacker had nothing to rise to — every third touch was played off the
		# ground. Aimed a little under the apex on purpose: the source is explicit
		# that an early jump tops out above the ball and whiffs, where a late one
		# meets it lower but still inside the envelope.
		to = Vector3(_sign(p.team) * 1.8, SPIKE_STRIKE_Y - 0.35,
			clampf(z, -COURT_Z + 0.8, COURT_Z - 0.8))
	else:
		# Attack: must clear the tape and land in their court.
		kind = "Spike"
		to = Vector3(-_sign(p.team) * 4.2, 0.0, randf_range(-COURT_Z + 0.6, COURT_Z - 0.6))
	ball.vel = Contact.placement_velocity(from, to, touches == 3)
	if not headless:
		# The ball has actually been struck: from here the follow-through plays.
		p.aim = to
		p.has_aim = true
		p.hit_type = _stroke_for(kind)
		p.trigger_hit()
	print("  CONTACT t=%d %s by team%d at (%.2f,%.2f,%.2f) -> (%.2f,%.2f,%.2f)"
		% [touches, kind, p.team, from.x, from.y, from.z, to.x, to.y, to.z])
	rally_seq += " %s%d:%s" % ["A" if p.team == 0 else "B", touches, kind]

# CheckNetCollision, ported. The net is a real obstacle now rather than a number
# the contact solver aims over: crossing the plane below the tape stops the ball
# instead of letting it pass through, which is what makes a service fault
# possible at all.
func _check_net_crossing() -> void:
	if not ball.in_play:
		return
	var prev_x := _prev_ball_x
	var x := ball.position.x
	_prev_ball_x = x
	if (prev_x < 0.0) == (x < 0.0):
		return
	if ball.position.y < Court.NET_TOP + Ball.RADIUS:
		# Into the net. Most of the pace goes out of it and it drops on the side
		# it came from.
		ball.vel.x = -ball.vel.x * 0.3
		var off := Court.NET_HALF_THICK + Ball.RADIUS
		ball.position.x = -off if x < 0.0 else off
		_prev_ball_x = ball.position.x
		_on_ball_hit_net()
	else:
		# Cleared it cleanly, so a serve in flight is now good.
		_serve_phase = false
		rally_crossings += 1

func _on_ball_hit_net() -> void:
	# Only a SERVE into the net is a fault. Mid-rally the ball is simply live
	# again on the side it rebounded to.
	if not _serve_phase:
		return
	_serve_phase = false
	_end_rally("serve_net", 1 - _serving_team_this_serve)

# The serve is a WINDUP, not an instant launch. The ball leaves the hand at
# SERVE_STRIKE_PHASE — the same choreography boundary the original uses — so the
# arm is actually at the strike position when the ball departs rather than the
# ball leaving mid-whip. This is in both paths on purpose: the moment headless
# and windowed disagree about when a rally starts, the headless run stops being
# evidence about the game.
const SERVE_WINDUP := 1.1
const SERVE_STRIKE_PHASE := 0.78

var serving := false
var serve_t := 0.0
var server: Player = null
var _served := false
var _serve_from := Vector3.ZERO
var _serve_vel := Vector3.ZERO

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
	# Whoever won the last point serves — rally scoring, so the side is not a
	# rotation but a consequence. This used to be hard-coded to team 0, which
	# meant team 1 never served and the receiving half of the game was never
	# exercised.
	var team := int(state.serving_team)
	var s := _sign(team)
	var from := Vector3(s * (COURT_X - 0.4), 2.0, 0.0)
	# Somebody has to hit it. The back player of the serving team stands behind
	# their own base line, where the ball leaves from.
	server = _back_player(team)
	if server != null:
		server.position = Vector3(from.x, Player.PLAYER_HEIGHT, from.z)
	var to := Vector3(-s * 4.0, BUMP_Y, randf_range(-2.0, 2.0))
	_serving_team_this_serve = team
	_serve_from = from
	_serve_vel = Contact.ballistic_velocity(from, to, 1.8)
	serving = true
	_served = false
	serve_t = 0.0
	_prev_ball_x = from.x

func _step_serve(dt: float) -> void:
	serve_t += dt
	var ph: float = serve_t / SERVE_WINDUP
	if not headless and server != null:
		server.hit_type = GestureIK.HIT_SERVE
		server.serve_phase = minf(ph, 1.0)
		server.gesture_blend = 1.0
		_armed[server] = true
	if not _served and ph >= SERVE_STRIKE_PHASE:
		_served = true
		ball.launch(_serve_from, _serve_vel)
		# OnServeLaunched: the rally starts at the STRIKE, not at the windup.
		state.start_rally()
		_serve_phase = true
	if ph >= 1.0:
		serving = false
		if not headless and server != null:
			server.hit_type = GestureIK.HIT_NONE
			server.serve_phase = 0.0

func _back_player(team: int) -> Player:
	for q in players:
		if q.team == team and not q.role_front:
			return q
	return null

# scoring_team of -1 means nobody scored. Only "timeout" uses it: that is the
# harness's safety valve for a rally that will not end, not a rule, so it must
# not hand out a point or move the serve.
func _end_rally(reason: String, scoring_team: int = -1) -> void:
	rallies_done += 1
	print("RALLY end reason=%s crossings=%d seq=[%s ]" % [reason, rally_crossings, rally_seq])
	for p in players:
		p.emit_motion_stats()
	_serve_phase = false
	if scoring_team >= 0:
		state.add_point(scoring_team as MatchState.Team)
	if not headless:
		_update_hud()

	if state.phase == MatchState.Phase.MATCH_OVER:
		print("MATCH OVER winner=%s sets=%d-%d" % [
			"A" if state.winner == MatchState.Team.A else "B",
			state.sets_won_a, state.sets_won_b])
		if headless:
			_done = true
			return
		# The windowed game just starts a new match rather than sitting on a
		# dead court.
		state.reset()
	elif state.phase == MatchState.Phase.SET_OVER:
		print("SET OVER set=%d sets=%d-%d" % [
			state.current_set, state.sets_won_a, state.sets_won_b])

	if headless and rallies_done >= 12:
		print("MATCH DONE")
		_done = true
		return
	_serve()

# --- helpers -----------------------------------------------------------------
func _stroke_for(kind: String) -> int:
	match kind:
		"Set": return GestureIK.HIT_SET
		"Spike": return GestureIK.HIT_SPIKE
		_: return GestureIK.HIT_BUMP

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
