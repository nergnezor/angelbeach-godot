// AngelBeach native sim.
//
// What lives here is the part of the port with no engine in it: ballistics,
// kinematics and the movement budget. Everything that touches a node, a
// skeleton, a scene tree or the RNG stays in GDScript on purpose.
//
// PRECISION IS PART OF THE CONTRACT. The GDScript build this replaces mixes two
// widths without meaning to: a Vector3 stores f32 components, but every scalar
// GDScript computes with is f64. Reading `pos.y` widens f32 -> f64, the maths
// runs in f64, and writing back into a Vector3 narrows f64 -> f32. That mixture
// is what the seeded 990-coordinate baseline was measured on, so this crate
// mirrors it deliberately: `f()` widens on the way in, `v3()` narrows on the way
// out, and nothing in between is ever f32. Running the whole thing in f64 would
// be more accurate and would silently invalidate the comparison.

use godot::prelude::*;
use std::sync::RwLock;

struct AngelBeachExtension;

#[gdextension]
unsafe impl ExtensionLibrary for AngelBeachExtension {}

// --- width discipline --------------------------------------------------------

/// Widen a Vector3 component the way GDScript does when you read it.
#[inline]
fn f(x: f32) -> f64 {
    x as f64
}

/// Narrow back into a Vector3 the way GDScript does when you store one.
#[inline]
fn v3(x: f64, y: f64, z: f64) -> Vector3 {
    Vector3::new(x as f32, y as f32, z as f32)
}

// --- tuning ------------------------------------------------------------------
//
// These are the output of five rounds of tuning and they will be touched again,
// so they are NOT compiled in as constants. The values below are only the
// defaults; `Tuning.apply()` replaces them at runtime from an inspector-authored
// TuningResource, and `Tuning.set_*` from a test or a debug key.

#[derive(Clone, Copy)]
struct Values {
    // MotionPlan: the measured rig/sim budget.
    first_step_lag: f64,
    hand_speed: f64,
    hand_travel: f64,
    margin: f64,
    settle_time: f64,
    brake: f64,
    // Contact: the net and the arc it has to clear.
    net_top_y: f64,
    net_clear_margin: f64,
}

impl Values {
    const DEFAULT: Values = Values {
        first_step_lag: 0.12,
        hand_speed: 2.5,
        hand_travel: 0.9,
        margin: 0.08,
        settle_time: 0.45,
        brake: 34.0,
        net_top_y: 2.43,
        net_clear_margin: 0.28,
    };
}

static TUNING: RwLock<Values> = RwLock::new(Values::DEFAULT);

#[inline]
fn tuning() -> Values {
    *TUNING.read().expect("tuning lock poisoned")
}

/// Inspector-authorable tuning, savable as a .tres next to the scenes.
#[derive(GodotClass)]
#[class(tool, init, base = Resource)]
pub struct TuningResource {
    #[export]
    #[init(val = 0.12)]
    first_step_lag: f64,
    #[export]
    #[init(val = 2.5)]
    hand_speed: f64,
    #[export]
    #[init(val = 0.9)]
    hand_travel: f64,
    #[export]
    #[init(val = 0.08)]
    margin: f64,
    #[export]
    #[init(val = 0.45)]
    settle_time: f64,
    /// MUST mirror the player's ground decel or budget and sim disagree.
    #[export]
    #[init(val = 34.0)]
    brake: f64,
    #[export]
    #[init(val = 2.43)]
    net_top_y: f64,
    #[export]
    #[init(val = 0.28)]
    net_clear_margin: f64,

    base: Base<Resource>,
}

/// Namespace for reading and replacing the live tuning from GDScript.
#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct Tuning;

#[godot_api]
impl Tuning {
    /// Push an inspector-authored resource into the live sim.
    #[func]
    fn apply(res: Gd<TuningResource>) {
        let r = res.bind();
        let mut w = TUNING.write().expect("tuning lock poisoned");
        *w = Values {
            first_step_lag: r.first_step_lag,
            hand_speed: r.hand_speed,
            hand_travel: r.hand_travel,
            margin: r.margin,
            settle_time: r.settle_time,
            brake: r.brake,
            net_top_y: r.net_top_y,
            net_clear_margin: r.net_clear_margin,
        };
    }

    /// Back to the shipped defaults.
    #[func]
    fn reset() {
        *TUNING.write().expect("tuning lock poisoned") = Values::DEFAULT;
    }

    // A tunable value cannot also be a GDScript `const` — a const is resolved at
    // parse time and would freeze whatever the .so shipped with. So every knob
    // is a getter/setter pair instead, and callers that used to read
    // MotionPlan.FIRST_STEP_LAG read Tuning.get_first_step_lag(). Written out
    // rather than generated: #[godot_api] reads this impl block's tokens before
    // any macro_rules expansion, so functions hidden behind a macro never get
    // registered.

    #[func]
    fn get_first_step_lag() -> f64 {
        tuning().first_step_lag
    }
    #[func]
    fn set_first_step_lag(v: f64) {
        TUNING.write().expect("tuning lock poisoned").first_step_lag = v;
    }

    #[func]
    fn get_hand_speed() -> f64 {
        tuning().hand_speed
    }
    #[func]
    fn set_hand_speed(v: f64) {
        TUNING.write().expect("tuning lock poisoned").hand_speed = v;
    }

    #[func]
    fn get_hand_travel() -> f64 {
        tuning().hand_travel
    }
    #[func]
    fn set_hand_travel(v: f64) {
        TUNING.write().expect("tuning lock poisoned").hand_travel = v;
    }

    #[func]
    fn get_margin() -> f64 {
        tuning().margin
    }
    #[func]
    fn set_margin(v: f64) {
        TUNING.write().expect("tuning lock poisoned").margin = v;
    }

    #[func]
    fn get_settle_time() -> f64 {
        tuning().settle_time
    }
    #[func]
    fn set_settle_time(v: f64) {
        TUNING.write().expect("tuning lock poisoned").settle_time = v;
    }

    #[func]
    fn get_brake() -> f64 {
        tuning().brake
    }
    #[func]
    fn set_brake(v: f64) {
        TUNING.write().expect("tuning lock poisoned").brake = v;
    }

    #[func]
    fn get_net_top_y() -> f64 {
        tuning().net_top_y
    }
    #[func]
    fn set_net_top_y(v: f64) {
        TUNING.write().expect("tuning lock poisoned").net_top_y = v;
    }

    #[func]
    fn get_net_clear_margin() -> f64 {
        tuning().net_clear_margin
    }
    #[func]
    fn set_net_clear_margin(v: f64) {
        TUNING.write().expect("tuning lock poisoned").net_clear_margin = v;
    }

    /// Everything at once, for a telemetry line or a test's assertion.
    #[func]
    fn snapshot() -> VarDictionary {
        let t = tuning();
        dict! {
            "first_step_lag" => t.first_step_lag,
            "hand_speed" => t.hand_speed,
            "hand_travel" => t.hand_travel,
            "margin" => t.margin,
            "settle_time" => t.settle_time,
            "brake" => t.brake,
            "net_top_y" => t.net_top_y,
            "net_clear_margin" => t.net_clear_margin,
        }
    }
}

// --- MotionPlan --------------------------------------------------------------
//
// The first-principles movement budget, ported from MotionPlan.gd, which was
// ported from AngelBeach/Script/AI/MotionPlan.as. Zero engine calls in the
// original, zero here.
//
// Every "how do I play this ball" decision is a race between three clocks:
//   BALL TIME  tau(y) — when the flight next descends through height y
//   BODY TIME        — first-step lag + acceleration-limited run to the spot
//   HAND TIME        — the IK effectors converging the last arm's length
// A contact is playable iff tau >= body + hand + margin.

const BALL_GRAVITY: f64 = -9.8;
/// Distances below this need no plan, 1 cm.
const MIN_TRAVEL: f64 = 0.01;

#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct MotionPlan;

#[godot_api]
impl MotionPlan {
    /// Time for the ball to next descend through height y, solved analytically.
    /// Returns [reached: bool, position: Vector3, time: float].
    #[func]
    fn ball_time_to_height(pos: Vector3, vel: Vector3, target_y: f64) -> VarArray {
        // y(t) = y0 + vy*t + 0.5*g*t^2  ->  solve for the LATER root (descending).
        let a = 0.5 * BALL_GRAVITY;
        let b = f(vel.y);
        let c = f(pos.y) - target_y;
        let disc = b * b - 4.0 * a * c;
        if disc < 0.0 {
            return varray![false, pos, 0.0];
        }
        let sq = disc.sqrt();
        // Two roots; we want the smallest strictly-positive one on the way DOWN.
        let t1 = (-b + sq) / (2.0 * a);
        let t2 = (-b - sq) / (2.0 * a);
        let mut t = -1.0f64;
        for cand in [t1.min(t2), t1.max(t2)] {
            if cand > 0.001 {
                t = cand;
                break;
            }
        }
        if t < 0.0 {
            return varray![false, pos, 0.0];
        }
        let hit = v3(f(pos.x) + f(vel.x) * t, target_y, f(pos.z) + f(vel.z) * t);
        varray![true, hit, t]
    }

    /// TRAPEZOID PROFILE: every approach both accelerates AND brakes to a stop —
    /// a contact demands a planted body, so a travel time that ignores braking
    /// lies exactly when it matters.
    #[func]
    fn body_travel_time(dist: f64, vmax: f64, accel: f64) -> f64 {
        let t = tuning();
        if dist <= MIN_TRAVEL {
            return 0.0;
        }
        let inv_sum = 1.0 / accel + 1.0 / t.brake;
        let ramp_dist = 0.5 * vmax * vmax * inv_sum;
        let travel = if dist <= ramp_dist {
            // Triangle: never reaches vmax. Peak from D = v^2/2*(1/a+1/b).
            let peak = (2.0 * dist / inv_sum).sqrt();
            peak * inv_sum
        } else {
            dist / vmax + 0.5 * vmax * inv_sum
        };
        t.first_step_lag + travel
    }

    /// The inverse: the exact cruise speed that covers dist in t_avail arriving
    /// stopped. Smaller root — the larger wastes speed and brakes longer.
    #[func]
    fn required_cruise_speed(dist: f64, t_avail: f64, vmax: f64, accel: f64) -> f64 {
        let t = tuning();
        if dist <= MIN_TRAVEL {
            return 0.0;
        }
        if t_avail <= 0.05 {
            return vmax;
        }
        let inv_sum = 1.0 / accel + 1.0 / t.brake;
        let disc = t_avail * t_avail - 2.0 * inv_sum * dist;
        if disc <= 0.0 {
            return vmax;
        }
        ((t_avail - disc.sqrt()) / inv_sum).clamp(0.0, vmax)
    }

    /// Hand time: the effectors cannot track from a sprinting body, so most of
    /// this must come after the body has largely arrived.
    #[func]
    fn hand_time() -> f64 {
        let t = tuning();
        t.hand_travel / t.hand_speed
    }

    /// Is this contact playable, and how fast must the body run to make it?
    #[func]
    fn plan(dist: f64, tau: f64, vmax: f64, accel: f64) -> VarDictionary {
        let tn = tuning();
        let body_t = Self::body_travel_time(dist, vmax, accel);
        let hand_t = Self::hand_time();
        let slack = tau - (body_t + hand_t + tn.margin);
        if slack < 0.0 {
            return dict! {
                "playable" => false,
                "speed_fraction" => 1.0,
                "body_time" => body_t,
                "hand_time" => hand_t,
                "slack" => slack,
            };
        }
        // Run exactly as fast as the budget demands, planted SETTLE_TIME before
        // contact — efficiency means no WASTED speed, not zero cushion.
        let avail = (tau - tn.settle_time - tn.first_step_lag).max(0.05);
        let need = Self::required_cruise_speed(dist, avail, vmax, accel);
        let frac = ((need / vmax) * 1.15).clamp(0.35, 1.0);
        dict! {
            "playable" => true,
            "speed_fraction" => frac,
            "body_time" => body_t,
            "hand_time" => hand_t,
            "slack" => slack,
        }
    }
}

// --- BallSim -----------------------------------------------------------------
//
// The ball's integrator, split the way the port scope calls for: the pure step
// function lives here, the Node3D that owns `position` stays in GDScript facing
// the engine. Substepped for the same reason the Angelscript original is — a
// hitchy frame integrated in one step tunnels the ball through the floor and
// through contact windows.
//
// The two lines inside the loop DO NOT have the same precision, and that is not
// an oversight. In GDScript `vel.y += GRAVITY * h` reads a component (f32 ->
// f64), does the arithmetic in f64 and narrows on store, while `position +=
// vel * h` goes through Vector3::operator*(real), which narrows `h` to f32
// first and runs the whole line in f32. Mirroring only one of them drifts the
// bounce, which is exactly the trap this port was warned about.

const RESTITUTION: f64 = 0.62;
/// Cap each physics step at 20 ms, as in Ball.as.
const MAX_SUBSTEP: f64 = 0.02;
const BALL_REST_SPEED: f64 = 0.4;
const GROUND_FRICTION: f64 = 0.8;

#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct BallSim;

#[godot_api]
impl BallSim {
    /// One frame of substepped flight. Returns [position, velocity, in_play].
    #[func]
    fn step(pos: Vector3, vel: Vector3, dt: f64, floor_y: f64) -> VarArray {
        let mut pos = pos;
        let mut vel = vel;
        let mut in_play = true;
        let mut remaining = dt;
        while remaining > 0.0 {
            let h = remaining.min(MAX_SUBSTEP);
            remaining -= h;
            vel.y = (f(vel.y) + BALL_GRAVITY * h) as f32;
            pos += vel * (h as f32);
            if f(pos.y) <= floor_y + BALL_RADIUS {
                pos.y = (floor_y + BALL_RADIUS) as f32;
                if f(vel.y).abs() < BALL_REST_SPEED {
                    vel = Vector3::ZERO;
                    // The original keeps substepping after the ball settles; with
                    // a zero velocity it is a no-op, and matching it costs nothing.
                    in_play = false;
                } else {
                    vel.y = (-f(vel.y) * RESTITUTION) as f32;
                    vel.x = (f(vel.x) * GROUND_FRICTION) as f32;
                    vel.z = (f(vel.z) * GROUND_FRICTION) as f32;
                }
            }
        }
        varray![pos, vel, in_play]
    }
}

// --- Contact -----------------------------------------------------------------
//
// The single most load-bearing idea in the original: a controlled volleyball
// contact is BALLISTIC PLACEMENT, not reflection. Pros do not bounce the ball
// off their arms, they place it — the dig pops to the setter zone, the set
// floats to the attack spot, each with a deliberate arc.
//
// Godot space: metres, Y up, net plane at x = 0.

const G: f64 = 9.8;
const BALL_RADIUS: f64 = 0.105;
/// No placement is flatter than this.
const MIN_APEX: f64 = 0.4;
const MIN_FLIGHT: f64 = 0.15;

#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct Contact;

#[godot_api]
impl Contact {
    /// Launch velocity carrying the ball from `from` to `to` on a parabola
    /// peaking `apex` metres above the higher endpoint.
    #[func]
    fn ballistic_velocity(from: Vector3, to: Vector3, apex: f64) -> Vector3 {
        let peak_y = f(from.y).max(f(to.y)) + apex.max(MIN_APEX);
        let vy = (2.0 * G * (peak_y - f(from.y))).sqrt();
        let t_up = vy / G;
        let t_down = (2.0 * (peak_y - f(to.y)).max(0.01) / G).sqrt();
        let t_total = (t_up + t_down).max(MIN_FLIGHT);
        v3(
            (f(to.x) - f(from.x)) / t_total,
            vy,
            (f(to.z) - f(from.z)) / t_total,
        )
    }

    // Net-plane flight tests. These GUARANTEE the three-touch protocol
    // physically rather than trusting the AI's intent: touches 1-2 must stay on
    // our side, touch 3 must clear the tape.
    #[func]
    fn crosses_net_plane(p: Vector3, v: Vector3) -> bool {
        if f(v.x).abs() < 0.01 {
            return false;
        }
        let t_cross = -f(p.x) / f(v.x);
        if t_cross <= 0.0 {
            return false;
        }
        Self::height_at_net_plane(p, v) > 0.0
    }

    #[func]
    fn height_at_net_plane(p: Vector3, v: Vector3) -> f64 {
        let t_cross = -f(p.x) / f(v.x);
        f(p.y) + f(v.y) * t_cross - 0.5 * G * t_cross * t_cross
    }

    #[func]
    fn net_clear_y() -> f64 {
        let t = tuning();
        t.net_top_y + BALL_RADIUS + t.net_clear_margin
    }

    /// Choose the arc for a placement so it satisfies the protocol: iterate the
    /// apex until the flight either stays on our side (touches 1-2) or clears
    /// the tape (touch 3). A fixed apex either dumped the ball into the net or
    /// sailed it out, depending on where the contact happened.
    ///
    /// `v` round-trips through a Vector3 on every iteration exactly as the
    /// GDScript version does — keeping it in f64 between iterations changes the
    /// result, because the f32 store is part of the measured behaviour.
    #[func]
    fn placement_velocity(from: Vector3, to: Vector3, must_cross: bool) -> Vector3 {
        let mut apex = 1.2f64;
        let mut v = Self::ballistic_velocity(from, to, apex);
        for _ in 0..12 {
            let crosses = Self::crosses_net_plane(from, v);
            if must_cross {
                // Needs to clear the tape with margin.
                if crosses && Self::height_at_net_plane(from, v) >= Self::net_clear_y() {
                    return v;
                }
                apex += 0.6;
            } else {
                // Must NOT cross — a first or second touch that flies over is a gift.
                if !crosses {
                    return v;
                }
                apex -= 0.25;
                if apex < MIN_APEX {
                    return v;
                }
            }
            v = Self::ballistic_velocity(from, to, apex);
        }
        v
    }
}
