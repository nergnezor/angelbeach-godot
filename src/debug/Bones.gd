# Diagnostic: which bone owns which lump of the mesh?
#
# "The torso is too big" is a statement about geometry, but the only handle we
# have on geometry is the skeleton. This walks the skinned mesh, assigns every
# vertex to the bone that weights it most, and prints that bone's vertex AABB in
# rest pose. That turns "the big slab" into a bone name and a width in metres —
# the thing you can actually scale.
#
#   godot --headless --path . res://src/debug/Bones.tscn
extends Node3D

func _ready() -> void:
	var scene := load("res://assets/player.glb") as PackedScene
	var model := scene.instantiate()
	add_child(model)
	var skel := _find(model, "Skeleton3D") as Skeleton3D
	var mi := _find(model, "MeshInstance3D") as MeshInstance3D
	var mesh := mi.mesh as ArrayMesh
	print("BONES mesh surfaces=%d skeleton bones=%d" % [mesh.get_surface_count(), skel.get_bone_count()])

	# In the bind pose skinning is the identity, so a vertex sits exactly where the
	# array says and no bone transform needs applying. That is the whole reason to
	# measure here rather than mid-animation.
	skel.reset_bone_poses()
	skel.force_update_all_bone_transforms()

	var mins: Array[Vector3] = []
	var maxs: Array[Vector3] = []
	var counts: Array[int] = []
	for b in skel.get_bone_count():
		mins.append(Vector3(1e9, 1e9, 1e9))
		maxs.append(Vector3(-1e9, -1e9, -1e9))
		counts.append(0)

	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / verts.size()   # 4 or 8 influences per vertex
		for i in verts.size():
			var p := verts[i]
			var best := -1
			var best_w := -1.0
			for k in per:
				var w := weights[i * per + k]
				if w > best_w:
					best_w = w
					best = bones[i * per + k]
			if best < 0:
				continue
			mins[best] = Vector3(minf(mins[best].x, p.x), minf(mins[best].y, p.y), minf(mins[best].z, p.z))
			maxs[best] = Vector3(maxf(maxs[best].x, p.x), maxf(maxs[best].y, p.y), maxf(maxs[best].z, p.z))
			counts[best] += 1

	print("BONES per-bone vertex AABB (model space, metres) — dominant weight wins:")
	for b in skel.get_bone_count():
		if counts[b] == 0:
			continue
		var size := maxs[b] - mins[b]
		print("   %-16s verts=%-5d size=(w %.3f, h %.3f, d %.3f)  y=%.3f..%.3f"
			% [skel.get_bone_name(b), counts[b], size.x, size.y, size.z, mins[b].y, maxs[b].y])
	_dump_tracks(_find(model, "AnimationPlayer") as AnimationPlayer)
	get_tree().quit()

# A bone pose written from a modifier survives only if the animation does not
# key the same channel. Which channels are keyed decides whether a proportion
# fix can be a one-off at setup or has to be re-applied every frame.
func _dump_tracks(anim: AnimationPlayer) -> void:
	for a in anim.get_animation_list():
		var an := anim.get_animation(a)
		var kinds := {}
		for t in an.get_track_count():
			var path := str(an.track_get_path(t))
			var bone := path.get_slice(":", 1)
			var kind := "pos" if an.track_get_type(t) == Animation.TYPE_POSITION_3D \
				else ("rot" if an.track_get_type(t) == Animation.TYPE_ROTATION_3D \
				else ("scale" if an.track_get_type(t) == Animation.TYPE_SCALE_3D else "other"))
			kinds[bone] = str(kinds.get(bone, "")) + kind + " "
		print("BONES anim '%s' (%.2fs): %d tracks" % [a, an.length, an.get_track_count()])
		for b in ["chest", "waist", "hip", "r-arm", "head"]:
			if kinds.has(b):
				print("   %-8s %s" % [b, kinds[b]])

func _find(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null
