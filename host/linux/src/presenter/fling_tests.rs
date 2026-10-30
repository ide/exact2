//! LLP 1057.001 §8 on the Android reader: a fling the reader recognized goes,
//! at the lift, to the innermost swipe on the touch's first hit's path that
//! names its direction at its count. A `press` or control between keeps the
//! contact, and a gesture of the presenter's that took it leaves no fling.
use super::super::*;

const SOURCE: &str = r#"component App
  state seen = ""
  state x = 0
  action outer(e: SwipeEvent)
    seen = `${seen}outer-${e.direction} `
  action inner(e: SwipeEvent)
    seen = `${seen}inner-${e.direction} `
  action pair(e: SwipeEvent)
    seen = `${seen}pair-${e.direction} `
  action moved(dx: number, dy: number)
    x = x + dx
  action pressed
    x = x + 1000
  view
    column width=400 height=500
      box testId="outer" width=400 height=300 swipe=outer swipe-direction="left right down"
        box testId="inner" width=400 height=60 swipe=inner swipe-direction="left"
        box testId="pan" width=400 height=60 pan=moved touch-action="none"
        button testId="button" press=pressed width=200 height=60
          text "press"
      box testId="pair" width=400 height=100 swipe=pair swipe-direction="up" touch-count=2
      text seen testId="seen"
      text `${x}` testId="x"
"#;
fn boot() -> Presenter<()> {
    let (p, error) = Presenter::boot_with(
        &crate::test_plan(SOURCE),
        (),
        (400., 500.),
        1.,
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/caltrain")),
        PainterChoice::Cpu,
    )
    .unwrap();
    assert!(error.is_none(), "{error:?}");
    p
}
fn text(p: &Presenter<()>, name: &str) -> String {
    let k = p.host.kernel();
    let id = k.node_by_key(k.find_by_test_id(name)[0]).unwrap().id;
    k.node(id)
        .unwrap()
        .props
        .str(PropId::Text)
        .unwrap_or("")
        .to_owned()
}
fn seen(p: &Presenter<()>) -> String {
    text(p, "seen")
}
/// One finger down at `y`, 60 px sideways, up; then the reader's fling.
fn flung(p: &mut Presenter<()>, y: f32, direction: &str, pointers: u32) -> bool {
    let t = p.host.now() + 100.;
    p.pointer_down(100., y, t).unwrap();
    p.pointer_move(70., y, t + 10.).unwrap();
    p.pointer_move(40., y, t + 20.).unwrap();
    p.pointer_up(40., y, t + 30.).unwrap();
    p.fling(direction, pointers, t + 30.).unwrap()
}

#[test]
fn a_fling_goes_to_the_innermost_swipe_that_names_its_direction() {
    let mut p = boot();
    assert!(flung(&mut p, 30., "left", 1));
    assert!(
        flung(&mut p, 30., "right", 1),
        "the inner one names no right"
    );
    assert!(
        !flung(&mut p, 30., "up", 1),
        "nor does the outer one name up"
    );
    assert!(flung(&mut p, 250., "down", 1));
    assert_eq!(seen(&p), "inner-left outer-right outer-down ");
    assert!(
        !p.fling("down", 1, p.host.now()).unwrap(),
        "one fling a touch"
    );
}

#[test]
fn a_press_between_keeps_the_contact_and_a_gesture_that_took_it_leaves_no_fling() {
    let mut p = boot();
    assert!(!flung(&mut p, 150., "left", 1), "the button keeps it");
    assert_eq!(
        text(&p, "x"),
        "1000",
        "a finger that lifts inside the button presses it"
    );
    assert!(!flung(&mut p, 90., "left", 1), "the pan began and took it");
    assert!(
        text(&p, "x").parse::<f64>().unwrap() < 1000.,
        "{}",
        text(&p, "x")
    );
    assert_eq!(seen(&p), "");
}

#[test]
fn a_count_takes_that_many_and_the_fling_outlives_the_contact_a_second_finger_ends() {
    let mut p = boot();
    assert!(
        !flung(&mut p, 350., "up", 1),
        "one finger is not the pair's"
    );
    // The reader sends a second finger's coming as a cancel; the touch goes on
    let t = p.host.now() + 100.;
    p.pointer_down(100., 350., t).unwrap();
    p.pointer_cancel(t + 10.).unwrap();
    assert!(p.fling("up", 2, t + 30.).unwrap());
    // With no count, the fling takes any number of fingers
    p.pointer_down(100., 250., t + 40.).unwrap();
    p.pointer_cancel(t + 50.).unwrap();
    assert!(p.fling("down", 2, t + 60.).unwrap());
    assert_eq!(seen(&p), "pair-up outer-down ");
}

fn view(p: &Presenter<()>, name: &str) -> ViewId {
    let k = p.host.kernel();
    k.node_by_key(k.find_by_test_id(name)[0]).unwrap().id
}

/// The agent's `tap … swipe` (§8.7): the fling a touch there would make, at
/// the node's count, once that touch would reach the node; refused, naming
/// why, when it would not.
#[test]
fn the_agents_swipe_is_the_fling_a_touch_there_would_make() {
    let mut p = boot();
    let (outer, inner, pair) = (view(&p, "outer"), view(&p, "inner"), view(&p, "pair"));
    let reply = p.agent_swipe(inner, "left", None).unwrap();
    assert!(reply.contains(r#""delivery":"recognized""#), "{reply}");
    assert!(
        p.agent_swipe(outer, "right", None).is_ok(),
        "its middle is its own"
    );
    assert!(p.agent_swipe(pair, "up", None).is_ok(), "at its count");
    assert_eq!(seen(&p), "inner-left outer-right pair-up ");
    let refusal =
        |p: &mut Presenter<()>, id, direction, at| p.agent_swipe(id, direction, at).unwrap_err();
    assert!(refusal(&mut p, outer, "up", None).contains("takes no swipe to the up"));
    assert!(
        refusal(&mut p, outer, "left", Some((100., 30.))).contains(&format!("#{inner}, nearer"))
    );
    assert!(
        refusal(&mut p, outer, "left", Some((100., 150.))).contains("keeps the contact"),
        "the button"
    );
    assert!(refusal(&mut p, outer, "down", Some((100., 400.))).contains("inside its box"));
    assert_eq!(seen(&p), "inner-left outer-right pair-up ");
}
