# Court — the thing you actually look at. Built in code because the sim was
# built in code: Match.gd news up its ball and its players, so the scene file
# stays a single node and the geometry follows the same constants the rules do.
#
# A beach court is 16 x 8 m, which is exactly 2*COURT_X by 2*COURT_Z. The net
# tape sits at Contact.NET_TOP_Y. Nothing here is decorative-only: if the visual
# and the sim disagree about where the net is, you can see it.
extends Node3D
class_name Court

const HALF_LENGTH := 8.0
const HALF_WIDTH := 4.0
const NET_TOP := 2.43
const NET_DROP := 1.0            # tape down to the bottom of the netting
const LINE_W := 0.05

static func _mat(color: Color, rough: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	add_child(mi)
	return mi

func _ready() -> void:
	_build_sand()
	_build_lines()
	_build_net()
	_build_sky()

func _build_sand() -> void:
	# Wider than the court so the eye has somewhere to land past the back line.
	_box(Vector3(46.0, 0.4, 30.0), Vector3(0.0, -0.2, 0.0),
		_mat(Color(0.85, 0.72, 0.48)))

func _build_lines() -> void:
	var mat := _mat(Color(0.95, 0.95, 0.92), 0.6)
	var y := 0.003                                    # just proud of the sand
	for x in [-HALF_LENGTH, 0.0, HALF_LENGTH]:
		_box(Vector3(LINE_W, 0.006, HALF_WIDTH * 2.0), Vector3(x, y, 0.0), mat)
	for z in [-HALF_WIDTH, HALF_WIDTH]:
		_box(Vector3(HALF_LENGTH * 2.0, 0.006, LINE_W), Vector3(0.0, y, z), mat)

func _build_net() -> void:
	var band := NET_DROP
	var mid := NET_TOP - band * 0.5
	# Netting: dark and see-through, so the far side stays readable.
	var mesh_mat := _mat(Color(0.08, 0.08, 0.10), 0.8)
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.albedo_color.a = 0.55
	mesh_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box(Vector3(0.02, band, HALF_WIDTH * 2.0 + 0.4), Vector3(0.0, mid, 0.0), mesh_mat)
	# The tape. This is the edge the third touch has to clear, so it is the one
	# piece of court geometry worth drawing precisely.
	_box(Vector3(0.06, 0.07, HALF_WIDTH * 2.0 + 0.4), Vector3(0.0, NET_TOP, 0.0),
		_mat(Color(0.97, 0.97, 0.97), 0.5))
	var post := _mat(Color(0.35, 0.33, 0.30), 0.7)
	for z in [-HALF_WIDTH - 0.25, HALF_WIDTH + 0.25]:
		_box(Vector3(0.1, NET_TOP + 0.15, 0.1),
			Vector3(0.0, (NET_TOP + 0.15) * 0.5, z), post)

func _build_sky() -> void:
	# Sun, sky and haze all live in CourtEnvironment now — it is the port of
	# Script/World/Environment.as, and the placeholder blue sky that used to sit
	# here was never the game's art direction, just something to see the court
	# against.
	add_child(CourtEnvironment.new())
