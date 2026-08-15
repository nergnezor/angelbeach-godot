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

# Thigh and shin rotate so the foot reaches `target` in world space. The solver
# itself is in TwoBoneIK — the arms are the same two-link problem, and the arms
# cannot measure their second length off a child bone, so the caller supplies
# both lengths.
func _solve_to(foot: int, target: Vector3) -> void:
	var shin := skel.get_bone_parent(foot)
	var thigh := skel.get_bone_parent(shin)
	if shin < 0 or thigh < 0:
		return

	var to_world := skel.global_transform
	var hip_w: Vector3 = (to_world * skel.get_bone_global_pose(thigh)).origin
	var knee_w: Vector3 = (to_world * skel.get_bone_global_pose(shin)).origin
	var foot_w: Vector3 = (to_world * skel.get_bone_global_pose(foot)).origin

	TwoBoneIK.solve(skel, thigh, shin,
		hip_w.distance_to(knee_w), knee_w.distance_to(foot_w), target)
