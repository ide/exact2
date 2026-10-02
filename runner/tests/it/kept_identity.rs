//! @ref LLP 1027 D4 — a kept answer shows at boot when its identifying
//! arguments (those before a `with`) match, however it was asked.
use exact_kernel::{Kernel, NodeType};
use exact_plan::{asm::Asm, builder::PlanBuilder, Plan, TypeKind, Value};
use exact_runner::{DataError, DataSource, Runner, Viewport};

#[derive(Default)]
struct Later {
    ready: bool,
    queries: Vec<Vec<Value>>,
}
impl DataSource for Later {
    fn query(&mut self, _: &str, args: &[Value]) -> Result<Value, DataError> {
        assert!(self.ready, "asked before the module loaded");
        self.queries.push(args.to_vec());
        Ok(Value::Number(42.))
    }
    fn ready(&self) -> bool {
        self.ready
    }
}

/// `resource status = status(car) with rev`, both slots set by `ask`; with
/// `identity` 2, every argument identifies (no `with`).
fn plan(identity: Option<u16>) -> Plan {
    let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
    let number = b.primitive(TypeKind::Number);
    let string = b.primitive(TypeKind::String);
    let empty = b.constant(&Value::str("a"));
    let zero = b.constant(&Value::Number(0.));
    let car = b.slot("car", string, empty);
    let rev = b.slot("rev", number, zero);
    let mut a = Asm::new();
    a.load_slot(car);
    let a = b.code(a);
    let mut r = Asm::new();
    r.load_slot(rev);
    let r = b.code(r);
    let status = b.resource(
        "status",
        "status",
        &[a, r],
        number,
        Some(&Value::Number(0.)),
    );
    b.set_resource_initial_args(status, &[Value::str("a"), Value::Number(0.)]);
    b.set_resource_reader(status, true);
    if let Some(identity) = identity {
        b.set_resource_identity(status, identity);
    }
    let mut ask = Asm::new();
    ask.load_param(0)
        .store_slot(car)
        .load_param(1)
        .store_slot(rev);
    let ask = b.code(ask);
    b.action("ask", &[("car", string), ("rev", number)], &[car, rev], ask);
    b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
    b.finish().unwrap()
}

/// The kept answer a session leaves after asking `car` at `rev`.
fn kept_after(identity: Option<u16>, car: &str, rev: f64) -> String {
    let mut r = Runner::boot(
        plan(identity),
        Later::default(),
        Kernel::with_monospace(),
        Viewport::default(),
        "/",
    )
    .unwrap();
    r.act("ask", vec![Value::str(car), Value::Number(rev)])
        .unwrap();
    r.data().ready = true;
    r.data_ready().unwrap();
    assert_eq!(r.resource("status"), Some(&Value::Number(42.)));
    r.take_store_writes()
        .into_iter()
        .find(|w| w.name == "exact.kept.status")
        .and_then(|w| w.value)
        .expect("the answer is kept")
}

fn launch(identity: Option<u16>, kept: String) -> Runner<Later> {
    Runner::boot_stored(
        plan(identity),
        Later::default(),
        Kernel::with_monospace(),
        vec![("exact.kept.status".into(), kept)],
        Viewport::default(),
        "/",
    )
    .unwrap()
}

#[test]
fn a_kept_answer_to_the_same_question_shows_however_it_was_asked() {
    let kept = kept_after(Some(1), "a", 5.);
    let mut r = launch(Some(1), kept);
    // Asked at revision 5 last time, at 0 now: still car "a"'s status.
    assert_eq!(r.resource("status"), Some(&Value::Number(42.)));
    r.data().ready = true;
    r.data_ready().unwrap();
    // … and asked again, with how it is asked now.
    assert_eq!(
        r.data().queries,
        vec![vec![Value::str("a"), Value::Number(0.)]]
    );
}

#[test]
fn a_kept_answer_to_another_question_never_shows() {
    let kept = kept_after(Some(1), "b", 5.);
    let r = launch(Some(1), kept);
    assert_eq!(r.resource("status"), Some(&Value::Number(0.)));
}

#[test]
fn without_with_every_argument_identifies_the_answer() {
    let kept = kept_after(None, "a", 5.);
    let r = launch(None, kept);
    assert_eq!(r.resource("status"), Some(&Value::Number(0.)));
}
