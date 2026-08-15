# Ball — custom Euler physics, ported from AngelBeach/Script/World/Ball.as.
# Substepped for the same reason the original is: a hitchy frame integrated in
# one step tunnels the ball through the floor and through contact windows.
#
# Godot space: metres, Y up. The Angelscript source is centimetres and Z-up.
extends Node3D
class_name Ball

const GRAVITY := -9.8            # -980 cm/s^2
const RESTITUTION := 0.62
const MAX_SUBSTEP := 0.02        # cap each physics step at 20ms, as in Ball.as
const RADIUS := 0.105
const REST_SPEED := 0.4          # below this the bounce is over, 40 cm/s
const GROUND_FRICTION := 0.8

var vel := Vector3.ZERO
var in_play := false
var floor_y := 0.0

# Visual only — the sim never reads this. Called by Match when there is a
# screen to draw on; a headless run skips it and stays a bare Node3D.
func setup_view() -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = RADIUS
	sm.height = RADIUS * 2.0
	sm.radial_segments = 24
	sm.rings = 12
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.98, 0.86, 0.30)
	m.roughness = 0.55
	mi.material_override = m
	add_child(mi)

func launch(from: Vector3, v: Vector3) -> void:
	position = from
	vel = v
	in_play = true

# The integrator itself lives in Rust (BallSim). What stays here is the half
# that has to face the engine: the node that owns a position, and the in_play
# flag the rally protocol reads. Everything BallSim needs, it is handed.
func step(dt: float) -> void:
	if not in_play:
		return
	var r := BallSim.step(position, vel, dt, floor_y)
	position = r[0]
	vel = r[1]
	in_play = r[2]

# The velocity that carries the ball from `from` to `target` in exactly
# `flight_time`. This is the solve keyed on TIME; Contact.ballistic_velocity is
# the one keyed on APEX, which is what every controlled contact uses. Two
# different questions, so they are deliberately two names.
static func velocity_for_flight_time(from: Vector3, target: Vector3, flight_time: float) -> Vector3:
	var d := target - from
	return Vector3(d.x / flight_time,
		(d.y - 0.5 * GRAVITY * flight_time * flight_time) / flight_time,
		d.z / flight_time)
