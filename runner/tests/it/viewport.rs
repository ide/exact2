//! @ref LLP 1039 D3 / LLP 1030 D7 — host facts must not enter kept storage.
use exact_kernel::{Kernel, NodeType};
use exact_plan::{asm::Asm, builder::PlanBuilder, TypeKind, Value};
use exact_runner::{DataError, DataSource, Runner, Viewport};

#[derive(Default)]
struct Deferred {
    ready: bool,
    queries: Vec<Vec<Value>>,
}
impl DataSource for Deferred {
    fn query(&mut self, source: &str, args: &[Value]) -> Result<Value, DataError> {
        assert!(
            self.ready,
            "deferred application source ran before activation"
        );
        assert_eq!(
            source, "value",
            "runner fact reached application data source"
        );
        self.queries.push(args.to_vec());
        Ok(args[0].clone())
    }
    fn ready(&self) -> bool {
        self.ready
    }
}

#[test]
fn runner_facts_never_write_kept_answers() {
    let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
    let number = b.primitive(TypeKind::Number);
    let string = b.primitive(TypeKind::String);
    let viewport = b.record("Viewport", &[("width", number), ("height", number)]);
    let delivery = b.record("Delivery", &[("stream", string)]);
    b.resource(
        "viewport",
        exact_runner::viewport::SOURCE,
        &[],
        viewport,
        Some(&Value::record(vec![Value::Number(1.), Value::Number(1.)])),
    );
    b.resource(
        "delivery",
        exact_runner::delivery::SOURCE,
        &[],
        delivery,
        Some(&Value::record(vec![Value::str("baked stream")])),
    );
    let zero = b.constant(&Value::Number(0.));
    let revision = b.slot("revision", number, zero);
    let mut arg = Asm::new();
    arg.load_slot(revision);
    let arg = b.code(arg);
    let value = b.resource("value", "value", &[arg], number, Some(&Value::Number(0.)));
    b.set_resource_initial_args(value, &[Value::Number(0.)]);
    b.set_resource_reader(value, true);
    let mut change = Asm::new();
    change.load_param(0).store_slot(revision);
    let change = b.code(change);
    b.action("change", &[("revision", number)], &[revision], change);
    b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
    let mut runner = Runner::boot(
        b.finish().unwrap(),
        Deferred::default(),
        Kernel::with_monospace(),
        Viewport::default(),
        "/",
    )
    .unwrap();
    assert!(runner.take_router_change().is_none());
    assert!(runner.carry().keeps_answers);
    assert!(runner.take_store_writes().is_empty());
    // Timers can change arguments while the host is still loading its module.
    // Each change must keep the compiled placeholder, without invoking app code.
    for revision in [1., 2.] {
        runner.act("change", vec![Value::Number(revision)]).unwrap();
        assert_eq!(runner.resource("value"), Some(&Value::Number(0.)));
    }
    assert!(runner.data().queries.is_empty());
    assert!(runner.data_ready().unwrap().is_none());
    assert!(runner.set_viewport(1280.0, 900.0).unwrap().is_some());
    assert_eq!(
        runner.resource("viewport"),
        Some(&Value::record(vec![
            Value::Number(1280.0),
            Value::Number(900.0)
        ]))
    );
    assert!(runner.take_store_writes().is_empty());
    let mut delivery = runner.delivery().clone();
    delivery.stream = "updated".into();
    assert!(runner.set_delivery(delivery).unwrap().is_some());
    assert!(runner.take_store_writes().is_empty());
    assert!(runner.carry().store.is_empty());
    assert_eq!(
        runner.resource("delivery"),
        Some(&Value::record(vec![Value::str("updated")]))
    );
    runner.data().ready = true;
    assert!(runner.data_ready().unwrap().is_some());
    assert_eq!(runner.resource("value"), Some(&Value::Number(2.)));
    assert_eq!(runner.data().queries, vec![vec![Value::Number(2.)]]);
    assert!(runner.data_ready().unwrap().is_none());
    assert_eq!(runner.data().queries.len(), 1);
    assert_eq!(
        runner
            .take_store_writes()
            .iter()
            .map(|write| write.name.as_str())
            .collect::<Vec<_>>(),
        ["exact.kept.value"]
    );
}

#[test]
fn corrupt_unicode_kept_answers_do_not_prevent_boot() {
    for stored in ["€x|00", "é|00", "💬|00", "0500000000|€x", "0500000000|€"] {
        let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
        let number = b.primitive(TypeKind::Number);
        let mut arg = Asm::new();
        arg.number(0.);
        let arg = b.code(arg);
        let value = b.resource("value", "value", &[arg], number, Some(&Value::Number(0.)));
        b.set_resource_initial_args(value, &[Value::Number(0.)]);
        b.set_resource_reader(value, true);
        b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
        let mut runner = Runner::boot_stored(
            b.finish().unwrap(),
            Deferred::default(),
            Kernel::with_monospace(),
            vec![("exact.kept.value".into(), stored.into())],
            Viewport::default(),
            "/",
        )
        .unwrap();
        assert_eq!(runner.resource("value"), Some(&Value::Number(0.)));
        runner.data().ready = true;
        runner.data_ready().unwrap();
        assert_eq!(runner.data().queries.len(), 1);
    }
}

/// #114: a focus change re-answers the `exactPage` readers whose shape
/// names `hasFocus`; a reader of `onLine` alone asks nothing, and with no
/// reader of it the change commits nothing, though the runner keeps it.
#[test]
fn page_focus_reanswers_only_the_readers_of_it() {
    let boot = |fields: &[&str]| {
        let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
        let boolean = b.primitive(TypeKind::Bool);
        for field in fields {
            let shape = b.record(&format!("{field}Shape"), &[(field, boolean)]);
            b.resource(field, exact_runner::page::SOURCE, &[], shape, None);
        }
        b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
        let data = Deferred {
            ready: true,
            ..Deferred::default()
        };
        let viewport = Viewport::default();
        Runner::boot(
            b.finish().unwrap(),
            data,
            Kernel::with_monospace(),
            viewport,
            "/",
        )
        .unwrap()
    };
    let one = |v: bool| Some(Value::record(vec![Value::Bool(v)]));
    let mut both = boot(&["hasFocus", "onLine"]);
    assert_eq!(both.resource("hasFocus").cloned(), one(true));
    let blurred = exact_runner::Page {
        has_focus: false,
        ..both.page()
    };
    assert!(both.set_page(blurred).unwrap().is_some());
    assert_eq!(both.resource("hasFocus").cloned(), one(false));
    assert_eq!(both.resource("onLine").cloned(), one(true));
    assert!(
        both.set_page(blurred).unwrap().is_none(),
        "the same facts again"
    );
    let mut online = boot(&["onLine"]);
    assert!(online.reads_page_field("onLine") && !online.reads_page_field("hasFocus"));
    assert!(
        !boot(&["hasFocus"]).reads_page_field("onLine"),
        "a host need not watch the network"
    );
    assert!(online.set_page(blurred).unwrap().is_none());
    assert!(!online.page().has_focus);
    let offline = exact_runner::Page {
        on_line: false,
        ..blurred
    };
    assert!(online.set_page(offline).unwrap().is_some());
    assert_eq!(online.resource("onLine").cloned(), one(false));
}

/// LLP 1139.003 D2: `exactViewport().gpuTier` is the page facts' tier,
/// `high` until a host tells another, and a change re-answers its readers.
#[test]
fn gpu_tier_is_a_page_fact_read_through_the_viewport() {
    let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
    let string = b.primitive(TypeKind::String);
    let shape = b.record("Viewport", &[("gpuTier", string)]);
    b.resource("viewport", "exactViewport", &[], shape, None);
    b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
    let mut runner = Runner::boot(
        b.finish().unwrap(),
        Deferred::default(),
        Kernel::with_monospace(),
        Viewport::default(),
        "/",
    )
    .unwrap();
    let tier = |w: &str| Some(Value::record(vec![Value::str(w)]));
    assert_eq!(runner.resource("viewport").cloned(), tier("high"));
    let low = exact_runner::Page::from_bits(runner.page().bits() | 2 << 11);
    assert!(runner.set_page(low).unwrap().is_some());
    assert_eq!(runner.resource("viewport").cloned(), tier("low"));
    assert!(
        runner.set_page(low).unwrap().is_none(),
        "the same tier again"
    );
}

#[test]
fn display_mode_changes_reanswer_without_resize_or_app_data() {
    let mut b = PlanBuilder::new(exact_kernel::SCHEMA_DIGEST, 1);
    let string = b.primitive(TypeKind::String);
    let shape = b.record("Viewport", &[("displayMode", string)]);
    b.resource("viewport", "exactViewport", &[], shape, None);
    b.node(NodeType::View as u8, None, None, 0, &[], &[], None);
    let mut runner = Runner::boot(
        b.finish().unwrap(),
        Deferred::default(),
        Kernel::with_monospace(),
        Viewport::default(),
        "/",
    )
    .unwrap();
    for (bits, expected) in [
        (0, "standalone"),
        (2 << 11, "fullscreen"),
        (0, "standalone"),
    ] {
        let preferences = exact_runner::Preferences::from_bits(bits);
        runner.set_preferences(preferences).unwrap();
        assert_eq!(
            runner.resource("viewport"),
            Some(&Value::record(vec![Value::str(expected)]))
        );
        assert!(runner.set_preferences(preferences).unwrap().is_none());
        let state = exact_runner::agent::state(&runner);
        assert!(
            state.contains(&format!("\"displayMode\":\"{expected}\"")),
            "{state}"
        );
    }
    assert_eq!(runner.viewport().width, 390.0);
    assert!(runner.data().queries.is_empty());
}

#[test]
fn deferred_mutations_are_counted_when_the_source_activates() {
    #[derive(Default)]
    struct Writes {
        ready: bool,
        calls: usize,
    }
    impl DataSource for Writes {
        fn ready(&self) -> bool {
            self.ready
        }
        fn query(&mut self, _: &str, _: &[Value]) -> Result<Value, DataError> {
            self.calls += 1;
            Ok(Value::Number(self.calls as f64))
        }
    }
    let plan = contract::compile("component App\n  mutation saved as shape number\n  task auto mount\n    after(1, save)\n  action save\n    send saved = save()\n  view\n    text \"hello\"\n").unwrap();
    let mut r = Runner::boot(
        plan,
        Writes::default(),
        Kernel::with_monospace(),
        Viewport::default(),
        "/",
    )
    .unwrap();
    assert!(r.advance_timed(1.).error.is_none());
    assert_eq!(r.data_ref().calls, 0);
    assert_eq!(
        r.mutation_requests(),
        0,
        "an unissued send has no request yet"
    );
    r.data().ready = true;
    r.data_ready().unwrap();
    assert_eq!(r.data_ref().calls, 1);
    assert_eq!(r.mutation_requests(), 1);
    assert!(exact_runner::agent::state(&r).contains("\"mutationRequests\":1"));
    r.data_ready().unwrap();
    assert_eq!(
        r.mutation_requests(),
        1,
        "activation does not resend a settled write"
    );
}

const COLLECTION_SOURCE: &str = r#"component App
  state showing = true
  action toggle
    showing = !showing
  view
    column
      if showing
        list virtualized=true height=900 estimated-item-height=100 scroll-start="end"
          for row in range(1000) key=row
            text `${row}` height=100 width=100 flex-shrink=0
"#;

fn boot_collection(source: &str, viewport: Viewport) -> Runner<()> {
    Runner::boot(
        contract::compile(source).unwrap(),
        (),
        Kernel::with_monospace(),
        viewport,
        "/",
    )
    .unwrap()
}

fn collection_rows(runner: &Runner<()>) -> Vec<usize> {
    runner.collections()[0]
        .rows
        .iter()
        .map(|row| row.index)
        .collect()
}

#[test]
fn collection_bootstrap_uses_each_runners_viewport_in_its_first_commit() {
    for horizontal in [false, true] {
        let source = if horizontal {
            COLLECTION_SOURCE.replace(
                "estimated-item-height=100",
                "display=\"flex\" flex-direction=\"row\" estimated-item-width=100",
            )
        } else {
            COLLECTION_SOURCE.to_string()
        };
        let mut small = boot_collection(&source, Viewport::sized(200., 300.));
        let mut large = boot_collection(&source, Viewport::sized(900., 200.));
        assert_eq!(collection_rows(&small), (997..1000).collect::<Vec<_>>());
        assert_eq!(collection_rows(&large), (991..1000).collect::<Vec<_>>());
        for runner in [&mut small, &mut large] {
            assert_eq!(runner.kernel().epoch(), 1, "bootstrap must use one commit");
            let snapshot = &runner.collections()[0];
            assert_eq!(
                snapshot.axis,
                if horizontal {
                    exact_runner::ListAxis::Horizontal
                } else {
                    exact_runner::ListAxis::Vertical
                }
            );
            assert_eq!(snapshot.correction.unwrap().offset, 100_000.);
            runner.act("toggle", vec![]).unwrap();
            assert!(runner.collections().is_empty());
        }
        large.act("toggle", vec![]).unwrap();
        small.act("toggle", vec![]).unwrap();
        assert_eq!(collection_rows(&large), (991..1000).collect::<Vec<_>>());
        assert_eq!(collection_rows(&small), (997..1000).collect::<Vec<_>>());
    }
}

#[test]
fn collection_bootstrap_keeps_its_bounds_and_authored_initial_count() {
    for (extent, count) in [(1., 1), (901., 10), (50_000., 16)] {
        let runner = boot_collection(COLLECTION_SOURCE, Viewport::sized(extent, extent));
        assert_eq!(
            collection_rows(&runner),
            (1000 - count..1000).collect::<Vec<_>>()
        );
        assert!(runner.kernel().live_count() <= 2 + 2 * count + 2);
    }
    for count in [1, 23, 64] {
        let source = COLLECTION_SOURCE.replace(
            "virtualized=true",
            &format!("virtualized=true initial-item-count={count}"),
        );
        let runner = boot_collection(&source, Viewport::sized(200., 900.));
        assert_eq!(
            collection_rows(&runner),
            (1000 - count..1000).collect::<Vec<_>>()
        );
    }
    let short = COLLECTION_SOURCE.replace("range(1000)", "range(2)");
    let runner = boot_collection(&short, Viewport::sized(200., 900.));
    assert_eq!(collection_rows(&runner), [0, 1]);
}

#[test]
fn collection_bootstrap_resize_affects_new_lists_and_replacement_uses_its_own_viewport() {
    let mut runner = boot_collection(COLLECTION_SOURCE, Viewport::sized(200., 300.));
    let first = runner.collections();
    assert!(runner.set_viewport(200., 900.).unwrap().is_none());
    assert_eq!(
        runner.collections(),
        first,
        "existing rows await port feedback"
    );
    runner.act("toggle", vec![]).unwrap();
    runner.act("toggle", vec![]).unwrap();
    assert_eq!(collection_rows(&runner), (991..1000).collect::<Vec<_>>());
    for (width, height) in [(f64::NAN, 100.), (100., 0.), (f64::INFINITY, 100.)] {
        assert!(runner.set_viewport(width, height).is_err());
    }
    runner.act("toggle", vec![]).unwrap();
    runner.act("toggle", vec![]).unwrap();
    assert_eq!(collection_rows(&runner), (991..1000).collect::<Vec<_>>());

    let before = runner.collections();
    let replacement = Runner::boot_carrying(
        contract::compile(COLLECTION_SOURCE).unwrap(),
        (),
        Kernel::with_monospace(),
        &runner.carry(),
        Viewport::sized(200., 450.),
        "/",
    )
    .unwrap();
    assert_eq!(
        collection_rows(&replacement),
        (995..1000).collect::<Vec<_>>()
    );
    assert_eq!(replacement.kernel().epoch(), 1);
    assert_eq!(runner.collections(), before);
}

#[test]
fn collection_bootstrap_refreshes_before_a_viewport_commit_creates_the_list() {
    let source = COLLECTION_SOURCE
        .replace(
            "component App",
            "shape BootstrapViewport\n  height: number\ncomponent App",
        )
        .replace(
            "  view",
            "  resource viewport = exactViewport() as shape BootstrapViewport\n  view",
        )
        .replace("if showing", "if showing && viewport.height >= 500");
    let mut runner = boot_collection(&source, Viewport::sized(200., 300.));
    assert!(runner.collections().is_empty());
    assert!(runner.set_viewport(200., 900.).unwrap().is_some());
    assert_eq!(collection_rows(&runner), (991..1000).collect::<Vec<_>>());
    assert_eq!(runner.kernel().epoch(), 2);
}

#[test]
fn collection_bootstrap_rolls_back_with_a_refused_viewport_commit() {
    let source = COLLECTION_SOURCE
        .replace("component App", "shape BootstrapViewport\n  height: number\ncomponent App")
        .replace(
            "  view",
            "  resource viewport = exactViewport() as shape BootstrapViewport\n  task guarded when true key=(viewport.height >= 500 ? 0 / 0 : 1)\n    after(100000, toggle)\n  view",
        );
    let viewport = Viewport::sized(200., 300.);
    let mut runner = boot_collection(&source, viewport);
    let before = runner.collections();
    assert!(runner.set_viewport(200., 900.).is_err());
    assert!(!runner.is_poisoned());
    assert_eq!(runner.viewport(), viewport);
    assert_eq!(runner.collections(), before);
    runner.act("toggle", vec![]).unwrap();
    runner.act("toggle", vec![]).unwrap();
    assert_eq!(collection_rows(&runner), (997..1000).collect::<Vec<_>>());
}
