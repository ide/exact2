//! `tap <target> swipe <direction> [at <x> <y>]` (LLP 1057.001 §8.7): on the
//! Android reader the platform's fling, recognized (`presenter/fling.rs`);
//! the Linux desktop and Windows make no swipe, and refuse it.
use super::*;

pub(super) fn tap<D: DataSource>(
    p: &mut Presenter<D>,
    id: Option<u32>,
    request: &serde_json::Value,
) -> String {
    if !cfg!(target_os = "android") {
        return error(&format!(
            "unsupported: the {HOST_NAME} host makes no swipe, as its platform gives its pointer none (LLP 1057.001 §8.2); swipe drives iOS, tvOS, macOS and the Android reader"
        ));
    }
    let Some(direction) = request["swipe"]
        .as_str()
        .filter(|d| ["left", "right", "up", "down"].contains(d))
    else {
        return malformed("swipe: expected left, right, up or down");
    };
    let Some(id) = id else {
        return malformed("swipe needs a target");
    };
    let at = match request.get("at") {
        None => None,
        Some(value) => match value.as_array().map(Vec::as_slice) {
            Some([x, y]) => match (x.as_f64(), y.as_f64()) {
                (Some(x), Some(y)) => Some((x as f32, y as f32)),
                _ => return malformed("at needs two finite numbers"),
            },
            _ => return malformed("at needs two finite numbers"),
        },
    };
    p.agent_swipe(id, direction, at)
        .unwrap_or_else(|e| error(&e))
}
