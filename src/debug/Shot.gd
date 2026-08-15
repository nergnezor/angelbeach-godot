# Screenshot harness. Runs the real match scene for a while, grabs the frame the
# player would be looking at, writes it out and quits.
#
# The point is to be able to LOOK at the game from a terminal. A rendering
# mistake — model on its side, camera under the sand, court at the wrong scale —
# is invisible to every headless number in this project, and those numbers are
# most of what we have.
#
#   godot --path . res://src/debug/Shot.tscn -- 240
extends Node3D

const DEFAULT_FRAMES := 240

func _ready() -> void:
	var frames := DEFAULT_FRAMES
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0 and argv[0].is_valid_int():
		frames = argv[0].to_int()
	add_child(load("res://src/match/Match.tscn").instantiate())
	_capture(frames)

func _capture(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	# The texture is only complete once the frame has actually been drawn.
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "user://shot.png"
	var err := img.save_png(path)
	print("SHOT frames=%d err=%d -> %s/shot.png" % [frames, err, OS.get_user_data_dir()])
	get_tree().quit()
