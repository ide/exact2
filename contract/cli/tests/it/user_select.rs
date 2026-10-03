//! CSS UI 4 §6.1 `user-select`: the five keywords, not inherited, the
//! `-webkit-user-select` alias UAs must take, and the UA sheet's
//! `button, select { user-select: none }`, which an author's value overrides.

use exact_kernel::{Kernel, UserSelect};
use exact_runner::{DataError, DataSource, Runner, Value};

struct NoData;

impl DataSource for NoData {
    fn query(&mut self, source: &str, _args: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(source.to_string()))
    }
}

fn boot(body: &str) -> Runner<NoData> {
    let body = body
        .lines()
        .map(|l| format!("      {l}\n"))
        .collect::<String>();
    let src = format!(
        "component App\n  state n = 0\n  action go\n    n = n + 1\n  view\n    column\n{body}"
    );
    Runner::boot(
        contract::compile(&src).unwrap_or_else(|e| panic!("{e}")),
        NoData,
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap()
}

fn used(r: &Runner<NoData>, test_id: &str) -> UserSelect {
    let key = r.kernel().find_by_test_id(test_id)[0];
    r.kernel().node_by_key(key).unwrap().style.user_select
}

#[test]
fn every_keyword_lowers_and_the_initial_value_is_auto() {
    let r = boot(
        "text \"a\" testId=\"auto\"\ntext \"b\" user-select=\"text\" testId=\"text\"\ntext \"c\" user-select=\"none\" testId=\"none\"\ncolumn user-select=\"contain\" testId=\"contain\"\n  text \"d\" testId=\"inner\"\ntext \"e\" user-select=\"all\" testId=\"all\"",
    );
    assert_eq!(used(&r, "auto"), UserSelect::Auto);
    assert_eq!(used(&r, "text"), UserSelect::Text);
    assert_eq!(used(&r, "none"), UserSelect::None);
    assert_eq!(used(&r, "contain"), UserSelect::Contain);
    assert_eq!(used(&r, "all"), UserSelect::All);
    assert_eq!(used(&r, "inner"), UserSelect::Auto, "not inherited");
}

#[test]
fn the_webkit_spelling_is_an_alias() {
    let r = boot("text \"a\" -webkit-user-select=\"all\" testId=\"a\"\ntext \"b\" -webkit-user-select=\"none\" testId=\"b\"");
    assert_eq!(used(&r, "a"), UserSelect::All);
    assert_eq!(used(&r, "b"), UserSelect::None);
}

#[test]
fn buttons_and_selects_are_none_unless_the_author_says() {
    let r = boot(
        "button press=go testId=\"button\"\n  text \"Go\"\nbutton press=go user-select=\"text\" testId=\"selectable\"\n  text \"Go\"\nbutton appearance=\"auto\" press=go testId=\"native\"\n  text \"Go\"\nselect testId=\"select\" aria-label=\"Pick\"\n  option \"One\"\ncolumn testId=\"column\"",
    );
    assert_eq!(used(&r, "button"), UserSelect::None);
    assert_eq!(
        used(&r, "selectable"),
        UserSelect::Text,
        "the UA sheet yields to the author"
    );
    assert_eq!(used(&r, "native"), UserSelect::None);
    assert_eq!(used(&r, "select"), UserSelect::None);
    assert_eq!(used(&r, "column"), UserSelect::Auto);
}

#[test]
fn an_unknown_keyword_is_refused() {
    let src = "component App\n  view\n    text \"a\" user-select=\"element\"\n";
    assert!(contract::compile(src).is_err());
}

#[test]
fn a_lists_copy_leaves_out_what_is_none_and_keeps_offsets() {
    struct Rows;
    impl DataSource for Rows {
        fn query(&mut self, _: &str, _: &[Value]) -> Result<Value, DataError> {
            Ok(Value::list(vec![Value::Number(1.0), Value::Number(2.0)]))
        }
    }
    let source = "component App\n  resource rows = rows() as shape list<number>\n  view\n    list virtualized=true estimated-item-height=20 height=200 testId=\"list\"\n      each x in rows key=x\n        column\n          text `Row ${x}`\n          text \"badge\" user-select=\"none\"\n          column user-select=\"none\"\n            text \"hidden\"\n            text `id ${x}` user-select=\"text\"\n";
    let runner = Runner::boot(
        contract::compile(source).unwrap_or_else(|e| panic!("{e}")),
        Rows,
        Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    let view = runner
        .kernel()
        .node_by_key(runner.kernel().find_by_test_id("list")[0])
        .unwrap()
        .id;
    assert_eq!(
        runner.list_text(view, None).unwrap(),
        "Row 1\n\nid 1\n\nRow 2\n\nid 2",
        "none paragraphs are cut; a selectable one inside none is kept"
    );
}
