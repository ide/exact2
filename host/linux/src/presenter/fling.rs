//! LLP 1057.001 §8 on the Android reader: `swipe` is the platform's fling,
//! which the reader recognizes over the whole touch (`ExactView.kt`) and
//! hands here at the lift with its direction and the most fingers it had
//! down. The presenter's contact is one finger and a second ends it, so the
//! touch's first hit, and whether one of the presenter's own gestures took
//! the contact, are kept past that end for the fling.
use super::*;
use exact_kernel::{ControlKind, NodeKey, PropValue};

/// Where a touch first came down, kept for its fling.
#[derive(Clone, Copy)]
pub(super) struct Landed {
    pub(super) hit: NodeKey,
    /// A pan, a drag binding, a group's lift, a `swiperight` or a canvas
    /// took the contact: the fling fails, as a swipe does when a continuous
    /// gesture begins (§8.4).
    pub(super) took: bool,
}

impl<D: DataSource> Presenter<D> {
    /// The touch's fling in `direction` (left, right, up or down) with
    /// `pointers` down at most: dispatched to the innermost node on its first
    /// hit's path whose swipe names that direction at that count (rule 3), and
    /// whether one took it. A text input, a control or a `press` handler
    /// between keeps the contact, and a gesture that took it leaves none.
    pub fn fling(&mut self, direction: &str, pointers: u32, now_ms: f64) -> Result<bool, String> {
        let Some(landed) = self.landed.take().filter(|l| !l.took) else {
            return Ok(false);
        };
        let Some(view) = self.fling_target(landed.hit, direction, pointers) else {
            return Ok(false);
        };
        let error = self
            .host
            .dispatch_at(view, Event::Swipe(direction.into()), now_ms)
            .or(self.after_commit());
        self.dirty = true;
        error.map_or(Ok(true), Err)
    }

    fn fling_target(&self, hit: NodeKey, direction: &str, pointers: u32) -> Option<ViewId> {
        let kernel = self.host.kernel();
        let mut at = kernel.node_by_key(hit).map(|n| n.id);
        while let Some(id) = at {
            let node = kernel.node(id)?;
            let handlers = self.host.runner().handlers_of(id);
            if handlers.contains(&EventKind::Swipe)
                && takes(node.props, direction, pointers)
                && self.input_live(node.key)
            {
                return Some(id);
            }
            if handlers.contains(&EventKind::Press)
                || node.node_type == NodeType::TextInput
                || node.node_type == NodeType::Pressable
                || ControlKind::of(node.node_type, node.props).is_some()
            {
                return None;
            }
            at = node.parent;
        }
        None
    }

    /// The agent's `tap <id> swipe <direction> [at <x> <y>]` (LLP 1057.001
    /// §8.7): the fling of a touch that starts there, at the node's count,
    /// delivered `recognized` (no driver synthesizes the reader's fling)
    /// once that touch would reach the node: it takes the direction, is
    /// hit there, is the innermost such on the hit path, and nothing between
    /// keeps the contact.
    pub(crate) fn agent_swipe(
        &mut self,
        id: ViewId,
        direction: &str,
        at: Option<(f32, f32)>,
    ) -> Result<String, String> {
        let named = format!("tap #{id} swipe {direction}");
        let node = self
            .host
            .kernel()
            .node(id)
            .ok_or_else(|| format!("no view {id}"))?;
        let (key, props) = (node.key, node.props.clone());
        let pointers = match props.get(PropId::TouchCount) {
            Some(PropValue::Int(n)) if *n >= 1 => u32::try_from(*n).unwrap_or(u32::MAX),
            _ => 1,
        };
        let swipes = self
            .host
            .runner()
            .handlers_of(id)
            .contains(&EventKind::Swipe);
        if !swipes || !takes(&props, direction, pointers) || !self.input_live(key) {
            return Err(format!("{named}: it takes no swipe to the {direction}; its `swipe-direction` names the directions"));
        }
        let b = self
            .box_of(id)
            .ok_or_else(|| format!("no view {id} on screen"))?;
        if let Some((x, y)) = at {
            if !(x.is_finite()
                && y.is_finite()
                && x >= 0.
                && y >= 0.
                && x < b.rect.2
                && y < b.rect.3)
            {
                return Err(format!("{named}: at must be a finite point inside its box"));
            }
        }
        let (x, y) = self
            .pointer_target(id, at)
            .map_err(|e| format!("{named}: {e}"))?;
        let hit = self
            .hit(x, y)
            .and_then(|h| self.host.kernel().node(h))
            .map(|n| n.key);
        match hit.and_then(|hit| self.fling_target(hit, direction, pointers)) {
            Some(target) if target == id => {}
            Some(nearer) => return Err(format!("{named}: #{nearer}, nearer on the hit path, takes that swipe (rule 3)")),
            None => return Err(format!("{named}: a `press`, a control or a text input between the hit and it keeps the contact (rule 3)")),
        }
        let now = self.host.now();
        if let Some(error) = self
            .host
            .dispatch_at(id, Event::Swipe(direction.into()), now)
            .or(self.after_commit())
        {
            return Err(error);
        }
        self.dirty = true;
        Ok(format!(
            "{{\"tapped\":{id},\"swipe\":\"{direction}\",\"at\":[{},{}],\"delivery\":\"recognized\"}}",
            x - b.rect.0,
            y - b.rect.1
        ))
    }

    /// A gesture took the touch's contact.
    pub(super) fn contact_taken(&mut self) {
        if let Some(landed) = &mut self.landed {
            landed.took = true;
        }
    }
}

/// Whether a node's swipe takes a fling in `direction` with `pointers` down:
/// its `swipe-direction` names it, and its `touch-count`, if any, is that
/// many. A computed count that is no whole number of at least 1 recognizes
/// nothing until it is one.
fn takes(props: &exact_kernel::PropList, direction: &str, pointers: u32) -> bool {
    let named = props
        .str(PropId::SwipeDirection)
        .is_some_and(|words| words.split_ascii_whitespace().any(|w| w == direction));
    let counts = match props.get(PropId::TouchCount) {
        None => true,
        Some(PropValue::Int(n)) => *n >= 1 && *n == i64::from(pointers),
        Some(_) => false,
    };
    named && counts
}

#[cfg(test)]
#[path = "fling_tests.rs"]
mod fling_tests;
