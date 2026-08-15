# Ball — custom Euler physics, ported from AngelBeach/Script/World/Ball.as.
# Substepped for the same reason the original is: a hitchy frame integrated in
# one step tunnels the ball through the floor and through contact windows.
extends Node3D
class_name Ball

const GRAVITY := -980.0
const RESTITUTION := 0.62
const MAX_SUBSTEP := 0.02        # cap each physics step at 20ms, as in Ball.as
const RADIUS := 10.5

var vel := Vector3.ZERO
var in_play := false
var floor_z := 0.0

func launch(from: Vector3, v: Vector3) -> void:
	position = from
	vel = v
	in_play = true

func step(dt: float) -> void:
	if not in_play:
		return
	var remaining := dt
	while remaining > 0.0:
		var h: float = minf(remaining, MAX_SUBSTEP)
		remaining -= h
		vel.z += GRAVITY * h
		position += vel * h
		if position.z <= floor_z + RADIUS:
			position.z = floor_z + RADIUS
			if absf(vel.z) < 40.0:
				vel = Vector3.ZERO
				in_play = false
			else:
				vel.z = -vel.z * RESTITUTION
				vel.x *= 0.8
				vel.y *= 0.8

# Ballistic solve: the velocity that sends the ball from here to `target`
# arriving at the given flight time. Used by every controlled contact in the
# original — dig and set are ballistic PLACEMENT, not reflection.
static func ballistic_velocity(from: Vector3, target: Vector3, flight_time: float) -> Vector3:
	var d := target - from
	var v := Vector3(d.x / flight_time, d.y / flight_time, 0.0)
	v.z = (d.z - 0.5 * GRAVITY * flight_time * flight_time) / flight_time
	return v
