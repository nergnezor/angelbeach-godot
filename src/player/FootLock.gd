# FootLock — two-bone IK that pins a planted foot to the world.
#
# This is the mechanism the whole engine move was decided on. Measurements said:
#   UE build, no locomotion wired      245 cm of foot skate per second of motion
#   Godot, run cycle at authored rate  362 cm/s
#   Godot, playback rate speed-synced  354 cm/s   <- only 2% better
#
# Rate matching cannot work on this cycle: the foot spends 19% of the cycle in
# contact and travels a SINUSOIDAL path, so its speed at the bottom of the arc
# is at maximum, not constant. No single playback rate cancels a varying sweep.
# The only thing that plants a foot is pinning it: when contact begins, remember
# where the foot was in world space, hold it there until the animation lifts it,
# and bend the leg to reach.
extends SkeletonModifier3D
class_name FootLock

# Contact window, measured from the rig (see debug/Diag.gd): the foot bone sits
# at ankle height and never drops below 0.078 even at full stance.
const PLANT_Y := 0.13
const RELEASE_Y := 0.19          # hysteresis, so a foot cannot chatter in and out
const MAX_LOCK_TIME := 0.45      # a lock outliving its stride drags the body

var skel: Skeleton3D
var l_foot := -1
var r_foot := -1
var _locked := {}                # bone index -> world position it is pinned to
var _lock_age := {}
var enabled := true

func setup(s: Skeleton3D) -> void:
	skel = s
	l_foot = s.find_bone("l-foot")
	r_foot = s.find_bone("r-foot")

func _process_modification() -> void:
	_run(get_process_delta_time())

# Same body, callable from a headless loop that drives the skeleton itself.
func _process_modification_manual(dt: float) -> void:
	_run(dt)

func _run(dt: float) -> void:
	if not enabled or skel == null:
		return
	for idx in [l_foot, r_foot]:
		if idx < 0:
			continue
		_update_foot(idx, dt)

func _update_foot(idx: int, dt: float) -> void:
	var world := skel.global_transform * skel.get_bone_global_pose(idx)
	var y := world.origin.y

	if _locked.has(idx):
		_lock_age[idx] = _lock_age.get(idx, 0.0) + dt
		# Release when the animation lifts the foot, or when the lock has held
		# longer than a stride could justify.
		if y > RELEASE_Y or _lock_age[idx] > MAX_LOCK_TIME:
			_locked.erase(idx)
			_lock_age.erase(idx)
			return
		_solve_to(idx, _locked[idx])
	elif y < PLANT_Y:
		# Contact begins here. Pin it where it landed.
		_locked[idx] = world.origin
		_lock_age[idx] = 0.0
		_solve_to(idx, world.origin)

# Two-bone IK: thigh and shin rotate so the foot reaches `target` in world
# space. Solved by the law of cosines, which is exact for a two-link chain and
# far cheaper than a full-body solver — and, unlike one, it cannot drag the
# pelvis around, which is what made the UE rig shake in the first place.
func _solve_to(foot: int, target: Vector3) -> void:
	var shin := skel.get_bone_parent(foot)
	var thigh := skel.get_bone_parent(shin)
	if shin < 0 or thigh < 0:
		return

	var to_world := skel.global_transform
	var hip_w: Vector3 = (to_world * skel.get_bone_global_pose(thigh)).origin
	var knee_w: Vector3 = (to_world * skel.get_bone_global_pose(shin)).origin
	var foot_w: Vector3 = (to_world * skel.get_bone_global_pose(foot)).origin

	var l1 := hip_w.distance_to(knee_w)
	var l2 := knee_w.distance_to(foot_w)
	var to_target := target - hip_w
	var dist: float = clampf(to_target.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	if dist < 0.0001:
		return

	# Knee angle from the law of cosines, then the hip angle that aims the chain.
	var cos_knee: float = clampf((l1 * l1 + l2 * l2 - dist * dist) / (2.0 * l1 * l2), -1.0, 1.0)
	var knee_angle := acos(cos_knee)
	var cos_hip: float = clampf((l1 * l1 + dist * dist - l2 * l2) / (2.0 * l1 * dist), -1.0, 1.0)
	var hip_angle := acos(cos_hip)

	# Bend in the plane containing the current knee, so the leg keeps the pose's
	# own knee direction instead of snapping to an arbitrary one.
	var chain_dir := to_target.normalized()
	var current := (knee_w - hip_w).normalized()
	var bend_axis := chain_dir.cross(current)
	if bend_axis.length_squared() < 0.0001:
		bend_axis = chain_dir.cross(Vector3.RIGHT)
		if bend_axis.length_squared() < 0.0001:
			bend_axis = chain_dir.cross(Vector3.FORWARD)
	bend_axis = bend_axis.normalized()

	var new_knee := hip_w + chain_dir.rotated(bend_axis, hip_angle) * l1
	_aim_bone(thigh, new_knee - hip_w)
	_aim_bone(shin, target - new_knee)

# Rotate a bone so its axis toward its child points along `dir` (world space).
func _aim_bone(bone: int, dir: Vector3) -> void:
	if dir.length_squared() < 0.000001:
		return
	var g := skel.get_bone_global_pose(bone)
	var cur_world := (skel.global_transform * g).basis
	# The rig's bones run down +Y in their own space; find the rotation that
	# takes the current direction onto the wanted one and pre-apply it.
	var from := (cur_world * Vector3.UP).normalized()
	var to := dir.normalized()
	var axis := from.cross(to)
	if axis.length_squared() < 0.000001:
		return
	var angle := from.angle_to(to)
	var delta := Basis(axis.normalized(), angle)
	var new_basis := delta * cur_world
	var local := skel.global_transform.basis.inverse() * new_basis
	skel.set_bone_global_pose(bone, Transform3D(local, g.origin))
