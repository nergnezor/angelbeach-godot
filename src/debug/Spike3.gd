# Spike 3 — does pinning a planted foot actually kill the slide?
#
# Same measurement as spike 2, same rig, same speed profile. Three configs:
#   A) fixed rate     — run cycle at its authored speed
#   B) speed-synced   — playback rate matched to ground speed
#   C) synced + lock  — B plus FootLock pinning the stance foot in world space
#
# The number to beat is the UE build's 245 cm of skate per second of motion.
extends Node3D

const HZ := 60.0
const RUN_SECONDS := 20.0
const PLANT_Y := 0.13

var model: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var lock: FootLock
var l_foot := -1
var r_foot := -1
var cycle_speed := 0.0

func _ready() -> void:
	var scene := load("res://assets/player.glb") as PackedScene
	model = scene.instantiate()
	add_child(model)
	skel = _find(model, "Skeleton3D") as Skeleton3D
	anim = _find(model, "AnimationPlayer") as AnimationPlayer
	l_foot = skel.find_bone("l-foot")
	r_foot = skel.find_bone("r-foot")

	lock = FootLock.new()
	lock.setup(skel)
	lock.enabled = false
	skel.add_child(lock)

	_calibrate()
	var a := _measure(false, false)
	var b := _measure(true, false)
	var c := _measure(true, true)

	print("")
	print("FOOTSLIDE  A fixed rate      = %6.1f cm/s" % a)
	print("FOOTSLIDE  B speed-synced    = %6.1f cm/s" % b)
	print("FOOTSLIDE  C synced + LOCK   = %6.1f cm/s" % c)
	print("FOOTSLIDE  UE reference      =  245.0 cm/s")
	print("SPIKE3 DONE")
	get_tree().quit()

func _find(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for ch in n.get_children():
		var r := _find(ch, cls)
		if r != null:
			return r
	return null

func _calibrate() -> void:
	anim.play("run")
	var len_s := anim.get_animation("run").length
	var min_z := 1e9
	var max_z := -1e9
	for i in 240:
		anim.seek(len_s * float(i) / 240.0, true)
		skel.force_update_all_bone_transforms()
		var p := (skel.global_transform * skel.get_bone_global_pose(l_foot)).origin
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	cycle_speed = ((max_z - min_z) / (len_s * 0.5)) * 100.0

func _measure(sync_rate: bool, use_lock: bool) -> float:
	lock.enabled = use_lock
	var dt := 1.0 / HZ
	var t := 0.0
	var slide := 0.0
	var moving := 0.0
	var pos := Vector3.ZERO
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var first := true
	anim.play("run")
	anim.seek(0.0, true)

	while t < RUN_SECONDS:
		var speed: float = 300.0 + 250.0 * sin(t * 0.7)
		if fmod(t, 7.0) < 1.0:
			speed = 0.0
		pos.z += (speed / 100.0) * dt
		model.position = pos

		var rate := 1.0
		if sync_rate and cycle_speed > 1.0:
			rate = clampf(speed / cycle_speed, 0.0, 6.0)
		anim.advance(dt * rate)
		skel.force_update_all_bone_transforms()
		if use_lock:
			# The modifier hook only fires inside the engine's own skeleton
			# update; drive it directly so the headless loop exercises the same
			# code the windowed run will.
			lock._process_modification_manual(dt)

		var lw := (skel.global_transform * skel.get_bone_global_pose(l_foot)).origin
		var rw := (skel.global_transform * skel.get_bone_global_pose(r_foot)).origin
		if not first and speed > 60.0:
			moving += dt
			if lw.y < PLANT_Y:
				slide += Vector2(lw.x - prev_l.x, lw.z - prev_l.z).length() * 100.0
			if rw.y < PLANT_Y:
				slide += Vector2(rw.x - prev_r.x, rw.z - prev_r.z).length() * 100.0
		first = false
		prev_l = lw
		prev_r = rw
		t += dt

	if moving <= 0.0:
		return 0.0
	return slide / moving
