//! What the settle ledger (`Runner::outstanding`) counts as still loading, which
//! time to interactive waits for.
use exact_runner::{DataError, DataSource, Runner, Value};

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
