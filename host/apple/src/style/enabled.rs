//! The one transition the presenter runs (`style_json_rows`): `-exact-enabled`,
//! a native control becoming enabled or disabled. The engine runs the rest.
use super::push_num;
use exact_motion::{Easing as E, TimingFunction, Transitions};

/// Writes the `-exact-enabled` declaration as `["spring", stiffness, damping,
/// mass, delay]`, or `[duration, delay, x1, y1, x2, y2]` for an easing as its
/// cubic Bézier (steps and `linear()` as linear). False when there is none.
pub(super) fn push_enabled(out: &mut String, transitions: &Transitions) -> bool {
    let Some(tr) = transitions.enabled() else {
        return false;
    };
    match &tr.timing {
        TimingFunction::Spring(c) => {
            out.push_str("[\"spring\",");
            for v in [c.stiffness, c.damping, c.mass, tr.delay] {
                push_num(out, v as f32);
                out.push(',');
            }
        }
        TimingFunction::Easing(e) => {
            let b = match e {
                E::Ease => [0.25, 0.1, 0.25, 1.0],
                E::EaseIn => [0.42, 0.0, 1.0, 1.0],
                E::EaseOut => [0.0, 0.0, 0.58, 1.0],
                E::EaseInOut => [0.42, 0.0, 0.58, 1.0],
                E::CubicBezier { x1, y1, x2, y2 } => [*x1, *y1, *x2, *y2],
                _ => [0.0, 0.0, 1.0, 1.0],
            };
            out.push('[');
            for v in [tr.duration, tr.delay, b[0], b[1], b[2], b[3]] {
                push_num(out, v as f32);
                out.push(',');
            }
        }
    }
    out.pop();
    out.push(']');
    true
}
