//! A presentation value the batch that creates its view sets and then puts
//! back: the presenter hears both, in order.
use super::*;
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

const APP: &str = r##"component A
  state width = 0
  action measured(w: number, h: number)
    width = w
  view
    column width=200 height=60
      box resize=measured height=60
      box testId="faded" width=60 height=60 opacity=(width > 0 ? 1 : 0)
"##;

/// A box's opacity bound to state its sibling's `resize` handler sets: the
/// boot batch creates it at 0, and the resize round's commit in the same
/// batch puts it back at 1, its identity, which the presenter must hear,
/// since it last heard 0 (Exact Chat's balloons hid their first frame so).
#[test]
fn an_opacity_put_back_in_the_batch_that_creates_its_view_is_presented() {
    let plan = contract::compile(APP).unwrap().encode();
    let (host, boot) = Host::boot(
        &plan,
        NoData,
        Box::new(MonospaceMeasurer::default()),
        390.0,
        844.0,
    )
    .unwrap();
    let k = host.runner.kernel();
    let faded = k.node_by_key(k.find_by_test_id("faded")[0]).unwrap().id;
    let v: serde_json::Value = serde_json::from_str(&boot).unwrap();
    let opacity: Vec<f64> = v["ops"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|op| op["op"] == "present" && op["id"] == faded && op["property"] == "opacity")
        .map(|op| op["x"].as_f64().unwrap())
        .collect();
    assert_eq!(opacity, [0.0, 1.0], "{boot}");
}
