# Sky, sun and haze — the port of Script/World/Environment.as plus the lighting
# half of ABeachVolleyballGameMode::SetupWorld.
#
# TWO THINGS ABOUT THE ORIGINAL THAT DO NOT SURVIVE A LITERAL PORT.
#
# 1. THE SKY WAS A MESH, AND IT WAS LIT. Angelscript built a 40-band dome out of
#    procedural geometry because Android has SkyAtmosphere disabled and no fog
#    setting can paint an empty background — height fog only tints RENDERED
#    GEOMETRY, so the black band above the horizon was never reachable that way.
#    Godot's sky shader runs on every target, so the dome's whole reason to exist
#    is gone. What is kept is the part that carries the look: the elevation
#    mapping and the two-segment colour curve, below, are the original's
#    SkyBandColor exactly. The staircase is not kept — the original called 40
#    bands "a deliberate ceiling" and noted the steps were visible as stripes at
#    18, so a smooth gradient is the thing it was approximating, not a departure.
#
# 2. THE COLOURS IN THE ORIGINAL ARE ALBEDOS, NOT COLOURS. The dome was a lit
#    surface under a deeply warm light, so its authored albedo was pre-divided by
#    the measured per-channel gain (0.314, 0.162, 0.067) — that is why the source
#    has a blue of 1.34, which is not a mistake but "what it costs to land a dusk
#    blue through a warm light". A Godot sky shader is UNLIT: nothing multiplies
#    it. Feeding it the albedos would land the absurd values literally and the
#    zenith would come out a violent blue. So the gain is applied here instead,
#    which reproduces the image the original actually rendered.
#
#    One inconsistency, surfaced rather than smoothed over: the source's own note
#    says the sea should land on linear (0.010, 0.023, 0.096), but its albedo
#    times its own gain is (0.009, 0.023, 0.057). Red and green agree, blue does
#    not. The zenith line checks out exactly, so the gain is right and the sea
#    note is stale. The gain is applied uniformly here.
#
# One more thing the original flags about itself, worth repeating because it is
# not a porting artefact: GameMode.as moved the sun from a low sunset (pitch -6)
# to straight overhead, and says in as many words that the sky colours "were
# tuned against the old sun angle and have not been re-measured against this
# one". The dusk gradient below is therefore authored for a sun that is no longer
# in the scene. It is ported as written; SUN_PITCH_DEG is one number if that mood
# needs to come back.
extends Node3D
class_name CourtEnvironment

# --- The dome's shape, as angles ---------------------------------------------
# The original ran the dome from -30 degrees to +90, because the bands below the
# horizon ARE the sea — there is no water plane, and at grazing angles a distant
# wall and a flat plane are indistinguishable. T below is the position across
# that full sweep, so elevation 0 is T = 0.25.
const SKY_BOTTOM_DEG := -30.0
const SKY_TOP_DEG := 90.0

# The measured warm-light gain the albedos were divided by. See note 2 above.
const LIGHT_GAIN := Vector3(0.314, 0.162, 0.067)

# The authored albedos, kept in the source's own numbers so they can be diffed
# against Environment.as line for line. They are turned into colours by _seen().
const SEA_ALBEDO := Vector3(0.03, 0.14, 0.85)
const HORIZON_ALBEDO := Vector3(0.95, 0.58, 0.34)
const ZENITH_ALBEDO := Vector3(0.05, 0.22, 1.34)

# The two-segment curve, verbatim from SkyBandColor. Sea climbs into the warm
# waterline band over T 0.15..0.25 (that is -12 degrees up to the horizon), then
# horizon climbs to zenith over T 0.25..0.458 (the horizon up to +25 degrees).
# The upper number is not a guess: the source records that completing at 42
# degrees put the interesting colour off-screen, because in the letterboxed view
# the top of frame is only about 20 degrees up.
const T_HORIZON := 0.25
const T_SEA_RAMP := 0.10
const T_ZENITH_RAMP := 0.208

# --- The look, as knobs -------------------------------------------------------
# Exposed rather than frozen: these are the values a scene gets retuned by, and
# the original's own history is one long argument for keeping them reachable.
@export var sun_pitch_deg := -90.0     # -90 is straight down: noon, no backlight
@export var sun_energy := 1.6
@export var sun_color := Color(1.0, 0.98, 0.92)   # neutral noon sun, not sunset
@export var ambient_energy := 1.2
# The exposure cut, and it is load-bearing rather than taste. The original ran
# -1.5 EV because the sun-lit sand was clipping, and it is the reason Court.as
# lifts the post albedo separately: the posts sat at half light and take the cut
# at face value, where the sand only loses its blow-out. Verified the same way
# here — with this at 0 the sand renders a flat near-white sheet and the court
# lines vanish into it, which is the "snowfield" build Court.as describes.
@export var exposure_ev := -1.5
@export var fog_enabled := true

# Fog: thin far-field haze only. The original is emphatic that this is NOT a
# coloured band over the court — dense volumetric fog read as smoke, not sunset —
# and that it must start beyond the sky so it cannot bleach the gradient. 5200 cm
# is 52 m, past a 50 m dome; here it is simply past everything the camera frames.
const FOG_BEGIN_M := 52.0
const FOG_END_M := 260.0
const FOG_COLOR := Color(0.55, 0.68, 0.85)   # neutral midday blue, per the sun

func _ready() -> void:
	_build_sun()
	_build_sky()

# Converts an authored albedo into the colour that albedo actually rendered as.
static func _seen(albedo: Vector3) -> Color:
	return Color(albedo.x * LIGHT_GAIN.x,
		albedo.y * LIGHT_GAIN.y,
		albedo.z * LIGHT_GAIN.z)

# SkyBandColor, unchanged apart from running on a continuous T instead of a band
# midpoint. Smoothstep is the source's own k*k*(3-2k).
static func band_color(t: float) -> Color:
	if t <= T_HORIZON:
		var k := clampf((t - (T_HORIZON - T_SEA_RAMP)) / T_SEA_RAMP, 0.0, 1.0)
		k = k * k * (3.0 - 2.0 * k)
		return _seen(SEA_ALBEDO).lerp(_seen(HORIZON_ALBEDO), k)
	var k2 := clampf((t - T_HORIZON) / T_ZENITH_RAMP, 0.0, 1.0)
	k2 = k2 * k2 * (3.0 - 2.0 * k2)
	return _seen(HORIZON_ALBEDO).lerp(_seen(ZENITH_ALBEDO), k2)

func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	# Yaw is irrelevant at the zenith, which is the point: the original chose
	# overhead so the sun lights the TOPS of the players on every platform rather
	# than backlighting them into silhouettes.
	sun.rotation_degrees = Vector3(sun_pitch_deg, 0.0, 0.0)
	sun.light_energy = sun_energy
	sun.light_color = sun_color
	sun.shadow_enabled = true
	add_child(sun)

func _build_sky() -> void:
	var shader := Shader.new()
	# The gradient is evaluated per-pixel from the view ray's elevation, which is
	# the same quantity the dome's bands indexed — EYEDIR.y is sin(elevation), so
	# asin recovers the angle the original worked in.
	shader.code = """
shader_type sky;

uniform vec3 sea_color;
uniform vec3 horizon_color;
uniform vec3 zenith_color;
uniform float bottom_deg;
uniform float top_deg;
uniform float t_horizon;
uniform float t_sea_ramp;
uniform float t_zenith_ramp;

void sky() {
	float elev_deg = degrees(asin(clamp(EYEDIR.y, -1.0, 1.0)));
	float t = (elev_deg - bottom_deg) / (top_deg - bottom_deg);
	vec3 col;
	if (t <= t_horizon) {
		float k = clamp((t - (t_horizon - t_sea_ramp)) / t_sea_ramp, 0.0, 1.0);
		k = k * k * (3.0 - 2.0 * k);
		col = mix(sea_color, horizon_color, k);
	} else {
		float k = clamp((t - t_horizon) / t_zenith_ramp, 0.0, 1.0);
		k = k * k * (3.0 - 2.0 * k);
		col = mix(horizon_color, zenith_color, k);
	}
	COLOR = col;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var sea := _seen(SEA_ALBEDO)
	var horizon := _seen(HORIZON_ALBEDO)
	var zenith := _seen(ZENITH_ALBEDO)
	mat.set_shader_parameter("sea_color", Vector3(sea.r, sea.g, sea.b))
	mat.set_shader_parameter("horizon_color", Vector3(horizon.r, horizon.g, horizon.b))
	mat.set_shader_parameter("zenith_color", Vector3(zenith.r, zenith.g, zenith.b))
	mat.set_shader_parameter("bottom_deg", SKY_BOTTOM_DEG)
	mat.set_shader_parameter("top_deg", SKY_TOP_DEG)
	mat.set_shader_parameter("t_horizon", T_HORIZON)
	mat.set_shader_parameter("t_sea_ramp", T_SEA_RAMP)
	mat.set_shader_parameter("t_zenith_ramp", T_ZENITH_RAMP)

	var sky := Sky.new()
	sky.sky_material = mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# The sky is the ambient source, which is the SkyLight's job in the original:
	# soft fill so the court is not black and the players do not crush in their
	# own shadow.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = pow(2.0, exposure_ev)

	if fog_enabled:
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_depth_begin = FOG_BEGIN_M
		env.fog_depth_end = FOG_END_M
		env.fog_light_color = FOG_COLOR
		# Zero, and this is the whole lesson from the original's fog history: fog
		# that reaches the sky saturates it to the inscattering colour, which is
		# what hid the sea for so long.
		env.fog_sky_affect = 0.0

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
