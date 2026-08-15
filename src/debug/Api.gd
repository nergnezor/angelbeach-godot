extends Node3D
func _ready() -> void:
	var s := Skeleton3D.new()
	var want := ["set_bone_global_pose", "set_bone_global_pose_override",
		"set_bone_pose_position", "set_bone_pose_rotation", "get_bone_global_pose",
		"force_update_all_bone_transforms", "get_bone_parent", "get_bone_rest"]
	for m in want:
		print("%-34s %s" % [m, s.has_method(m)])
	print("SkeletonModifier3D exists: ", ClassDB.class_exists("SkeletonModifier3D"))
	print("SkeletonIK3D exists:       ", ClassDB.class_exists("SkeletonIK3D"))
	get_tree().quit()
