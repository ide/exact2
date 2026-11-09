use super::super::*;
use crate::surfaces::control_tests::{
    boot as boot_canvas, done, input_count, last_input, set_canvas_probe,
};

const SOURCE: &str = r#"component App
  state seen = ""
  state off = false
  state ups = 0
  action swiped(name: string, e: SwipeEvent)
    seen = `${seen}${name}-${e.direction} `
  action pressed
    seen = `${seen}press `
  action disable
    off = true
  action moved(dx: number, dy: number)
    seen = "pan"
  action stopped(dx: number, dy: number)
    off = true
  action lifted
    ups = ups + 1
  view
    column width=400
      box testId="outer" width=400 height=320 swipe=swiped("outer") swipe-direction="left right up down"
        box testId="inner" width=400 height=30 swipe=swiped("inner") swipe-direction="left" pointerup=lifted
        button testId="button" width=400 height=30 press=pressed
          text "Press"
        input testId="field" width=400 height=30 value="" swipe=swiped("field") swipe-direction="left"
        input testId="check" type="checkbox" width=400 height=30
        box testId="off" disabled=true width=400 height=30 swipe=swiped("off") swipe-direction="left"
        box disabled=true
          box testId="under" width=400 height=30 swipe=swiped("under") swipe-direction="left"
        box testId="list" width=400 height=60 overflow-y="auto"
          box width=400 height=200
        box testId="pan" width=400 height=30 pan=stopped touch-action="none" disabled=off pointerup=lifted
        box testId="fickle" width=400 height=30 swipe=swiped("fickle") swipe-direction="left" disabled=off pointerup=disable
      box testId="pair" width=400 height=30 swipe=swiped("pair") swipe-direction="up" touch-count=2
      box display="none"
        box testId="hidden" width=100 height=30 swipe=swiped("hidden") swipe-direction="left"
      box inert=true
        box testId="inert" width=100 height=30 swipe=swiped("inert") swipe-direction="left"
      box height=80
        box testId="scaled" width=100 height=30 scale=2 transform-origin="0 0" swipe=swiped("scaled") swipe-direction="left"
      box testId="right" width=200 height=40 swiperight=pressed swipe=swiped("right") swipe-direction="left up down" touch-action="none" translate="0px 0px" pointerup=lifted
      text seen testId="seen"
      text `${ups}` testId="ups"
"#;

fn boot() -> Presenter<()> {
    boot_source(SOURCE)
}
fn boot_source(source: &str) -> Presenter<()> {
    let (mut p, error) = Presenter::boot_with(
        &crate::test_plan(source),
        (),
        (400., 700.),
        1.,
        PathBuf::new(),
        PainterChoice::Cpu,
    )
    .unwrap();
    assert!(error.is_none(), "{error:?}");
    p.set_pointer_kind(PointerKind::Touch);
    p.serve_overlays();
    p.frame();
    p
}
fn id(p: &Presenter<()>, name: &str) -> ViewId {
    let k = p.host.kernel();
    k.node_by_key(k.find_by_test_id(name)[0]).unwrap().id
}
fn seen(p: &Presenter<()>) -> &str {
    p.host
        .kernel()
        .node(id(p, "seen"))
        .unwrap()
        .props
        .str(PropId::Text)
        .unwrap_or("")
}
fn swipe(
    p: &mut Presenter<()>,
    name: &str,
    direction: &str,
    at: Option<(f32, f32)>,
) -> Result<serde_json::Value, String> {
    let id = id(p, name);
    p.agent_swipe(id, direction, at)
        .map(|r| serde_json::from_str(&r).unwrap())
}
fn agent(p: &mut Presenter<()>, request: serde_json::Value) -> serde_json::Value {
    serde_json::from_str(&crate::agent::handle(p, &request.to_string())).unwrap()
}
fn ups(p: &mut Presenter<()>) -> serde_json::Value {
    agent(p, serde_json::json!({"op": "state"}))["slots"]["ups"].clone()
}

#[test]
fn agent_terminal_phases_clear_the_fling_with_or_without_a_live_contact() {
    for phase in ["up", "cancel"] {
        for cancelled in [false, true] {
            let mut p = boot();
            let inner = id(&p, "inner");
            let down = agent(
                &mut p,
                serde_json::json!({"op": "tap", "phase": "down", "id": inner}),
            );
            assert!(down.get("error").is_none(), "{down}");
            assert_eq!(down["contact"], true);
            if cancelled {
                p.pointer_cancel(p.host.now()).unwrap();
                assert!(p.contact.is_none());
                assert!(p.landed.is_some(), "a physical cancel keeps the fling");
            }
            let now = p.host.now();
            let ended = agent(&mut p, serde_json::json!({"op": "tap", "phase": phase}));
            assert!(ended.get("error").is_none(), "{ended}");
            assert_eq!(ended["contact"], false);
            assert!(p.landed.is_none());
            assert_eq!(ups(&mut p), 1, "one up for the contact");
            swipe(&mut p, "inner", "left", None).unwrap();
            for again in ["up", "cancel"] {
                let ended = agent(&mut p, serde_json::json!({"op": "tap", "phase": again}));
                assert!(ended.get("error").is_none(), "{ended}");
                assert_eq!(ended["contact"], false);
            }
            assert_eq!(ups(&mut p), 1, "no-op terminals send no second up");
            assert_eq!(p.host.now(), now);
            assert_eq!(seen(&p), "inner-left ");
            swipe(&mut p, "inner", "left", None).unwrap();
        }
    }
}

#[test]
fn agent_terminal_phases_release_an_observer_after_the_gesture_contact_ends() {
    for phase in ["up", "cancel"] {
        let mut p = boot();
        let row = id(&p, "right");
        let down = agent(
            &mut p,
            serde_json::json!({"op": "tap", "phase": "down", "id": row}),
        );
        assert_eq!(down["contact"], true, "{down}");
        let moved = agent(
            &mut p,
            serde_json::json!({"op": "tap", "phase": "move", "dx": -30, "dy": 0}),
        );
        assert!(moved.get("error").is_none(), "{moved}");
        assert_eq!(
            moved["contact"], false,
            "the resting swiperight refused leftward motion"
        );
        assert!(p.pointer_held.is_some());
        let ended = agent(&mut p, serde_json::json!({"op": "tap", "phase": phase}));
        assert!(ended.get("error").is_none(), "{ended}");
        assert!(p.landed.is_none());
        assert!(p.pointer_held.is_none());
        assert_eq!(ups(&mut p), 1);
        swipe(&mut p, "right", "left", None).unwrap();
        assert_eq!(seen(&p), "right-left ");
    }
}

#[test]
fn agent_terminal_phases_clear_a_down_retired_by_its_pointerdown_handler() {
    let source = SOURCE.replace(
        "disabled=off pointerup=disable",
        "disabled=off pointerdown=disable pointerup=lifted",
    );
    for phase in ["up", "cancel"] {
        let mut p = boot_source(&source);
        let fickle = id(&p, "fickle");
        let now = p.host.now();
        let down = agent(
            &mut p,
            serde_json::json!({"op": "tap", "phase": "down", "id": fickle}),
        );
        assert!(down.get("error").is_none(), "{down}");
        assert_eq!(down["delivery"], "presenter");
        assert_eq!(down["contact"], false);
        assert_eq!(
            p.host
                .kernel()
                .node(fickle)
                .unwrap()
                .props
                .bool(PropId::Disabled),
            Some(true)
        );
        assert!(p.contact.is_none());
        assert!(p.landed.is_some(), "retirement keeps the touch's fling");
        assert!(p.pointer_held.is_none());
        assert_eq!(p.pointer_buttons, 0);
        assert_eq!(ups(&mut p), 1, "retirement already sent the observer's up");
        assert!(swipe(&mut p, "inner", "left", None)
            .unwrap_err()
            .contains("already down"));
        let ended = agent(&mut p, serde_json::json!({"op": "tap", "phase": phase}));
        assert!(ended.get("error").is_none(), "{ended}");
        assert_eq!(ended["contact"], false);
        assert!(p.landed.is_none());
        assert!(p.pointer_held.is_none());
        assert_eq!(p.pointer_buttons, 0);
        assert_eq!(ups(&mut p), 1, "the terminal sends no second up");
        swipe(&mut p, "inner", "left", None).unwrap();
        assert_eq!(seen(&p), "inner-left ");
        assert_eq!(p.host.now(), now);
    }
}

#[test]
fn agent_terminal_phases_release_an_observer_after_a_pan_disables_its_node() {
    for phase in ["up", "cancel"] {
        let mut p = boot();
        let pan = id(&p, "pan");
        let down = agent(
            &mut p,
            serde_json::json!({"op": "tap", "phase": "down", "id": pan}),
        );
        assert_eq!(down["contact"], true, "{down}");
        let moved = agent(
            &mut p,
            serde_json::json!({"op": "tap", "phase": "move", "dx": -30, "dy": 0}),
        );
        assert!(moved.get("error").is_none(), "{moved}");
        assert_eq!(moved["contact"], false);
        assert!(
            p.host
                .kernel()
                .node(pan)
                .unwrap()
                .props
                .bool(PropId::Disabled)
                == Some(true)
        );
        assert!(
            p.landed.is_none(),
            "the pan took the contact before disabling itself"
        );
        assert!(p.pointer_held.is_some());
        assert_eq!(ups(&mut p), 0);
        let ended = agent(&mut p, serde_json::json!({"op": "tap", "phase": phase}));
        assert!(ended.get("error").is_none(), "{ended}");
        assert_eq!(ended["contact"], false);
        assert!(p.pointer_held.is_none());
        assert_eq!(ups(&mut p), 1, "the disabled node still hears its up once");
        swipe(&mut p, "inner", "left", None).unwrap();
        let again = agent(&mut p, serde_json::json!({"op": "tap", "phase": phase}));
        assert!(again.get("error").is_none(), "{again}");
        assert_eq!(ups(&mut p), 1);
        assert_eq!(seen(&p), "inner-left ");
    }
}

#[test]
fn a_discrete_left_swipe_yields_only_to_a_swiperight_that_would_begin() {
    for open in [false, true] {
        let source = if open {
            SOURCE.replace("translate=\"0px 0px\"", "translate=\"80px 0px\"")
        } else {
            SOURCE.to_owned()
        };
        let mut p = boot_source(&source);
        let row = id(&p, "right");
        assert_eq!(
            p.host.presented(row).translate.0,
            if open { 80. } else { 0. }
        );
        let result = swipe(&mut p, "right", "left", None);
        if open {
            assert!(result.unwrap_err().contains("drag on the hit path"));
        } else {
            assert_eq!(result.unwrap()["delivery"], "recognized");
        }
        let (x, y) = p.box_of(row).unwrap().center();
        let now = p.host.now();
        p.pointer_down(x, y, now).unwrap();
        assert_eq!(p.pointer_move(x - 30., y, now + 10.).unwrap(), open);
        assert_eq!(
            p.landed.is_none(),
            open,
            "only a gesture that began takes the fling"
        );
        p.pointer_cancel(now + 10.).unwrap();
    }
    let mut p = boot_source(&SOURCE.replace(
        "column width=400",
        "column width=400 pan=moved touch-action=\"none\"",
    ));
    swipe(&mut p, "right", "left", None).unwrap();
    assert_eq!(
        seen(&p),
        "right-left ",
        "a refused inner swipe does not fall through to an outer pan"
    );
    let mut p =
        boot_source(&SOURCE.replace("testId=\"right\" width", "testId=\"right\" pan=moved width"));
    assert!(
        swipe(&mut p, "right", "left", None)
            .unwrap_err()
            .contains("drag on the hit path"),
        "the same node's pan precedes its swipe"
    );
}

#[test]
fn multifinger_admission_matches_the_second_pointer_cancel_then_native_fling() {
    for (gesture, direction, delta) in [
        ("pan=moved touch-action=\"none\"", "up", (0., -30.)),
        (
            "swiperight=pressed touch-action=\"none\" translate=\"80px 0px\"",
            "left",
            (-30., 0.),
        ),
    ] {
        for pointers in [1, 2] {
            let source = SOURCE.replace(
                "box testId=\"pair\" width=400 height=30 swipe=swiped(\"pair\") swipe-direction=\"up\" touch-count=2",
                &format!("box testId=\"pair\" width=400 height=30 swipe=swiped(\"pair\") swipe-direction=\"{direction}\" touch-count={pointers} {gesture} pointerup=lifted"),
            );
            let mut recognized = boot_source(&source);
            let result = swipe(&mut recognized, "pair", direction, None);
            if pointers == 1 {
                assert!(result.unwrap_err().contains("drag on the hit path"));
                assert_eq!(seen(&recognized), "");
            } else {
                assert_eq!(result.unwrap()["delivery"], "recognized");
                assert_eq!(seen(&recognized), format!("pair-{direction} "));
            }
            assert!(recognized.contact.is_none());
            assert!(recognized.landed.is_none());
            assert!(recognized.pointer_held.is_none());
            assert_eq!(ups(&mut recognized), 0, "preflight made no touch");

            let mut physical = boot_source(&source);
            let (x, y) = physical.box_of(id(&physical, "pair")).unwrap().center();
            let now = physical.host.now();
            assert!(physical.pointer_down(x, y, now).unwrap());
            assert!(physical.contact.is_some());
            assert!(physical.landed.is_some());
            if pointers == 1 {
                assert!(physical
                    .pointer_move(x + delta.0, y + delta.1, now + 10.)
                    .unwrap());
                assert!(physical.landed.is_none(), "the single-pointer drag began");
                assert!(!physical.fling(direction, pointers, now + 20.).unwrap());
                physical.pointer_cancel(now + 20.).unwrap();
            } else {
                // ExactView sends the second pointer as cancel before motion.
                physical.pointer_cancel(now + 1.).unwrap();
                assert!(physical.contact.is_none());
                assert!(physical.landed.is_some(), "cancel preserves the first hit");
                assert!(physical.pointer_held.is_none());
                assert!(
                    swipe(&mut physical, "pair", direction, None)
                        .unwrap_err()
                        .contains("already down"),
                    "the pending native fling still owns its touch"
                );
                assert!(!physical
                    .pointer_move(x + delta.0, y + delta.1, now + 10.)
                    .unwrap());
                assert!(physical.fling(direction, pointers, now + 20.).unwrap());
                physical
                    .pointer_up(x + delta.0, y + delta.1, now + 20.)
                    .unwrap();
                assert_eq!(seen(&physical), seen(&recognized));
            }
            assert!(physical.contact.is_none());
            assert!(physical.landed.is_none());
            assert!(physical.pointer_held.is_none());
            assert_eq!(ups(&mut physical), 1, "one observer up for the touch");
        }
    }
}

#[test]
fn swiperight_yields_the_same_system_edge_in_preflight_and_live_input() {
    let mut p = boot_source(&SOURCE.replace("translate=\"0px 0px\"", "translate=\"80px 0px\""));
    assert!(p
        .set_window(Window {
            size: (400., 700.),
            gestures: [0., 20., 0., 100.],
            ..Default::default()
        })
        .is_none());
    swipe(&mut p, "right", "left", Some((5., 20.))).unwrap();
    let b = p.box_of(id(&p, "right")).unwrap();
    let ((x, y), _) = b.point_at(Some((5., 20.))).unwrap();
    assert!(p.in_gesture_edge(x));
    let now = p.host.now();
    p.pointer_down(x, y, now).unwrap();
    assert!(!p.pointer_move(x - 30., y, now + 10.).unwrap());
    assert!(p.fling("left", 1, now + 10.).unwrap());
    p.pointer_up(x - 30., y, now + 10.).unwrap();
    assert_eq!(seen(&p), "right-left right-left ");
}

#[test]
fn the_agent_uses_the_innermost_live_swipe_and_the_nodes_count() {
    let mut p = boot();
    let r = swipe(&mut p, "inner", "left", None).unwrap();
    assert_eq!(r["delivery"], "recognized");
    assert_eq!(r["at"], serde_json::json!([200., 15.]));
    assert!(swipe(&mut p, "outer", "left", Some((100., 15.)))
        .unwrap_err()
        .contains("nearer"));
    swipe(&mut p, "outer", "right", Some((100., 15.))).unwrap();
    swipe(&mut p, "pair", "up", None).unwrap();
    assert!(swipe(&mut p, "pair", "left", None).is_err());
    assert!(swipe(&mut p, "off", "left", None).is_err());
    assert!(swipe(&mut p, "under", "left", None).is_err());
    assert!(swipe(&mut p, "hidden", "left", None).is_err());
    assert!(swipe(&mut p, "inert", "left", None).is_err());
    let y = p.rect_of(id(&p, "off")).unwrap().1 + 15.;
    swipe(&mut p, "outer", "left", Some((100., y))).unwrap();
    assert_eq!(seen(&p), "inner-left outer-right pair-up outer-left ");
    assert!(
        p.landed.is_none(),
        "the recognized fling leaves no pending hit"
    );
}

struct Fields;
impl crate::fields::FieldMetrics for Fields {
    fn measure(
        &self,
        _face: &crate::fields::FieldFace,
        _text: &str,
        _width: Option<f32>,
    ) -> [f32; 3] {
        [0., 20., 15.]
    }
}

#[test]
fn a_disabled_first_hit_arms_no_ancestor_pan_before_its_fling() {
    let _fields = crate::fields::host_here(&Fields, 1.);
    let with_pan = SOURCE.replace(
        "testId=\"outer\" width",
        "testId=\"outer\" pan=moved touch-action=\"none\" width",
    );
    for name in ["off", "under"] {
        let mut p = boot_source(&with_pan);
        let first = id(&p, name);
        let hit = p.host.kernel().node(first).unwrap().key;
        let (x, y) = p.box_of(first).unwrap().center();
        let outer = id(&p, "outer");
        let (ox, oy, _, _) = p.rect_of(outer).unwrap();
        assert_eq!(p.hit(x, y), Some(first), "{name}");
        assert!(!p.input_live(hit));
        let now = p.host.now();
        let focus = p.focus;
        let reply = swipe(&mut p, "outer", "left", Some((x - ox, y - oy))).unwrap();
        assert_eq!(reply["delivery"], "recognized");
        assert_eq!(seen(&p), "outer-left ");
        assert_eq!(p.host.now(), now);
        assert_eq!(p.focus, focus);
        assert!(p.contact.is_none());
        assert!(p.landed.is_none());
        assert!(p.pointer_held.is_none());
        assert_eq!(p.pointer_buttons, 0);
        assert_eq!(ups(&mut p), 0, "recognition made no contact");

        assert_eq!(p.hit(x, y), Some(first));
        assert!(!p.pointer_down(x, y, now).unwrap());
        assert!(p.contact.is_none(), "the disabled hit arms no ancestor pan");
        assert_eq!(p.landed, Some(hit), "only the fling keeps the first hit");
        assert!(!p.pointer_move(x - 30., y, now + 10.).unwrap());
        assert_eq!(seen(&p), "outer-left ", "motion dispatched no pan");
        assert!(p.fling("left", 1, now + 20.).unwrap());
        assert_eq!(seen(&p), "outer-left outer-left ");
        p.pointer_up(x - 30., y, now + 20.).unwrap();
        assert!(p.contact.is_none());
        assert!(p.landed.is_none());
        assert!(p.pointer_held.is_none());
        assert_eq!(p.pointer_buttons, 0);
        assert_eq!(ups(&mut p), 0, "the refused down armed no pointer observer");
    }
}

#[test]
fn a_hosted_field_under_a_disabled_parent_keeps_the_readers_touch() {
    let _fields = crate::fields::host_here(&Fields, 1.);
    let source = SOURCE
        .replace(
            "testId=\"outer\" width",
            "testId=\"outer\" pan=moved touch-action=\"none\" width",
        )
        .replace(
            "        input testId=\"field\"",
            "        box disabled=true\n          input testId=\"field\"",
        );
    let mut p = boot_source(&source);
    let field = id(&p, "field");
    let (x, y) = p.box_of(field).unwrap().center();
    let outer = id(&p, "outer");
    let (ox, oy, _, _) = p.rect_of(outer).unwrap();
    assert_eq!(p.hit(x, y), Some(field));
    assert!(!p.input_live(p.host.kernel().node(field).unwrap().key));
    assert_eq!(p.scrollers_at(x, y).field, Some(field));
    let words = p.reader_fields(1.).expect("the hosted field's metadata");
    assert_eq!(words[0], 1);
    assert_eq!(words[1], field as i32);
    // Fields.at admits PLACED (1) without INERT (2); Fields.under accepts
    // the same field from scrollers_at before a down reaches the presenter.
    assert_eq!(words[3] & 3, 1);
    let px = |at: usize| f32::from_bits(words[at] as u32);
    assert!(x >= px(5) && x < px(5) + px(7));
    assert!(y >= px(6) && y < px(6) + px(8));
    let now = p.host.now();
    let focus = p.focus;
    let error = swipe(&mut p, "outer", "left", Some((x - ox, y - oy))).unwrap_err();
    assert!(error.contains("hosted text input keeps the touch"));
    assert_eq!(seen(&p), "");
    assert_eq!(p.host.now(), now);
    assert_eq!(p.focus, focus);
    assert!(p.contact.is_none());
    assert!(p.landed.is_none());
    assert!(p.pointer_held.is_none());
    assert_eq!(p.pointer_buttons, 0);
    assert_eq!(ups(&mut p), 0);
    assert_eq!(p.scrollers_at(x, y).field, Some(field));
    assert!(
        p.reader_fields(1.).is_none(),
        "refusal changes no field metadata"
    );
}

#[test]
fn the_agent_does_not_fling_over_a_live_control_editor_or_scroller() {
    // Install the reader's field hosting so its editor keeps its own touch
    let _fields = crate::fields::host_here(&Fields, 1.);
    let mut p = boot();
    for name in ["button", "field", "check", "list", "pan"] {
        let y = p.rect_of(id(&p, name)).unwrap().1 + 10.;
        assert!(
            swipe(&mut p, "outer", "down", Some((100., y))).is_err(),
            "{name}"
        );
    }
    assert!(
        swipe(&mut p, "field", "left", None)
            .unwrap_err()
            .contains("text input"),
        "a hosted editor keeps even its own swipe's touch"
    );
    let y = p.rect_of(id(&p, "list")).unwrap().1 + 10.;
    swipe(&mut p, "outer", "left", Some((100., y))).unwrap();
    assert_eq!(
        seen(&p),
        "outer-left ",
        "a vertical scroller leaves the other axis"
    );
}

#[test]
fn the_agent_maps_local_points_through_the_paints_transform_and_rejects_bad_points() {
    let mut p = boot();
    let scaled = id(&p, "scaled");
    let b = p.box_of(scaled).unwrap();
    assert_eq!(b.rect.2, 200.);
    let ((x, y), local) = b.point_at(Some((75., 15.))).unwrap();
    assert_eq!(local, (75., 15.));
    assert_eq!(p.hit(x, y), Some(scaled));
    let r = swipe(&mut p, "scaled", "left", Some(local)).unwrap();
    assert_eq!(r["at"], serde_json::json!([75., 15.]));
    for at in [(100., 15.), (-1., 0.), (f32::NAN, 0.), (0., f32::INFINITY)] {
        assert!(swipe(&mut p, "scaled", "left", Some(at)).is_err());
    }
    assert!(swipe(&mut p, "scaled", "sideways", None).is_err());
    assert_eq!(seen(&p), "scaled-left ");
}

#[test]
fn a_pending_contact_is_refused_and_its_real_fling_still_rechecks_the_up_handler() {
    let mut p = boot();
    let (x, y) = p.box_of(id(&p, "fickle")).unwrap().center();
    let now = p.host.now();
    p.pointer_down(x, y, now).unwrap();
    assert!(swipe(&mut p, "fickle", "left", None)
        .unwrap_err()
        .contains("already down"));
    assert!(p.contact.is_some());
    assert!(p.landed.is_some());
    assert_eq!(seen(&p), "");
    assert!(p.fling("left", 1, now + 10.).unwrap());
    assert_eq!(
        seen(&p),
        "outer-left ",
        "the authored up disabled the inner swipe"
    );
    p.pointer_up(x, y, now + 10.).unwrap();
    assert!(p.landed.is_none());
    assert!(swipe(&mut p, "fickle", "left", None).is_err());
}

#[test]
fn a_clipped_or_covered_start_is_refused() {
    let source = r#"component App
  state seen = "untouched"
  action swiped
    seen = "swiped"
  view
    box width=400 height=400
      box width=100 height=30 overflow="hidden"
        box testId="clipped" width=200 height=30 swipe=swiped swipe-direction="left"
      box testId="covered" position="absolute" top=60 width=100 height=30 swipe=swiped swipe-direction="left"
      box position="absolute" top=60 width=100 height=30
      text seen testId="seen"
"#;
    let (mut p, error) = Presenter::boot_with(
        &crate::test_plan(source),
        (),
        (400., 700.),
        1.,
        PathBuf::new(),
        PainterChoice::Cpu,
    )
    .unwrap();
    assert!(error.is_none(), "{error:?}");
    p.frame();
    assert!(swipe(&mut p, "clipped", "left", Some((150., 15.))).is_err());
    assert!(swipe(&mut p, "covered", "left", None).is_err());
    assert_eq!(seen(&p), "untouched");
}

#[test]
fn a_second_fingers_cancel_keeps_a_fling_pending_but_a_final_lift_leaves_none() {
    let mut p = boot();
    let (x, y) = p.box_of(id(&p, "inner")).unwrap().center();
    let now = p.host.now();
    p.pointer_down(x, y, now).unwrap();
    p.pointer_cancel(now + 1.).unwrap();
    assert!(p.contact.is_none());
    let invalid = agent(
        &mut p,
        serde_json::json!({"op": "tap", "phase": "cancel", "ms": 1}),
    );
    assert_eq!(
        invalid["malformed"], true,
        "an invalid terminal must leave the touch alone"
    );
    assert!(swipe(&mut p, "inner", "left", None)
        .unwrap_err()
        .contains("already down"));
    assert!(
        p.landed.is_some(),
        "the touch's fling outlives its first pointer's cancel"
    );
    assert!(p.fling("left", 2, now + 2.).unwrap());
    p.pointer_up(x, y, now + 2.).unwrap();
    swipe(&mut p, "inner", "left", None).unwrap();
    p.pointer_down(x, y, now + 3.).unwrap();
    p.pointer_up(x, y, now + 4.).unwrap();
    assert!(
        p.landed.is_none(),
        "a completed tap leaves no pending fling"
    );
    swipe(&mut p, "inner", "left", None).unwrap();
    assert_eq!(seen(&p), "inner-left inner-left inner-left ");
}

#[test]
fn reader_terminals_end_scrolling_and_pending_multifinger_touches_once() {
    let source = SOURCE
        .replace(
            "testId=\"list\" width",
            "testId=\"list\" pointerup=lifted width",
        )
        .replace(
            "testId=\"pair\" width",
            "testId=\"pair\" pointerup=lifted width",
        );
    for scrolling in [true, false] {
        for cancelled in [false, true] {
            let mut p = boot_source(&source);
            let target = id(&p, if scrolling { "list" } else { "pair" });
            let (x, y) = p.box_of(target).unwrap().center();
            let first = p.hit(x, y).unwrap();
            let hit = p.host.kernel().node(first).unwrap().key;
            let under = p.scrollers_at(x, y);
            if scrolling {
                assert!(under.chain.iter().any(|s| s.id == target && s.axes.1));
                assert_eq!(under.claims, (false, false));
            }
            let now = p.host.now();
            p.reader_touch(0, x, y, now).unwrap();
            assert!(p.contact.is_some());
            assert_eq!(p.landed, Some(hit));
            assert_eq!(ups(&mut p), 0);
            // Scrolling takes over, or a second pointer ends recognition.
            // Both preserve the first hit until the physical terminal.
            p.reader_touch(3, x, y, now + 1.).unwrap();
            assert!(p.contact.is_none());
            assert!(p.pointer_held.is_none());
            assert_eq!(p.landed, Some(hit));
            assert_eq!(ups(&mut p), 1, "takeover releases the observer once");
            assert!(swipe(&mut p, "inner", "left", None)
                .unwrap_err()
                .contains("already down"));
            assert_eq!(
                p.landed,
                Some(hit),
                "a refused drive keeps the physical touch"
            );
            assert_eq!(seen(&p), "");

            // Both consumed scrolling terminals end as cancel 5; ordinary
            // non-scrolling lifts still use up 1.
            let terminal = if scrolling || cancelled { 5 } else { 1 };
            p.reader_touch(terminal, x, y, now + 20.).unwrap();
            assert!(p.contact.is_none());
            assert!(p.landed.is_none());
            assert!(p.pointer_held.is_none());
            assert_eq!(p.pointer_buttons, 0);
            assert_eq!(ups(&mut p), 1, "the physical terminal sends no second up");
            assert!(!p
                .fling(if scrolling { "down" } else { "up" }, 2, now + 20.)
                .unwrap());
            swipe(&mut p, "inner", "left", None).unwrap();
            assert_eq!(seen(&p), "inner-left ");
            for phase in ["up", "cancel"] {
                let reply = agent(&mut p, serde_json::json!({"op": "tap", "phase": phase}));
                assert!(reply.get("error").is_none(), "{reply}");
                assert_eq!(reply["contact"], false);
            }
            assert_eq!(ups(&mut p), 1);
        }
    }
}

#[test]
fn physical_reader_cancel_releases_a_live_observer_once_and_retires_its_fling() {
    let mut p = boot();
    let (x, y) = p.box_of(id(&p, "inner")).unwrap().center();
    let now = p.host.now();
    p.reader_touch(0, x, y, now).unwrap();
    assert!(p.contact.is_some());
    assert!(p.pointer_held.is_some());
    assert!(p.landed.is_some());
    for _ in 0..2 {
        p.reader_touch(5, x, y, now + 10.).unwrap();
        assert!(p.contact.is_none());
        assert!(p.pointer_held.is_none());
        assert!(p.landed.is_none());
        assert_eq!(p.pointer_buttons, 0);
        assert_eq!(ups(&mut p), 1);
    }
    swipe(&mut p, "inner", "left", None).unwrap();
    assert_eq!(seen(&p), "inner-left ");
}

const CANVAS_SOURCE: &str = r#"component App
  state seen = ""
  state downs = 0
  state ups = 0
  action swiped(e: SwipeEvent)
    seen = `${seen}${e.direction} `
  action moved(dx: number, dy: number)
    seen = "pan"
  action pressed
    seen = "press"
  action lowered
    downs = downs + 1
  action lifted
    ups = ups + 1
  view
    column width=100
      input testId="editor" value="" width=100 height=30
      canvas testId="canvas" width=100 height=100 swipe=swiped swipe-direction="left" touch-count=1 pointerdown=lowered pointerup=lifted
        box testId="hit" width=100 height=100
      text seen testId="seen"
"#;

#[test]
fn recognized_canvas_admission_matches_native_down_candidate_order_and_fling() {
    for owns_input in [true, false] {
        for gesture in [
            "",
            "pan=moved touch-action=\"none\"",
            "swiperight=pressed touch-action=\"none\" translate=\"0px 0px\"",
        ] {
            for pointers in [1, 2] {
                let source = CANVAS_SOURCE.replace(
                    "touch-count=1",
                    &format!("touch-count={pointers} {gesture}"),
                );
                let (mut p, path) = boot_canvas(&source, &["canvas"]);
                p.set_pointer_kind(PointerKind::Touch);
                let canvas = id(&p, "canvas");
                // Probe world 98 declines gpu_wants_input but remains a canvas.
                set_canvas_probe(&mut p, canvas, if owns_input { 1 } else { 98 });
                let editor = id(&p, "editor");
                p.focus = Some(editor);
                let now = p.host.now();
                let canvas_takes = owns_input && gesture.is_empty();
                let pan_takes = gesture.starts_with("pan=") && pointers == 1;
                let admitted = !canvas_takes && !pan_takes;

                let result = swipe(&mut p, "canvas", "left", None);
                if canvas_takes {
                    assert!(result
                        .unwrap_err()
                        .contains("canvas at the start takes input"));
                } else if pan_takes {
                    assert!(result.unwrap_err().contains("drag on the hit path"));
                } else {
                    assert_eq!(result.unwrap()["delivery"], "recognized");
                }
                assert_eq!(seen(&p), if admitted { "left " } else { "" });
                assert_eq!(p.host.now(), now);
                assert_eq!(p.focus, Some(editor), "preflight moves no focus");
                assert_eq!(input_count(&p), 0, "preflight sends no GPU input");
                assert!(p.contact.is_none());
                assert!(p.landed.is_none());
                assert!(p.pointer_held.is_none());
                assert_eq!(p.pointer_buttons, 0);
                for slot in ["downs", "ups"] {
                    assert_eq!(
                        p.host.runner().slot(slot),
                        Some(&exact_plan::Value::Number(0.)),
                        "preflight sends no {slot}"
                    );
                }

                let (x, y) = p.box_of(canvas).unwrap().center();
                assert_eq!(p.hit(x, y), Some(id(&p, "hit")));
                assert!(p.pointer_down(x, y, now).unwrap());
                assert_eq!(p.contact_canvas(), canvas_takes.then_some(canvas));
                assert_eq!(p.landed.is_none(), canvas_takes);
                assert_eq!(input_count(&p), u32::from(canvas_takes));
                if canvas_takes {
                    let (_, _, event) = last_input(&p);
                    assert_eq!(event["phase"], "down");
                    assert_eq!(event["kind"], "touch");
                    assert_eq!(event["buttons"], 1);
                }
                if pointers == 2 {
                    // The reader cancels its one-pointer contact before motion.
                    p.pointer_cancel(now + 1.).unwrap();
                    assert!(p.contact.is_none());
                    assert_eq!(p.landed.is_none(), canvas_takes);
                } else if !canvas_takes {
                    assert_eq!(p.pointer_move(x - 30., y, now + 10.).unwrap(), pan_takes);
                }
                assert_eq!(p.fling("left", pointers, now + 20.).unwrap(), admitted);
                if !canvas_takes {
                    assert_eq!(input_count(&p), 0, "no GPU input before terminal release");
                }
                p.pointer_up(x - 30., y, now + 20.).unwrap();
                assert_eq!(
                    seen(&p),
                    if admitted {
                        "left left "
                    } else if pan_takes {
                        "pan"
                    } else {
                        ""
                    }
                );
                assert!(p.contact.is_none());
                assert!(p.landed.is_none());
                assert!(p.pointer_held.is_none());
                assert_eq!(p.pointer_buttons, 0);
                for slot in ["downs", "ups"] {
                    assert_eq!(
                        p.host.runner().slot(slot),
                        Some(&exact_plan::Value::Number(1.)),
                        "the physical touch sends {slot} once"
                    );
                }
                if !canvas_takes {
                    // Only the one-finger pan still has a contact at release;
                    // a free pointer over an input canvas sends one hover move.
                    let free_move = owns_input && !pan_takes;
                    assert_eq!(input_count(&p), u32::from(free_move));
                    if free_move {
                        let (probe, _, event) = last_input(&p);
                        assert_eq!(probe, 1);
                        assert_eq!(event["t"], "pointer");
                        assert_eq!(event["phase"], "move");
                        assert_eq!(event["buttons"], 0);
                        assert_eq!(event["kind"], "mouse");
                    }
                }
                done(p, path);
            }
        }
    }
}
