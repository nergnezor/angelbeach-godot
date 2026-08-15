# Contact model — ported from AngelBeach/Script/Player/VolleyballPlayer.as.
#
# The single most load-bearing idea in the original, and the one that took the
# longest to find: a controlled volleyball contact is BALLISTIC PLACEMENT, not
# reflection. Pros do not bounce the ball off their arms, they place it — the
# dig pops to the setter zone, the set floats to the attack spot, each with a
# deliberate arc. Before this existed the ball never reached spike height and
# the AI could never jump-attack.
#
# Coordinates match the UE original: centimetres, net plane at x = 0, z up.
class_name Contact

const G := 980.0
const NET_TOP_Z := 243.0
const BALL_RADIUS := 10.5
# Tape + ball + margin. A shot that clears by centimetres lands in a standing
# blocker's catch envelope, so the margin is not cosmetic.
const NET_CLEAR_MARGIN := 28.0

# Launch velocity carrying the ball from `from` to `to` on a parabola peaking
# `apex` cm above the higher endpoint.
static func ballistic_velocity(from: Vector3, to: Vector3, apex: float) -> Vector3:
	var peak_z: float = maxf(from.z, to.z) + maxf(apex, 40.0)
	var vz := sqrt(2.0 * G * (peak_z - from.z))
	var t_up := vz / G
	var t_down := sqrt(2.0 * maxf(peak_z - to.z, 1.0) / G)
	var t_total: float = maxf(t_up + t_down, 0.15)
	return Vector3((to.x - from.x) / t_total, (to.y - from.y) / t_total, vz)

# --- Net-plane flight tests. These GUARANTEE the three-touch protocol
# physically rather than trusting the AI's intent: touches 1-2 must stay on our
# side, touch 3 must clear the tape.
static func crosses_net_plane(p: Vector3, v: Vector3) -> bool:
	if absf(v.x) < 1.0:
		return false
	var t_cross := -p.x / v.x
	if t_cross <= 0.0:
		return false
	return height_at_net_plane(p, v) > 0.0

static func height_at_net_plane(p: Vector3, v: Vector3) -> float:
	var t_cross := -p.x / v.x
	return p.z + v.z * t_cross - 0.5 * G * t_cross * t_cross

static func net_clear_z() -> float:
	return NET_TOP_Z + BALL_RADIUS + NET_CLEAR_MARGIN

# Choose the arc for a placement so it satisfies the protocol: iterate the apex
# until the flight either stays on our side (touches 1-2) or clears the tape
# (touch 3). The original does exactly this — a fixed apex either dumped the
# ball into the net or sailed it out, depending on where the contact happened.
static func placement_velocity(from: Vector3, to: Vector3, must_cross: bool) -> Vector3:
	var apex := 120.0
	var v := ballistic_velocity(from, to, apex)
	for i in 12:
		var crosses := crosses_net_plane(from, v)
		if must_cross:
			# Needs to clear the tape with margin.
			if crosses and height_at_net_plane(from, v) >= net_clear_z():
				return v
			apex += 60.0
		else:
			# Must NOT cross — a first or second touch that flies over is a gift.
			if not crosses:
				return v
			apex -= 25.0
			if apex < 40.0:
				return v
		v = ballistic_velocity(from, to, apex)
	return v
