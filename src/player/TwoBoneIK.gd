# Two-bone IK, solved by the law of cosines.
#
# Exact for a two-link chain and far cheaper than a full-body solver — and,
# unlike one, it cannot drag the pelvis around, which is what made the UE rig
# shake in the first place.
#
# Both the legs (thigh -> leg -> foot) and the arms (arm -> forearm -> the tip
# where a hand would be, since this rig has no hand bone) are two-link chains, so
# they share this. The caller measures its own link lengths, because the arm's
# second length cannot be read off a child bone that does not exist.
class_name TwoBoneIK

# Place the chain so its end effector reaches `target` in world space.
# `upper` and `lower` are bone indices; `l1` is upper's length, `l2` is the
# distance from `lower`'s origin out to the effector.
#
# `pole` is the elbow/knee hint: the joint bends TOWARD it. Without one the limb
# keeps whatever bend direction the animation already had, which is right for a
# foot being planted but wrong for a stroke — a bump wants the elbows locked out
# and pointing down, and only the pole says so.
static func solve(skel: Skeleton3D, upper: int, lower: int,
		l1: float, l2: float, target: Vector3,
		pole: Vector3 = Vector3.ZERO, use_pole: bool = false) -> void:
	if upper < 0 or lower < 0 or l1 < 0.0001 or l2 < 0.0001:
		return
	var to_world := skel.global_transform
	var root_w: Vector3 = (to_world * skel.get_bone_global_pose(upper)).origin
	var mid_w: Vector3 = (to_world * skel.get_bone_global_pose(lower)).origin

	var to_target := target - root_w
	# Clamp into the annulus the chain can actually reach, so acos stays real.
	var dist: float = clampf(to_target.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	if dist < 0.0001:
		return

	# The angle at the root between the chain direction and the upper link.
	var cos_root: float = clampf((l1 * l1 + dist * dist - l2 * l2) / (2.0 * l1 * dist), -1.0, 1.0)
	var root_angle := acos(cos_root)

	# The mid joint sits in the plane spanned by the chain and the bend direction,
	# at `root_angle` off the chain. Working with the perpendicular component
	# directly rather than rotating about an axis is the same construction and
	# takes a pole hint without a special case.
	var chain_dir := to_target.normalized()
	var bend := Vector3.ZERO
	if use_pole:
		var pv := pole - root_w
		bend = pv - chain_dir * pv.dot(chain_dir)
	if bend.length_squared() < 0.000001:
		# No usable hint: keep the bend the animation already had.
		var current := (mid_w - root_w).normalized()
		bend = current - chain_dir * current.dot(chain_dir)
	if bend.length_squared() < 0.000001:
		bend = chain_dir.cross(Vector3.RIGHT)
		if bend.length_squared() < 0.000001:
			bend = chain_dir.cross(Vector3.FORWARD)
	bend = bend.normalized()

	var new_mid := root_w + (chain_dir * cos(root_angle) + bend * sin(root_angle)) * l1
	place_bone(skel, upper, root_w, new_mid - root_w)
	place_bone(skel, lower, new_mid, target - new_mid)

# Put a bone AT `world_origin` with its child-ward axis along `dir`.
#
# The origin is not optional. Writing back the origin the bone already had
# leaves the lower link where the animation put it, so the moment the upper link
# rotates the limb comes apart at the joint — visible as a forearm floating a
# few centimetres off its own elbow. The parent's new global pose is not
# necessarily reflected in a child's yet when we get here, so rather than depend
# on when the skeleton flushes, both links are placed explicitly.
static func place_bone(skel: Skeleton3D, bone: int, world_origin: Vector3, dir: Vector3) -> void:
	if dir.length_squared() < 0.000001:
		return
	var g := skel.get_bone_global_pose(bone)
	var cur_world := (skel.global_transform * g).basis
	# The rig's bones run down +Y in their own space; find the rotation that
	# takes the current direction onto the wanted one and pre-apply it.
	var from := (cur_world * Vector3.UP).normalized()
	var to := dir.normalized()
	var new_world := cur_world
	var axis := from.cross(to)
	if axis.length_squared() > 0.000001:
		new_world = Basis(axis.normalized(), from.angle_to(to)) * cur_world
	elif from.dot(to) < 0.0:
		# Exactly reversed: any perpendicular axis will do for the half turn.
		var perp := from.cross(Vector3.RIGHT)
		if perp.length_squared() < 0.000001:
			perp = from.cross(Vector3.FORWARD)
		new_world = Basis(perp.normalized(), PI) * cur_world
	skel.set_bone_global_pose(bone, Transform3D(
		skel.global_transform.basis.inverse() * new_world,
		skel.global_transform.affine_inverse() * world_origin))
