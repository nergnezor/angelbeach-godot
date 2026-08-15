extends Node3D
func _ready() -> void:
	print("cmdline_args=", OS.get_cmdline_args())
	print("user_args=", OS.get_cmdline_user_args())
	print("display=", DisplayServer.get_name())
	print("feature headless=", OS.has_feature("headless"))
	get_tree().quit()
