//! What the settle ledger (`Runner::outstanding`) counts as still loading, which
//! time to interactive waits for.
use exact_runner::{DataError, DataSource, Runner, Value};

struct NoData;
impl DataSource for NoData {
    fn query(&mut self, source: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::UnknownSource(source.to_string()))
    }
}

fn boot(source: &str) -> Runner<NoData> {
    Runner::boot(
        contract::compile(source).unwrap(),
        NoData,
        exact_kernel::Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap()
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
    let mut r = boot(SCREEN);
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

const FEED: &str = r#"shape Feed
  title: string

component App
  state rev = 0
  resource feed = feed(rev) as shape Feed else blank()
  mutation saved as shape Feed then afterSave
  action refresh
    rev = rev + 1
  action save
    send saved = save()
  action afterSave
    rev = rev
  view
    column
      text feed.title testId="title"
"#;

/// `blank` answers now; every other source answers later, with a title.
struct Later;
impl DataSource for Later {
    fn query(&mut self, source: &str, _: &[Value]) -> Result<Value, DataError> {
        Err(DataError::Unavailable(format!("{source} answers later")))
    }
    fn answer(
        &mut self,
        _: &mut exact_runner::Store,
        source: &str,
        _: &[Value],
    ) -> Result<exact_runner::Answer, DataError> {
        if source == "blank" {
            return Ok(exact_runner::Answer::Now(Value::record(vec![Value::str(
                "loading",
            )])));
        }
        Ok(exact_runner::Answer::Later(exact_runner::Request::get(
            &format!("https://feed.test/{source}"),
        )))
    }
    fn parse(
        &mut self,
        _: &mut exact_runner::Store,
        _: &str,
        _: &[Value],
        _: exact_runner::Outcome,
    ) -> Result<exact_runner::Answer, DataError> {
        Ok(exact_runner::Answer::Now(Value::record(vec![Value::str(
            "news",
        )])))
    }
}

fn reply() -> exact_runner::Outcome {
    exact_runner::Outcome::Response(exact_runner::Response {
        status: 200,
        headers: vec![],
        body: b"{}".to_vec(),
    })
}

/// TTI waits only for what the screen lacks: a placeholder's request holds
/// it; a refresh behind a shown answer and a mutation the app sent don't.
#[test]
fn only_a_placeholders_request_holds_the_ledger() {
    let mut r = Runner::boot(
        contract::compile(FEED).unwrap(),
        Later,
        exact_kernel::Kernel::with_monospace(),
        Default::default(),
        "/",
    )
    .unwrap();
    assert_eq!(
        r.outstanding().requests,
        vec!["feed".to_string()],
        "the placeholder is loading"
    );
    let first = r.take_requests();
    r.fulfill(first[0].ticket, reply()).unwrap();
    assert!(r.outstanding().is_clear(), "answered");

    r.act("refresh", vec![]).unwrap();
    assert_eq!(r.take_requests().len(), 1, "the refresh is in flight");
    assert!(
        r.outstanding().is_clear(),
        "a refresh behind the shown answer is not outstanding"
    );

    r.act("save", vec![]).unwrap();
    assert!(!r.take_requests().is_empty(), "the mutation is in flight");
    assert!(
        r.outstanding().is_clear(),
        "a mutation the app sent is not outstanding"
    );
}

const STACK: &str = r#"routes nav
  home "/"
    item "/item/:id"

component App
  state loaded = false
  action follow(url: string)
    nav = go(nav, url)
  action back
    nav = back(nav)
  view
    main navigationKey=`${top(nav).id}` navigationBack="back" navigate=follow width="100%" height="100%"
      for e in stack(nav) key=e.id
        if e.name == "home"
          column navigationKey=`${e.id}` testId="home" position="absolute" inset=0 aria-busy=(not loaded)
            text "Home"
        if e.name == "item"
          column navigationKey=`${e.id}` testId=`item-${e.params.id}` position="absolute" inset=0
            text e.params.id
"#;

/// A busy element under a route that is not shown (here the screen a pushed
/// route covers) is not on screen, so it does not hold TTI.
#[test]
fn a_busy_element_on_a_covered_route_does_not_hold_the_ledger() {
    let mut r = boot(STACK);
    assert_eq!(
        r.outstanding().busy,
        vec!["home".to_string()],
        "shown and busy"
    );
    let root = r.kernel().roots()[0];
    r.dispatch(root, exact_runner::Event::Navigate("/item/b".into()))
        .unwrap();
    assert!(
        r.outstanding().busy.is_empty(),
        "covered by the pushed route"
    );
    r.dispatch(root, exact_runner::Event::Navigate("/".into()))
        .unwrap();
    assert_eq!(
        r.outstanding().busy,
        vec!["home".to_string()],
        "shown again"
    );
}
