# The strokes, applied to the rig.
#
# GestureSolver (Rust) answers "where do the hands want to be" from body anchors
# and the stroke being played. This half is everything that needs the engine:
# reading live bone transforms, smoothing, and driving the two arms with
# TwoBoneIK — the same solver the feet use.
#
# Runs BEFORE FootLock in the modifier order, because the crouch channel moves
# the hips and the feet have to be re-planted after that, not before.
extends SkeletonModifier3D
class_name GestureIK

# Mirrors the constants in rust/src/lib.rs.
const HIT_NONE := 0
const HIT_BUMP := 1
const HIT_SET := 2
const HIT_SPIKE := 3
const HIT_BLOCK := 4
const HIT_SERVE := 5

# The original's anti-flicker sink existed to break a feedback loop in UE's
# full-body IK, where the solver moved the pelvis, which moved the shoulders,
# which moved the targets. This rig has no such loop — two-bone IK cannot drag
# the pelvis — so all that is left to do is stop a pose POP when the stroke
# changes. One limit, set well above the fastest real gesture: the original
# measured its hardest whip at 6-8 m/s, so 14 never clips choreography.
const SINK_SPEED := 14.0
const CROUCH_DROP := 0.16         # metres the hips sink at full crouch. The
                                  # rig's hips sit ~0.7 m up. 0.10 was chosen
                                  # back when the bug below meant blend rarely
                                  # got past its first tick of ramping, so the
                                  # sink was barely reachable regardless of
                                  # this value — it was never actually tuned
                                  # against a working sink. Bumped once fixed;
                                  # this mechanism has no shearing failure mode
                                  # to stay cautious of (see the comment at the
                                  # top of _run), the limit is just how deep a
                                  # bend still reads as an athletic stance.

var skel: Skeleton3D
var player: Player
var hide_head := true

var b_head := -1
var b_hip := -1
var b_r_arm := -1
var b_r_fore := -1
var b_l_arm := -1
var b_l_fore := -1

var upper_len := 0.0
var fore_len := 0.0
var arm_reach := 0.0

var _sink_init := false
var _hand_r := Vector3.ZERO
var _hand_l := Vector3.ZERO
var _crouch := 0.0
var bone_unit_m := 0.0

func setup(s: Skeleton3D, p: Player) -> void:
	skel = s
	player = p
	b_head = s.find_bone("head")
	b_hip = s.find_bone("hip")
	b_r_arm = s.find_bone("r-arm")
	b_r_fore = s.find_bone("r-forearm")
	b_l_arm = s.find_bone("l-arm")
	b_l_fore = s.find_bone("l-forearm")
	_measure()

# Measure the arm, do not assume it. The gesture offsets are all expressed
# against arm reach, and this rig is 1.45 m rather than the original's ~1.8 m.
#
# The forearm's length cannot be read off a child bone, because there is no hand
# bone — the forearm is the end of the chain and its tip is where a hand would
# be. Taking it as equal to the upper arm is the rig's own proportion: the two
# rest offsets that DO exist are symmetric.
func _measure() -> void:
	if b_r_arm < 0 or b_r_fore < 0:
		return
	skel.force_update_all_bone_transforms()
	var sh: Vector3 = (skel.global_transform * skel.get_bone_global_pose(b_r_arm)).origin
	var el: Vector3 = (skel.global_transform * skel.get_bone_global_pose(b_r_fore)).origin
	upper_len = sh.distance_to(el)
	fore_len = upper_len
	arm_reach = upper_len + fore_len
	# Bone poses are in the rig's OWN units, not metres: this rig's hip rest is
	# 2.106 on a body 1.45 m tall. The conversion is measurable rather than
	# guessable — the forearm's rest offset is a known length in bone units and
	# we just measured the same segment in metres.
	var rest_len := skel.get_bone_rest(b_r_fore).origin.length()
	if rest_len > 0.0001:
		bone_unit_m = upper_len / rest_len

func _process_modification() -> void:
	_run(get_process_delta_time())

# Same body, callable from a headless loop that drives the skeleton itself.
func _process_modification_manual(dt: float) -> void:
	_run(dt)

func _bone_world(idx: int) -> Vector3:
	return (skel.global_transform * skel.get_bone_global_pose(idx)).origin

func _run(dt: float) -> void:
	if skel == null or player == null or arm_reach < 0.0001:
		return
	if hide_head and b_head >= 0:
		# One skinned mesh, so the head cannot be hidden as a node — collapse the
		# bone instead. Not exactly zero: a degenerate basis makes the skinning
		# matrix non-invertible.
		skel.set_bone_pose_scale(b_head, Vector3(0.001, 0.001, 0.001))

	# The crouch goes on BEFORE the anchors are read, using last frame's value,
	# so the shoulder positions below already include the sink. FootLock runs
	# after this and re-plants the feet at the true floor height, so the legs
	# bend instead of the body sinking into sand.
	#
	# This sinks the MODEL NODE, not a bone. Two earlier attempts translated the
	# hip bone's pose instead and both looked worse: the offset sheared the
	# torso whether it was taken from the animated pose or from rest, and taking
	# it from the animated pose also stacked on itself every frame, because
	# these animations do not key the hip's translation, so the modifier's own
	# write survived into the next one and the sink ran away. A plain Node3D
	# translation on `view` has none of that — it is a rigid offset below the
	# whole skeleton, not a write into one of its bones — and FootLock already
	# has the machinery (two-bone IK, the same solver the arms use) to bend the
	# legs back out to the feet's true position once the hips have moved.
	if player.view != null:
		player.view.position.y = -Player.PLAYER_HEIGHT - _crouch * CROUCH_DROP

	var sh_r := _bone_world(b_r_arm)
	var sh_l := _bone_world(b_l_arm)
	var head := _bone_world(b_head) if b_head >= 0 else (sh_r + sh_l) * 0.5

	var fwd := player.facing.normalized()
	# fwd x UP is the standard right-hand rule and matches Godot's own basis
	# (a node facing -Z has +X to its right). Measured against this rig it comes
	# out mirrored — with the body facing +X the bone named "r-arm" sits at
	# negative Z — so the rig's r-/l- names are on the opposite sides to the
	# convention. Negating here keeps "right" meaning the rig's right arm, which
	# is the one the spike has to whip with.
	var right := Vector3.UP.cross(fwd)

	var pose: Dictionary = GestureSolver.solve({
		"hit": player.hit_type,
		"blend": player.gesture_blend,
		"swing": player.swing,
		"serve_phase": player.serve_phase,
		"sh_r": sh_r,
		"sh_l": sh_l,
		"head": head,
		"fwd": fwd,
		"right": right,
		"ball": player.ball_pos,
		"ball_in_play": player.ball_live,
		"meet": player.meet,
		"has_meet": player.has_meet,
		"aim": player.aim,
		"has_aim": player.has_aim,
		"arm_reach": arm_reach,
		"feet_y": player.position.y - Player.PLAYER_HEIGHT,
		"extra_crouch": player.extra_crouch,
	})

	var want_r: Vector3 = pose["hand_r"]
	var want_l: Vector3 = pose["hand_l"]
	var want_crouch: float = pose["crouch"]

	if not _sink_init:
		_sink_init = true
		_hand_r = want_r
		_hand_l = want_l
		_crouch = want_crouch
	var max_step := SINK_SPEED * dt
	_hand_r = _toward(_hand_r, want_r, max_step)
	_hand_l = _toward(_hand_l, want_l, max_step)
	# Sinking fast and rising lazy: a slow release reads as a held stance.
	var err := want_crouch - _crouch
	_crouch += err * minf((8.0 if err > 0.0 else 3.0) * dt, 1.0)

	# The poles are the whole reason a bump reads as a locked-out platform and a
	# spike as a high elbow leading the hand. Dropping them leaves the solver to
	# keep whatever bend the idle animation had.
	TwoBoneIK.solve(skel, b_r_arm, b_r_fore, upper_len, fore_len, _hand_r,
		pose["pole_r"], true)
	TwoBoneIK.solve(skel, b_l_arm, b_l_fore, upper_len, fore_len, _hand_l,
		pose["pole_l"], true)
	if debug_arms:
		_debug(sh_r)

var debug_arms := false
var _dbg_n := 0

func _debug(_sh_r: Vector3) -> void:
	_dbg_n += 1
	if _dbg_n % 30 != 0:
		return
	# Read the chain back AFTER solving. The question is not what we asked for,
	# it is where the bones ended up: is the elbow on the shoulder->hand line
	# (locked out) or off it (bent), and does the forearm tip land on target?
	var sh := _bone_world(b_r_arm)
	var el := _bone_world(b_r_fore)
	var fore_axis: Vector3 = (skel.global_transform * skel.get_bone_global_pose(b_r_fore)).basis * Vector3.UP
	var tip := el + fore_axis.normalized() * fore_len
	var straight := sh.distance_to(el) + el.distance_to(tip)
	print("ARM hit=%d blend=%.2f | l1=%.3f l2=%.3f | sh=(%.2f,%.2f,%.2f) el=(%.2f,%.2f,%.2f) tip=(%.2f,%.2f,%.2f) want=(%.2f,%.2f,%.2f) tipErr=%.3f  |sh-want|=%.3f of %.3f"
		% [player.hit_type, player.gesture_blend, upper_len, fore_len,
			sh.x, sh.y, sh.z, el.x, el.y, el.z, tip.x, tip.y, tip.z,
			_hand_r.x, _hand_r.y, _hand_r.z, tip.distance_to(_hand_r),
			sh.distance_to(_hand_r), straight])

static func _toward(from: Vector3, to: Vector3, max_step: float) -> Vector3:
	var d := to - from
	var l := d.length()
	if l <= max_step or l < 0.000001:
		return to
	return from + d * (max_step / l)
