use super::*;

#[test]
fn base64_round_trips_every_byte_and_refuses_what_is_not_base64() {
    let all: Vec<u8> = (0..=255).collect();
    for n in 0..=4 {
        let bytes = &all[..all.len() - n];
        assert_eq!(unbase64(&base64(bytes)).as_deref(), Some(bytes));
    }
    assert_eq!(unbase64("").as_deref(), Some(&[][..]));
    assert_eq!(unbase64("AP+ACg0A").unwrap(), [0, 255, 128, 10, 13, 0]);
    assert_eq!(unbase64("AP-A"), None);
    assert_eq!(unbase64("AP A"), None);
}

#[test]
fn flat_fields_parse() {
    let r = r#"{"op":"logs","since":12,"text":"a \"b\" \\ c\n","wheel":true}"#;
    assert_eq!(field_str(r, "op").as_deref(), Some("logs"));
    assert_eq!(field_num(r, "since"), Some(12.0));
    assert_eq!(field_str(r, "text").as_deref(), Some("a \"b\" \\ c\n"));
    assert!(field_bool(r, "wheel"));
    assert!(!field_bool(r, "since"));
    assert_eq!(field_str(r, "missing"), None);
    assert_eq!(field_num(r, "op"), None);
}

#[test]
fn keys_inside_values_and_nested_objects_never_match() {
    // A string value that contains `"op":`, a nested object with an `op`,
    // and an array — only the top-level `op` counts.
    let r = r#"{"text":"{\"op\":\"logs\"}","meta":{"op":"state"},"list":[{"op":"x"}],"op":"tree"}"#;
    assert_eq!(field_str(r, "op").as_deref(), Some("tree"));
    assert_eq!(field_str(r, "text").as_deref(), Some(r#"{"op":"logs"}"#));
    assert_eq!(field_str(r#"{"meta":{"op":"state"}}"#, "op"), None);
    // A key at the top level whose value is not a string.
    assert_eq!(field_str(r#"{"op":3}"#, "op"), None);
    assert_eq!(field_num(r#"{"since":"3"}"#, "since"), None);
    // Unterminated strings and requests are `None`, never a panic.
    assert_eq!(field_str(r#"{"op":"tre"#, "op"), None);
    assert_eq!(field_str(r#"{"op"#, "op"), None);
    assert_eq!(field_str(r#"{"op\"#, "op"), None);
    // Surrogate pairs decode to one character; a lone surrogate is refused.
    assert_eq!(field_str(r#"{"t":"😀"}"#, "t").as_deref(), Some("😀"));
    assert_eq!(field_str(r#"{"t":"\ud83d"}"#, "t"), None);
}

#[test]
fn numbers_render_as_json() {
    assert_eq!(num(3.0).to_string(), "3");
    assert_eq!(num(-0.0).to_string(), "0");
    assert_eq!(num(-0.5).to_string(), "-0.5");
    assert_eq!(num(1e-8).to_string(), "0.00000001");
    assert_eq!(num(f64::NAN).to_string(), "null");
    assert_eq!(num(f64::INFINITY).to_string(), "null");
    assert_eq!(num(f64::NEG_INFINITY).to_string(), "null");
    assert_eq!(num(1e20).to_string(), "100000000000000000000");
    let mut output = String::from("[");
    write!(output, "{},{},{}]", num(-0.0), num(1e-8), num(f64::NAN)).unwrap();
    assert_eq!(output, "[0,0.00000001,null]");
    let mut s = String::new();
    quote("tab\there \"q\" \u{1}", &mut s);
    assert_eq!(s, "\"tab\\there \\\"q\\\" \\u0001\"");
}

#[test]
fn quoted_strings_preserve_unicode_and_escape_boundaries() {
    for input in [
        "",
        "plain",
        "é🦀",
        "\"é\\🦀\n",
        "\u{2028}\u{2029}",
        "\t\r\n",
    ] {
        let mut json = String::from("{\"text\":");
        quote(input, &mut json);
        json.push('}');
        assert_eq!(field_str(&json, "text").as_deref(), Some(input));
    }
    let mut json = String::new();
    quote("é\u{0}🦀\u{8}\u{c}\u{1f}\u{7f}", &mut json);
    assert_eq!(json, "\"é\\u0000🦀\\u0008\\u000c\\u001f\u{7f}\"");
}
