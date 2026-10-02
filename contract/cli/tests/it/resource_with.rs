//! @ref LLP 1027 D4 — `resource r = source(args) with values`: the call's
//! arguments say what the answer is, `with` how it is asked.

const SRC: &str = r#"component App
  state car = "a"
  state rev = 0
  resource status = status(car) with rev, rev + 1 as shape number
  resource plain = other(car, rev) as shape number
  view
    column
      text `${status} ${plain}`
"#;

#[test]
fn with_values_follow_the_call_and_only_the_call_identifies() {
    let plan = contract::compile(SRC).unwrap_or_else(|e| panic!("{e}"));
    let row = |name: &str| {
        plan.resources
            .iter()
            .find(|r| plan.str(r.name) == name)
            .unwrap_or_else(|| panic!("no resource {name}"))
    };
    let status = row("status");
    assert_eq!(
        status.args.len, 3,
        "the source gets the call's argument, then both values"
    );
    assert_eq!(status.identity, 1);
    let plain = row("plain");
    assert_eq!(
        plain.identity, plain.args.len as u16,
        "without `with`, every argument"
    );
}

#[test]
fn the_formatter_keeps_with() {
    let formatted = contract_syntax::fmt::format(SRC).unwrap();
    assert!(
        formatted.contains("status(car) with rev, rev + 1 as shape number"),
        "{formatted}"
    );
}
