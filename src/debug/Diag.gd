# Diagnostic: what does the run cycle actually do? Before trusting any
# footSlide number, establish the model's scale and which axis the stride runs
# along. Getting either wrong guarantees slide that has nothing to do with the
# engine.
extends Node3D

func _ready() -> void:
	var scene := load("res://assets/player.glb") as PackedScene
	var model := scene.instantiate()
	add_child(model)
	var skel := _find(model, "Skeleton3D") as Skeleton3D
	var anim := _find(model, "AnimationPlayer") as AnimationPlayer
	var lf := skel.find_bone("l-foot")
	var rf := skel.find_bone("r-foot")

	_dump_skeleton(skel)

	# Model scale: how tall is the rig, root to head?
	var head := skel.find_bone("head")
	anim.play("RESET")
	anim.advance(0.0)
	skel.force_update_all_bone_transforms()
	var head_y := (skel.global_transform * skel.get_bone_global_pose(head)).origin.y
	var foot_y := (skel.global_transform * skel.get_bone_global_pose(lf)).origin.y
	print("DIAG scale: head_y=%.3f foot_y=%.3f  => rig height ~%.3f units" % [head_y, foot_y, head_y - foot_y])

	anim.play("run")
	var len_s := anim.get_animation("run").length
	var n := 24
	var minv := Vector3(1e9, 1e9, 1e9)
	var maxv := Vector3(-1e9, -1e9, -1e9)
	print("DIAG run cycle length=%.3fs — left foot trajectory:" % len_s)
	for i in n:
		anim.seek(len_s * float(i) / float(n), true)
		skel.force_update_all_bone_transforms()
		var p := (skel.global_transform * skel.get_bone_global_pose(lf)).origin
		minv = Vector3(minf(minv.x, p.x), minf(minv.y, p.y), minf(minv.z, p.z))
		maxv = Vector3(maxf(maxv.x, p.x), maxf(maxv.y, p.y), maxf(maxv.z, p.z))
		if i % 3 == 0:
			print("   t=%.3f  foot=(%.3f, %.3f, %.3f)" % [len_s * float(i) / float(n), p.x, p.y, p.z])
	print("DIAG foot range: x=%.3f y=%.3f z=%.3f  (stride axis = the largest)"
		% [maxv.x - minv.x, maxv.y - minv.y, maxv.z - minv.z])
	_contact_profile(skel, anim, lf)
	get_tree().quit()

# The gesture engine needs to name shoulders, elbows and hands. Print the whole
# hierarchy once rather than guessing at UE's naming (upperarm_r, hand_l, ...) —
# this rig is not the UE rig and does not share its conventions.
func _dump_skeleton(skel: Skeleton3D) -> void:
	print("DIAG skeleton: %d bones" % skel.get_bone_count())
	for i in skel.get_bone_count():
		var depth := 0
		var p := skel.get_bone_parent(i)
		while p >= 0:
			depth += 1
			p = skel.get_bone_parent(p)
		var rest := skel.get_bone_rest(i).origin
		print("   %s%2d %-16s parent=%-2d rest=(%.3f, %.3f, %.3f)"
			% ["  ".repeat(depth), i, skel.get_bone_name(i), skel.get_bone_parent(i),
				rest.x, rest.y, rest.z])

func _find(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null

# Appended: how much of the cycle is the foot actually in contact? A run cycle
# authored for locomotion has a clear stance phase — a flat, linear backward
# sweep. A stylised cycle just oscillates the foot, and no amount of playback
# rate matching will plant it.
func _contact_profile(skel: Skeleton3D, anim: AnimationPlayer, lf: int) -> void:
	var len_s := anim.get_animation("run").length
	var n := 200
	for thresh in [0.10, 0.12, 0.15, 0.20, 0.25]:
		var below := 0
		for i in n:
			anim.seek(len_s * float(i) / float(n), true)
			skel.force_update_all_bone_transforms()
			if (skel.global_transform * skel.get_bone_global_pose(lf)).origin.y < thresh:
				below += 1
		print("DIAG contact: foot below y=%.2f for %d%% of the cycle" % [thresh, below * 100 / n])
