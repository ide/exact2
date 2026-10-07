//! LLP 1069.011: a flex button's content axis and gap, sent in its style
//! dictionary (`button_content_direction`, `button_content_gap`) for UIKit's
//! own symbol-and-title pairing, and sent again when either changes.

use exact_apple::Host;
use exact_kernel::MonospaceMeasurer;
use exact_runner::{DataError, DataSource, Event, Value};

struct NoData;
impl DataSource for NoData {
    fn query(&mut self, s: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(s.into()))
    }
}

fn boot(src: &str) -> (Host<NoData>, String) {
    let plan = contract::bake(contract::compile(src).unwrap(), NoData).unwrap();
    Host::boot(&plan.encode(), NoData, Box::new(MonospaceMeasurer::default()), 402.0, 874.0).unwrap()
}

fn view(host: &Host<NoData>, test_id: &str) -> u32 {
    let k = host.runner().kernel();
    k.node_by_key(k.find_by_test_id(test_id)[0]).unwrap().id
}

/// The last op of `kind` for `id`, up to the next op, as JSON text.
fn last_op<'a>(batch: &'a str, kind: &str, id: u32) -> Option<&'a str> {
    let at = batch.rfind(&format!("\"op\":\"{kind}\",\"id\":{id},"))?;
    let rest = &batch[at..];
    let end = rest[1..].find("\"op\":").map_or(rest.len(), |n| n + 1);
    Some(&rest[..end])
}

#[test]
fn a_flex_button_sends_its_content_axis_and_gap() {
    let (mut host, first) = boot(
        r#"component App
  state down = true
  action turn
    down = not down
  view
    column
      button testId="stacked" press=turn display="flex" flex-direction=(down ? "column" : "row") row-gap=4 column-gap=6
        image "symbol:sf/lock.fill"
        text "Lock"
      button testId="auto" press=turn display="flex" flex-direction="row"
        image "symbol:sf/map.fill"
        text "Last Parked"
      button testId="plain" press=turn
        text "Plain"
"#,
    );
    let (stacked, auto, plain) = (view(&host, "stacked"), view(&host, "auto"), view(&host, "plain"));
    let create = last_op(&first, "create", stacked).unwrap();
    assert!(create.contains("\"button_content_direction\":\"column\""), "{create}");
    assert!(create.contains("\"button_content_gap\":4"), "{create}");
    // No gap written: the padding is the platform's, so none is sent.
    let create = last_op(&first, "create", auto).unwrap();
    assert!(create.contains("\"button_content_direction\":\"row\""), "{create}");
    assert!(!create.contains("button_content_gap"), "{create}");
    let create = last_op(&first, "create", plain).unwrap();
    assert!(!create.contains("button_content"), "not a flex box: {create}");
    let after = host.dispatch_at(stacked, Event::Press, 0.0);
    let style = last_op(&after, "style", stacked).unwrap();
    assert!(style.contains("\"button_content_direction\":\"row\""), "{style}");
    assert!(style.contains("\"button_content_gap\":6"), "{style}");
}
