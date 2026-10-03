//! Read-only text projection for virtual rows. Uses the same realization and
//! binding evaluation as rendering, but commits no kernel or host operations.
use super::*;
use crate::ListTextPosition;
use exact_kernel::{PropId, StyleId};

/// A virtualized list's rows as logical text sees them: every row, mounted
/// or not.
fn list_region<'a>(
    children: &'a [Child],
    view: ViewId,
    frames: &mut Vec<Frame>,
) -> Option<&'a collection::Collection> {
    fn walk<'a>(
        children: &'a [Child],
        view: ViewId,
        frames: &mut Vec<Frame>,
    ) -> Option<&'a collection::Collection> {
        for child in children {
            match child {
                Child::Node(n) => {
                    if n.view == view {
                        return n.collection.as_deref();
                    }
                    // A nested list lives in a mounted row (LLP 1070 §4.7).
                    if let Some(c) = &n.collection {
                        for (_, row) in c.mounted_rows() {
                            frames.push(row.frame.clone());
                            if let Some(r) = walk(&row.roots, view, frames) {
                                return Some(r);
                            }
                            frames.pop();
                        }
                    }
                    if let Some(r) = walk(&n.children, view, frames) {
                        return Some(r);
                    }
                }
                Child::Region(r) => match &r.active {
                    Active::Arm { roots, frame, .. } => {
                        frames.push(frame.clone());
                        if let Some(r) = walk(roots, view, frames) {
                            return Some(r);
                        }
                        frames.pop();
                    }
                    Active::Rows { rows } => {
                        for row in rows {
                            frames.push(row.frame.clone());
                            if let Some(r) = walk(&row.roots, view, frames) {
                                return Some(r);
                            }
                            frames.pop();
                        }
                    }
                },
            }
        }
        None
    }
    walk(children, view, frames)
}

fn hidden(n: &NodeInst, plan: &Plan) -> bool {
    plan.node(n.node).bindings.iter().enumerate().any(|(i, b)| {
        let b = plan.binding(b);
        b.kind == BindingKind::Style
            && b.id == StyleId::Display as u16
            && n.last[i].as_ref().and_then(Value::as_str) == Some("none")
    })
}

/// CSS UI 4 §6.1: `user-select`'s used value from the node's own and its
/// parent's (an editable element's is `contain`, which keeps its text).
fn user_select<'a>(n: &'a NodeInst, plan: &Plan, parent: &'a str) -> &'a str {
    match n
        .bound_style(plan, StyleId::UserSelect)
        .and_then(Value::as_str)
    {
        Some(own) if own != "auto" => own,
        _ if parent == "all" || parent == "none" => parent,
        _ => "text",
    }
}

/// A paragraph's text as runs, each whether a selection may include it: a
/// run whose `user-select` is used `none` keeps its place, so the host's
/// UTF-16 offsets over the whole paragraph still hold, and is cut from the
/// copy, as CSS leaves it out of a selection extending across it.
type Runs = Vec<(String, bool)>;

fn collect(
    u: &mut Update<'_>,
    children: &[Child],
    frames: &[Frame],
    inline: bool,
    parent: &str,
    out: &mut Vec<Runs>,
) -> Result<(), InstanceError> {
    for child in children {
        match child {
            Child::Node(n) if !hidden(n, u.env.plan) => {
                let text = u.env.plan.node(n.node).node_type == NodeType::Text as u8;
                let used = user_select(n, u.env.plan, parent).to_string();
                if text && !inline {
                    out.push(Vec::new());
                }
                if text {
                    if let Some(value) = n
                        .bound_prop(u.env.plan, PropId::Text)
                        .and_then(Value::as_str)
                    {
                        if let Some(last) = out.last_mut() {
                            last.push((value.to_string(), used != "none"));
                        }
                    }
                }
                collect(u, &n.children, frames, inline || text, &used, out)?;
            }
            Child::Node(_) => {}
            Child::Region(r) => match &r.active {
                Active::Arm { roots, frame, .. } => {
                    let mut inner = frames.to_vec();
                    inner.push(frame.clone());
                    collect(u, roots, &inner, inline, parent, out)?;
                }
                Active::Rows { rows } => {
                    for row in rows {
                        let mut inner = frames.to_vec();
                        inner.push(row.frame.clone());
                        collect(u, &row.roots, &inner, inline, parent, out)?;
                    }
                }
            },
        }
    }
    Ok(())
}

impl Tree {
    /// Resolve a row key without creating its views.
    pub fn list_index(&self, view: ViewId, key: &str) -> Option<usize> {
        list_region(&self.children, view, &mut Vec::new())?.logical_index(key)
    }

    /// Text for all rows, or two stable UTF-16 endpoints, without mutation.
    pub fn list_text(
        &self,
        u: &mut Update<'_>,
        view: ViewId,
        range: Option<(ListTextPosition<'_>, ListTextPosition<'_>)>,
    ) -> Result<String, InstanceError> {
        let mut frames = Vec::new();
        let list = list_region(&self.children, view, &mut frames)
            .ok_or(InstanceError::List("unknown list"))?;
        let mut start = (0, 0, 0);
        let mut end = (list.logical_len().saturating_sub(1), usize::MAX, usize::MAX);
        if let Some((a, b)) = range {
            let position = |p: ListTextPosition<'_>| {
                list.logical_index(p.key)
                    .map(|i| (i, p.paragraph, p.offset))
                    .ok_or(InstanceError::List("selection row no longer exists"))
            };
            start = position(a)?;
            end = position(b)?;
            if start > end {
                std::mem::swap(&mut start, &mut end);
            }
        }
        let mounted: exact_kernel::SortedMap<usize, &Row> = list.mounted_rows().collect();
        let mut result = String::new();
        for i in start.0..list.logical_len().min(end.0.saturating_add(1)) {
            let temporary;
            let row = if let Some(row) = mounted.get(&i) {
                *row
            } else {
                temporary = list.logical_row(u, i, &frames)?;
                &temporary
            };
            let mut inner = frames.clone();
            inner.push(row.frame.clone());
            let mut paragraphs = Vec::new();
            // A row's parent is the list, selectable where the host let a
            // selection start in it.
            collect(u, &row.roots, &inner, false, "text", &mut paragraphs)?;
            for (p, runs) in paragraphs.into_iter().enumerate() {
                if (i, p) < (start.0, start.1) || (i, p) > (end.0, end.1) {
                    continue;
                }
                let units: Vec<u16> = runs.iter().flat_map(|(t, _)| t.encode_utf16()).collect();
                let lo = if (i, p) == (start.0, start.1) {
                    start.2.min(units.len())
                } else {
                    0
                };
                let hi = if (i, p) == (end.0, end.1) {
                    end.2.min(units.len())
                } else {
                    units.len()
                };
                // The included runs' units within lo..hi.
                let mut kept = Vec::new();
                let mut at = 0;
                for (t, included) in &runs {
                    let n = t.encode_utf16().count();
                    if *included {
                        kept.extend_from_slice(
                            &units[at.max(lo).min(hi)..(at + n).max(lo).min(hi)],
                        );
                    }
                    at += n;
                }
                if kept.is_empty() {
                    continue;
                }
                if !result.is_empty() {
                    result.push_str("\n\n");
                }
                result.push_str(&String::from_utf16_lossy(&kept));
            }
            u.ops.clear();
            u.surfaces.clear();
        }
        Ok(result)
    }
}
