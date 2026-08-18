# Crouch — does HIT_BUMP actually bend the knees during a REAL match, measured
# in degrees instead of eyeballed off a render?
#
# Runs the genuine Match.tscn as a child (not headless — Match only drives its
# SkeletonModifier3D pipeline, GestureIK and FootLock, when DisplayServer is
# not "headless", same as the windowed game the crouch fix targets), and every
# physics tick reads each player's actual thigh/shin/foot bones to get a real
# knee angle: 180 deg is a straight leg, less is bent. Baseline is sampled
# whenever a player is standing with no stroke and no other crouch source
# live; the bump number is the minimum (most bent) seen while HIT_BUMP is
# playing. Prints one CROUCH RESULT line and quits — no image to look at.
#
#   godot --path . res://src/debug/Crouch.tscn
extends Node3D

const RUN_SECONDS := 45.0

var match_scene: Node
var _t := 0.0
var _base_sum := 0.0
var _base_n := 0
var _bump_min := 999.0
var _bump_n := 0
var _bump_deepest_line := ""
var _still_bump_min := 999.0
var _still_bump_line := ""
var _still_bump_sum := 0.0
var _still_bump_n := 0
var _base_still_sum := 0.0
var _base_still_n := 0

# Jitter: how often does gesture_blend fall BACKWARD while a stroke is still
# in its windup (hit_type set, swing not yet triggered)? A player easing into
# a pose should have blend rise monotonically toward 1 over BLEND_TIME; any
# drop mid-windup is the pose visibly snapping back toward ready before
# building again — the armed/release_stroke flicker's direct fingerprint.
var _prev_blend := {}       # Player -> last frame's gesture_blend
var _windup_ticks := 0
var _blend_drops := 0
var _worst_drop := 0.0

var _traced: Player = null
var _trace_done := false

func _ready() -> void:
	var scene := load("res://src/match/Match.tscn") as PackedScene
	match_scene = scene.instantiate()
	add_child(match_scene)

func _physics_process(dt: float) -> void:
	_t += dt
	for p: Player in match_scene.players:
		if p.skel == null:
			continue
		var lr := _knee_angle(p, true)
		var ll := _knee_angle(p, false)
		var deg := minf(lr, ll)
		var speed := Vector2(p.vel.x, p.vel.z).length()
		# Sink fraction actually written to the model this frame, read back out
		# of view.position.y rather than GestureIK's private _crouch, so this
		# checks what was APPLIED, not just what was computed.
		var sink_frac := 0.0
		if p.view != null:
			sink_frac = (-Player.PLAYER_HEIGHT - p.view.position.y) / GestureIK.CROUCH_DROP
		if p.hit_type == GestureIK.HIT_BUMP:
			_bump_n += 1
			if deg < _bump_min:
				_bump_min = deg
				_bump_deepest_line = "%s knee_r=%.1f knee_l=%.1f sink_frac=%.2f extra_crouch=%.2f swing=%.2f speed=%.2f grounded=%s" \
					% [p.name, lr, ll, sink_frac, p.extra_crouch, p.swing, speed, p.grounded]
			# Also track the deepest bend while essentially STATIONARY, i.e. a
			# real reception rather than a bump played off a run.
			if speed < 0.3:
				if deg < _still_bump_min:
					_still_bump_min = deg
					_still_bump_line = "%s knee_r=%.1f knee_l=%.1f sink_frac=%.2f extra_crouch=%.2f swing=%.2f" \
						% [p.name, lr, ll, sink_frac, p.extra_crouch, p.swing]
				_still_bump_sum += deg
				_still_bump_n += 1
		elif p.hit_type == GestureIK.HIT_NONE and p.extra_crouch < 0.02 and p.grounded:
			_base_sum += deg
			_base_n += 1
			if speed < 0.3:
				_base_still_sum += deg
				_base_still_n += 1
		# Windup jitter, independent of which stroke: any hit_type counts, as
		# long as the through-swing has not started yet.
		if p.hit_type != GestureIK.HIT_NONE and p.swing <= 0.0:
			_windup_ticks += 1
			var prev: float = _prev_blend.get(p, p.gesture_blend)
			var drop := prev - p.gesture_blend
			if drop > 0.001:
				_blend_drops += 1
				_worst_drop = maxf(_worst_drop, drop)
		_prev_blend[p] = p.gesture_blend
		# One full bump traced tick-by-tick, from the first windup frame to
		# release, to see whether sink_frac actually reaches its ~0.5 target or
		# stalls early — the aggregate stats above cannot tell those apart.
		if not _trace_done:
			if _traced == null and p.hit_type == GestureIK.HIT_BUMP:
				_traced = p
				print("TRACE start %s" % p.name)
			if _traced == p:
				if p.hit_type == GestureIK.HIT_BUMP:
					print("TRACE t=%.3f blend=%.2f swing=%.2f sink_frac=%.3f knee=%.1f speed=%.2f"
						% [_t, p.gesture_blend, p.swing, sink_frac, deg, speed])
				else:
					print("TRACE end")
					_trace_done = true
	if _t >= RUN_SECONDS:
		_finish()

func _finish() -> void:
	var base_avg := (_base_sum / _base_n) if _base_n > 0 else -1.0
	var base_still_avg := (_base_still_sum / _base_still_n) if _base_still_n > 0 else -1.0
	var still_bump_avg := (_still_bump_sum / _still_bump_n) if _still_bump_n > 0 else -1.0
	print("CROUCH RESULT baseline_knee_avg=%.1fdeg baseline_still_avg=%.1fdeg bump_knee_min=%.1fdeg still_bump_knee_min=%.1fdeg still_bump_knee_avg=%.1fdeg samples base=%d base_still=%d bump=%d still_bump=%d"
		% [base_avg, base_still_avg, _bump_min, _still_bump_min, still_bump_avg, _base_n, _base_still_n, _bump_n, _still_bump_n])
	if _bump_deepest_line != "":
		print("CROUCH DEEPEST(any speed) %s" % _bump_deepest_line)
	if _still_bump_line != "":
		print("CROUCH DEEPEST(stationary) %s" % _still_bump_line)
	var drop_rate := (100.0 * _blend_drops / _windup_ticks) if _windup_ticks > 0 else -1.0
	print("JITTER windup_ticks=%d blend_drops=%d drop_rate=%.1f%% worst_drop=%.3f"
		% [_windup_ticks, _blend_drops, drop_rate, _worst_drop])
	get_tree().quit()

func _knee_angle(p: Player, right: bool) -> float:
	var skel := p.skel
	var foot := skel.find_bone("r-foot" if right else "l-foot")
	if foot < 0:
		return 180.0
	var shin := skel.get_bone_parent(foot)
	var thigh := skel.get_bone_parent(shin)
	if shin < 0 or thigh < 0:
		return 180.0
	var to_world := skel.global_transform
	var hip_w: Vector3 = (to_world * skel.get_bone_global_pose(thigh)).origin
	var knee_w: Vector3 = (to_world * skel.get_bone_global_pose(shin)).origin
	var foot_w: Vector3 = (to_world * skel.get_bone_global_pose(foot)).origin
	var a := (hip_w - knee_w).normalized()
	var b := (foot_w - knee_w).normalized()
	return rad_to_deg(a.angle_to(b))
