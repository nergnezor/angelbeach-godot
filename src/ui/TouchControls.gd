# On-screen stick + jump for Android and for web on a phone.
#
# Keyboard/gamepad keep working: this layer only ADDS a stick vector and a
# jump flag. Match reads them next to Input.get_vector / ui_accept, so a
# desktop session that never touches the screen never sees any of it.
#
# WHY THIS IS DRAWN IN SCRIPT. The Unreal original split movement and buttons
# because Angelscript could not read the raw touch stream — movement was the
# engine joystick overlay, actions were HUD hit boxes (see reference/Script/
# Match/HUD.as). Godot can read InputEventScreenTouch/Drag, so both live here,
# drawn with _draw (no textures) the same way that HUD was. The Godot port
# also collapsed Pass/Set/Spike into the AI stroke picker, so the only action
# that still needs a finger is JUMP — the same button that takes over the
# nearest player on the keyboard.
#
# Multi-touch is load-bearing: a thumb on the stick and a thumb on JUMP have
# to work at once. Mouse emulation would collapse them to one pointer, so
# this listens only to ScreenTouch/ScreenDrag (and to a real mouse only when
# the engine is NOT synthesizing mouse from touch).
extends CanvasLayer
class_name TouchControls

var stick := Vector2.ZERO
var jump_held := false
var jump_just := false

var shown := false

var _stick_index := -1
var _jump_index := -1
var _origin := Vector2.ZERO
var _knob := Vector2.ZERO
var _overlay: Control

func _ready() -> void:
	layer = 20
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	get_viewport().size_changed.connect(_on_resized)
	shown = _is_phone()
	set_process_input(true)


func consume_jump() -> bool:
	var v := jump_just
	jump_just = false
	return v


func _is_phone() -> bool:
	return OS.has_feature("android") or OS.has_feature("ios") \
		or OS.has_feature("mobile") or OS.has_feature("web_android") \
		or OS.has_feature("web_ios")


func _on_resized() -> void:
	if _overlay:
		_overlay.queue_redraw()


func _process(_dt: float) -> void:
	if shown and _overlay:
		_overlay.queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch(event)
	elif event is InputEventScreenDrag:
		_drag(event)
	elif not shown:
		return
	elif event is InputEventMouseButton or event is InputEventMouseMotion:
		# Only a stand-in when the overlay is already up (a phone). A desktop
		# mouse click must not reveal the stick — that would put a joystick on
		# a keyboard session from the first click.
		if Input.emulate_mouse_from_touch:
			return
		_mouse(event)


func _touch(ev: InputEventScreenTouch) -> void:
	if not shown:
		shown = true
		_overlay.queue_redraw()
	var i: int = ev.index
	if ev.pressed:
		if _in_jump(ev.position) and _jump_index < 0:
			_jump_index = i
			jump_held = true
			jump_just = true
			get_viewport().set_input_as_handled()
		elif _on_move_side(ev.position) and _stick_index < 0:
			_stick_index = i
			_origin = ev.position
			_knob = ev.position
			_update_stick()
			get_viewport().set_input_as_handled()
	else:
		if i == _stick_index:
			_stick_index = -1
			stick = Vector2.ZERO
			_knob = _origin
			get_viewport().set_input_as_handled()
		if i == _jump_index:
			_jump_index = -1
			jump_held = false
			get_viewport().set_input_as_handled()


func _drag(ev: InputEventScreenDrag) -> void:
	if ev.index != _stick_index:
		return
	_knob = ev.position
	_update_stick()
	get_viewport().set_input_as_handled()


func _mouse(event: InputEvent) -> void:
	# Desktop stand-in so the overlay can be tried with a mouse when it is
	# already shown (a phone, or a first tap that revealed it). Finger index
	# 0 is borrowed; a real touch session never reaches here because the
	# emulate_mouse_from_touch gate above returns first.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var fake := InputEventScreenTouch.new()
		fake.index = 0
		fake.pressed = event.pressed
		fake.position = event.position
		_touch(fake)
	elif event is InputEventMouseMotion and _stick_index == 0 and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var fake := InputEventScreenDrag.new()
		fake.index = 0
		fake.position = event.position
		_drag(fake)


func _update_stick() -> void:
	var delta := _knob - _origin
	var max_r := _stick_r()
	if delta.length() > max_r:
		delta = delta.normalized() * max_r
		_knob = _origin + delta
	var v := delta / max_r
	if v.length() < 0.12:
		stick = Vector2.ZERO
	else:
		stick = v.limit_length(1.0)


func _view() -> Rect2:
	return get_viewport().get_visible_rect()


func _safe() -> Rect2:
	var v := _view()
	var s := DisplayServer.get_display_safe_area()
	if s.size.x < 8.0 or s.size.y < 8.0:
		return v
	# Safe area is in screen pixels; the viewport rect is in viewport pixels.
	# On a 1:1 window they match. On a scaled Android surface they may not,
	# so intersect rather than replace — a wrong safe rect that clips the
	# stick off-screen is worse than drawing over a notch.
	var hit := v.intersection(s)
	return hit if hit.size.x > 8.0 and hit.size.y > 8.0 else v


func _scale() -> float:
	var v := _view().size
	return clampf(minf(v.x, v.y) / 720.0, 0.65, 1.6)


func _stick_r() -> float:
	return 78.0 * _scale()


func _jump_r() -> float:
	return 56.0 * _scale()


func _margin() -> float:
	return 36.0 * _scale()


func _idle_stick() -> Vector2:
	var r := _safe()
	var m := _margin()
	var rad := _stick_r()
	return Vector2(r.position.x + m + rad, r.position.y + r.size.y - m - rad)


func _jump_center() -> Vector2:
	var r := _safe()
	var m := _margin()
	var rad := _jump_r()
	return Vector2(r.position.x + r.size.x - m - rad, r.position.y + r.size.y - m - rad)


func _on_move_side(p: Vector2) -> bool:
	if _in_jump(p):
		return false
	return p.x < _view().position.x + _view().size.x * 0.55


func _in_jump(p: Vector2) -> bool:
	return p.distance_to(_jump_center()) <= _jump_r() * 1.25


func _draw_overlay() -> void:
	if not shown:
		return
	var base := _origin if _stick_index >= 0 else _idle_stick()
	var knob := _knob if _stick_index >= 0 else base
	_circle(base, _stick_r(), Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.45), 3.0)
	_circle(knob, _stick_r() * 0.42, Color(1, 1, 1, 0.28), Color(1, 1, 1, 0.85), 2.0)
	var jc := _jump_center()
	var fill := Color(1, 1, 1, 0.22) if jump_held else Color(1, 1, 1, 0.14)
	var ring := Color(1, 0.92, 0.55, 0.95) if jump_held else Color(1, 0.92, 0.55, 0.7)
	_circle(jc, _jump_r(), fill, ring, 3.0)
	var font := ThemeDB.fallback_font
	var fs := int(18.0 * _scale())
	var text := "JUMP"
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	_overlay.draw_string(font, jc - tw * 0.5 + Vector2(0, fs * 0.35),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.9))


func _circle(c: Vector2, r: float, fill: Color, stroke: Color, width: float) -> void:
	_overlay.draw_circle(c, r, fill)
	_overlay.draw_arc(c, r, 0.0, TAU, 48, stroke, width, true)
