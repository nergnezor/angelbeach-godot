# Spike 2 — does a real skeletal locomotion setup kill the foot sliding?
#
# UE measured 245 cm of foot skate per second of motion, with no locomotion
# animation wired up and no foot planting. The question this answers is not
# "is Godot nicer" but "does the thing that was missing actually fix the number,
# and can I build and measure it myself".
#
# Two configurations, same engine, same movement, same metric:
#   A) FIXED   — run cycle plays at its authored rate, as a naive setup does.
#   B) SYNCED  — playback rate driven by actual ground speed, which is what
#                makes a foot that is planted in the animation stay planted in
#                the world.
#
# footSlide is measured exactly as in the UE build: horizontal travel of a foot
# bone, in world space, while that foot is near the ground.
extends Node3D

const HZ := 60.0
const RUN_SECONDS := 20.0
# Measured from the rig (see Diag.gd), not guessed: this character is 1.45m
# tall and its foot bone never drops below y=0.078 even at full stance, while
# the swing phase peaks at 0.48. A "planted" threshold of 0.25 counted half the
# swing as contact — the first version of this spike did exactly that and
# reported a meaningless number for both configurations.
const PLANT_Y := 0.12
# Distance the authored run cycle covers per second at speed_scale 1.0. Measured
# below rather than guessed — see _calibrate().
var cycle_speed := 0.0

var model: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var l_foot := -1
var r_foot := -1

func _ready() -> void:
	var scene := load("res://assets/player.glb") as PackedScene
	model = scene.instantiate()
	add_child(model)
	skel = _find_skeleton(model)
	anim = _find_anim(model)
	if skel == null or anim == null:
		print("SPIKE2 FAIL: skeleton=%s anim=%s" % [skel, anim])
		get_tree().quit()
		return
	l_foot = skel.find_bone("l-foot")
	r_foot = skel.find_bone("r-foot")
	print("SPIKE2 rig: bones=%d  l-foot=%d  r-foot=%d  anims=%s"
		% [skel.get_bone_count(), l_foot, r_foot, anim.get_animation_list()])

	_calibrate()
	var fixed := _measure(false)
	var synced := _measure(true)

	print("")
	print("FOOTSLIDE  fixed-rate   = %6.1f cm/s of motion" % fixed)
	print("FOOTSLIDE  speed-synced = %6.1f cm/s of motion" % synced)
	print("FOOTSLIDE  UE reference = 245.0 cm/s of motion")
	print("SPIKE2 DONE")
	get_tree().quit()

func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null

# How fast does the authored cycle actually travel? A run cycle with no root
# motion "travels" at the speed its planted foot sweeps backward through the
# stride. Measure that sweep directly: it is the number the playback rate has to
# match, and guessing it is exactly how foot sliding gets baked in.
func _calibrate() -> void:
	anim.play("run")
	anim.speed_scale = 1.0
	var len_s := anim.get_animation("run").length
	var samples := 240
	var min_z := 1e9
	var max_z := -1e9
	for i in samples + 1:
		anim.seek(len_s * float(i) / float(samples), true)
		skel.force_update_all_bone_transforms()
		var p := _bone_world(l_foot)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	# STRIDE LENGTH per HALF cycle: each leg plants once per cycle, so the body
	# advances one full stride in half a cycle. Summing only the samples below a
	# plant threshold undercounts badly — the foot bone sits at ankle height and
	# spends little time at its true minimum, which is what made the first
	# calibration report 26 cm/s for a cycle that actually carries 150.
	var stride := max_z - min_z
	cycle_speed = (stride / (len_s * 0.5)) * 100.0
	print("SPIKE2 calibrated: cycle=%.3fs stride=%.1f cm -> authored speed %.1f cm/s"
		% [len_s, stride * 100.0, cycle_speed])

func _bone_world(idx: int) -> Vector3:
	return (skel.global_transform * skel.get_bone_global_pose(idx)).origin

func _measure(sync_rate: bool) -> float:
	var dt := 1.0 / HZ
	var t := 0.0
	var slide := 0.0
	var moving := 0.0
	var pos := Vector3.ZERO
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var first := true
	anim.play("run")

	while t < RUN_SECONDS:
		# A speed profile with accelerations, stops and restarts — a constant
		# jog would flatter any setup.
		var speed: float = 300.0 + 250.0 * sin(t * 0.7)
		if fmod(t, 7.0) < 1.0:
			speed = 0.0
		# Advance the body along +Z, exactly like the ported player would.
		pos.z += (speed / 100.0) * dt          # cm/s -> m/s
		model.position = pos

		# advance() shifts the playhead by the delta it is GIVEN — it does not
		# apply speed_scale. Setting speed_scale and calling advance(dt) left both
		# configurations stepping identically, which is why the first run reported
		# the same number twice. Scale the delta instead.
		var rate := 1.0
		if sync_rate and cycle_speed > 1.0:
			rate = clampf(speed / cycle_speed, 0.0, 6.0)
		anim.advance(dt * rate)
		skel.force_update_all_bone_transforms()

		var lw := _bone_world(l_foot)
		var rw := _bone_world(r_foot)
		if not first:
			if speed > 60.0:
				moving += dt
				# planted = foot near the ground; slide = its horizontal travel
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
