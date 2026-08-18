# Spike 4 — does hit_type go HIT_SPIKE early enough for the backswing/cocked
# phases to actually play before contact, or does it still snap straight to
# the follow-through?
#
# Same approach as Crouch.gd: run the real Match.tscn windowed (not
# --headless, since the SkeletonModifier3D/gesture pipeline is gated on that),
# trace ONE player's first full spike from the moment hit_type first goes live
# through contact, and print blend/swing/swing_phase-relevant state — no image
# needed, the numbers say whether phase 1-3 actually ran.
#
#   godot --path . res://src/debug/Spike4.tscn
extends Node3D

const RUN_SECONDS := 45.0

var match_scene: Node
var _t := 0.0
var _traced: Player = null
var _trace_done := false
var _armed_at := -1.0
var _contact_at := -1.0
var _prev_hit := GestureIK.HIT_NONE
var _prev_blend := {}
var _windup_ticks := 0
var _blend_drops := 0

func _ready() -> void:
	var scene := load("res://src/match/Match.tscn") as PackedScene
	match_scene = scene.instantiate()
	add_child(match_scene)

func _physics_process(dt: float) -> void:
	_t += dt
	for p: Player in match_scene.players:
		if p.skel == null:
			continue
		# Jitter check, same fingerprint as Crouch.gd's, scoped to spikes only.
		if p.hit_type == GestureIK.HIT_SPIKE and p.swing <= 0.0:
			_windup_ticks += 1
			var prev: float = _prev_blend.get(p, p.gesture_blend)
			if p.gesture_blend < prev - 0.001:
				_blend_drops += 1
		_prev_blend[p] = p.gesture_blend

		if _trace_done:
			continue
		if _traced == null and p.hit_type == GestureIK.HIT_SPIKE:
			_traced = p
			_armed_at = _t
			_prev_hit = GestureIK.HIT_NONE
			print("SPIKE4 armed_at t=%.3f" % _t)
		if _traced != p:
			continue
		if p.hit_type != GestureIK.HIT_SPIKE:
			print("SPIKE4 end t=%.3f (hit_type left HIT_SPIKE, armed_for=%.3fs)" % [_t, _t - _armed_at])
			_trace_done = true
			continue
		if p.swing > 0.0 and _contact_at < 0.0:
			_contact_at = _t
			print("SPIKE4 contact_at t=%.3f windup_duration=%.3fs" % [_t, _t - _armed_at])
		print("SPIKE4 t=%.3f blend=%.2f swing=%.2f grounded=%s vel_y=%.2f"
			% [_t, p.gesture_blend, p.swing, p.grounded, p.vel.y])
	if _t >= RUN_SECONDS:
		_finish()

func _finish() -> void:
	var rate := (100.0 * _blend_drops / _windup_ticks) if _windup_ticks > 0 else -1.0
	print("SPIKE4 RESULT windup_ticks=%d blend_drops=%d drop_rate=%.1f%%"
		% [_windup_ticks, _blend_drops, rate])
	get_tree().quit()
