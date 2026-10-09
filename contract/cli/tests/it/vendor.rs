//! Exact's vendor properties (`-exact-…`, CSS's prefix convention): a
//! platform's own vocabulary, which only that platform's host reads.

use exact_kernel::generated::{ExactAppleButtonSize, ExactAppleButtonStyle};

#[test]
fn an_apple_button_style_is_a_vendor_property_and_a_negation_is_not() {
    let src = r#"component App
  state n = 1
  view
    column
      button -exact-apple-button-style="glass" -exact-apple-button-size="small" testId="lock"
        text "Lock"
      text `${-n}` testId="neg"
"#;
    let plan = contract::compile(src).unwrap_or_else(|e| panic!("{e}"));
    let runner = exact_runner::Runner::boot(
        plan,
        NoData,
        exact_kernel::Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    let key = runner.kernel().find_by_test_id("lock")[0];
    let node = runner.kernel().node_by_key(key).unwrap();
    assert_eq!(
        node.style.exact_apple_button_style,
        ExactAppleButtonStyle::Glass
    );
    assert_eq!(
        node.style.exact_apple_button_size,
        ExactAppleButtonSize::Small
    );
}

struct NoData;
impl exact_runner::DataSource for NoData {
    fn query(
        &mut self,
        source: &str,
        _args: &[exact_runner::Value],
    ) -> Result<exact_runner::Value, exact_runner::DataError> {
        Err(exact_runner::DataError::UnknownSource(source.to_string()))
    }
}
