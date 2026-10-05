//! `observe(…)`, `observeAttributes(…)` and `observeError(…)` reach the host as
//! commands, in order, with their arguments. Malformed calls fail to compile.
use exact_runner::{DataError, DataSource, Runner, Value};

const APP: &str = r#"shape Checkout
  items: number
  total: number

shape Tier
  tier: string

component App
  state count = 0
  action checkout(items: number)
    count = count + 1
    observeAttributes(Tier(tier="pro"))
    observe("checkout.completed", Checkout(items=items, total=items * 3), "info")
    observe("checkout.seen")
  action fail
    observeError("cart unavailable", "CartError")
  view
    column
      button press=checkout(2) testId="buy"
        text "Buy"
"#;

struct NoData;
impl DataSource for NoData {
    fn query(&mut self, source: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(source.to_string()))
    }
}

#[test]
fn custom_events_are_commands_in_order() {
    let mut r = Runner::boot(
        contract::compile(APP).unwrap(),
        NoData,
        exact_kernel::Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    r.take_commands();
    r.act("checkout", vec![Value::Number(2.)]).unwrap();
    let names: Vec<_> = r
        .take_commands()
        .into_iter()
        .map(|c| (c.name, c.args.len()))
        .collect();
    assert_eq!(
        names,
        [
            ("observeAttributes".to_string(), 2),
            ("observe".to_string(), 6),
            ("observe".to_string(), 2)
        ]
    );
    r.act("checkout", vec![Value::Number(2.)]).unwrap();
    let observed = r
        .take_commands()
        .into_iter()
        .find(|c| c.name == "observe")
        .unwrap();
    assert_eq!(
        observed.args,
        vec![
            Value::str("checkout.completed"),
            Value::str("info"),
            Value::str("items"),
            Value::Number(2.),
            Value::str("total"),
            Value::Number(6.)
        ],
        "the fields go by name"
    );
    r.act("fail", vec![]).unwrap();
    let error = r.take_commands();
    assert_eq!(
        error[0].args,
        vec![Value::str("cart unavailable"), Value::str("CartError")]
    );
}

#[test]
fn observe_arguments_are_checked() {
    for statement in [
        "observe()",
        "observe(1)",
        r#"observe("a", "b")"#,
        r#"observe("a", Tier(tier="x"), 2)"#,
        r#"observeAttributes("x")"#,
        "observeError(3)",
    ] {
        let source = APP.replace(r#"observe("checkout.seen")"#, statement);
        let refused = contract::compile(&source).expect_err(statement);
        assert!(
            format!("{refused:?}").contains("type-observe"),
            "{statement}: {refused:?}"
        );
    }
}

const SCREEN: &str = r#"component App
  state loaded = false
  action load
    loaded = true
  view
    column aria-busy=(not loaded) testId="forecast"
      button press=load testId="load"
        text "Load"
"#;

/// A mounted `aria-busy` element is outstanding, by test id, until it is no
/// longer busy.
#[test]
fn aria_busy_holds_the_ledger_until_cleared() {
    let mut r = Runner::boot(
        contract::compile(SCREEN).unwrap(),
        NoData,
        exact_kernel::Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    assert_eq!(
        r.outstanding().busy,
        vec!["forecast".to_string()],
        "busy at boot"
    );
    assert!(!r.outstanding().is_clear());
    r.act("load", vec![]).unwrap();
    assert!(r.outstanding().busy.is_empty(), "not busy once loaded");
    assert!(r.outstanding().is_clear());
}
