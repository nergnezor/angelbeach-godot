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
var _landed := false
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
		# GameMode.as hands each AI its own Difficulty: 0.80 at the net, 0.75 in
		# the back. It is not decoration — it sets move speed, decision cadence
		# and aim spread together.
		p.set_difficulty(0.80 if p.role_front else 0.75)
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

const HUMAN_TEAM := 0             # team 0 is the side you may take over

# Nobody is on the stick by default: all four players run the budget-driven AI
# and the match plays itself. JUMP is the takeover — press it and whoever on
# your team is nearest the ball becomes yours, jumps on that same frame, and
# stays yours until the rally ends. null means the court is entirely the AI's.
var human_player: Player = null

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
	for p in players:
		p.setup_view(model)

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
	var ctrl := "space to take over the player nearest the ball" if human_player == null \
		else "arrows / WASD to move, space to jump"
	hud.text = "YOU %d%s —  %d CPU   set %d   %s\ntouch %d/3\n\n%s" % [
		state.score_a, serve_mark, state.score_b, state.current_set,
		state.sets_string(), touches, ctrl]

# The takeover. Nearest to the BALL rather than nearest to anything of yours:
# pressing jump says "this play, now", and the body that moment belongs to is
# the one standing under the ball. It runs before the drive loop so the frame
# that grabs the player is also the frame that spends the jump — a takeover
# that cost a frame would always land late on exactly the balls you press for.
func _take_over() -> void:
	var pick: Player = null
	var best := INF
	for p in players:
		if p.team != HUMAN_TEAM:
			continue
		# Not the server mid-windup: the serve launches from a scripted spot, so
		# dragging that body around would fire the ball from where they no longer
		# stand.
		if serving and p == server:
			continue
		var flat := Vector2(p.position.x - ball.position.x, p.position.z - ball.position.z)
		var d := flat.length_squared()
		if d < best:
			best = d
			pick = p
	if pick == null or pick == human_player:
		return
	_release_human()
	human_player = pick
	pick.human = true
	pick.mark_as_human(true)

# Hand the body back to the AI. The stale plan goes with it: a goal chosen
# before you took over is a decision nobody made any more, and leaving it set
# means the player sprints off to finish it the moment they are released.
func _release_human() -> void:
	if human_player == null:
		return
	human_player.human = false
	human_player.move_input = Vector3.ZERO
	human_player.has_plan = false
	human_player.has_face_target = false
	human_player.mark_as_human(false)
	human_player = null

# The player you took over takes the stick; the other three keep the
# budget-driven AI. Input is camera-relative and derived from the camera's own
# basis rather than hard-coded axes, so moving the camera cannot silently
# invert your controls.
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
	# Windowed only, and deliberately outside the per-player loop: the takeover
	# picks ONE body out of the four, so it cannot be a decision each player
	# makes about itself.
	if not headless and Input.is_action_just_pressed("ui_accept"):
		_take_over()
	_armed.clear()
	for p in players:
		_drive(p, dt)
		p.step(dt)
		if not headless:
			p.update_gesture(dt)
			p._update_view()
	ball.step(dt)
	# The arms track the LIVE ball every frame, even though the AI behind them
	# only re-decides at reaction_delay cadence (that gap is deliberate — it is
	# the simulated reaction time). Without this, GestureIK read whatever
	# ball_pos _arm_stroke last wrote at the previous decision tick, held it for
	# up to a few tenths of a second, then jumped it — a platform that snaps to
	# a new target every reaction tick and races SINK_SPEED to catch up, instead
	# of a hand that follows the ball smoothly.
	if not headless:
		for p in players:
			p.ball_pos = ball.position
			p.ball_live = ball.in_play
	_check_contacts()
	_check_net_crossing()
	if not headless:
		_arm_blocks()
		for p in players:
			if not _armed.has(p):
				p.release_stroke()
		_update_hud()
	# FIRST TOUCHDOWN ends the rally, not the moment the ball comes to rest.
	# Waiting for in_play to clear meant waiting out the whole bounce series, so
	# the reported landing was where the ball stopped rolling — every serve was
	# logged at x = 18.88, eleven metres past the base line, and the point was
	# awarded from that instead of from where it actually came down. A ball that
	# lands in and rolls out is in.
	if not serving and ball.in_play and not _landed \
			and ball.position.y <= ball.floor_y + Ball.RADIUS + 0.001:
		_landed = true
		_on_ball_hit_floor()
		return
	# `serving` guards the windup, where the ball is deliberately not in play yet
	# and would otherwise read as having hit the sand on the first frame.
	if not ball.in_play and not serving and not _landed:
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
	# Cleared here and re-asserted only on the path that commits to the ball, so
	# the split step cancels itself the moment this player becomes the digger.
	p.is_reaching = false
	if p.human:
		_human_drive(p)
		return
	# The AI thinks on a cadence, not every frame. Between ticks it keeps moving
	# toward the last decision rather than standing still — a player who has
	# committed keeps running while they think about the next thing.
	var stamp := touches * 4 + last_touch_team + (8 if ball.in_play else 0)
	if stamp != p.percept_stamp:
		# The ball's state changed under us: that is an event, and events cost a
		# beat of visual reaction before any new decision is possible.
		p.percept_stamp = stamp
		p.perception_t = Player.PERCEPTION_LATENCY
	if p.perception_t > 0.0:
		p.perception_t -= dt
		_hold_plan(p)
		return
	p.reaction_t += dt
	if p.reaction_t < p.reaction_delay:
		_hold_plan(p)
		return
	p.reaction_t = 0.0
	if not ball.in_play:
		p.has_face_target = false
		_go(p, _home(p))
		return
	var mine: bool = _side_of(ball.position.x) == p.team
	if not mine:
		# The ball is on their side. The front player goes to the net to block
		# the attack; everyone else resets.
		if p.role_front and _play_block(p):
			return
		p.has_face_target = false
		_go(p, _home(p))
		return
	# Where does the ball next cross contact height, and can I be there?
	var target_y: float = SET_Y if touches == 1 else BUMP_Y
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, target_y)
	if not bt[0]:
		p.has_face_target = false
		_go(p, _home(p))
		return
	var contact: Vector3 = bt[1]
	var tau: float = bt[2]
	# The digger is not the setter is not the attacker: whoever touched last
	# steps aside. This is what stops double contacts and fourth-touch faults.
	if p == last_toucher:
		p.has_face_target = false
		_go(p, _home(p))
		return
	# IsDeep: a ball coming down behind 3.5 m is serve receive, and it belongs to
	# the back player by role rather than by distance. The sticky rule alone had
	# whoever happened to be nearer turning and chasing it, which is how you end
	# up with the net player digging from the base line.
	var fresh: bool = last_touch_team != p.team
	var deep: bool = _sign(p.team) * contact.x > 3.5
	var mine_by_role := false
	if fresh and deep:
		if p.role_front:
			p.is_chasing = false
			p.has_face_target = false
			_go(p, _home(p))
			return
		mine_by_role = true
		p.is_chasing = true
	var mate := _teammate(p)
	if not mine_by_role and mate != null and mate != last_toucher:
		var my_d := Vector2(contact.x - p.position.x, contact.z - p.position.z).length()
		var their_d := Vector2(contact.x - mate.position.x, contact.z - mate.position.z).length()
		# Sticky role with a dead band, as in the original: a bare comparison
		# had the two players swapping the ball back and forth at tick rate.
		var margin: float = ROLE_DEAD_BAND if p.is_chasing else -ROLE_DEAD_BAND
		p.is_chasing = my_d <= their_d + margin
		if not p.is_chasing:
			p.has_face_target = false
			_go(p, _home(p))
			return
	# The third touch is an attack, and an attack is a jump. Only if the set
	# actually reaches strike height — otherwise fall through and play it over
	# from the ground.
	if touches == 2:
		# PlayHitter: touch three is an attack, full stop. It never falls through
		# to the generic intercept, because that path's fallback height cannot
		# clear the net.
		_approach_for_spike(p)
		return
	var flat := Vector3(contact.x - p.position.x, 0.0, contact.z - p.position.z)
	var eff_vmax := p.move_speed * p.move_dir_speed_scale(flat)
	var plan := MotionPlan.plan(flat.length(), tau, eff_vmax, Player.GROUND_ACCEL)

	# THE DIVE IS DELIBERATELY NOT CALLED. The reach model above is what it was
	# missing and is now correct, but the trigger is not: at serve reception the
	# receiver is genuinely far from the ball, so every gate tried says "the run
	# cannot make it" and the receiver lunges instead of digging. A dive commits
	# blind for 0.42 s and then lies in 0.75 s of recovery, so a wrong one is an
	# ace against us. Measured on the seeded run with the trigger live: 143
	# CONTACT lines fall to 5, and seven of twelve rallies end with seq=[ ] --
	# nobody touching the ball at all.
	#
	# Tightening tau did not help (0.8 s -> one decision tick plus the lunge
	# still gave 5), because the receiver is late by the budget's reckoning on
	# essentially every serve. What is missing is not a threshold but the
	# source's staged approach: PlanIntercept HOLDS an expectation point while
	# slack remains and only re-decides late, so its receivers are already
	# closing when the dive question is asked. Wire this up after that, not
	# before:
	#
	#   var need := maxf(0.0, flat.length() - REACH)
	#   var reach_t: float = MotionPlan.plan(need, tau, eff_vmax,
	#       Player.GROUND_ACCEL)["body_time"]
	#   if reach_t > tau and p.can_dive() and tau > 0.0 and tau < DIVE_MAX_TAU \
	#           and flat.length() > DIVE_MIN_DIST \
	#           and flat.length() < DIVE_MAX_DIST:
	#       p.start_dive(flat)
	#       return

	p.is_reaching = true
	_go(p, contact, plan["speed_fraction"])
	p.face_target = contact
	p.has_face_target = true
	if not headless:
		_arm_stroke(p, contact, tau)
		_armed[p] = true

# PickAttackTarget: the opponent's open court, away from their players. Both
# depth and accuracy scale with Difficulty, so a weaker attacker hits shorter
# AND sprays wider — one number, two tells.
func _pick_attack_target(p: Player) -> Vector3:
	# Search the opponent's court for the spot FURTHEST from anyone who could
	# dig it. The source's comment asks for exactly this — "aim for the
	# opponent's open court, away from their players" — but its implementation
	# only ever picked a fixed depth and one of two halves, so every attack from
	# a given player landed in the same place and the defence never had to move.
	#
	# The defenders' home positions barely move inside a rally, so this sweep
	# used to be deterministic AND its argmax was almost always the exact same
	# grid cell — the boundary column farthest from mid-court, tie-broken the
	# same way every time. Every kill from a given player landed in the same
	# corner, rally after rally: the very failure the comment below already
	# describes, just one layer deeper. Collecting every near-tied cell and
	# drawing among them is the fix; the placement error below still applies
	# on top.
	var opp := 1 - p.team
	var s := -_sign(p.team)                 # sign of THEIR half
	var candidates: Array[Vector3] = []
	var scores: Array[float] = []
	var best_score := -1.0
	for xi in 6:
		for zi in 7:
			# Inside the lines with a margin: a kill that lands out is a point
			# for them, and the aim carries error on top of this.
			var tx := s * lerpf(1.2, COURT_X - 0.8, xi / 5.0)
			var tz := lerpf(-COURT_Z + 0.6, COURT_Z - 0.6, zi / 6.0)
			var nearest := 999.0
			for q: Player in players:
				if q.team != opp:
					continue
				nearest = minf(nearest, Vector2(tx - q.position.x, tz - q.position.z).length())
			# Depth is worth a little on its own: a ball driven deep gives the
			# defender less time even when they are the same distance away.
			# Depth is worth a LITTLE, not a lot: at 0.15 the bonus reached 1.08 at
			# the base line and swamped every defender distance, so the attack
			# just hammered the deepest corner every time — the same failure the
			# fixed target had, one step further out.
			var score := nearest + absf(tx) * 0.04
			candidates.append(Vector3(tx, 0.0, tz))
			scores.append(score)
			best_score = maxf(best_score, score)
	# Anything within a racket-length of the best is an equally good kill —
	# pick among those at random instead of always the first one the sweep
	# happens to visit.
	var near_best: Array[Vector3] = []
	for i in candidates.size():
		if scores[i] >= best_score - 0.35:
			near_best.append(candidates[i])
	var best: Vector3 = near_best[randi() % near_best.size()]
	# Accuracy still scales with Difficulty — a weaker attacker finds the gap and
	# then misses it by more.
	var err := randf_range(-1.8, 1.8) * (1.0 - p.difficulty)
	return Vector3(best.x, 0.0, clampf(best.z + err, -COURT_Z + 0.3, COURT_Z - 0.3))

# Every AI move goes through here so the goal is remembered as well as acted on.
func _go(p: Player, goal: Vector3, speed: float = 1.0) -> void:
	p.plan_goal = goal
	p.plan_speed = speed
	p.has_plan = true
	p.move_toward_ground(goal, speed)

# Between decisions: keep executing the last one.
func _hold_plan(p: Player) -> void:
	if p.has_plan:
		p.move_toward_ground(p.plan_goal, p.plan_speed)
	else:
		p.move_input = Vector3.ZERO

# The block, ported from PlayDefense. Returns false when there is nothing to
# block, so the caller falls back to resetting.
#
# This lives in _drive rather than in the pose code on purpose: a block is a
# JUMP, so it changes the sim, and the moment the headless run and the windowed
# one disagree about who left the ground the headless numbers stop being evidence
# about the game.
# Dive window, from MotionPlan.as: only worthwhile beyond a lunge and inside the
# 1.75x speed burst's real range.
const DIVE_MIN_DIST := 1.30
const DIVE_MAX_DIST := 4.00
# A dive commits BLIND: the lunge owns velocity and facing for DIVE_DURATION,
# with no chance to correct. So it may only be taken when there is no longer
# time to think again — one more decision tick plus the lunge itself. The
# source's 0.8 s window let receivers commit with 0.7 s of flight left, and they
# threw themselves past serves they could have run down: seven of twelve rallies
# became aces with nobody touching the ball.
const DIVE_MAX_TAU := 0.8         # the source's outer bound; the gate below is tighter

const BLOCK_NET_X := 0.55         # right up at the net, on our side
const BLOCK_AIM_X := 3.0          # stuff it into the middle of their court
const BLOCK_JUMP_RADIUS := 0.90
const BLOCK_SETTLE_SPEED := 0.90  # the drive must be dead before takeoff

func _play_block(p: Player) -> bool:
	# The cue is the opponents' second touch AND a set that actually reaches
	# strike height near the net. UpdateSpikeIncoming is what the source uses
	# here; without it the blocker committed on every second touch, abandoned the
	# back court to a lone defender, and rallies died a crossing after the serve
	# — 144 CONTACT lines fell to 121.
	if touches != 2:
		return false
	var spike_incoming := false
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, SPIKE_STRIKE_Y)
	if bt[0]:
		var strike: Vector3 = bt[1]
		spike_incoming = absf(strike.x) < 3.0 and absf(strike.z) < COURT_Z
	# Only hold the net line while there's a spike worth blocking. Chasing the
	# ball's z but always parking at BLOCK_NET_X meant a blocker with no real
	# block to make still camped right at the net instead of falling back to
	# the middle — the one place they can actually help the back-row defender.
	var goal := Vector3(_sign(p.team) * BLOCK_NET_X, Player.PLAYER_HEIGHT,
			clampf(ball.position.z, -COURT_Z + 0.6, COURT_Z - 0.6)) \
		if spike_incoming else _home(p)
	p.face_target = ball.position
	p.has_face_target = true
	if not p.grounded:
		# Airborne: hold still and throw the block up now. Drifting into the net
		# is a fault, and momentum carries in the air.
		p.move_input = Vector3.ZERO
		if not headless:
			p.hit_type = GestureIK.HIT_BLOCK
			p.ball_pos = ball.position
			p.ball_live = true
			p.aim = Vector3(-_sign(p.team) * BLOCK_AIM_X, 0.0, p.position.z)
			p.has_aim = true
			_armed[p] = true
		return true
	var horiz := Vector2(goal.x - p.position.x, goal.z - p.position.z).length()
	if spike_incoming and horiz < BLOCK_JUMP_RADIUS:
		# Kill the drive FIRST so the block jump is vertical. Blocks load too —
		# the same full-body gather the attacker uses, which is also what makes
		# the two jumps land on the same beat.
		p.move_input = Vector3.ZERO
		if Vector2(p.vel.x, p.vel.z).length() < BLOCK_SETTLE_SPEED:
			p.start_loaded_jump()
	else:
		# Track along the net in a loaded stance, hands low. Holding the middle
		# until the attack cue is deliberate: following every set's small lateral
		# drift was visually busy and gave up the centre for no benefit.
		_go(p, goal, 0.85)
		p.request_crouch(0.3)
	return true

# DoSpike from the ground: no jump available, so stand under the ball where it
# drops to a height an attack can still be struck from, and play it over.
func _ground_attack(p: Player) -> bool:
	for h: float in [SET_Y, BUMP_Y]:
		var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, h)
		if not bt[0]:
			continue
		var c: Vector3 = bt[1]
		_go(p, Vector3(clampf(c.x, -COURT_X, COURT_X), Player.PLAYER_HEIGHT,
			clampf(c.z, -COURT_Z, COURT_Z)))
		p.face_target = ball.position
		p.has_face_target = true
		return true
	_go(p, _home(p))
	return true

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
	if not p.grounded:
		# Airborne: hold still and let the arms do the work. Drive in the air is
		# drift, and drift at the net is a fault.
		p.move_input = Vector3.ZERO
		p.face_target = ball.position
		p.has_face_target = true
		return true
	var bt := MotionPlan.ball_time_to_height(ball.position, ball.vel, SPIKE_STRIKE_Y)
	var strike: Vector3 = bt[1] if bt[0] else Vector3.ZERO
	var tau: float = bt[2] if bt[0] else -1.0
	if not bt[0] or absf(strike.x) > COURT_X or absf(strike.z) > COURT_Z:
		# The set never gets to strike height, so there is no jump attack. Get
		# under where it DOES drop to a playable height and hit it over from the
		# ground instead.
		#
		# This branch is why the attack must not share the generic intercept:
		# PlanIntercept's fallback is waist height, and a third touch played from
		# the waist cannot clear the tape — the ball stays on our side and the
		# rally dies on a four-touch fault. AIPlayer.as never routes an attack
		# through it either. PlayHitter sends touch three straight here, and this
		# is ApproachForSpike's own fallback.
		return _ground_attack(p)
	var time_to_apex: float = Player.LOADED_JUMP_VELOCITY / 19.0
	var plant := Vector3(strike.x + _sign(p.team) * PLANT_OFFSET,
		Player.PLAYER_HEIGHT, strike.z)
	var to_plant := Vector3(plant.x - p.position.x, 0.0, plant.z - p.position.z)
	var dist := to_plant.length()
	var eff_vmax := p.move_speed * p.move_dir_speed_scale(to_plant)
	var sprint_time := dist / maxf(eff_vmax, 0.01) + Tuning.get_first_step_lag()

	p.face_target = ball.position
	p.has_face_target = true

	if tau > sprint_time + time_to_apex + 0.25:
		# Early. Wait coiled at the approach start behind the plant, eyes on the
		# ball — a hitter who drifts onto the plant early has nothing left to
		# convert into height.
		var start := Vector3(plant.x + _sign(p.team) * APPROACH_BACK,
			Player.PLAYER_HEIGHT, plant.z)
		_go(p, start, 0.8)
		p.request_crouch(0.25)
		return true

	# GO. Sprint only outside the jump radius: driving at full speed through the
	# plant made the hitter overshoot and shuttle back and forth over it while
	# waiting for the jump window.
	_go(p, plant, 1.0 if dist > JUMP_RADIUS else 0.35)
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
	if not ball.in_play or _tossing:
		return
	for p in players:
		if p == last_toucher:
			continue
		var c := _contact_centre(p)
		if (ball.position - c).length() > REACH:
			continue
		_do_contact(p)
		return

# Where a player's platform actually is. Standing, that is the chest. DIVING,
# it is out along the lunge and down near the sand — which is the whole point of
# leaving your feet, and until now the thing this sim did not model.
#
# A dive used to buy nothing: start_dive hops the body UP, extra_crouch is a
# presentation channel that never moves the sim node, and this test measured
# from a fixed chest height. So a dive raised the contact point and extended no
# reach, costing 0.42 s of committed velocity plus 0.75 s of recovery for
# nothing. That, not the AI, is why eight attempts to call it made the game
# worse.
const DIVE_EXTEND := 0.55     # the platform reaches this far along the lunge
const DIVE_DROP := 0.45       # and this far below the hip origin, near the sand

func _contact_centre(p: Player) -> Vector3:
	if p.is_diving():
		return Vector3(
			p.position.x + p.dive_dir.x * DIVE_EXTEND,
			p.position.y - DIVE_DROP,
			p.position.z + p.dive_dir.z * DIVE_EXTEND)
	return Vector3(p.position.x, p.position.y + CHEST_OFFSET, p.position.z)

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
		to = _pick_attack_target(p)
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
	# The other split-step trigger, and it is deliberately ONLY the attack: the
	# source fired on their receive and set and attack too, which stacked three
	# dips in a row and read as the body shaking before we ever dug the ball.
	# The attack is the touch that drives the ball toward us.
	if touches == 3:
		for q in players:
			if q.team != p.team:
				q.start_split_step()

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
# The toss is real, not a cut: the left hand lets go at 0.55 and the right hand
# meets the ball at 0.78, so between those two phases the ball is genuinely in
# free flight. The alternative -- spawning it at the strike -- is what made the
# serve read as the ball teleporting into the swing.
const SERVE_TOSS_PHASE := 0.55
const SERVE_STRIKE_PHASE := 0.78
const SERVE_CARRY_UP := 0.35      # the ball rides this far above the hip origin

var serving := false
var serve_t := 0.0
var server: Player = null
var _served := false
var _serve_from := Vector3.ZERO
var _serve_vel := Vector3.ZERO
# The ball is airborne during the toss but must not be playable: a receiver who
# could dig the server's own toss is not a rule, it is a bug.
var _tossing := false
var _tossed := false

func _serve() -> void:
	# The takeover lasts one rally. A new serve starts with the court back under
	# full AI, so every point begins the same way and you press for the ball you
	# actually want rather than inheriting a body from the last exchange.
	_release_human()
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
	_landed = false
	_served = false
	_tossed = false
	_tossing = false
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
	if not _tossed and ph >= SERVE_TOSS_PHASE:
		# Up it goes, aimed to arrive at the strike point exactly when the hand
		# does. velocity_for_flight_time is the solve keyed on TIME, which is the
		# right question here: the toss has to meet a choreography beat, not an
		# apex.
		_tossed = true
		_tossing = true
		var carry := Vector3(_serve_from.x, Player.PLAYER_HEIGHT + SERVE_CARRY_UP,
			_serve_from.z)
		var t_free := (SERVE_STRIKE_PHASE - SERVE_TOSS_PHASE) * SERVE_WINDUP
		ball.launch(carry, Ball.velocity_for_flight_time(carry, _serve_from, t_free))
	if not _served and ph >= SERVE_STRIKE_PHASE:
		_served = true
		_tossing = false
		ball.launch(_serve_from, _serve_vel)
		# OnServeLaunched: the rally starts at the STRIKE, not at the windup.
		state.start_rally()
		_serve_phase = true
		# The ball just went live against the receivers, which is one of the two
		# moments a defender split-steps.
		for p in players:
			if p.team != _serving_team_this_serve:
				p.start_split_step()
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
