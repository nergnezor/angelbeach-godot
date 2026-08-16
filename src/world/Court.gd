# Court — the port of Script/World/Court.as. Sand, net, lines, posts, all built
# in code because the sim is built in code: Match.gd news up its ball and its
# players, so the scene file stays a single node and the geometry follows the
# same constants the rules do.
#
# Regulation beach court, 16 x 8 m, which is exactly 2*COURT_X by 2*COURT_Z.
# Nothing here is decorative-only: if the visual and the sim disagree about where
# the net is, you can see it.
#
# THREE THINGS THE ORIGINAL FOUGHT FOR, KEPT DELIBERATELY.
#
# The colours are ALBEDO, not pixels. They were first picked for an unlit
# vertex-colour material where the colour IS what you see; the material is lit
# now, and 0.93 sand over a bright sky clipped to near-white — the source calls
# that build "a snowfield". They are kept in the range real surfaces reflect (dry
# sand ~0.5, line paint ~0.8) and the lighting does the brightening.
#
# The net is see-through because of its GEOMETRY, not its material: a band woven
# from thin strings with gaps between them. Two earlier attempts died on
# translucency — one rendered a solid red sheet, the other used an engine debug
# material that silently did not apply in packaged builds. A woven net needs no
# alpha to be transparent, so the whole class of bug goes away. The box with 0.55
# alpha that used to stand here was the same shortcut those attempts took.
#
# There is no centre line. Beach volleyball has none — that is an indoor marking,
# and the version of this file that drew one was wrong about the sport.
extends Node3D
class_name Court

# --- Dimensions, the original's centimetres in metres ------------------------
const HALF_LENGTH := 8.0          # 800 cm, across the net
const HALF_WIDTH := 4.0           # 400 cm, along the net
const NET_TOP := 2.43             # men's net height
const NET_HALF_THICK := 0.025
const POST_HEIGHT := 2.60
const POST_RADIUS := 0.05
const LINE_W := 0.05
const LINE_Y := 0.01              # slightly proud of the sand

# --- The deformable sand heightfield -----------------------------------------
# The skirt was +2 m per side once, and at that width the beach ended barely
# outside the sidelines — the court read as a slab dropped into the sea rather
# than a court marked out on a beach. 5 m gives it somewhere to sit. Grid cells
# land at ~32 cm, still finer than a footprint.
const SAND_GRID_X := 80
const SAND_GRID_Z := 48
const SAND_SKIRT := 5.0
const SAND_MIN_Y := -0.24         # deepest a crater can go
const SAND_HEAL_RATE := 0.35      # how fast footprints and craters refill
const SAND_UPDATE_INTERVAL := 0.06

# --- Albedos ------------------------------------------------------------------
const SAND_COLOR := Color(0.62, 0.52, 0.36)
const NET_BAND_COLOR := Color(0.03, 0.03, 0.04)
const NET_TAPE_COLOR := Color(0.75, 0.75, 0.72)
const LINE_COLOR := Color(0.80, 0.80, 0.76)
# The posts are the exception to the clipping story above: measured at linear
# 0.235 for a 0.45 albedo, they sat at roughly half light rather than saturated,
# so they take an exposure cut at face value where the sand only loses its
# blow-out. Lifted to keep them from going muddy.
const POST_COLOR := Color(0.65, 0.62, 0.56)

var _sand_w := 0.0                # half-extent along x
var _sand_d := 0.0                # half-extent along z
var _cell_x := 1.0
var _cell_z := 1.0

var _height := PackedFloat32Array()      # persistent offset, negative = pushed down
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()

var _sand_mesh: ArrayMesh
var _sand_dirty := false
var _sand_accum := 0.0

static func _mat(color: Color, rough: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = 0.0
	return m

func _ready() -> void:
	_build_sand()
	_build_net()
	_build_lines()
	_build_posts()
	add_child(CourtEnvironment.new())

func _idx(ix: int, iz: int) -> int:
	return iz * (SAND_GRID_X + 1) + ix

func _build_sand() -> void:
	_sand_w = HALF_LENGTH + SAND_SKIRT
	_sand_d = HALF_WIDTH + SAND_SKIRT
	_cell_x = (2.0 * _sand_w) / float(SAND_GRID_X)
	_cell_z = (2.0 * _sand_d) / float(SAND_GRID_Z)

	_verts.resize((SAND_GRID_X + 1) * (SAND_GRID_Z + 1))
	_normals.resize(_verts.size())
	_uvs.resize(_verts.size())
	_colors.resize(_verts.size())
	_height.resize(_verts.size())

	for iz in range(SAND_GRID_Z + 1):
		for ix in range(SAND_GRID_X + 1):
			var i := _idx(ix, iz)
			_verts[i] = Vector3(-_sand_w + ix * _cell_x, 0.0, -_sand_d + iz * _cell_z)
			_normals[i] = Vector3.UP
			_uvs[i] = Vector2(float(ix) / SAND_GRID_X, float(iz) / SAND_GRID_Z)
			_colors[i] = SAND_COLOR
			_height[i] = 0.0

	_indices.resize(SAND_GRID_X * SAND_GRID_Z * 6)
	var t := 0
	for iz in range(SAND_GRID_Z):
		for ix in range(SAND_GRID_X):
			var a := _idx(ix, iz)
			var b := _idx(ix + 1, iz)
			var c := _idx(ix + 1, iz + 1)
			var d := _idx(ix, iz + 1)
			# Winding flips against the original: the z axis is mirrored by the
			# UE -> Godot mapping, so keeping the source's order would face every
			# sand triangle downward.
			_indices[t] = a; _indices[t + 1] = b; _indices[t + 2] = c
			_indices[t + 3] = a; _indices[t + 4] = c; _indices[t + 5] = d
			t += 6

	_sand_mesh = ArrayMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _sand_mesh
	# The crater tint the original could only store and never show: it wrote the
	# per-vertex shade into the section, then noted "a solid-colour material
	# cannot show it, but the data is there for an authored vertex-colour
	# material later." Godot's standard material takes vertex colour as albedo
	# directly, so later is now.
	var m := _mat(Color.WHITE, 0.95)
	m.vertex_color_use_as_albedo = true
	mi.material_override = m
	add_child(mi)
	_upload_sand()

# Sand colour, darkened inside craters — compacted, shadowed sand.
func _shade_at(i: int) -> Color:
	var depth := clampf(-_height[i] / -SAND_MIN_Y, 0.0, 1.0)
	var shade := 1.0 - depth * 0.35
	return Color(SAND_COLOR.r * shade, SAND_COLOR.g * shade, SAND_COLOR.b * shade)

func _upload_sand() -> void:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = _verts
	arr[Mesh.ARRAY_NORMAL] = _normals
	arr[Mesh.ARRAY_TEX_UV] = _uvs
	arr[Mesh.ARRAY_COLOR] = _colors
	arr[Mesh.ARRAY_INDEX] = _indices
	_sand_mesh.clear_surfaces()
	_sand_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

# Push the sand down at a world position: a crater with a small raised rim.
# Called by whatever lands — feet, dives, the ball.
func deform_sand(world_pos: Vector3, radius: float, depth: float) -> void:
	if _height.is_empty():
		return
	var local := world_pos - global_position
	var inv_r := 1.0 / radius if radius > 0.01 else 1.0
	var rim_r := radius * 1.5

	var min_x := clampi(int((local.x - rim_r + _sand_w) / _cell_x) - 1, 0, SAND_GRID_X)
	var max_x := clampi(int((local.x + rim_r + _sand_w) / _cell_x) + 1, 0, SAND_GRID_X)
	var min_z := clampi(int((local.z - rim_r + _sand_d) / _cell_z) - 1, 0, SAND_GRID_Z)
	var max_z := clampi(int((local.z + rim_r + _sand_d) / _cell_z) + 1, 0, SAND_GRID_Z)

	for iz in range(min_z, max_z + 1):
		for ix in range(min_x, max_x + 1):
			var i := _idx(ix, iz)
			var p := _verts[i]
			var d := Vector2(p.x - local.x, p.z - local.z).length()
			if d < radius:
				# Parabolic falloff, deepest at the centre.
				var f := 1.0 - (d * inv_r) * (d * inv_r)
				_height[i] = maxf(SAND_MIN_Y, _height[i] - depth * f)
			elif d < rim_r:
				# The displaced sand has to go somewhere: a low rim, 18% of the
				# crater depth, fading out to nothing.
				var t := (d - radius) / (rim_r - radius)
				_height[i] += (1.0 - t) * depth * 0.18
	_sand_dirty = true

func _process(delta: float) -> void:
	# Heal deformations back toward flat.
	var any_heal := false
	var heal := 1.0 - clampf(SAND_HEAL_RATE * delta, 0.0, 1.0)
	for i in range(_height.size()):
		var h := _height[i]
		if absf(h) > 0.0005:
			_height[i] = h * heal
			any_heal = true
		elif h != 0.0:
			_height[i] = 0.0
			any_heal = true
	if any_heal:
		_sand_dirty = true

	# Throttle the rebuild: it is the one per-frame cost here worth bounding.
	if _sand_dirty:
		_sand_accum += delta
		if _sand_accum >= SAND_UPDATE_INTERVAL:
			_sand_accum = 0.0
			_sand_dirty = false
			_rebuild_sand()

func _rebuild_sand() -> void:
	for i in range(_verts.size()):
		var p := _verts[i]
		_verts[i] = Vector3(p.x, _height[i], p.z)
		_colors[i] = _shade_at(i)

	for iz in range(SAND_GRID_Z + 1):
		for ix in range(SAND_GRID_X + 1):
			var xl := maxi(ix - 1, 0)
			var xr := mini(ix + 1, SAND_GRID_X)
			var zl := maxi(iz - 1, 0)
			var zr := mini(iz + 1, SAND_GRID_Z)
			var dyx := (_height[_idx(xr, iz)] - _height[_idx(xl, iz)]) / ((xr - xl) * _cell_x)
			var dyz := (_height[_idx(ix, zr)] - _height[_idx(ix, zl)]) / ((zr - zl) * _cell_z)
			_normals[_idx(ix, iz)] = Vector3(-dyx, 1.0, -dyz).normalized()

	_upload_sand()

# --- Net ----------------------------------------------------------------------
# Regulation beach mesh is ~10 cm square. Slightly coarser here so the string
# count stays modest: ~72 verticals plus ~11 horizontals is a few hundred
# triangles, and at match camera distance the weave reads correctly.
const NET_SPACING := 0.12
const NET_STRING_W := 0.016
const NET_TAPE_H := 0.07
const NET_BAND_BOTTOM := 1.00     # the mesh stops ~1 m off the sand

func _build_net() -> void:
	var hw := HALF_WIDTH + 0.30
	var band_top := NET_TOP - NET_TAPE_H

	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	var vcount := int((2.0 * hw) / NET_SPACING)
	for i in range(vcount + 1):
		var z := -hw + i * NET_SPACING
		_add_net_strip(v, idx, z - NET_STRING_W * 0.5, z + NET_STRING_W * 0.5,
			NET_BAND_BOTTOM, band_top)
	var hcount := int((band_top - NET_BAND_BOTTOM) / NET_SPACING)
	for i in range(hcount + 1):
		var y := NET_BAND_BOTTOM + i * NET_SPACING
		_add_net_strip(v, idx, -hw, hw, y - NET_STRING_W * 0.5, y + NET_STRING_W * 0.5)
	_add_mesh(v, idx, _mat(NET_BAND_COLOR, 0.8))

	# The white top tape — the classic visual cue for the net line, and the edge
	# the third touch has to clear, so it is the one piece worth drawing exactly.
	var tv := PackedVector3Array()
	var ti := PackedInt32Array()
	_add_net_strip(tv, ti, -hw, hw, band_top, NET_TOP)
	_add_mesh(tv, ti, _mat(NET_TAPE_COLOR, 0.5))

# One double-sided quad in the net plane (x ~ 0), spanning z0..z1 by y0..y1.
func _add_net_strip(v: PackedVector3Array, idx: PackedInt32Array,
		z0: float, z1: float, y0: float, y1: float) -> void:
	var b := v.size()
	v.append(Vector3(-NET_HALF_THICK, y0, z0)); v.append(Vector3(-NET_HALF_THICK, y0, z1))
	v.append(Vector3(-NET_HALF_THICK, y1, z1)); v.append(Vector3(-NET_HALF_THICK, y1, z0))
	v.append(Vector3(NET_HALF_THICK, y0, z1)); v.append(Vector3(NET_HALF_THICK, y0, z0))
	v.append(Vector3(NET_HALF_THICK, y1, z0)); v.append(Vector3(NET_HALF_THICK, y1, z1))
	for tri in [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]]:
		idx.append(b + tri[0]); idx.append(b + tri[1]); idx.append(b + tri[2])

func _add_mesh(v: PackedVector3Array, idx: PackedInt32Array, mat: Material) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# The source hands every strip a flat up normal so the whole band takes
	# identical lighting; generating real ones here costs nothing and stops the
	# strings from reading as a flat sheet.
	var st := SurfaceTool.new()
	st.create_from(am, 0)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)
	return mi

# --- Lines and posts ----------------------------------------------------------
func _build_lines() -> void:
	var mat := _mat(LINE_COLOR, 0.6)
	# Four lines: two sidelines and two end lines. No centre line — that is an
	# indoor marking.
	for z in [-HALF_WIDTH, HALF_WIDTH]:
		_box(Vector3(HALF_LENGTH * 2.0, 0.006, LINE_W), Vector3(0.0, LINE_Y, z), mat)
	for x in [-HALF_LENGTH, HALF_LENGTH]:
		_box(Vector3(LINE_W, 0.006, HALF_WIDTH * 2.0), Vector3(x, LINE_Y, 0.0), mat)

func _build_posts() -> void:
	var mat := _mat(POST_COLOR, 0.7)
	for z in [-HALF_WIDTH - 0.30, HALF_WIDTH + 0.30]:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = POST_RADIUS
		cm.bottom_radius = POST_RADIUS
		cm.height = POST_HEIGHT
		cm.radial_segments = 8
		mi.mesh = cm
		mi.position = Vector3(0.0, POST_HEIGHT * 0.5, z)
		mi.material_override = mat
		add_child(mi)

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	add_child(mi)
	return mi
