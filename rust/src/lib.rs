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
        // HALF the effector travel, and the source is explicit about why: only
        // "the second half of the effector travel happens after the body has
        // settled" -- the first half overlaps the run. Charging the full hand
        // time made this budget stricter than PlanIntercept's, so contacts read
        // as unplayable that the original would have committed to.
        let hand_t = Self::hand_time() * 0.5;
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

// --- GestureSolver -----------------------------------------------------------
//
// The strokes, ported from AngelBeach/Script/Player/PlayerIK.as. Given where the
// body currently is, this returns where the two hands and the two elbow hints
// want to be, in world space, for whichever stroke is being played.
//
// Unlike the rest of this crate there is no baseline to match here — the poses
// are visual only and never feed the rules — so it uses plain Vector3 maths
// instead of the f32/f64 mirroring the sim code has to observe.
//
// Every offset in the original is in centimetres against a ~180 cm actor. This
// rig is 1.45 m, so they are expressed here as metres scaled by `s`, the ratio
// of the rig's MEASURED arm reach to the original's 1.10 m. Hard-coding 0.35 m
// "forward from the chest" onto a shorter rig puts the platform through its own
// stomach.
const ORIGINAL_ARM_REACH: f32 = 1.10;

// Real limb motion is never constant-speed. Three profiles cover every segment,
// chosen by what the segment physically IS.
//
// MinJerk: a self-contained reach (cock, toss, platform set-up) — the
// minimum-jerk law (Flash & Hogan), bell velocity, slow-fast-slow.
fn min_jerk(t: f32) -> f32 {
    let c = t.clamp(0.0, 1.0);
    c * c * c * (10.0 + c * (6.0 * c - 15.0))
}

/// EaseIn: a segment ENDING at contact — the hand passes through the ball at
/// PEAK speed. A whip never decelerates into the ball.
fn ease_in(t: f32) -> f32 {
    let c = t.clamp(0.0, 1.0);
    c * c
}

/// EaseOut: follow-through — starts at strike speed and bleeds off.
fn ease_out(t: f32) -> f32 {
    let c = t.clamp(0.0, 1.0);
    1.0 - (1.0 - c) * (1.0 - c)
}

/// Hands sweep ARCS around the shoulder, not chords between waypoints: nlerp the
/// direction from the pivot and lerp the radius. A straight-line hand path is
/// the giveaway of keyframe interpolation; the arc is what a hinged arm does.
fn arc_around(pivot: Vector3, a: Vector3, b: Vector3, t: f32) -> Vector3 {
    let da = a - pivot;
    let db = b - pivot;
    let ra = da.length();
    let rb = db.length();
    if ra < 0.01 || rb < 0.01 {
        return a + (b - a) * t;
    }
    let dir = nrm(da / ra + (db / rb - da / ra) * t);
    pivot + dir * (ra + (rb - ra) * t)
}

/// Godot's normalized() yields zero for a zero vector, which silently produces a
/// hand target at the pivot. Every direction here goes through this instead.
fn nrm(v: Vector3) -> Vector3 {
    if v.length_squared() < 1e-8 {
        Vector3::ZERO
    } else {
        v.normalized()
    }
}

/// Clamp `to - from` onto a sphere of `reach` around `from`.
fn within_reach(from: Vector3, to: Vector3, reach: f32) -> Vector3 {
    let d = to - from;
    if d.length() > reach {
        from + nrm(d) * reach
    } else {
        to
    }
}

pub const HIT_NONE: i64 = 0;
pub const HIT_BUMP: i64 = 1;
pub const HIT_SET: i64 = 2;
pub const HIT_SPIKE: i64 = 3;
pub const HIT_BLOCK: i64 = 4;
pub const HIT_SERVE: i64 = 5;

#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct GestureSolver;

#[godot_api]
impl GestureSolver {
    /// Returns { hand_r, hand_l, pole_r, pole_l, crouch } in world space.
    ///
    /// Takes a dictionary because the pose genuinely depends on fifteen things,
    /// and a fifteen-argument call is unreadable from both sides.
    #[func]
    fn solve(a: VarDictionary) -> VarDictionary {
        let hit = geti(&a, "hit");
        let blend = getf(&a, "blend") as f32;
        let swing = getf(&a, "swing") as f32;
        let serve_phase = getf(&a, "serve_phase") as f32;
        let sh_r = getv(&a, "sh_r");
        let sh_l = getv(&a, "sh_l");
        let head = getv(&a, "head");
        let fwd = nrm(getv(&a, "fwd"));
        let right = nrm(getv(&a, "right"));
        let ball = getv(&a, "ball");
        let ball_in_play = getb(&a, "ball_in_play");
        let meet = getv(&a, "meet");
        let has_meet = getb(&a, "has_meet");
        let aim_at = getv(&a, "aim");
        let has_aim = getb(&a, "has_aim");
        let reach = getf(&a, "arm_reach") as f32;
        let feet_y = getf(&a, "feet_y") as f32;
        let extra_crouch = getf(&a, "extra_crouch") as f32;

        let s = reach / ORIGINAL_ARM_REACH;
        let up = Vector3::UP;
        let chest = (sh_r + sh_l) * 0.5;

        // Where the player is sending the ball; falls back to "up and forward".
        let aim = if has_aim {
            nrm(aim_at - head)
        } else {
            nrm(fwd * 0.4 + up)
        };
        let mut aim_flat = nrm(Vector3::new(aim.x, 0.0, aim.z));
        if aim_flat.length_squared() < 0.01 {
            aim_flat = fwd;
        }

        // The hands reach straight at the ball, clamped to arm's length from the
        // chest so the IK stays solvable.
        let mut ball_contact = chest + fwd * 0.35 * s + up * 0.05 * s;
        if ball_in_play {
            ball_contact = within_reach(chest, ball, reach);
        }

        // Relaxed ready pose: hands hang slightly forward at the sides.
        let ready_r = sh_r + fwd * 0.18 * s - up * 0.35 * s;
        let ready_l = sh_l + fwd * 0.18 * s - up * 0.35 * s;

        let contact_r;
        let contact_l;
        let pole_r;
        let pole_l;
        let mut crouch = 0.0f32;

        if hit == HIT_BUMP {
            // Dig: arms STRAIGHT, hands JOINED, contact on the FOREARMS. The hand
            // targets are pushed to near-full extension along the shoulder->ball
            // line — a bent-elbow "hands on the ball" pose reads as poking, not a
            // platform.
            //
            // While the ball is still descending, PARK the platform at the
            // predicted meet point instead of tracking the live ball. "Set your
            // platform early and let the ball come to you", literally: a static
            // target is the one thing a speed-limited solver reliably converges
            // on.
            let mut platform_ball = ball_contact;
            if ball_in_play && has_meet && ball.y > meet.y + 0.30 * s {
                platform_ball = within_reach(chest, meet, reach);
            }
            let platform = platform_ball - up * 0.12 * s;
            let mut plat_dir = nrm(platform - chest);
            if plat_dir.length_squared() < 0.01 {
                plat_dir = nrm(fwd - up);
            }
            // Lock the elbows out.
            let ext = (platform - chest).length().max(0.96 * s);
            let mut plat_end = chest + plat_dir * ext;
            // At contact the platform SWINGS THROUGH the ball, lifting along the
            // aim — a bagger is a controlled swing from the shoulders, not a held
            // tray. EaseOut: starts at contact speed and bleeds off.
            plat_end += (aim_flat * 0.26 * s + up * 0.18 * s) * ease_out(swing);
            contact_r = plat_end - right * 0.05 * s;
            contact_l = plat_end + right * 0.05 * s;
            // Elbow hints sit ON the shoulder->hand line, nudged down and in, so
            // the arms stay straight instead of chicken-winging outward.
            pole_r = sh_r + plat_dir * 0.45 * s - up * 0.22 * s - right * 0.06 * s;
            pole_l = sh_l + plat_dir * 0.45 * s - up * 0.22 * s + right * 0.06 * s;
            // THE LEGS SET THE PLATFORM HEIGHT: the lower the ball, the deeper the
            // knees, while the arms keep their stable slope. Keyed on the BALL's
            // height, never on the chest — chest-derived depth feeds back through
            // the crouch and the legs oscillate.
            let mut knee_key_y = platform_ball.y;
            if ball_in_play {
                knee_key_y = if has_meet && ball.y > meet.y + 0.30 * s {
                    meet.y
                } else {
                    ball.y
                };
            }
            let above_feet = knee_key_y - feet_y;
            let ball_low = ((1.10 * s - above_feet) / (0.80 * s)).clamp(0.0, 1.0);
            crouch = 0.5 + 0.2 * ball_low;
        } else if hit == HIT_SET {
            // Overhead window set: hands form a triangle above the forehead,
            // elbows out and forward. At contact the wrists GIVE to load (the
            // cushion), then the whole body EXTENDS through the ball. A set with
            // no cushion and no leg drive reads as a stiff tap.
            let mut cup_ball = ball_contact;
            if ball_in_play && has_meet && ball.y > meet.y + 0.30 * s {
                cup_ball = within_reach(chest, meet, reach);
            }
            let cup = cup_ball - up * 0.06 * s;
            let push = nrm(aim_flat * 0.6 + up * 0.8);
            // Swing is 0 until the real contact fires, so pre-contact the window
            // just holds under the ball; the give and the extend are follow-through.
            let along = if swing <= 0.0 {
                0.06 * s * min_jerk(blend)
            } else if swing < 0.2 {
                (0.06 - 0.14 * (swing / 0.2)) * s
            } else {
                (-0.08 + 0.42 * ((swing - 0.2) / 0.8)) * s
            };
            let extend = push * along;
            // Hands ~20 cm apart and UNCROSSED — right hand right, left hand left.
            contact_r = cup + right * 0.10 * s + extend;
            contact_l = cup - right * 0.10 * s + extend;
            // Elbows OUT to the sides and forward: the open triangle window.
            pole_r = sh_r + fwd * 0.30 * s + right * 0.18 * s + up * 0.04 * s;
            pole_l = sh_l + fwd * 0.30 * s - right * 0.18 * s + up * 0.04 * s;
            // Legs load through the cushion and extend through the drive. Single
            // direction in swing so it cannot oscillate.
            crouch = 0.22 - 0.22 * ((swing - 0.2) / 0.5).clamp(0.0, 1.0);
        } else if hit == HIT_SPIKE {
            // A real overhand swing in four phases. The right arm draws a bow and
            // whips over the top; the left arm is the timing/counter-rotation arm.
            //   1 BACKSWING  swung back at shoulder height as the body rises
            //   2 COCKED     bow drawn: elbow HIGH, hand above and behind the head
            //   3 STRIKE     elbow leads, forearm whips over, contact at extension
            //   4 FOLLOW     hand snaps down and across to the opposite hip
            // Phases 1-3 time to the ball descending; phase 4 runs off the
            // post-contact envelope, so a whiff retracts instead of finishing.
            let back_sw = sh_r - fwd * 0.18 * s - up * 0.06 * s + right * 0.16 * s;
            let cocked = head - fwd * 0.16 * s + right * 0.06 * s + up * 0.24 * s;
            // Reach for the REAL ball height, not the reach-clamped contact point:
            // the solver saturates at full extension so over-asking is free, while
            // under-asking leaves the hand below the ball at the jump apex.
            let ball_y_raw = if ball_in_play { ball.y } else { ball_contact.y };
            let strike_up = (ball_y_raw - sh_r.y).clamp(0.35 * s, 1.25 * s);
            let strike = sh_r + up * strike_up + fwd * 0.24 * s + right * 0.06 * s;
            let finish = sh_r - up * 0.42 * s + fwd * 0.06 * s - right * 0.32 * s;

            let mut swing_phase = blend;
            if ball_in_play {
                // 0 when the ball is a long way above the strike height, 1 at contact.
                let drop = ball.y - strike.y;
                swing_phase = (1.0 - drop / (2.60 * s)).clamp(0.0, 1.0) * blend;
            }

            if swing > 0.001 {
                contact_r = arc_around(sh_r, strike, finish, ease_out(swing));
                pole_r = contact_r + up * 0.12 * s - fwd * 0.04 * s + right * 0.08 * s;
            } else if swing_phase < 0.4 {
                // Backswing -> cocked: draw the bow as the body rises.
                contact_r = arc_around(sh_r, back_sw, cocked, min_jerk(swing_phase / 0.4));
                pole_r = contact_r + up * 0.22 * s - fwd * 0.26 * s + right * 0.12 * s;
            } else {
                // Cocked -> strike: the elbow travels forward and down, leading
                // the hand over the top.
                let t = ease_in((swing_phase - 0.4) / 0.6);
                contact_r = arc_around(sh_r, cocked, strike, t);
                pole_r = contact_r + up * (0.22 - 0.08 * t) * s
                    - fwd * (0.26 - 0.40 * t) * s
                    + right * 0.10 * s;
            }

            // Left arm points at the ball through the windup, then PULLS DOWN to
            // the ribs as the right whips over. A left arm still pointing at
            // contact is the tell of a video-game spike.
            let to_ball_l = {
                let d = ball_contact - sh_l;
                if d.length() > 0.95 * s {
                    nrm(d) * 0.95 * s
                } else {
                    d
                }
            };
            let point_l = sh_l + to_ball_l;
            let tuck_l = sh_l - up * 0.28 * s + fwd * 0.12 * s;
            let left_pull = ((swing_phase - 0.5) / 0.4).max(swing).clamp(0.0, 1.0);
            contact_l = point_l + (tuck_l - point_l) * left_pull;
            pole_l = if left_pull < 0.5 {
                sh_l + to_ball_l * 0.4 - up * 0.15 * s
            } else {
                sh_l - up * 0.20 * s - fwd * 0.10 * s
            };
        } else if hit == HIT_BLOCK {
            // Both hands reach up and toward the ball, as high and close as the
            // arms allow, pressed together to penetrate the net rather than spread.
            let block_mid = chest + {
                let d = ball_contact - chest;
                if d.length() > 0.95 * s {
                    nrm(d) * 0.95 * s
                } else {
                    d
                }
            };
            contact_r = block_mid + right * 0.09 * s;
            contact_l = block_mid - right * 0.09 * s;
            // Elbows high and slightly forward so the arms form a firm wall.
            pole_r = contact_r + fwd * 0.25 * s - up * 0.05 * s;
            pole_l = contact_l + fwd * 0.25 * s - up * 0.05 * s;
        } else if hit == HIT_SERVE {
            // Choreographed by serve_phase, not by the ball: the LEFT arm carries
            // the ball to a toss apex in front of the RIGHT shoulder then tucks
            // away, while the RIGHT draws back behind the ear and whips overhead.
            let p = serve_phase.clamp(0.0, 1.0);
            let toss_apex = chest + fwd * 0.24 * s + up * 0.62 * s + right * 0.10 * s;
            let toss_start = chest + fwd * 0.30 * s - up * 0.06 * s + right * 0.06 * s;
            let toss_hand = toss_apex - up * 0.16 * s;
            let tuck_l = sh_l - up * 0.26 * s + fwd * 0.10 * s;
            if p < 0.6 {
                let t = p / 0.6;
                contact_l = toss_start + (toss_hand - toss_start) * min_jerk(t);
                pole_l = sh_l + fwd * 0.35 * s - up * 0.04 * s;
            } else {
                let t = (p - 0.6) / 0.4;
                contact_l = toss_hand + (tuck_l - toss_hand) * min_jerk(t);
                pole_l = sh_l - up * 0.18 * s - fwd * 0.08 * s;
            }

            let rest_r = sh_r + fwd * 0.15 * s - up * 0.22 * s;
            let draw_r = head + right * 0.24 * s - fwd * 0.14 * s + up * 0.04 * s;
            let strike_r = toss_apex + up * 0.06 * s;
            let follow_r = sh_r + fwd * 0.55 * s + up * 0.08 * s;
            // Segment boundaries match the serve physics: the ball leaves at phase
            // 0.78, so the hand must be AT strike_r exactly then.
            if p < 0.55 {
                contact_r = arc_around(sh_r, rest_r, draw_r, min_jerk(p / 0.55));
                pole_r = contact_r + up * 0.20 * s - fwd * 0.25 * s + right * 0.12 * s;
            } else if p < 0.78 {
                let t = (p - 0.55) / 0.23;
                contact_r = arc_around(sh_r, draw_r, strike_r, ease_in(t));
                pole_r = contact_r + up * 0.18 * s - fwd * 0.20 * s + right * 0.10 * s;
            } else {
                let t = (p - 0.78) / 0.22;
                contact_r = arc_around(sh_r, strike_r, follow_r, ease_out(t));
                pole_r = contact_r + up * 0.10 * s + right * 0.12 * s;
            }
            // A gather-dip as the toss goes up, legs extending through the strike.
            crouch = 0.22 * (((p / 0.7).clamp(0.0, 1.0)) * std::f32::consts::PI).sin();
        } else {
            contact_r = ready_r;
            contact_l = ready_l;
            pole_r = sh_r - up * 0.40 * s;
            pole_l = sh_l - up * 0.40 * s;
        }

        // Spike, block and serve build their own motion into the contact targets
        // via swing_phase/serve_phase, so re-lerping them from the ready pose
        // would start the hand at the hip instead of cocked. Everything else
        // eases out of ready on a MinJerk ramp — constant speed reads mechanical.
        let (want_r, want_l) = if hit == HIT_SPIKE || hit == HIT_BLOCK || hit == HIT_SERVE {
            (contact_r, contact_l)
        } else {
            let ramp = min_jerk(blend);
            (
                ready_r + (contact_r - ready_r) * ramp,
                ready_l + (contact_l - ready_l) * ramp,
            )
        };

        dict! {
            "hand_r" => want_r,
            "hand_l" => want_l,
            "pole_r" => pole_r,
            "pole_l" => pole_l,
            "crouch" => (crouch * blend + extra_crouch).clamp(0.0, 1.0) as f64,
        }
    }
}

fn getf(d: &VarDictionary, k: &str) -> f64 {
    d.get(k).and_then(|v| v.try_to::<f64>().ok()).unwrap_or(0.0)
}
fn geti(d: &VarDictionary, k: &str) -> i64 {
    d.get(k).and_then(|v| v.try_to::<i64>().ok()).unwrap_or(0)
}
fn getb(d: &VarDictionary, k: &str) -> bool {
    d.get(k)
        .and_then(|v| v.try_to::<bool>().ok())
        .unwrap_or(false)
}
fn getv(d: &VarDictionary, k: &str) -> Vector3 {
    d.get(k)
        .and_then(|v| v.try_to::<Vector3>().ok())
        .unwrap_or(Vector3::ZERO)
}
