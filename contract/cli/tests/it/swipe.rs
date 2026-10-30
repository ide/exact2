//! LLP 1057.001 §8: `swipe=action` with `swipe-direction` and `touch-count`.
//! Lowering checks the literals and the three together; the runner hands
//! the action the direction the host recognized, and drops one the node no
//! longer names.
use exact_kernel::{Kernel, PropId, PropValue};
use exact_plan::Value;
use exact_runner::{DataError, DataSource, Event, Runner};

struct NoData;
impl DataSource for NoData {
    fn query(&mut self, source: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(source.into()))
    }
}

fn node(attrs: &str) -> String {
    format!("component App\n  action go\n    focus(\"x\")\n  view\n    column\n      box {attrs} width=40 height=40 testId=\"it\"\n")
}

#[test]
fn a_swipes_literals_are_checked_and_kept_lowercase() {
    let plan = contract::compile(&node(
        "swipe=go swipe-direction=\"Down  left\" touch-count=2",
    ))
    .unwrap();
    let r = Runner::boot(
        plan,
        NoData,
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    let k = r.kernel();
    let it = k.node_by_key(k.find_by_test_id("it")[0]).unwrap();
    assert_eq!(it.props.str(PropId::SwipeDirection), Some("down left"));
    assert!(
        matches!(it.props.get(PropId::TouchCount), Some(PropValue::Int(2))),
        "{:?}",
        it.props.get(PropId::TouchCount)
    );
    for (attrs, id) in [
        (
            "swipe=go swipe-direction=\"sideways\"",
            "lower-swipe-direction",
        ),
        ("swipe=go swipe-direction=\"\"", "lower-swipe-direction"),
        ("swipe=go", "lower-swipe-direction"),
        (
            "swipe=go swipe-direction=\"down\" touch-count=0",
            "lower-swipe-count",
        ),
        (
            "swipe=go swipe-direction=\"down\" touch-count=1.5",
            "lower-swipe-count",
        ),
        (
            "swipe=go swipe-direction=\"down\" touch-count=\"2\"",
            "lower-swipe-count",
        ),
        ("swipe-direction=\"down\"", "lower-swipe-unused"),
        ("touch-count=2", "lower-swipe-unused"),
        (
            "swiperight=go swipe=go swipe-direction=\"right up\"",
            "lower-swipe-twice",
        ),
        (
            "swiperight=go swipe=go swipe-direction=\"right\" touch-count=1",
            "lower-swipe-twice",
        ),
    ] {
        let error = contract::compile(&node(attrs)).expect_err(attrs);
        assert_eq!(error.id, id, "{attrs}: {error:?}");
    }
    // Another count recognizes another contact, and another direction another swipe
    for attrs in [
        "swiperight=go swipe=go swipe-direction=\"right\" touch-count=2",
        "swiperight=go swipe=go swipe-direction=\"left down\"",
    ] {
        contract::compile(&node(attrs)).expect(attrs);
    }
}

#[test]
fn the_action_takes_the_direction_and_a_direction_no_longer_named_is_dropped() {
    let plan = contract::compile(
        "component App
  state seen = \"\"
  state directions = \"down\"
  action went(e: SwipeEvent)
    seen = e.direction
  action widen
    directions = \"down up\"
  view
    column
      box swipe=went swipe-direction=directions width=40 height=40 testId=\"it\"
      text seen testId=\"seen\"
      button \"widen\" press=widen testId=\"widen\"
",
    )
    .unwrap();
    let mut r = Runner::boot(
        plan,
        NoData,
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    let view = |r: &Runner<NoData>, id: &str| {
        let k = r.kernel();
        k.node_by_key(k.find_by_test_id(id)[0]).unwrap().id
    };
    let seen = |r: &Runner<NoData>| {
        let k = r.kernel();
        k.node_by_key(k.find_by_test_id("seen")[0])
            .unwrap()
            .props
            .str(PropId::Text)
            .unwrap_or("")
            .to_owned()
    };
    let it = view(&r, "it");
    r.dispatch(it, Event::Swipe("down".into())).unwrap();
    assert_eq!(seen(&r), "down");
    r.dispatch(it, Event::Swipe("up".into())).unwrap();
    assert_eq!(
        seen(&r),
        "down",
        "up is not named yet: dropped, not an error"
    );
    let widen = view(&r, "widen");
    r.dispatch(widen, Event::Press).unwrap();
    r.dispatch(it, Event::Swipe("up".into())).unwrap();
    assert_eq!(seen(&r), "up");
    assert!(Event::of_host_kind(60, "up").is_ok_and(|e| e == Event::Swipe("up".into())));
    assert!(Event::of_host_kind(60, "diagonal").is_err());
}
