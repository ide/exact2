//! `lower-env-in-owner` (LLP 1123 D9): a route reads the window's
//! `env(safe-area-inset-*)`, `env(-exact-<region>-inset-*)` or
//! `env(viewport-segment-*)`. A route is a content owner whose safe area,
//! layout regions and segments are its own, read as `var(--exact-…)`:
//! under a navigation bar the window's top inset clears the status bar a
//! second time, and a pane placed on the window's segment misses the fold
//! by the bar's height. A dialog or a popover is the document's (D9), so
//! `env()` is right inside one. A computed value is given the benefit.

use crate::LowerError;
use contract_syntax::{Attr, Expr, Node, StyleDecl};
use std::collections::BTreeSet;

/// Warns once for each row of a route's root or its content, written there
/// or in a class it names, that reads one of the window's owner values: the
/// root's own padding clears what the route already clears.
pub(super) fn env_in_owner(
    route: &[Node],
    styles: &[StyleDecl],
    seen: &mut BTreeSet<(u32, u32, u32)>,
    out: &mut Vec<LowerError>,
) {
    let mut stack: Vec<&Node> = route.iter().collect();
    while let Some(node) = stack.pop() {
        match node {
            Node::Element {
                tag,
                attrs,
                children,
                ..
            } => {
                if tag == "dialog" || attrs.iter().any(|a| a.name == "popover") {
                    continue;
                }
                let classes =
                    attrs
                        .iter()
                        .filter(|a| a.name == "class")
                        .filter_map(|a| match &a.value {
                            Expr::Ident(name, _) => styles.iter().find(|s| &s.name == name),
                            _ => None,
                        });
                for row in attrs.iter().chain(classes.flat_map(|s| &s.attrs)) {
                    warn(row, seen, out);
                }
                stack.extend(children);
            }
            Node::When {
                then, otherwise, ..
            } => stack.extend(then.iter().chain(otherwise)),
            Node::Each { body, .. } => stack.extend(body),
            Node::Match { some, none, .. } => stack.extend(some.1.iter().chain(none)),
            Node::Use { children, .. } => stack.extend(children),
            Node::Children { .. } => {}
        }
    }
}

fn warn(row: &Attr, seen: &mut BTreeSet<(u32, u32, u32)>, out: &mut Vec<LowerError>) {
    let Expr::Str(value, _) = &row.value else {
        return;
    };
    let Some(owned) = owner_spelling(value) else {
        return;
    };
    if !seen.insert((row.span.source_id, row.span.line, row.span.col)) {
        return;
    }
    let name = &row.name;
    out.push(LowerError {
        id: "lower-env-in-owner",
        message: format!("`{name}=\"{value}\"` reads the window's `env()` inside a route, which has a safe area, layout regions and fold segments of its own, measured from where its content starts (LLP 1123 D9): under a navigation bar the window's top inset clears the status bar twice, and a pane on the window's segment misses the fold by the bar's height. Write the route's: `{name}=\"{owned}\"`. In a dialog or a popover, which are the window's, `env()` is right"),
        span: row.span,
    });
}

/// `value` with each `env()` an owner gives its own value for spelled as
/// that value's `var(--exact-…)`, when it has one and none with a fallback.
fn owner_spelling(value: &str) -> Option<String> {
    let mut out = String::new();
    let (mut rest, mut changed) = (value, false);
    while let Some(at) = rest.find("env(") {
        out.push_str(&rest[..at]);
        let inner = &rest[at + 4..];
        let end = inner.find(')')?;
        let name = inner[..end].trim();
        let owned = if let Some(field) = name.strip_prefix("viewport-segment-") {
            let mut parts = field.split_whitespace();
            match (parts.next(), parts.next(), parts.next(), parts.next()) {
                (Some(f), Some(x), Some(y), None) => {
                    Some(format!("--exact-viewport-segment-{f}-{x}-{y}"))
                }
                _ => None,
            }
        } else if name.starts_with("safe-area-inset-") {
            Some(format!("--exact-{name}"))
        } else {
            name.strip_prefix("-exact-")
                .filter(|n| n.contains("-inset-") && !n.contains(','))
                .map(|n| format!("--exact-{n}"))
        };
        match owned.filter(|n| exact_kernel::OwnerVar::from_name(n).is_some()) {
            Some(n) => {
                out.push_str(&format!("var({n})"));
                changed = true;
            }
            None if name.contains(',') && is_owner_env(name) => return None,
            None => out.push_str(&rest[at..at + 4 + end + 1]),
        }
        rest = &inner[end + 1..];
    }
    out.push_str(rest);
    changed.then_some(out)
}

/// Whether an `env()`'s text, with a fallback, names an owner value.
fn is_owner_env(name: &str) -> bool {
    ["safe-area-inset-", "viewport-segment-", "-exact-"]
        .iter()
        .any(|p| name.starts_with(p))
}

#[cfg(test)]
mod tests {
    use super::owner_spelling;

    #[test]
    fn each_owner_value_is_spelled_as_its_var() {
        assert_eq!(
            owner_spelling("calc(env(safe-area-inset-top) + 8px)").as_deref(),
            Some("calc(var(--exact-safe-area-inset-top) + 8px)")
        );
        assert_eq!(
            owner_spelling("env(viewport-segment-left 1 0)").as_deref(),
            Some("var(--exact-viewport-segment-left-1-0)")
        );
        assert_eq!(
            owner_spelling("max(0px, env(-exact-readable-content-corners-inset-left))").as_deref(),
            Some("max(0px, var(--exact-readable-content-corners-inset-left))")
        );
        assert_eq!(owner_spelling("env(keyboard-inset-height)"), None);
        assert_eq!(owner_spelling("env(titlebar-area-x)"), None);
        assert_eq!(owner_spelling("env(safe-area-inset-top, 0px)"), None);
    }
}
