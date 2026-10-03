//! LLP 1078 D1, D6 on the Apple host: what the kernel resolves itself — a
//! gradient's stops, an SVG scene's paint, paint motion's endpoints —
//! follows the presenter's report, and a new report re-presents it.
use super::*;
use exact_kernel::style::{roles, Color, ColorValue};
use exact_kernel::MonospaceMeasurer;
use exact_plan::Value;
use exact_runner::DataError;

#[derive(Clone, Default)]
struct NoData;
impl DataSource for NoData {
    fn query(&mut self, source: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(source.into()))
    }
}

// A name no other test reports: the table is process-wide.
const BRAND: &str = "platform-color(ios colorsTestBrandColor, macos colorsTestBrandColor, light-dark(#102030, #405060))";

fn app() -> String {
    format!(
        "component A\n  view\n    column\n      box testId=\"wash\" width=20 height=20 background-image=\"linear-gradient({BRAND}, #ffffff)\"\n      svg width=10 height=10 viewBox=\"0 0 10 10\"\n        circle cx=5 cy=5 r=5 fill=\"{BRAND}\"\n      text \"hi\" color=\"{BRAND}\" transition=\"color 300ms linear\"\n"
    )
}

fn ops(batch: &str) -> Vec<serde_json::Value> {
    let v: serde_json::Value = serde_json::from_str(batch).unwrap();
    v["ops"].as_array().cloned().unwrap_or_default()
}

fn brand() -> ColorValue {
    roles::references(cfg!(target_os = "macos"))
        .into_iter()
        .find(|(_, name)| &**name == "colorsTestBrandColor")
        .map(|(c, _)| c)
        .expect("the plan interned it")
}

#[test]
fn a_report_re_presents_what_the_kernel_resolved() {
    let plan = contract::compile(&app()).unwrap().encode();
    let (mut host, boot) = Host::boot(
        &plan,
        NoData,
        Box::new(MonospaceMeasurer::default()),
        390.0,
        844.0,
    )
    .unwrap();
    // Before any report: the fallback pair, light.
    assert!(boot.contains("16,32,48"), "the gradient's fallback stop");
    host.set_scheme(false);
    let c = brand();
    assert_eq!(c.resolve(false), Color(0x1020_30ff));
    // The platform says the brand is red in light and green in dark.
    let (red, green) = (Color(0xff00_00ff), Color(0x00ff_00ff));
    let batch = host.set_colors(vec![(c, false, red), (c, true, green)]);
    assert_eq!(c.resolve(false), red);
    assert_eq!(c.resolve(true), green);
    let ops = ops(&batch);
    let restyled = ops
        .iter()
        .find(|op| op["op"] == "style" && op["style"].get("background_image").is_some())
        .expect("the gradient's box is restyled");
    let stops = restyled["style"]["background_image"]["stops"].to_string();
    assert!(stops.starts_with("[0,255,0,0,255"), "{stops}");
    let dark = restyled["style"]["background_image"]["dark"].to_string();
    assert!(dark.starts_with("[0,0,255,0,255"), "{dark}");
    let scene = ops
        .iter()
        .find(|op| op["op"] == "svg")
        .expect("the scene is rebuilt");
    assert!(
        scene["scene"]
            .to_string()
            .contains("[[255,0,0,255],[0,255,0,255]]"),
        "{}",
        scene["scene"]
    );
    // The text's colour transitions toward the reported one (LLP 1078 D6).
    let v: serde_json::Value = serde_json::from_str(&batch).unwrap();
    assert_eq!(v["motion"], true, "a transition runs");
    // The same report again changes nothing and sends nothing.
    let again = host.set_colors(vec![(c, false, red), (c, true, green)]);
    assert!(ops_of(&again).is_empty(), "{again}");
    // No report: the fallback pair again.
    host.set_colors(Vec::new());
    assert_eq!(c.resolve(false), Color(0x1020_30ff));
}

fn ops_of(batch: &str) -> Vec<serde_json::Value> {
    ops(batch)
}
