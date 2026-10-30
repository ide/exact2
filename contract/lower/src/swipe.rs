//! LLP 1057.001 §8: `swipe`, a discrete swipe in the directions a node
//! names, and its two props. A literal is checked here; a computed value is
//! the runner's to check as it changes.
use crate::{err, values::numeric_literal, LowerError};
use contract_syntax::{Attr, Expr, Span};

const DIRECTIONS: [&str; 4] = ["left", "right", "up", "down"];

/// `swipe-direction`: one or more of left, right, up and down, physical,
/// space-separated, kept lowercase.
pub(crate) fn direction(value: &Expr, span: Span) -> Result<Expr, LowerError> {
    let Expr::Str(s, at) = value else {
        return Ok(value.clone());
    };
    let words: Vec<String> = s
        .split_ascii_whitespace()
        .map(str::to_ascii_lowercase)
        .collect();
    if words.is_empty() || !words.iter().all(|w| DIRECTIONS.contains(&w.as_str())) {
        return err(
            "lower-swipe-direction",
            "`swipe-direction` names where a swipe goes: one or more of left, right, up and down, space-separated (for example \"down\" or \"left right\")",
            span,
        );
    }
    Ok(Expr::Str(words.join(" "), *at))
}

/// `touch-count`: a whole number of at least 1.
pub(crate) fn count(value: &Expr, span: Span) -> Result<Expr, LowerError> {
    let literal = numeric_literal(value).or(match value {
        Expr::Str(..) | Expr::Bool(..) => Some(f64::NAN),
        _ => None,
    });
    match literal {
        Some(n) if !(n.is_finite() && n.fract() == 0.0 && n >= 1.0) => err(
            "lower-swipe-count",
            "`touch-count` is how many touches a swipe takes: a whole number of at least 1; leave it out for the platform's own swipe",
            span,
        ),
        _ => Ok(value.clone()),
    }
}

/// A node's `swipe` and its props together: either prop without `swipe`
/// does nothing, `swipe` without `swipe-direction` recognizes nothing, and
/// `swiperight` beside a one-touch `swipe` that names `right` would hear
/// the same contact twice.
pub(crate) fn check(attrs: &[Attr]) -> Result<(), LowerError> {
    let find = |name: &str| attrs.iter().find(|a| a.name == name);
    let swipe = find("swipe");
    for prop in ["swipe-direction", "touch-count"] {
        if let (None, Some(a)) = (swipe, find(prop)) {
            return err(
                "lower-swipe-unused",
                format!("`{prop}` describes this node's `swipe`, which it does not have: add `swipe=action`, or remove `{prop}`"),
                a.span,
            );
        }
    }
    let Some(swipe) = swipe else { return Ok(()) };
    let Some(direction) = find("swipe-direction") else {
        return err(
            "lower-swipe-direction",
            "`swipe` needs `swipe-direction`: one or more of left, right, up and down (for example `swipe-direction=\"down\"`)",
            swipe.span,
        );
    };
    let one_touch = find("touch-count").is_none_or(|a| numeric_literal(&a.value) == Some(1.0));
    let names_right = matches!(&direction.value, Expr::Str(s, _) if s.split_ascii_whitespace().any(|w| w.eq_ignore_ascii_case("right")));
    if let (Some(right), true, true) = (find("swiperight"), one_touch, names_right) {
        return err(
            "lower-swipe-twice",
            "`swiperight` and a one-touch `swipe` that names `right` would both take this node's swipe to the right: keep one, or give the `swipe` another `touch-count`",
            right.span,
        );
    }
    Ok(())
}
