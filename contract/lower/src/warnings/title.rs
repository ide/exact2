//! `lower-title-twice` (LLP 1116.005 D6): a heading in a route's content
//! that says what its `header`'s heading says. On iOS that header is the
//! navigation bar and its heading the bar's title, so the title shows
//! twice, once in the bar and once in the page; on the web the content
//! heading sits under the header that says it. Trivia, in rounds 6 and 7,
//! put "Trivia Quiz" in both (round 5's said "Timed Trivia" under it).

use super::{computed, has, holds_heading, kids, literal, part, Part};
use crate::LowerError;
use contract_syntax::{Expr, Node, Span, TemplatePart, VisitSpans};

/// What a heading says: its words when they are written, else its
/// expression with its places dropped, so the same name twice is equal.
#[derive(PartialEq)]
enum Says {
    Words(String),
    Bound(Expr),
}

/// A `text` heading's words, from its first positional argument.
fn says(node: &Node) -> Option<Says> {
    let Node::Element { positional, .. } = node else {
        return None;
    };
    let words = |s: &str| Says::Words(s.split_whitespace().collect::<Vec<_>>().join(" "));
    match positional.first()? {
        Expr::Str(s, _) => Some(words(s)),
        Expr::Template(parts, _) if parts.iter().all(|p| matches!(p, TemplatePart::Text(_))) => {
            let text: String = parts
                .iter()
                .map(|p| match p {
                    TemplatePart::Text(t) => t.as_str(),
                    TemplatePart::Expr(_) => "",
                })
                .collect();
            Some(words(&text))
        }
        e => {
            let mut e = e.clone();
            e.visit_spans(&mut |s: &mut Span| *s = Span::default());
            Some(Says::Bound(e))
        }
    }
}

/// A heading is a `text` whose role says so; an `aria-level` alone is not
/// one (LLP 1115.000 D12.5, `lower-level-without-heading`).
fn heading(tag: &str, attrs: &[contract_syntax::Attr]) -> bool {
    tag == "text" && literal(attrs, "role") == Some("heading")
}

/// One walk of a route's content for headings that say its title.
struct Walk<'a> {
    title: &'a Says,
    out: Vec<Span>,
}

impl Walk<'_> {
    /// A heading of `nodes` that says the title and is the first heading
    /// the page shows under the bar. Past one that is always shown before
    /// it, or inside a `section`, it is a section's own name, not the
    /// screen's. An `if`, `for` or `match` may show nothing, so a heading
    /// under one is passed only within it. What the page never shows with
    /// the bar is skipped: a hidden node, a popover or dialog (over the
    /// page when opened) and another route. Under a `for` or `match`, a
    /// bound expression may name another value: the benefit of the doubt.
    fn walk(&mut self, nodes: &[Node], bound: bool, section: bool, passed: &mut bool) {
        for node in nodes {
            match node {
                Node::Element {
                    tag,
                    attrs,
                    children,
                    ..
                } => {
                    if literal(attrs, "display") == Some("none")
                        || computed(attrs, "display")
                        || has(attrs, "popover")
                        || has(attrs, "navigationKey")
                        || tag == "dialog"
                    {
                        continue;
                    }
                    if heading(tag, attrs) {
                        let same = says(node).is_some_and(|s| {
                            &s == self.title && (matches!(s, Says::Words(_)) || !bound)
                        });
                        if same && !*passed && !section {
                            self.out.push(node.span());
                        }
                        *passed = true;
                    }
                    self.walk(children, bound, section || tag == "section", passed);
                }
                Node::When {
                    then, otherwise, ..
                } => {
                    for arm in [then, otherwise] {
                        self.walk(arm, bound, section, &mut passed.clone());
                    }
                }
                Node::Each { body, .. } => self.walk(body, true, section, &mut passed.clone()),
                Node::Match { some, none, .. } => {
                    for arm in [&some.1, none] {
                        self.walk(arm, true, section, &mut passed.clone());
                    }
                }
                Node::Use { children, .. } => self.walk(children, bound, section, passed),
                Node::Children { .. } => {}
            }
        }
    }
}

/// `lower-title-twice`: `title` is the heading of a route's `header` that
/// is its iOS bar (one heading, by `route_header`'s rule), `content` the
/// route's nodes after that header.
pub(super) fn title_twice(title: &Node, content: &[&Node], out: &mut Vec<LowerError>) {
    let Some(says_title) = says(title) else {
        return;
    };
    let large = match title {
        Node::Element { attrs, .. } => {
            matches!(
                attrs.iter().rev().find(|a| a.name == "aria-level").map(|a| &a.value),
                Some(Expr::Number(n, _)) if *n == 1.0
            ) || literal(attrs, "aria-level") == Some("1")
        }
        _ => false,
    };
    let words = match &says_title {
        Says::Words(w) => format!("\"{w}\""),
        Says::Bound(_) => "the same value".into(),
    };
    let bar = if large {
        "once large in the navigation bar"
    } else {
        "once in the navigation bar"
    };
    let mut walk = Walk {
        title: &says_title,
        out: Vec::new(),
    };
    let mut passed = false;
    for node in content {
        walk.walk(std::slice::from_ref(*node), false, false, &mut passed);
    }
    for span in walk.out {
        out.push(LowerError {
            id: "lower-title-twice",
            message: format!(
                "this heading says {words}, as the route's `header` heading does, so the title shows twice: on iOS {bar} and once in the page, and on the web just under the header that says it. Drop this heading, or make it say something else (a section's own name, \"Results\") — the bar's title already names the screen (docs/recipes/navigation-stack.md)"
            ),
            span,
        });
    }
}

fn shown(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
    if let Node::Element { attrs, .. } = node {
        let class = crate::class::rows(attrs, &|name| {
            styles
                .iter()
                .find(|s| s.name == name)
                .map(|s| s.attrs.as_slice())
        })
        .ok()
        .flatten();
        let display = attrs
            .iter()
            .rev()
            .chain(class.iter().flat_map(|(_, rows)| rows.iter().rev()))
            .find(|a| a.name == "display");
        if display.is_some_and(|a| !matches!(&a.value, Expr::Str(value, _) if value != "none")) {
            return false;
        }
    }
    true
}

/// A passive title wrapper, as HeaderTitle selects it, holds no separate bar control.
pub(super) fn wrapper(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
    fn apart(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
        if !shown(node, styles) {
            return false;
        }
        match part(node) {
            Part::Pressable | Part::Search | Part::Tablist => true,
            Part::Status if !holds_heading(node) => readout(node, styles),
            Part::Box | Part::Status => kids(node).iter().any(|child| apart(child, styles)),
            _ => false,
        }
    }
    holds_heading(node) && !kids(node).iter().any(|child| apart(child, styles))
}

/// A definite ChipFace part: HeaderShape separates a readout only for text, a symbol
/// or a childless filled box with positive authored dimensions in points.
fn readout(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
    use exact_kernel::{style::RowValue, Dimension, NodeType, StyleId, StyleProps, StyleValue};
    let Node::Element {
        tag,
        attrs,
        positional,
        children,
        ..
    } = node
    else {
        return false;
    };
    if !shown(node, styles) || matches!(part(node), Part::Hidden | Part::Doubt) {
        return false;
    }
    if tag == "text" || tag == "time" {
        return match positional.first() {
            Some(Expr::Str(text, _)) => !text.is_empty(),
            Some(Expr::Template(parts, _))
                if parts.iter().all(|p| matches!(p, TemplatePart::Text(_))) =>
            {
                parts
                    .iter()
                    .any(|p| matches!(p, TemplatePart::Text(text) if !text.is_empty()))
            }
            None => children.iter().any(|child| readout(child, styles)),
            _ => false,
        };
    }
    if tag == "image" {
        return match positional.first() {
            Some(Expr::Str(source, _)) => source.strip_prefix("symbol:").is_some_and(|name| {
                !exact_kernel::apple_symbol_name(name).is_empty()
                    || crate::icons::named(name)
                        .is_some_and(|icon| !icon.sf.is_empty() || !icon.path.is_empty())
            }),
            _ => false,
        };
    }
    if !children.is_empty() {
        return children.iter().any(|child| readout(child, styles));
    }
    if !crate::tags::tag(tag).is_some_and(|t| t.node_type == NodeType::View) {
        return false;
    }
    let class = crate::class::rows(attrs, &|name| {
        styles
            .iter()
            .find(|s| s.name == name)
            .map(|s| s.attrs.as_slice())
    })
    .ok()
    .flatten()
    .map(|(_, rows)| rows)
    .unwrap_or_default();
    let mut dot = [false; 3];
    for attr in class.iter().chain(attrs) {
        for row in crate::tags::rows(attr) {
            let index = match row {
                StyleId::Width => 0,
                StyleId::Height => 1,
                StyleId::BackgroundColor => 2,
                _ => continue,
            };
            let value = match &attr.value {
                Expr::Str(text, _) => Some(StyleValue::Text(text.as_str().into())),
                Expr::Number(n, _) => Some(StyleValue::Number(*n)),
                _ => None,
            };
            dot[index] = value.is_some_and(|value| {
                let mut probe = StyleProps::default();
                !value.unsets(row) && probe.set_dynamic(row, &value).is_ok()
                    && (index == 2 || matches!(probe.get(row), RowValue::Dimension(Dimension::Points(n)) if n > 0.0))
            });
        }
    }
    dot.into_iter().all(|part| part)
}

/// Read paint through lowering's class expansion and the kernel's row parser.
/// Computed paint may fill the box; a literal unset cannot.
fn filled(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
    let Node::Element { attrs, .. } = node else {
        return false;
    };
    let class = crate::class::rows(attrs, &|name| {
        styles
            .iter()
            .find(|s| s.name == name)
            .map(|s| s.attrs.as_slice())
    })
    .ok()
    .flatten()
    .map(|(_, rows)| rows)
    .unwrap_or_default();
    let mut paint = [false; 2];
    for attr in class.iter().chain(attrs) {
        for row in crate::tags::rows(attr) {
            let index = match row {
                exact_kernel::StyleId::BackgroundColor => 0,
                exact_kernel::StyleId::BackgroundImage => 1,
                _ => continue,
            };
            paint[index] = match &attr.value {
                Expr::None(_) => false,
                Expr::Str(text, _) => {
                    let value = exact_kernel::StyleValue::Text(text.as_str().into());
                    let mut probe = exact_kernel::StyleProps::default();
                    !value.unsets(row)
                        && probe.set_dynamic(row, &value).is_ok()
                        && match probe.get(row) {
                            exact_kernel::style::RowValue::BackgroundImage(image) => {
                                !image.layers().is_empty()
                            }
                            _ => true,
                        }
                }
                _ => true,
            };
        }
    }
    paint.into_iter().any(|p| p)
}

/// Paint alone does not make an unsupported title child an avatar.
pub(super) fn avatar(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
    fn contents(node: &Node, seen: &mut bool) -> bool {
        kids(node).iter().all(|child| match (part(child), child) {
            (Part::Hidden, _) => true,
            (Part::Doubt | Part::Text, _) => {
                *seen = true;
                true
            }
            (Part::Box, _) => contents(child, seen),
            (
                Part::Other,
                Node::Element {
                    tag, positional, ..
                },
            ) if tag == "image" => {
                let symbol = match positional.first() {
                    Some(Expr::Str(s, _)) => s.starts_with("symbol:"),
                    Some(_) => true,
                    None => false,
                };
                *seen |= symbol;
                symbol
            }
            _ => false,
        })
    }
    let mut seen = false;
    filled(node, styles) && contents(node, &mut seen) && seen
}

/// A passive box of texts and symbol images, one of each at least: a
/// subtitle's line of glyphs (Signal's "🔕 Muted ⏱ 1w").
pub(super) fn glyph_line(node: &Node, styles: &[contract_syntax::StyleDecl]) -> bool {
    let (mut symbol, mut text) = (false, false);
    for k in kids(node) {
        match (part(k), k) {
            (Part::Text, _) => text = true,
            (
                Part::Other,
                Node::Element {
                    tag, positional, ..
                },
            ) if tag == "image" => match positional.first() {
                // A computed source may be a symbol: the benefit.
                Some(Expr::Str(s, _)) if !s.starts_with("symbol:") => return false,
                Some(_) => symbol = true,
                None => return false,
            },
            (Part::Hidden, _) => {}
            _ => return false,
        }
    }
    symbol && text && !filled(node, styles)
}
