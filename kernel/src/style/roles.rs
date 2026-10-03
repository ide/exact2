//! Colours that name a platform colour (LLP 1081): a role from the schema's
//! table (D2), or `platform-color()` (D3). Each carries a fallback pair, so
//! the kernel and any host without the platform's colour always have a
//! deterministic RGBA; a host that has it resolves the name per view.

use super::{Color, ColorValue};
use crate::generated::{ColorRole, COLOR_ROLES};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, RwLock};

/// The role a keyword names: CSS's system colours in any ASCII case, Exact's
/// roles, WebKit's `-apple-system-*` names for them, and the web form a role
/// is written as (`var(--exact-<role>, …)`), so canonical CSS reads back.
pub fn role(text: &str) -> Option<u8> {
    let text = text.trim();
    let name = match text.strip_prefix("var(--exact-") {
        Some(rest) => &rest[..rest.find([',', ')'])?],
        None => text,
    };
    COLOR_ROLES
        .iter()
        .position(|r| {
            r.name.eq_ignore_ascii_case(name)
                || (!r.alias.is_empty() && r.alias.eq_ignore_ascii_case(name))
        })
        .and_then(|i| u8::try_from(i).ok())
}

/// A role by id.
pub fn role_of(id: u8) -> &'static ColorRole {
    &COLOR_ROLES[usize::from(id) % COLOR_ROLES.len()]
}

/// Whether a role is one of CSS's system colours (the web writes it as is).
pub fn is_css_system(role: &ColorRole) -> bool {
    role.name.starts_with(|c: char| c.is_ascii_uppercase())
}

/// A role's fallback: its light and dark values.
pub fn role_fallback(id: u8) -> ColorValue {
    let r = role_of(id);
    ColorValue::LightDark(Color(r.light), Color(r.dark))
}

/// One `platform-color()`: a native name per platform, and the fallback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformColor {
    /// `UIColor`'s class property, or `named:<Asset>`.
    pub ios: Option<Box<str>>,
    /// `NSColor`'s class property, or `named:<Asset>`.
    pub macos: Option<Box<str>>,
    /// A CSS colour for the web.
    pub web: Option<Box<str>>,
    /// What every other host shows: a colour or a `light-dark()` pair.
    pub fallback: ColorValue,
    /// The function as written, canonical: what the wire carries.
    pub text: Box<str>,
}

/// What a host reported each reference resolves to (LLP 1081 D1), by
/// reference and appearance: a host with the platform's colours resolves
/// every reference under the traits it is showing (style, Increased
/// Contrast) and reports the whole set again whenever they change, so what
/// the kernel resolves itself — paint motion, gradients, SVG scenes and
/// filters — is the platform's colour, not a snapshot of the fallback. A
/// host that reports nothing (Linux, headless) keeps the fallback pair.
/// One platform per process, so one table.
static REPORTED: RwLock<BTreeMap<(u8, u16, bool), Color>> = RwLock::new(BTreeMap::new());

fn reference_key(c: ColorValue) -> Option<(u8, u16)> {
    match c {
        ColorValue::Role(id) => Some((0, u16::from(id))),
        ColorValue::Platform(id) => Some((1, id)),
        _ => None,
    }
}

/// The colour a host reported for a reference under an appearance.
pub fn reported(c: ColorValue, dark: bool) -> Option<Color> {
    let (kind, id) = reference_key(c)?;
    REPORTED.read().ok()?.get(&(kind, id, dark)).copied()
}

/// Replace every reported resolution with `entries` (a reference, an
/// appearance, its colour); `true` when anything resolves differently.
pub fn set_reported(entries: impl IntoIterator<Item = (ColorValue, bool, Color)>) -> bool {
    let next: BTreeMap<(u8, u16, bool), Color> = entries
        .into_iter()
        .filter_map(|(c, dark, color)| reference_key(c).map(|(k, id)| ((k, id, dark), color)))
        .collect();
    let Ok(mut table) = REPORTED.write() else {
        return false;
    };
    let changed = *table != next;
    *table = next;
    changed
}

/// Every reference a host may resolve, with its native name on this
/// platform: each role, then each interned `platform-color()` that names one.
pub fn references(macos: bool) -> Vec<(ColorValue, Box<str>)> {
    let mut out: Vec<(ColorValue, Box<str>)> = COLOR_ROLES
        .iter()
        .enumerate()
        .filter_map(|(i, r)| {
            let name = if macos { r.macos } else { r.ios };
            let id = u8::try_from(i).ok()?;
            (!name.is_empty()).then(|| (ColorValue::Role(id), name.into()))
        })
        .collect();
    if let Ok(table) = PLATFORM.lock() {
        for (i, p) in table.iter().enumerate() {
            let name = if macos {
                p.macos.clone()
            } else {
                p.ios.clone()
            };
            if let (Some(name), Ok(id)) = (name, u16::try_from(i)) {
                out.push((ColorValue::Platform(id), name));
            }
        }
    }
    out
}

/// Interned `platform-color()`s. A plan names a few; the cap keeps a data
/// source that writes one (Contract refuses it, the runtime only bounds it)
/// from growing the table without end.
static PLATFORM: Mutex<Vec<Arc<PlatformColor>>> = Mutex::new(Vec::new());
const PLATFORM_CAP: usize = 1024;

/// A `platform-color()` by id.
pub fn platform(id: u16) -> Option<Arc<PlatformColor>> {
    PLATFORM.lock().ok()?.get(usize::from(id)).cloned()
}

/// Whether a native name is one a host may look up: a class colour property
/// (`[a-z][A-Za-z0-9]*Color`, so never a private `_` selector, `new` or
/// `alloc`), or an asset catalogue colour.
pub fn native_name_ok(name: &str) -> bool {
    if let Some(asset) = name.strip_prefix("named:") {
        return !asset.is_empty()
            && asset
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_-./ ".contains(c));
    }
    name.len() > 5
        && name.ends_with("Color")
        && name.starts_with(|c: char| c.is_ascii_lowercase())
        && name.chars().all(|c| c.is_ascii_alphanumeric())
}

/// `platform-color(<platform> <name>, …, <fallback>)` (LLP 1081 D3), interned.
/// The fallback is a colour or a `light-dark()` pair, never a reference.
pub fn parse_platform(text: &str) -> Option<ColorValue> {
    let inner = text
        .trim()
        .strip_prefix("platform-color(")?
        .strip_suffix(')')?;
    let mut parts = Vec::new();
    let (mut depth, mut start) = (0i32, 0);
    for (i, c) in inner.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => {
                parts.push(inner[start..i].trim());
                start = i + 1;
            }
            _ => {}
        }
    }
    parts.push(inner[start..].trim());
    let fallback_text = parts.pop()?;
    let fallback = super::ColorValue::parse_pair(fallback_text)
        .or_else(|| Color::parse(fallback_text).map(ColorValue::Fixed))?;
    let (mut ios, mut macos, mut web) = (None, None, None);
    for part in &parts {
        let (platform, name) = part.split_once(char::is_whitespace)?;
        let name = name.trim();
        let slot = match platform {
            "ios" if native_name_ok(name) => &mut ios,
            "macos" if native_name_ok(name) => &mut macos,
            "web" if !name.is_empty() && !name.contains(['{', '}', ';']) => &mut web,
            _ => return None,
        };
        if slot.replace(Box::<str>::from(name)).is_some() {
            return None;
        }
    }
    let mut canonical = String::from("platform-color(");
    for (platform, name) in [("ios", &ios), ("macos", &macos), ("web", &web)] {
        if let Some(n) = name {
            canonical.push_str(platform);
            canonical.push(' ');
            canonical.push_str(n);
            canonical.push_str(", ");
        }
    }
    crate::gradient::color_css(&mut canonical, fallback);
    canonical.push(')');
    let mut table = PLATFORM.lock().ok()?;
    if let Some(i) = table.iter().position(|p| *p.text == *canonical) {
        return Some(ColorValue::Platform(u16::try_from(i).ok()?));
    }
    if table.len() >= PLATFORM_CAP {
        return Some(fallback);
    }
    table.push(Arc::new(PlatformColor {
        ios,
        macos,
        web,
        fallback,
        text: canonical.into(),
    }));
    Some(ColorValue::Platform(u16::try_from(table.len() - 1).ok()?))
}

/// A reference's CSS for the browser and for canonical text: a CSS system
/// colour as is; an Exact role as `var(--exact-<role>, <fallback>)`, which a
/// page's sheet may define (WebKit's own dynamic colour) and which reads
/// back as the role; a
/// `platform-color()` as its web colour, else its fallback.
pub(crate) fn reference_css(out: &mut String, c: ColorValue) {
    match c {
        ColorValue::Role(id) => {
            let r = role_of(id);
            if is_css_system(r) {
                out.push_str(r.name);
            } else {
                out.push_str("var(--exact-");
                out.push_str(r.name);
                out.push_str(", ");
                crate::gradient::color_css(out, role_fallback(id));
                out.push(')');
            }
        }
        ColorValue::Platform(id) => match platform(id) {
            Some(p) => match &p.web {
                Some(web) => out.push_str(web),
                None => crate::gradient::color_css(out, p.fallback),
            },
            None => out.push_str("transparent"),
        },
        other => crate::gradient::color_css(out, other),
    }
}

impl ColorValue {
    /// A role's WebKit name (`-apple-system-label`), when it has one: what an
    /// Apple host draws vibrantly inside a material (LLP 1077 D13).
    pub fn system_name(self) -> Option<&'static str> {
        match self {
            ColorValue::Role(id) => {
                let alias = role_of(id).alias;
                (!alias.is_empty()).then_some(alias)
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reported_resolution_replaces_the_fallback_until_withdrawn() {
        // A name no other test reports: the table is process-wide.
        let c = ColorValue::parse_light_dark(
            "platform-color(ios rolesTestReportColor, light-dark(#010203, #040506))",
        )
        .unwrap();
        assert_eq!(c.resolve(true), Color(0x0405_06ff));
        assert!(references(false)
            .iter()
            .any(|(r, name)| *r == c && &**name == "rolesTestReportColor"));
        assert!(set_reported([(c, true, Color(0xff00_00ff))]));
        assert_eq!(c.resolve(true), Color(0xff00_00ff));
        assert_eq!(
            c.resolve(false),
            Color(0x0102_03ff),
            "light was not reported"
        );
        assert!(!set_reported([(c, true, Color(0xff00_00ff))]), "unchanged");
        assert!(set_reported([]));
        assert_eq!(c.resolve(true), Color(0x0405_06ff));
    }

    #[test]
    fn roles_answer_to_css_and_webkit_names_and_their_own_css() {
        let id = role("secondary-label").unwrap();
        assert_eq!(role("-apple-system-secondary-label"), Some(id));
        assert_eq!(
            role("var(--exact-secondary-label, light-dark(#3c3c4399, #ebebf599))"),
            Some(id)
        );
        assert_eq!(role("canvastext"), role("CanvasText"));
        assert!(role("ButtonBorder").is_none() && role("secondary_label").is_none());
        assert_eq!(
            role_fallback(id),
            ColorValue::LightDark(Color(0x3c3c_4399), Color(0xebeb_f599))
        );
        let mut css = String::new();
        reference_css(&mut css, ColorValue::Role(id));
        assert_eq!(
            ColorValue::parse_light_dark(&css),
            Some(ColorValue::Role(id))
        );
        css.clear();
        reference_css(&mut css, ColorValue::Role(role("LinkText").unwrap()));
        assert_eq!(css, "LinkText");
    }

    #[test]
    fn a_platform_color_is_interned_with_a_required_fallback() {
        let a = parse_platform("platform-color(ios systemMintColor, macos systemMintColor, light-dark(#00c7be, #63e6e2))").unwrap();
        let b = parse_platform(
            "platform-color(macos systemMintColor,ios systemMintColor,light-dark(#00c7be,#63e6e2))",
        )
        .unwrap();
        assert_eq!(a, b, "one canonical form, one id");
        let ColorValue::Platform(id) = a else {
            panic!("{a:?}")
        };
        let p = platform(id).unwrap();
        assert_eq!(p.ios.as_deref(), Some("systemMintColor"));
        assert_eq!(a.resolve(true), Color(0x63e6_e2ff));
        assert!(
            parse_platform("platform-color(ios systemMintColor)").is_none(),
            "no fallback"
        );
        assert!(parse_platform("platform-color(ios _privateColor, #000)").is_none());
        assert!(parse_platform("platform-color(ios new, #000)").is_none());
        assert!(
            parse_platform("platform-color(ios labelColor, label)").is_none(),
            "a reference is no fallback"
        );
        assert!(parse_platform("platform-color(android x, #000)").is_none());
        assert!(parse_platform("platform-color(ios named:Brand, #c8102e)").is_some());
    }

    #[test]
    fn references_cross_the_wire_as_what_they_name() {
        use crate::wire::codec::{Reader, Writer};
        for text in [
            "secondary-label",
            "Canvas",
            "platform-color(ios systemTealColor, light-dark(#30b0c7, #40c8e0))",
        ] {
            let c = ColorValue::parse_light_dark(text).unwrap();
            let mut w = Writer::new();
            w.color_value(c);
            let bytes = w.into_vec();
            assert_eq!(Reader::new(&bytes).color_value().unwrap(), c, "{text}");
        }
    }
}
