use super::*;
use crate::launch_marks::tests::{boot, land, Held};
use crate::launch_marks::Marks;
use exact_runner::DataSource;
use std::cell::RefCell;
use std::sync::mpsc::Receiver;

thread_local! {
    /// What the marks journaled on this test's thread.
    static EVENTS: RefCell<Vec<(String, Map<String, Value>)>> = const { RefCell::new(Vec::new()) };
}

/// Keeps an event, with the time of its mark as `_at`.
fn collect(kind: &str, mut fields: Map<String, Value>, at: f64) {
    fields.insert("_at".into(), at.into());
    EVENTS.with(|e| e.borrow_mut().push((kind.into(), fields)));
}

/// The events journaled since the last call, as `kind` or `kind name`, with their fields.
fn take() -> Vec<(String, Map<String, Value>)> {
    EVENTS
        .with(|e| std::mem::take(&mut *e.borrow_mut()))
        .into_iter()
        .map(
            |(kind, fields)| match fields.get("name").and_then(Value::as_str) {
                Some(name) => (format!("{kind} {name}"), fields),
                None => (kind, fields),
            },
        )
        .collect()
}

fn kinds(events: &[(String, Map<String, Value>)]) -> Vec<&str> {
    events.iter().map(|(k, _)| k.as_str()).collect()
}

fn marks() -> NavigationMarks {
    NavigationMarks {
        record: collect,
        ..NavigationMarks::new()
    }
}

fn change(top: u64, url: &str, removed: &[u64]) -> RouterChange {
    RouterChange {
        top,
        url: url.into(),
        removed: removed.to_vec(),
        visits: Vec::new(),
        pattern: url.into(),
        params: Vec::new(),
        from_event: true,
    }
}

fn busy() -> Ledger {
    Ledger {
        items: vec!["requests:feed".into()],
        ..Ledger::default()
    }
}

#[test]
fn a_screen_is_a_visit_at_its_url() {
    let mut s = ScreenHistory::default();
    let screen = |shown, interactive| Some(Screen { shown, interactive });
    assert_eq!(s.top(1, "/", &[]), screen(false, false));
    assert_eq!(s.top(1, "/", &[]), None, "the same screen on top");
    assert_eq!(s.top(2, "/a", &[]), screen(false, false));
    assert_eq!(s.top(1, "/", &[]), screen(false, false), "not rendered yet");
    s.shown(1, "/");
    assert_eq!(s.top(2, "/a", &[]), screen(false, false));
    assert_eq!(s.top(1, "/", &[]), screen(true, false));
    s.interactive(1, "/");
    assert_eq!(s.top(1, "/?q", &[]), screen(false, false), "another URL");
    assert_eq!(s.top(1, "/", &[]), screen(true, true));
    s.shown(2, "/a");
    s.interactive(2, "/a");
    assert_eq!(s.top(3, "/b", &[2]), screen(false, false));
    assert_eq!(
        s.top(2, "/a", &[]),
        screen(false, false),
        "a removed visit is forgotten"
    );
}

/// The launch route is journaled once as `navigation.launch`. A navigation
/// starts at the input whose dispatch committed it, else at the commit;
/// renders at the first frame built after it; and is interactive once nothing
/// is outstanding on screen.
#[test]
fn navigations_time_from_their_cause_to_render_and_tti() {
    let mut m = marks();
    m.changed(&change(1, "/", &[]), 10.0, None);
    m.presented();
    let events = take();
    assert_eq!(kinds(&events), ["navigation.launch"]);
    assert_eq!(events[0].1["entry"], 1);
    assert!(!m.waiting(), "startup covers the launch route");

    m.changed(&change(2, "/a", &[]), 10.6, Some(10.5));
    m.shown(10.62, &busy(), &busy());
    assert!(take().is_empty(), "that frame was built before the change");
    m.submitted();
    m.shown(10.7, &busy(), &busy());
    m.turn(&Ledger::default(), false, 10.8);
    m.turn(&Ledger::default(), true, 10.9);
    let events = take();
    assert_eq!(kinds(&events), ["navigation cold_ttr", "navigation tti"]);
    assert_eq!(
        (&events[0].1["_at"], &events[1].1["_at"]),
        (&Value::from(10.7), &Value::from(10.9)),
        "each row at its mark: the presentation, the settled turn"
    );
    assert_eq!(events[0].1["exact.nav.cause"], "input");
    assert_eq!(events[0].1["url"], "/a");
    assert!((events[0].1["value"].as_f64().unwrap() - 0.2).abs() < 1e-9);
    assert!((events[1].1["value"].as_f64().unwrap() - 0.4).abs() < 1e-9);
    assert_eq!(m.current().unwrap()["url"], "/a");

    // A change no input's dispatch committed starts at its commit.
    m.changed(&change(3, "/b", &[]), 12.0, None);
    m.submitted();
    m.shown(12.05, &Ledger::default(), &Ledger::default());
    let events = take();
    assert_eq!(kinds(&events), ["navigation cold_ttr", "navigation tti"]);
    assert_eq!(events[0].1["exact.nav.cause"], "program");
    assert!((events[0].1["value"].as_f64().unwrap() - 0.05).abs() < 1e-9);
    assert_eq!(
        events[0].1["value"], events[1].1["value"],
        "settled as shown"
    );
    m.changed(&change(3, "/b", &[]), 13.0, None);
    assert!(take().is_empty(), "the same screen on top is no navigation");
}

/// A poisoned runtime handles no action again: a navigation shown then ends
/// without TTI, also when a reload later clears what it waited for.
#[test]
fn a_poisoned_runtime_cancels_the_navigation_waiting_for_tti() {
    let mut m = marks();
    m.changed(&change(1, "/", &[]), 10.0, None);
    m.presented();
    take();
    m.changed(&change(2, "/a", &[]), 10.6, Some(10.5));
    m.submitted();
    m.shown(10.7, &busy(), &busy());
    assert_eq!(kinds(&take()), ["navigation cold_ttr"]);
    let poisoned = Ledger {
        poisoned: true,
        ..busy()
    };
    m.turn(&poisoned, true, 10.8);
    assert!(!m.waiting(), "cancelled");
    m.turn(&Ledger::default(), true, 11.0);
    assert!(take().is_empty(), "no TTI once the reload clears the work");
}

/// Until the first frame is presented, a router change replaces the launch
/// route: it is journaled as `navigation.launch` again, measures nothing and
/// shows nothing, so the screen it replaced stays cold. The first frame shows
/// the screen on top then.
#[test]
fn a_change_before_the_first_frame_replaces_the_launch_route() {
    let clear = Ledger::default();
    let mut m = marks();
    m.changed(&change(1, "/", &[]), 1.0, None);
    m.changed(&change(1, "/welcome", &[]), 1.1, Some(1.05));
    m.submitted();
    m.turn(&clear, true, 1.15);
    let events = take();
    assert_eq!(kinds(&events), ["navigation.launch", "navigation.launch"]);
    assert_eq!(events[1].1["url"], "/welcome");
    assert!(!m.waiting(), "no navigation before the first frame");
    m.presented();
    m.shown(1.2, &clear, &clear);
    assert!(take().is_empty(), "the first frame is startup's");

    m.changed(&change(2, "/a", &[]), 2.0, None);
    m.submitted();
    m.shown(2.1, &clear, &clear);
    m.changed(&change(1, "/", &[2]), 3.0, None);
    m.submitted();
    m.shown(3.1, &clear, &clear);
    m.changed(&change(1, "/welcome", &[]), 4.0, None);
    m.submitted();
    m.shown(4.1, &clear, &clear);
    let events = take();
    assert_eq!(
        kinds(&events),
        [
            "navigation cold_ttr",
            "navigation tti",
            "navigation cold_ttr",
            "navigation tti",
            "navigation warm_ttr",
            "navigation tti"
        ],
        "the replaced launch screen was never shown; the one the first frame showed was"
    );
    assert_eq!(events[2].1["url"], "/");
    assert_eq!(events[4].1["url"], "/welcome");
}

/// A screen is shown once a navigation to it rendered, and measures TTI until
/// it has been interactive: a newer navigation that cancels its TTI leaves the
/// next visit one to measure. Startup's TTI makes the launch screen interactive.
#[test]
fn a_screen_measures_tti_until_it_has_been_interactive() {
    let clear = Ledger::default();
    for startup in [false, true] {
        let mut m = marks();
        m.changed(&change(1, "/", &[]), 1.0, None);
        m.presented();
        if startup {
            m.startup_interactive();
        }
        m.changed(&change(2, "/a", &[]), 2.0, None);
        m.submitted();
        m.shown(2.1, &clear, &clear);
        m.changed(&change(1, "/", &[2]), 3.0, None);
        m.submitted();
        m.shown(3.1, &clear, &clear);
        let events = take();
        let back = if startup {
            &["navigation warm_ttr"][..]
        } else {
            &["navigation warm_ttr", "navigation tti"][..]
        };
        assert_eq!(kinds(&events[3..]), back, "startup's TTI: {startup}");
    }

    let mut m = marks();
    m.changed(&change(1, "/", &[]), 1.0, None);
    m.presented();
    m.changed(&change(2, "/a", &[]), 2.0, None);
    m.changed(&change(3, "/b", &[]), 2.5, None);
    m.submitted();
    m.shown(2.6, &busy(), &busy());
    m.changed(&change(2, "/a", &[]), 3.0, None);
    m.turn(&clear, true, 3.0);
    let events = take();
    assert_eq!(
        kinds(&events),
        [
            "navigation.launch",
            "navigation.superseded",
            "navigation cold_ttr",
            "navigation.superseded",
            "navigation cold_ttr",
            "navigation tti"
        ],
        "/a was superseded before its frame, so it is cold later; /b's TTI was cancelled"
    );
    assert_eq!(
        (
            &events[1].1["route"],
            &events[2].1["url"],
            &events[4].1["url"]
        ),
        (&json("/b"), &json("/b"), &json("/a")),
    );
    assert_eq!(events[4].1["_at"], 3.0, "it needed no new frame");

    m.changed(&change(3, "/b", &[]), 4.0, None);
    m.submitted();
    m.shown(4.1, &clear, &clear);
    m.changed(&change(2, "/a", &[]), 5.0, None);
    m.submitted();
    m.shown(5.1, &clear, &clear);
    let events = take();
    assert_eq!(
        kinds(&events),
        [
            "navigation warm_ttr",
            "navigation tti",
            "navigation warm_ttr"
        ],
        "/b was never interactive; /a was"
    );

    let failed = Ledger {
        failed: vec!["stations".into()],
        ..Ledger::default()
    };
    m.changed(&change(4, "/c", &[]), 6.0, None);
    m.submitted();
    m.turn(&failed, true, 6.05);
    assert!(take().is_empty(), "not before render");
    m.shown(6.1, &failed, &failed);
    let events = take();
    assert_eq!(kinds(&events), ["navigation cold_ttr", "navigation tti"]);
    assert_eq!(events[1].1["exact.tti.failed"], 1);

    m.changed(&change(1, "/", &[2, 3, 4]), 7.0, None);
    m.submitted();
    m.shown(7.1, &clear, &clear);
    m.changed(&change(3, "/b", &[]), 8.0, None);
    m.submitted();
    m.shown(8.1, &clear, &clear);
    let events = take();
    assert_eq!(
        kinds(&events),
        [
            "navigation warm_ttr",
            "navigation tti",
            "navigation cold_ttr",
            "navigation tti"
        ],
        "the launch screen was shown, never interactive; a removed visit is forgotten"
    );
}

/// Home, and a detail screen.
const APP: &str = r#"routes nav
  home "/"
    detail "/detail/:id"
component App
  action open
    nav = push(nav, "/detail/7")
  action back
    nav = back(nav)
  view
    main navigationKey=`${top(nav).id}` width="100%" height="100%"
      for e in stack(nav) key=e.id
        column navigationKey=`${e.id}` position="absolute" inset=0
          if e.name == "home"
            button press=open testId="open"
              text "Open"
          if e.name == "detail"
            button press=back testId="back"
              text "Back"
"#;

fn press<D: DataSource>(p: &mut crate::Presenter<D>, test_id: &str) {
    let kernel = p.host().kernel();
    let key = kernel.find_by_test_id(test_id)[0];
    let id = kernel.node_by_key(key).unwrap().id;
    p.dispatch_press(id, 0., false);
}

/// An app booted on a [`Held`] source, its marks journaling into this test's
/// collector, and its first frame presented by the display loop's calls.
fn launch(source: &str) -> (crate::Presenter<Held>, Marks, Receiver<exact_runner::Reply>) {
    let (mut p, handed) = boot(source);
    let mut m = Marks::new();
    m.navigation.record = collect;
    m.launch.launch_end();
    m.frame(&mut p);
    let first = p.display_frame().unwrap();
    m.shown(boottime(), &p);
    p.display_complete(&first);
    m.turn(&mut p, false);
    (p, m, handed)
}

/// One frame through the display loop's calls: built, submitted, and flipped at `at`.
fn flip<D: DataSource>(m: &mut Marks, p: &mut crate::Presenter<D>, at: f64) {
    m.frame(p);
    let frame = p.display_frame().unwrap();
    m.turn(p, true);
    m.shown(at, p);
    p.display_complete(&frame);
    m.turn(p, false);
}

/// A routed app's router changes reach the marks through the host, timed from
/// the input that pressed the button to the flips that show the screen.
#[test]
fn the_display_loop_journals_an_apps_navigations() {
    let (mut p, mut m, _) = launch(APP);
    while !m.launch.done() && p.dirty() {
        flip(&mut m, &mut p, boottime());
    }
    assert!(m.launch.done(), "home settles");
    let events = take();
    assert_eq!(kinds(&events), ["navigation.launch"]);

    let tapped = boottime();
    p.dispatching(Some(tapped));
    press(&mut p, "open");
    p.dispatching(None);
    m.turn(&mut p, false);
    let report = m.report();
    assert_eq!(
        (&report["route"]["route"], &report["route"]["url"]),
        (&json("/"), &json("/")),
        "the route at TTI, though the report goes out after a navigation"
    );
    let shown = boottime() + 0.016;
    flip(&mut m, &mut p, shown);
    let events = take();
    assert_eq!(
        kinds(&events),
        ["navigation cold_ttr", "navigation tti"],
        "nothing outstanding: interactive at the flip that shows it"
    );
    let ttr = &events[0].1;
    assert_eq!(
        (&ttr["route"], &ttr["url"], &ttr["exact.nav.cause"]),
        (&json("/detail/:id"), &json("/detail/7"), &json("input"))
    );
    assert_eq!(ttr["routeParams"], serde_json::json!({ "id": "7" }));
    for (_, metric) in &events {
        assert!((metric["value"].as_f64().unwrap() - (shown - tapped)).abs() < 1e-9);
        assert_eq!(metric["_at"], shown, "stamped at its flip");
    }

    press(&mut p, "back");
    flip(&mut m, &mut p, boottime() + 0.016);
    let events = take();
    assert_eq!(kinds(&events), ["navigation warm_ttr"]);
    assert_eq!(events[0].1["exact.nav.cause"], "program");
    assert_eq!(m.navigation.current().unwrap()["url"], "/");
}

/// Home, loading `item` (0 until it answers), and a detail screen that is ready.
const LOADING_HOME: &str = r#"routes nav
  home "/"
    detail "/detail/:id"
component App
  resource item = item() as shape number else fallback()
  action open
    nav = push(nav, "/detail/7")
  action back
    nav = back(nav)
  view
    main navigationKey=`${top(nav).id}` width="100%" height="100%"
      for e in stack(nav) key=e.id
        column navigationKey=`${e.id}` position="absolute" inset=0
          if e.name == "home"
            column testId="home"
              text `${item}`
              button press=open testId="open"
                text "Open"
          if e.name == "detail"
            button press=back testId="back"
              text "Back"
"#;

/// Startup's TTI makes the screen on top interactive, not the launch screen: a
/// launch that leaves its loading home for a ready screen settles there once the
/// load lands, timed from the input that opened it, and the home it returns to
/// still measures its first TTI.
#[test]
fn startup_tti_marks_the_screen_on_top_interactive() {
    let (mut p, mut m, handed) = launch(LOADING_HOME);
    while p.dirty() {
        flip(&mut m, &mut p, boottime());
    }
    assert!(!m.launch.done(), "home is loading");

    let tapped = boottime();
    p.dispatching(Some(tapped));
    press(&mut p, "open");
    p.dispatching(None);
    m.turn(&mut p, false);
    flip(&mut m, &mut p, boottime() + 0.016);
    assert!(!m.launch.done(), "still loading");
    assert_eq!(kinds(&take()), ["navigation.launch", "navigation cold_ttr"]);

    land(&mut p, &handed);
    let settled = boottime() + 0.033;
    flip(&mut m, &mut p, settled);
    assert!(m.launch.done(), "startup settles on the detail screen");
    assert_eq!(m.report()["route"]["url"], "/detail/7");
    let events = take();
    assert_eq!(kinds(&events), ["navigation tti"]);
    let tti = &events[0].1;
    assert_eq!(tti["url"], "/detail/7");
    assert!((tti["value"].as_f64().unwrap() - (settled - tapped)).abs() < 1e-9);
    assert_eq!(tti["_at"], settled, "stamped at the settled frame's flip");

    press(&mut p, "back");
    flip(&mut m, &mut p, boottime() + 0.016);
    let events = take();
    assert_eq!(
        kinds(&events),
        ["navigation warm_ttr", "navigation tti"],
        "home was never interactive"
    );
    assert_eq!(events[1].1["url"], "/");
}

/// Armed by a press, a timer opens the detail screen a second later.
const TIMER: &str = r#"routes nav
  home "/"
    detail "/detail/:id"
component App
  state armed = false
  action arm
    armed = true
  action go
    armed = false
    nav = push(nav, "/detail/7")
  task later when armed
    after(1000, go)
  view
    main navigationKey=`${top(nav).id}` width="100%" height="100%"
      for e in stack(nav) key=e.id
        column navigationKey=`${e.id}` position="absolute" inset=0
          if e.name == "home"
            button press=arm testId="arm"
              text "Arm"
          if e.name == "detail"
            text "Detail"
"#;

/// An input causes only the router changes its dispatch commits: a timer the
/// same loop turn runs after it, which navigates, is timed from its commit.
#[test]
fn a_timer_after_an_input_is_not_its_doing() {
    let (mut p, mut m, _) = launch(TIMER);
    while !m.launch.done() && p.dirty() {
        flip(&mut m, &mut p, boottime());
    }
    assert!(m.launch.done(), "home settles");
    take();

    let tapped = boottime();
    p.dispatching(Some(tapped));
    press(&mut p, "arm");
    p.dispatching(None);
    assert!(
        p.host_mut().routes.take().is_empty(),
        "the press navigated nowhere"
    );
    assert!(p.advance(1000.0).is_none());
    let committed = boottime();
    m.turn(&mut p, false);
    let shown = boottime() + 0.016;
    flip(&mut m, &mut p, shown);
    let events = take();
    assert_eq!(kinds(&events), ["navigation cold_ttr", "navigation tti"]);
    assert_eq!(events[0].1["url"], "/detail/7");
    assert_eq!(events[0].1["exact.nav.cause"], "program");
    let value = events[0].1["value"].as_f64().unwrap();
    assert!(
        value <= shown - tapped && value >= shown - committed,
        "from the timer's commit, not the press: {value}"
    );
}

const DUE: &str = r#"routes nav
  home "/"
    detail "/detail/:id"
component App
  state count = 0
  action bump
    count = count + 1
  action go
    nav = push(nav, "/detail/7")
  task later mount
    after(1500, go)
  view
    main navigationKey=`${top(nav).id}` width="100%" height="100%"
      for e in stack(nav) key=e.id
        column navigationKey=`${e.id}` position="absolute" inset=0
          if e.name == "home"
            button press=bump testId="bump"
              text `${count}`
          if e.name == "detail"
            text "Detail"
"#;

/// A timer the runner fires before an input's own commit (it came due before the
/// input's time) is not the input's doing, though the same dispatch ran it.
#[test]
fn a_timer_due_before_an_input_is_not_its_doing() {
    let (mut p, mut m, _) = launch(DUE);
    while !m.launch.done() && p.dirty() {
        flip(&mut m, &mut p, boottime());
    }
    assert!(m.launch.done(), "home settles");
    take();

    let kernel = p.host().kernel();
    let id = kernel
        .node_by_key(kernel.find_by_test_id("bump")[0])
        .unwrap()
        .id;
    p.dispatching(Some(boottime()));
    // At 1.6 s: the redirect due at 1.5 s runs first, then the press (a timer over
    // 1 s does not hold TTI, so startup settled before it).
    p.dispatch_press(id, 1600., false);
    p.dispatching(None);
    m.turn(&mut p, false);
    flip(&mut m, &mut p, boottime() + 0.016);
    let events = take();
    assert_eq!(kinds(&events)[0], "navigation cold_ttr");
    assert_eq!(events[0].1["url"], "/detail/7");
    assert_eq!(
        events[0].1["exact.nav.cause"], "program",
        "the timer navigated, not the press"
    );
}

/// The platform's own Back (a mouse's back button, Alt+Left) with no authored Back
/// control is the runner's `host_back`, not a dispatched event: it is still the input's.
#[test]
fn the_platforms_back_is_its_inputs_doing() {
    let (mut p, mut m, _) = launch(DUE);
    while !m.launch.done() && p.dirty() {
        flip(&mut m, &mut p, boottime());
    }
    // The redirect pushes the detail screen.
    assert!(p.advance(1600.0).is_none());
    m.turn(&mut p, false);
    flip(&mut m, &mut p, boottime() + 0.016);
    take();

    let pressed = boottime();
    p.dispatching(Some(pressed));
    assert!(p.system_back(1700.), "the stack pops");
    p.dispatching(None);
    m.turn(&mut p, false);
    flip(&mut m, &mut p, boottime() + 0.016);
    let events = take();
    assert_eq!(kinds(&events)[0], "navigation warm_ttr");
    assert_eq!(events[0].1["url"], "/");
    assert_eq!(events[0].1["exact.nav.cause"], "input");
}

/// Home's pad opens the detail screen when the pointer goes down on it.
const POINTER_DOWN: &str = r#"routes nav
  home "/"
    detail "/detail/:id"
component App
  action open(e: PointerEvent)
    nav = push(nav, "/detail/7")
  view
    main navigationKey=`${top(nav).id}` width="100%" height="100%"
      for e in stack(nav) key=e.id
        column navigationKey=`${e.id}` position="absolute" inset=0
          if e.name == "home"
            box pointerdown=open testId="pad" width=200 height=100
          if e.name == "detail"
            text "Detail"
"#;

/// A `pointerdown` handler that pushes a route is its press's doing, timed from
/// the press: the display loop dispatches each input, the lift too, in a window
/// of its own.
#[test]
fn a_pointerdowns_navigation_is_its_inputs_doing() {
    let (mut p, mut m, _) = launch(POINTER_DOWN);
    while !m.launch.done() && p.dirty() {
        flip(&mut m, &mut p, boottime());
    }
    assert!(m.launch.done(), "home settles");
    take();

    let pressed = boottime();
    p.dispatching(Some(pressed));
    p.pointer_down(20., 20., 0.).unwrap();
    p.dispatching(None);
    p.dispatching(Some(boottime()));
    p.pointer_up(20., 20., 1.).unwrap();
    p.dispatching(None);
    m.turn(&mut p, false);
    let shown = boottime() + 0.016;
    flip(&mut m, &mut p, shown);
    let events = take();
    assert_eq!(kinds(&events), ["navigation cold_ttr", "navigation tti"]);
    assert_eq!(events[0].1["url"], "/detail/7");
    assert_eq!(events[0].1["exact.nav.cause"], "input");
    let value = events[0].1["value"].as_f64().unwrap();
    assert!(
        (value - (shown - pressed)).abs() < 1e-9,
        "from the press: {value}"
    );
}

fn json(s: &str) -> Value {
    Value::String(s.into())
}
