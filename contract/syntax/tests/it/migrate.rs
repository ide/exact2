use contract_syntax::migrate::migrate;

#[test]
fn press_paints_move_into_one_active_block_without_rewriting_literals() {
    let before = r##"// -exact-press-color is mentioned here.
style Card
  -exact-press-color = "#ffffff" padding=8
  :active
    opacity = 0.8
component App
  state on = false
  view
    column -exact-press-background-color=(on ? "#111111" : none) testId="paint"
      -exact-press-color="#222222" // Keep this comment.
      text "-exact-press-color is text"
"##;
    let after = migrate(before).unwrap();
    assert_eq!(
        after,
        r##"// -exact-press-color is mentioned here.
style Card
   padding=8
  :active
    color = "#ffffff"
    opacity = 0.8
component App
  state on = false
  view
    column  testId="paint"
      :active
        background-color=(on ? "#111111" : none)
        color="#222222"
       // Keep this comment.
      text "-exact-press-color is text"
"##
    );
    assert_eq!(migrate(&after).unwrap(), after);
}

#[test]
fn press_migration_preserves_multiline_values_and_other_repairs() {
    let before = r##"component App
  state text = " x "
  view
    column -exact-press-color=(true ?
      trim(text) : "#111111")
      text text
"##;
    let after = migrate(before).unwrap();
    assert!(after.contains(":active\n"), "{after}");
    assert!(
        after.contains("color=(true ?\n      (text).trim() : \"#111111\")"),
        "{after}"
    );
    assert_eq!(migrate(&after).unwrap(), after);
}

#[test]
fn press_migration_refuses_conflicts_and_unsupported_targets() {
    for before in [
        "component App\n  view\n    column -exact-press-color=\"#ff0000\"\n      :active\n        color=\"#ffffff\"\n      text \"x\"\n",
        "component App\n  view\n    select appearance=\"auto\" -exact-press-color=\"#ff0000\"\n      option \"x\"\n",
        "component App\n  view\n    text\n      text \"x\" -exact-press-color=\"#ff0000\"\n",
    ] {
        assert!(migrate(before).is_err(), "{before}");
    }
}

#[test]
fn press_migration_keeps_native_buttons_native() {
    let before = "component App\n  view\n    button appearance=\"auto\" -exact-press-color=\"#ff0000\"\n      text \"Go\"\n";
    let after = migrate(before).unwrap();
    assert!(after.contains("button appearance=\"auto\""), "{after}");
    assert!(
        after.contains(":active\n        color=\"#ff0000\""),
        "{after}"
    );
    assert_eq!(migrate(&after).unwrap(), after);
}

#[test]
fn press_migration_keeps_indentation_positionals_and_line_endings() {
    for before in [
        "component App\n    view\n        text -exact-press-color=\"red\" \"title\"\n            testId=\"title\"\n",
        "component App\r\n  view\r\n    column -exact-press-background-color=\"red\"\r\n      text \"héllo\"\r\n",
        "component App\n  view\n    column -exact-press-background-color=\"red\"",
    ] {
        let after = migrate(before).unwrap();
        assert!(after.contains(":active"), "{after}");
        assert!(!after.contains("-exact-press-"), "{after}");
        if before.contains("\r\n") { assert!(!after.replace("\r\n", "").contains('\n'), "{after:?}"); }
        assert_eq!(migrate(&after).unwrap(), after);
    }
}
