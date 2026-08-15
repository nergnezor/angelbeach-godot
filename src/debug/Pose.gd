# One player, one stroke, one close-up frame.
#
# Debugging arm IK inside a running match is hopeless: four rigs, a moving ball,
# and a camera far enough away that a broken elbow looks like a rendering
# artefact. This puts a single rig in front of a close camera, holds one stroke
# at one point in its swing, and writes a PNG.
#
#   godot --path . res://src/debug/Pose.tscn -- <hit> <swing> <head>
#     hit    1 bump  2 set  3 spike  4 block  5 serve   (0 = ready pose)
#     swing  0..1 through-swing, or -1 for "windup only"
#     head   1 to keep the head, 0 to hide it
extends Node3D

var player: Player
var _hit := 1
var _swing := -1.0
var _phase := 0.5

func _ready() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0:
		_hit = argv[0].to_int()
	if argv.size() > 1:
		_swing = argv[1].to_float()
	if argv.size() > 2:
		_phase = argv[2].to_float()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40.0, 35.0, 0.0)
	sun.light_energy = 1.3
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.45, 0.55, 0.65)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.7)
	env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	player = Player.new()
	add_child(player)
	player.position = Vector3(0.0, Player.PLAYER_HEIGHT, 0.0)
	player.facing = Vector3.RIGHT
	player._sm_want = player.facing
	player.setup_view(load("res://assets/player.glb") as PackedScene)

	# Side-on, so a backswing and a follow-through are actually distinguishable.
	var cam := Camera3D.new()
	cam.position = Vector3(0.6, 1.2, 3.4)
	cam.look_at_from_position(cam.position, Vector3(0.0, 1.0, 0.0), Vector3.UP)
	cam.fov = 45.0
	add_child(cam)

	_capture()

func _capture() -> void:
	# Where the ball would be for this stroke, so the pose has something to aim at.
	var ball_at := Vector3(0.55, 1.15, 0.0)
	if _hit == GestureIK.HIT_SET:
		ball_at = Vector3(0.35, 1.75, 0.0)
	elif _hit == GestureIK.HIT_SPIKE or _hit == GestureIK.HIT_BLOCK:
		ball_at = Vector3(0.45, 2.15, 0.0)

	player.hit_type = _hit
	player.gesture_blend = 1.0
	player.ball_pos = ball_at
	player.ball_live = true
	player.aim = Vector3(6.0, 0.0, 0.0)
	player.has_aim = true
	player.serve_phase = _phase
	if player.gesture != null:
		player.gesture.hide_head = OS.get_cmdline_user_args().size() < 4
		player.gesture.debug_arms = true

	# Let the sink converge on the held pose rather than catching it mid-approach.
	# _update_view is what turns the model to match `facing`; without it the rig
	# faces its authored direction while the solver poses for another, and every
	# stroke comes out rotated off the body. The match calls this every step, so
	# a harness that skips it is testing something the game never does.
	for i in 90:
		player.swing = maxf(_swing, 0.0)
		player._update_view()
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var name := "user://pose_%d_%s.png" % [_hit, str(_swing)]
	img.save_png(name)
	print("POSE hit=%d swing=%.2f -> %s/%s" % [_hit, _swing,
		OS.get_user_data_dir(), name.get_file()])
	get_tree().quit()
