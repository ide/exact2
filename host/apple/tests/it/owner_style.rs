//! A content owner's container units (LLP 1123 D12) in a native style: the
//! presenter is sent them resolved by the owner, as layout resolves them,
//! not by the window.

use crate::host::{view, NoData};
use exact_apple::{Claims, Host};
use exact_kernel::{MonospaceMeasurer, OwnerValues};

const PAGE: &str = r##"component App
  view
    column testId="owner" width="100%" height="100%"
      box testId="box" width=40 min-height="10cqh"
"##;

/// The style the batch last sends `id`.
fn style_of(batch: &str, id: u32) -> serde_json::Value {
    let batch: serde_json::Value = serde_json::from_str(batch).unwrap();
    let ops = batch["ops"].as_array().unwrap();
    let op = ops
        .iter()
        .rev()
        .find(|o| o["op"] == "style" && o["id"] == id);
    op.map_or(serde_json::Value::Null, |o| o["style"].clone())
}

#[test]
fn an_owners_container_unit_reaches_the_presenter_as_the_owner_resolves_it() {
    let plan = contract::compile(PAGE).unwrap();
    let measurer = Box::new(MonospaceMeasurer::default());
    let (mut host, _) = Host::boot(&plan.encode(), NoData, measurer, 800.0, 600.0).unwrap();
    let (owner, boxed) = (view(&host, "owner"), view(&host, "box"));
    let values = OwnerValues {
        safe: [0.0; 4],
        regions: None,
        cols: 1,
        rows: 1,
        segments: vec![],
        size: (400.0, 300.0),
    };
    let batch = host.set_claims(&Claims {
        owners: &[(owner, Some(values))],
        ..Claims::default()
    });
    assert_eq!(
        style_of(&batch, boxed)["min_height"],
        30.0,
        "the owner's 300, not the window's 600"
    );
}
