//! Screen swaps and projected route titles.

use super::warnings::{route, warned};

const SCREEN: &str = "lower-screen-by-state";

/// The line `needle` is on, from 1.
fn line_of(src: &str, needle: &str) -> u32 {
    let at = src
        .find(needle)
        .unwrap_or_else(|| panic!("{needle}\n{src}"));
    src[..at].matches('\n').count() as u32 + 1
}

/// recipe-finder's round-7 page: its screens chosen in `choice`, inside one
/// `scroll` under a bar laid out by hand, with no `header` (LLP 1116.005).
fn finder(choice: &str) -> String {
    let choice: String = choice.lines().map(|l| format!("        {l}\n")).collect();
    format!(
        "shape Meal\n  id: string\n  name: string\ncomponent App\n  state query = \"\"\n  state chosen = []\n  state shared = \"\"\n  state tab = \"all\"\n  state open2 = false\n  resource meals = searchMeals(query) as shape Meal[] else empty()\n  resource viewport = exactViewport() as shape Meal else empty()\n  derive showingDetail = chosen.length > 0\n  action edit(v: string)\n    query = v\n  action open(m: Meal)\n    chosen = [m]\n  action back\n    chosen = []\n  action share(m: Meal)\n    shared = m.name\n  action pick(t: string)\n    tab = t\n    chosen = []\n  action toggle\n    open2 = not open2\n  view\n    column height=\"100%\" display=\"flex\" flex-direction=\"column\"\n      row padding=16\n        text \"Recipe Finder\" font-weight=700\n      scroll flex=1 min-height=0\n{choice}"
    )
}

/// The detail: Back, its heading deep in its layout, one more control.
const DETAIL: &str = "  column gap=16\n    button press=back testId=\"back\"\n      text \"Back to recipes\"\n    row gap=16\n      column\n        text m.name role=\"heading\" aria-level=1\n    button press=share(m) testId=\"share\"\n      text \"Share\"\n";
/// The list: its heading, a search field and rows that open the detail.
const LIST: &str = "  column gap=16\n    text \"What sounds good today?\" role=\"heading\" aria-level=1\n    input value=query input=edit type=\"search\" aria-label=\"Search\"\n    for m in meals key=m.id\n      button press=open(m) testId=`meal-${m.id}`\n        text m.name\n";

#[test]
fn screens_swapped_by_state_without_routes_are_named_with_the_repair() {
    // recipe-finder: Back left the app, a reload lost the recipe.
    let when = format!(
        "if showingDetail\n  for m in chosen key=m.id\n{}else\n{LIST}",
        DETAIL
            .replace("\n  ", "\n    ")
            .replacen("  column", "    column", 1)
    );
    let src = finder(&when);
    assert_eq!(
        warned(&src),
        [(SCREEN.to_string(), line_of(&src, "if showingDetail"))]
    );
    let (_, warnings) = contract::compile_warned(&src);
    let m = &warnings[0].message;
    assert!(
        m.starts_with("this `if` swaps the page between screens by state")
            && m.contains("the browser's Back leaves the app, a reload loses the place and no screen can be linked")
            && m.contains("`routes` with a path for each, `push` to open one")
            && m.contains("`contract vocab screen`"),
        "{m}"
    );
    // The same screens through a `match` on the chosen option, and as a
    // chain with no last `else`, after a loading arm (flashcards).
    let matched = finder(&format!(
        "match first(chosen)\n  case some(m)\n{}  case none\n{}",
        DETAIL
            .replace("\n  ", "\n    ")
            .replacen("  column", "    column", 1),
        LIST.replace("\n  ", "\n    ")
            .replacen("  column", "    column", 1)
    ));
    assert_eq!(
        warned(&matched),
        [(SCREEN.to_string(), line_of(&matched, "match first"))]
    );
    let chain = finder(&format!("if pending(meals)\n  progress aria-label=\"Loading\"\nelse if chosen.length == 0\n{LIST}else if chosen.length > 0\n  for m in chosen key=m.id\n{}", DETAIL.replace("\n  ", "\n    ").replacen("  column", "    column", 1)));
    assert_eq!(
        warned(&chain),
        [(SCREEN.to_string(), line_of(&chain, "if pending"))]
    );
    // event-rsvp's: a create form and an event's detail in one pane, the
    // form's Cancel the press that leaves it.
    let rsvp = "shape Event\n  id: string\n  title: string\ncomponent App\n  state selected = \"1\"\n  state creating = false\n  state title = \"\"\n  state answer = \"\"\n  resource events = loadEvents() as shape Event[] else empty()\n  action newEvent\n    creating = true\n  action back\n    selected = \"\"\n    creating = false\n  action editTitle(v: string)\n    title = v\n  action create\n    creating = false\n  action rsvp(r: string)\n    answer = r\n  view\n    main height=\"100%\" display=\"flex\" flex-direction=\"column\"\n      row padding=16\n        text \"gather\"\n        button press=newEvent testId=\"new-event\"\n          text \"Create event\"\n      scroll flex=1 min-height=0\n        column flex=1 min-width=0 gap=18 testId=\"detail-pane\"\n          if creating\n            column gap=22\n              column gap=8\n                text \"A new reason to get together.\" role=\"heading\" aria-level=2\n              input value=title input=editTitle aria-label=\"Event title\"\n              row gap=10\n                button press=create testId=\"create-save\"\n                  text \"Create event\"\n                button press=back testId=\"create-cancel\"\n                  text \"Cancel\"\n          else\n            for e in events.filter(x => x.id == selected) key=e.id\n              column gap=24\n                column gap=10\n                  text e.title role=\"heading\" aria-level=2\n                row role=\"radiogroup\" aria-label=\"Your RSVP\"\n                  button role=\"radio\" aria-checked=(answer == \"going\") press=rsvp(\"going\")\n                    text \"Going\"\n                  button role=\"radio\" aria-checked=(answer == \"maybe\") press=rsvp(\"maybe\")\n                    text \"Maybe\"\n";
    assert_eq!(
        warned(rsvp),
        [(SCREEN.to_string(), line_of(rsvp, "if creating"))]
    );
}

#[test]
fn routes_tabs_loading_empty_disclosure_and_overlays_are_not_named() {
    let detail = DETAIL
        .replace("\n  ", "\n    ")
        .replacen("  column", "    column", 1);
    let swap = format!("if showingDetail\n  for m in chosen key=m.id\n{detail}else\n{LIST}");
    for (case, choice) in [
        // Tabs: a state a `tab` reads its selection from.
        ("tabs", format!("row role=\"tablist\"\n  button role=\"tab\" aria-selected=(tab == \"all\") press=pick(\"all\")\n    text \"All\"\n  button role=\"tab\" aria-selected=(tab != \"all\") press=pick(\"saved\")\n    text \"Saved\"\nif tab == \"all\"\n{LIST}else\n{}", LIST.replace("What sounds good today?", "Saved"))),
        // A loading or error view: keyed on a resource.
        ("loading", format!("if pending(meals)\n  for m in meals key=m.id\n{detail}else\n{LIST}")),
        ("responsive", format!("if viewport.name == \"wide\"\n{LIST}else\n{LIST}")),
        // An empty state: one control.
        ("empty", format!("if chosen.length == 0\n  column\n    text \"Nothing chosen yet\" role=\"heading\"\n    button press=edit(\"\")\n      text \"Search\"\nelse\n{LIST}")),
        // Disclosure: an arm with no heading.
        ("disclosure", format!("if open2\n{LIST}else\n  button press=toggle\n    text \"Show the recipes\"\n  button press=edit(\"\")\n    text \"Clear\"")),
        // A swap no press inside it moves (the bar outside does).
        ("unmoved", format!("if showingDetail\n  for m in chosen key=m.id\n{}else\n{}", detail.replace("press=back", "press=share(m)"), LIST.replace("press=open(m)", "press=share(m)"))),
        // Inside a row, a dialog or a popover: theirs.
        ("row", format!("for n in meals key=n.id\n  {}", swap.replace('\n', "\n  "))),
        ("dialog", format!("dialog id=\"d\" closedby=\"any\"\n  {}", swap.replace('\n', "\n  "))),
        ("popover", format!("column id=\"p\" popover=\"auto\"\n  {}", swap.replace('\n', "\n  "))),
    ] {
        let src = finder(&choice);
        // The row case walks `chosen` in each meal's row: `lower-row-lookup`'s, not this one's.
        let named: Vec<_> = warned(&src)
            .into_iter()
            .filter(|(id, _)| id != "lower-row-lookup")
            .collect();
        assert_eq!(named, [], "{case}\n{src}");
    }
    // A kept setting: a `persist` state.
    let kept = finder(
        &format!("if tab == \"all\"\n  for m in chosen key=m.id\n{detail}else\n{LIST}")
            .replace("press=back", "press=pick(\"x\")"),
    )
    .replace("state tab = \"all\"", "state tab = \"all\" persist");
    assert_eq!(warned(&kept), []);
}

fn siblings(first: &str, second: &str) -> String {
    finder(&format!("if {first}\n{LIST}if {second}\n{LIST}"))
        .replace("  derive showingDetail", "  derive wide = viewport.name == \"wide\"\n  derive phoneDetail = showingDetail\n  derive mixed = wide or pending(meals)\n  derive mixedState = wide or open2\n  derive showingDetail")
}

#[test]
fn complementary_sibling_screens_are_named_once_at_the_first_if() {
    for (first, second) in [
        ("showingDetail", "not showingDetail"),
        ("not showingDetail", "showingDetail"),
        ("not showingDetail", "not not showingDetail"),
        ("chosen.length == 0", "chosen.length != 0"),
        ("wide or not phoneDetail", "wide or phoneDetail"),
        ("not phoneDetail or wide", "wide or phoneDetail"),
        (
            "viewport.name == \"wide\" or showingDetail",
            "viewport.name == \"wide\" or not showingDetail",
        ),
    ] {
        let src = siblings(first, second);
        assert_eq!(
            warned(&src),
            [(SCREEN.to_string(), line_of(&src, &format!("if {first}")))],
            "{first} / {second}"
        );
    }
}

#[test]
fn unrelated_responsive_and_loading_siblings_stay_quiet() {
    for (first, second) in [
        ("showingDetail", "open2"),
        ("wide", "not wide"),
        ("wide or showingDetail", "not wide or not showingDetail"),
        (
            "viewport.name == \"wide\" or showingDetail",
            "viewport.name == \"narrow\" or not showingDetail",
        ),
        ("mixed or showingDetail", "mixed or not showingDetail"),
        (
            "mixedState or showingDetail",
            "mixedState or not showingDetail",
        ),
        ("pending(meals)", "not pending(meals)"),
        (
            "pending(meals) or showingDetail",
            "not (pending(meals) or showingDetail)",
        ),
        ("wide or pending(meals)", "wide or not pending(meals)"),
    ] {
        let src = siblings(first, second);
        assert_eq!(warned(&src), [], "{first} / {second}");
    }
}

#[test]
fn sibling_swaps_keep_the_screen_exemptions_and_outermost_warning() {
    let pair = format!("if showingDetail\n{LIST}if not showingDetail\n{LIST}");
    for choice in [
        format!(
            "dialog id=\"d\" closedby=\"any\"\n  {}",
            pair.replace('\n', "\n  ")
        ),
        format!("column role=\"tabpanel\"\n  {}", pair.replace('\n', "\n  ")),
        format!("if showingDetail\n{LIST}if not showingDetail\n  text \"Empty\""),
        pair.replace("press=open(m)", "press=share(m)"),
    ] {
        assert_eq!(warned(&finder(&choice)), []);
    }
    let kept = siblings("tab == \"all\"", "tab != \"all\"")
        .replace("state tab = \"all\"", "state tab = \"all\" persist")
        .replace("press=open(m)", "press=pick(\"saved\")");
    assert_eq!(warned(&kept), []);
    let selected = format!(
        "button role=\"radio\" aria-checked=showingDetail press=back\n  text \"Detail\"\n{pair}"
    );
    assert_eq!(warned(&finder(&selected)), []);

    let nested = pair.lines().map(|l| format!("  {l}\n")).collect::<String>();
    for choice in [
        format!("if showingDetail\n{nested}if not showingDetail\n{nested}"),
        format!("if showingDetail\n{nested}else\n{nested}"),
    ] {
        let src = finder(&choice);
        assert_eq!(
            warned(&src),
            [(SCREEN.to_string(), line_of(&src, "if showingDetail"))]
        );
    }
}

#[test]
fn responsive_chain_with_a_disclosure_stays_quiet() {
    let search = LIST.replace("press=open(m)", "press=toggle");
    let src = finder(&format!(
        "if viewport.name == \"wide\"\n{search}else if open2\n  button press=toggle\n    text \"Close\"\nelse\n{search}"
    ));
    assert_eq!(warned(&src), []);
}

#[test]
fn persisted_state_in_a_viewport_arm_does_not_hide_a_later_screen_swap() {
    let detail = DETAIL
        .replace("\n  ", "\n    ")
        .replacen("  column", "    column", 1);
    let src = finder(&format!(
        "if viewport.name == \"wide\" and hidden\n  text \"Hidden\"\nelse if showingDetail\n  for m in chosen key=m.id\n{detail}else if not showingDetail\n{LIST}"
    ))
    .replace("  state open2", "  state hidden = false persist\n  state open2");
    assert_eq!(
        warned(&src),
        [(SCREEN.to_string(), line_of(&src, "if viewport"))]
    );
}

#[test]
fn sibling_comparisons_accept_option_and_list_operands() {
    let cases = [
        ("selected == some(id)", "selected != some(id)"),
        ("chosen == []", "chosen != []"),
        (
            "chosen.length == (open2 ? 0 : 1)",
            "chosen.length != (open2 ? 0 : 1)",
        ),
    ];
    let results: Vec<_> = cases
        .iter()
        .map(|(first, second)| {
            let src = siblings(first, second)
                .replace(
                    "  state chosen",
                    "  state selected = some(\"x\")\n  state id = \"x\"\n  state chosen",
                )
                .replace(
                    "    chosen = [m]",
                    "    chosen = [m]\n    selected = some(m.id)",
                );
            (
                warned(&src),
                vec![(SCREEN.to_string(), line_of(&src, &format!("if {first}")))],
            )
        })
        .collect();
    for ((actual, expected), case) in results.iter().zip(cases) {
        assert_eq!(actual, expected, "{case:?}");
    }
}

/// A page named by one state, its arms without a heading, as round 34's
/// classifieds app did: `page == "browse"`, `"detail"`, `"form"`.
fn pages(choice: &str) -> String {
    let choice: String = choice.lines().map(|l| format!("      {l}\n")).collect();
    format!(
        "component App\n  state page = \"browse\"\n  state draft = \"\"\n  action go(p: string)\n    page = p\n  action edit(v: string)\n    draft = v\n  view\n    column height=\"100%\"\n{choice}"
    )
}

const BROWSE: &str = "  column\n    button press=go(\"detail\") testId=\"open\"\n      text \"Chair\"\n    button press=go(\"form\") testId=\"sell\"\n      text \"Sell\"\n";
const ITEM: &str = "  column\n    button press=go(\"browse\") testId=\"back\"\n      text \"Back to finds\"\n    button press=edit(\"hi\") testId=\"message\"\n      text \"Message seller\"\n";
const FORM: &str = "  column\n    input value=draft input=edit aria-label=\"Title\"\n    button press=go(\"browse\") testId=\"save\"\n      text \"Publish\"\n";

#[test]
fn pages_named_by_one_state_are_named_without_headings_and_when_kept() {
    // An `else if` chain, as classifieds wrote it.
    let chain = pages(&format!(
        "if page == \"browse\"\n{BROWSE}else if page == \"detail\"\n{ITEM}else if page == \"form\"\n{FORM}"
    ));
    assert_eq!(
        warned(&chain),
        [(SCREEN.to_string(), line_of(&chain, "if page == \"browse\""))]
    );
    // Sibling `if`s, the state kept across launches and arms also gated on the
    // width or another state, as the training and notes apps wrote them: named once.
    let siblings = pages(&format!(
        "if wide or page == \"browse\"\n{BROWSE}text \"between\"\nif page == \"detail\" and draft == \"\"\n{ITEM}if page == \"form\"\n{FORM}"
    ))
    .replace("state page = \"browse\"", "state page = \"browse\" persist\n  state wide = false");
    assert_eq!(
        warned(&siblings),
        [(SCREEN.to_string(), line_of(&siblings, "if wide or page"))]
    );
    // Two pages are judged as any swap: no heading, no warning.
    let two = pages(&format!(
        "if page == \"browse\"\n{BROWSE}else if page == \"detail\"\n{ITEM}"
    ));
    assert_eq!(warned(&two), []);
}

#[test]
fn a_swap_inside_a_route_is_named_and_the_routes_are_not() {
    // Round 34's issue tracker: its detail chosen by `selected` inside the one route.
    let detail = DETAIL
        .replace("\n  ", "\n    ")
        .replacen("  column", "    column", 1);
    let swap = format!("if showingDetail\n  for m in chosen key=m.id\n{detail}else\n{LIST}");
    let list = LIST
        .replace("\n  ", "\n    ")
        .replacen("  column", "    column", 1);
    let stack = |home: &str| {
        let home: String = home.lines().map(|l| format!("    {l}\n")).collect();
        finder(&format!(
            "for e in stack(nav) key=e.id\n  if e.name == \"home\"\n{home}  if e.name == \"add\"\n{list}"
        ))
        .replacen("shape Meal", "routes nav\n  home \"/\"\n    add \"/add\"\nshape Meal", 1)
    };
    let routed = stack(&swap);
    assert_eq!(
        warned(&routed),
        [(SCREEN.to_string(), line_of(&routed, "if showingDetail"))]
    );
    // A routed app's swap outside the stack is named too.
    let top = finder(&swap).replacen("shape Meal", "routes nav\n  home \"/\"\nshape Meal", 1);
    assert_eq!(
        warned(&top),
        [(SCREEN.to_string(), line_of(&top, "if showingDetail"))]
    );
    // Screens that are routes: quiet.
    assert_eq!(warned(&stack(LIST)), []);
}

#[test]
fn a_title_wrapper_with_bar_controls_keeps_the_avatar_warning() {
    let source = |header: &str| {
        format!(
            "style Avatar\n  background-color=\"-exact-system-blue\"\nstyle Hidden\n  display=\"none\"\nstyle Shown\n  display=\"flex\"\nstyle Dot\n  width=7\n  height=7\n  background-color=\"-exact-system-blue\"\nstyle Cleared\n  width=7\n  height=7\n  background-color=\"\"\n{}",
            route(header)
        )
    };
    let group = "  row\n    box class=Avatar\n      text \"AL\"\n    text \"Ada\" role=\"heading\"";
    for control in [
        "button press=go\n  text \"More\"",
        "column\n  button press=go\n    text \"More\"",
        "button class=Hidden display=\"flex\" press=go\n  text \"More\"",
        "input type=\"search\" value=q",
        "row role=\"tablist\"\n  button role=\"tab\" aria-selected=true press=go\n    text \"All\"",
        "text \"Live\" role=\"status\"",
        "text \" \" role=\"status\"",
        "image \"symbol:checkmark\" role=\"status\"",
        "view role=\"status\" class=Dot",
        "view role=\"status\" class=(q == \"\" ? Dot : Dot)",
        "view role=\"status\" class=Dot width=\"7px\" background-color=\"transparent\"",
        "row role=\"status\"\n  view class=Dot",
        "row role=\"status\" class=Cleared width=\"auto\"\n  text \"Live\"",
        "row role=\"status\"\n  text \"Live\" class=Hidden display=\"flex\"",
        "row role=\"status\"\n  text \"\"\n  view class=Dot",
    ] {
        let control: String = control
            .lines()
            .map(|line| format!("    {line}\n"))
            .collect();
        let src = source(&format!("{group}\n{control}"));
        assert_eq!(
            warned(&src),
            [(
                "lower-header-unplaced".into(),
                line_of(&src, "box class=Avatar")
            )],
            "{src}"
        );
    }
    for header in [
        // A control outside the title's group does not disqualify it.
        format!("{group}\n  button press=go\n    text \"More\""),
        // An inner wrapper can qualify even when its ancestor contains a bar item.
        format!("  row\n{}\n    button press=go\n      text \"More\"", group.lines().map(|line| format!("  {line}")).collect::<Vec<_>>().join("\n")),
        // A tapped title chooses its pressable group directly.
        format!("{}\n    button press=go\n      text \"More\"", group.replacen("  row", "  row press=go", 1)),
        group.replacen("  row\n", "  row\n    view role=\"status\"\n", 1),
        format!("{group}\n    button press=go display=\"none\"\n      text \"More\""),
        format!("{group}\n    button class=Hidden press=go\n      text \"More\""),
        // Conditional and computed controls retain the compiler's uncertainty.
        format!("{group}\n    if q != \"\"\n      button press=go\n        text \"More\""),
        format!("{group}\n    button press=go display=(q == \"\" ? \"none\" : \"flex\")\n      text \"More\""),
        format!("{group}\n    button class=(q == \"\" ? Hidden : Shown) press=go\n      text \"More\""),
        format!("{group}\n    text \"Live\" role=(q == \"\" ? \"status\" : \"note\")"),
    ] {
        let src = source(&header);
        assert_eq!(warned(&src), [], "{src}");
    }
    // A status without a ChipFace is not apart from the title's wrapper.
    for status in [
        "view role=\"status\"",
        "row role=\"status\"\n  view",
        "row role=\"status\"\n  text \"\"\n  view class=Dot width=0",
        "text \"\" role=\"status\"",
        "view role=\"status\" class=Cleared",
        "view role=\"status\" class=Dot background-color=\"unset\"",
        "view role=\"status\" class=Dot background-color=\"\"",
        "view role=\"status\" class=Avatar",
        "view role=\"status\" class=Dot width=0",
        "view role=\"status\" class=Dot height=0",
        "view role=\"status\" class=Dot height=\"\"",
        "view role=\"status\" class=Dot width=\"25%\"",
        "view role=\"status\" width=7 height=7 background-image=\"linear-gradient(white, black)\"",
        "image \"symbol:\" role=\"status\"",
        "image \"symbol:sf/\" role=\"status\"",
        "image \"assets/avatar.png\" role=\"status\"",
        "row role=\"status\"\n  text \"Hidden\" display=\"none\"",
        "row role=\"status\"\n  view class=Hidden\n    text \"Hidden\"",
        "row role=\"status\"\n  image \"symbol:checkmark\" class=Hidden",
        // Unresolved contents or paint cannot establish a separate readout.
        "text q role=\"status\"",
        "row role=\"status\"\n  if q != \"\"\n    text \"Live\"",
        "view role=\"status\" class=(q == \"\" ? Dot : Cleared)",
        "view role=\"status\" class=Dot background-color=(q == \"\" ? \"\" : \"-exact-system-blue\")",
    ] {
        let status: String = status.lines().map(|line| format!("    {line}\n")).collect();
        let src = source(&format!("{group}\n{status}"));
        assert_eq!(warned(&src), [], "{src}");
    }
    for title in [
        "text \"No heading\"",
        "text \"A\" role=\"heading\"\n    text \"B\" role=\"heading\"",
    ] {
        let src = source(&format!(
            "  row\n    box class=Avatar\n      text \"AL\"\n    {title}\n    view role=\"status\""
        ));
        assert!(
            warned(&src)
                .iter()
                .any(|(id, _)| id == "lower-header-no-bar"),
            "{src}"
        );
    }
}
