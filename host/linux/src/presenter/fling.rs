//! LLP 1057.001 §8 on the Android reader: `swipe` is the platform's fling,
//! which the reader recognizes over the whole touch (`Flings.kt`) and hands
//! here before the lift, with its direction and the most pointers the touch
//! had down at once. The presenter's contact is one pointer and a second ends
//! it, so the touch's first hit is kept past that end for the fling, until a
//! gesture of the presenter's own takes the contact.
use super::contact::Candidate;
use super::*;
use exact_kernel::{ControlKind, Display, NodeKey, PropValue};

impl<D: DataSource> Presenter<D> {
    /// The fling a new touch here could make, recognized without making
    /// platform touches. Admission and dispatch are the live fling's own.
    pub(crate) fn agent_swipe(
        &mut self,
        id: ViewId,
        direction: &str,
        at: Option<(f32, f32)>,
    ) -> Result<String, String> {
        if !["left", "right", "up", "down"].contains(&direction) {
            return Err("swipe: expected left, right, up or down".into());
        }
        if self.contact.is_some()
            || self.landed.is_some()
            || self.pointer_held.is_some()
            || self.pointer_buttons != 0
        {
            return Err("a contact is already down; use `tap up` or `tap cancel` first".into());
        }
        let named = format!("tap #{id} swipe {direction}");
        let b = self
            .box_of(id)
            .ok_or_else(|| format!("{named}: no box on screen"))?;
        let node = self
            .host
            .kernel()
            .node(id)
            .ok_or_else(|| format!("no view {id}"))?;
        let pointers = match node
            .props
            .get(PropId::TouchCount)
            .and_then(PropValue::as_int)
        {
            Some(n) => u32::try_from(n)
                .ok()
                .filter(|n| *n > 0)
                .ok_or_else(|| format!("{named}: its touch-count cannot be driven"))?,
            None => 1,
        };
        if !self.input_live(node.key)
            || self.placement_hidden(id)
            || !self
                .host
                .runner()
                .handlers_of(id)
                .contains(&EventKind::Swipe)
            || !takes(node.props, direction, pointers)
        {
            return Err(format!("{named}: it takes no swipe that way while hidden, disabled or inert, or its swipe-direction does not name it"));
        }
        let ((x, y), local) = b
            .point_at(at)
            .ok_or_else(|| format!("{named}: at must be a finite point inside its box"))?;
        if x < 0. || y < 0. || x >= self.viewport.0 || y >= self.viewport.1 {
            return Err(format!("{named}: its start is outside the viewport"));
        }
        let first = self
            .hit(x, y)
            .ok_or_else(|| format!("{named}: nothing is under its start"))?;
        if !std::iter::successors(Some(first), |&id| self.host.kernel().node(id)?.parent)
            .any(|n| n == id)
        {
            return Err(format!("{named}: it is covered or clipped at its start"));
        }
        if self.hosted_at(first).is_some() {
            return Err(format!("{named}: a hosted text input keeps the touch"));
        }
        let hit = self
            .host
            .kernel()
            .node(first)
            .ok_or_else(|| format!("{named}: its hit is gone"))?
            .key;
        // The reader has already kept hosted touches. A down on any other hit
        // that is not live keeps only the path for its later fling.
        if self.input_live(hit) {
            let candidates = self.candidates_at(hit, x);
            if candidates.is_empty() && self.canvas_contact_target(first).is_some() {
                return Err(format!("{named}: the canvas at the start takes input and keeps the touch; use a control for this action instead"));
            }
            let (dx, dy) = match direction {
                "left" => (-1., 0.),
                "right" => (1., 0.),
                "up" => (0., -1.),
                _ => (0., 1.),
            };
            // With multiple pointers down before motion, the reader cancels this
            // single-pointer contact and keeps its first hit for the native fling.
            if pointers == 1
                && candidates
                    .into_iter()
                    .find(|c| c.accepts(dx, dy))
                    .is_some_and(|c| match c {
                        Candidate::Swipe(key) => self.swipe_admits_motion(key, dx),
                        _ => true,
                    })
            {
                return Err(format!("{named}: a drag on the hit path takes the contact"));
            }
        }
        match self.fling_target(hit, direction, pointers) {
            Some(target) if target == id => {},
            Some(nearer) => return Err(format!("{named}: #{nearer}, nearer on the hit path, takes that swipe (rule 3)")),
            None => return Err(format!("{named}: a scroller, press, control or text input on the hit path keeps the contact")),
        }
        self.landed = Some(hit);
        if !self.fling(direction, pointers, self.host.now())? {
            return Err(format!("{named}: its swipe is no longer eligible"));
        }
        Ok(serde_json::json!({"tapped": id, "swipe": direction, "at": [local.0, local.1], "delivery": "recognized"}).to_string())
    }

    /// Dispatches the touch's fling in `direction` (left, right, up or down)
    /// to the innermost node on its first hit's path whose swipe takes that
    /// direction with `pointers` down (rule 3), and returns whether one took
    /// it. The fling first ends the contact, and with it an armed press.
    pub fn fling(&mut self, direction: &str, pointers: u32, now_ms: f64) -> Result<bool, String> {
        let Some(hit) = self.landed.take() else {
            return Ok(false);
        };
        let Some(target) = self.fling_target(hit, direction, pointers) else {
            return Ok(false);
        };
        self.dirty = true;
        // End a contact that is still alive, then find the swipe again: the
        // cancel runs the authored up handlers (LLP 1005 §3), which may
        // disable, hide or remove it. A contact that already ended past the
        // slop has nothing to end: the up handlers run at the lift, or ran at
        // an earlier cancel such as a second finger's.
        let target = if self.contact.is_some() {
            if let Err(e) = self.pointer_cancel(now_ms) {
                self.host.log(e);
            }
            self.fling_target(hit, direction, pointers)
        } else {
            Some(target)
        };
        let Some(view) = target else {
            return self.after_commit().map_or(Ok(false), Err);
        };
        let error = self
            .host
            .dispatch_at(view, Event::Swipe(direction.into()), now_ms)
            .or(self.after_commit());
        error.map_or(Ok(true), Err)
    }

    /// The node on the path from the touch's first hit, `hit`, whose swipe
    /// takes the fling. A scroller on the path that scrolls on the fling's
    /// axis keeps it, as the reader's scrolling takes the touch, and so does
    /// a live text input, control or `press` node below the swipe. A node
    /// that is not rendered, or whose input is not live (`disabled`, or
    /// inside such a node), passes it on (§8.1).
    fn fling_target(&mut self, hit: NodeKey, direction: &str, pointers: u32) -> Option<ViewId> {
        let first = self.host.kernel().node_by_key(hit)?.id;
        let sideways = matches!(direction, "left" | "right");
        if self
            .chain_from(first)
            .iter()
            .any(|s| if sideways { s.axes.0 } else { s.axes.1 })
        {
            return None;
        }
        let kernel = self.host.kernel();
        let path: Vec<ViewId> =
            std::iter::successors(Some(first), |&id| kernel.node(id)?.parent).collect();
        // Start above the highest node that is not rendered, which hides every node below it
        let start = path
            .iter()
            .rposition(|&id| {
                kernel
                    .node(id)
                    .is_some_and(|n| n.style.display == Display::None)
                    || matches!(
                        self.brush.placements.get(&id),
                        Some(crate::placement::Placement::Hidden)
                    )
            })
            .map_or(0, |i| i + 1);
        for &id in &path[start..] {
            let node = kernel.node(id)?;
            let handlers = self.host.runner().handlers_of(id);
            let live = self.input_live(node.key);
            if live
                && handlers.contains(&EventKind::Swipe)
                && takes(node.props, direction, pointers)
            {
                return Some(id);
            }
            if live
                && (handlers.contains(&EventKind::Press)
                    || node.node_type == NodeType::TextInput
                    || node.node_type == NodeType::Pressable
                    || ControlKind::of(node.node_type, node.props).is_some())
            {
                return None;
            }
        }
        None
    }

    /// Ends the touch's fling: a gesture of the presenter's took its contact.
    pub(super) fn contact_taken(&mut self) {
        self.landed = None;
    }
}

fn takes(props: &exact_kernel::PropList, direction: &str, pointers: u32) -> bool {
    props
        .str(PropId::SwipeDirection)
        .is_some_and(|words| words.split_ascii_whitespace().any(|w| w == direction))
        && props
            .get(PropId::TouchCount)
            .and_then(PropValue::as_int)
            .is_none_or(|n| n == i64::from(pointers))
}

#[cfg(test)]
#[path = "fling_tests.rs"]
mod fling_tests;

#[cfg(test)]
#[path = "agent_swipe_tests.rs"]
mod agent_swipe_tests;
