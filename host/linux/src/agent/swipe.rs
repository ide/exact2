//! The Android reader's recognized swipe. Desktop platforms make none.
use super::*;

pub(super) fn tap<D: DataSource>(p: &mut Presenter<D>, request: &serde_json::Value) -> String {
    let Some(fields) = request.as_object() else {
        return malformed("swipe needs an object");
    };
    if fields
        .keys()
        .any(|k| !["op", "id", "swipe", "at"].contains(&k.as_str()))
    {
        return malformed("swipe takes only a direction and optional at <x> <y>");
    }
    let Some(direction) = request["swipe"]
        .as_str()
        .filter(|d| ["left", "right", "up", "down"].contains(d))
    else {
        return malformed("swipe: expected left, right, up or down");
    };
    let Some(id) = request["id"].as_u64().and_then(|n| u32::try_from(n).ok()) else {
        return malformed("swipe needs a view id");
    };
    let at = match request.get("at") {
        None => None,
        Some(value) => match value.as_array().map(Vec::as_slice) {
            Some([x, y]) => match (x.as_f64(), y.as_f64()) {
                (Some(x), Some(y)) if (x as f32).is_finite() && (y as f32).is_finite() => {
                    Some((x as f32, y as f32))
                }
                _ => return malformed("at needs two finite numbers"),
            },
            _ => return malformed("at needs two finite numbers"),
        },
    };
    if !cfg!(target_os = "android") {
        return error(&format!(
            "unsupported: the {HOST_NAME} host makes no swipe (LLP 1057.001 §8.2)"
        ));
    }
    p.agent_swipe(id, direction, at)
        .unwrap_or_else(|e| error(&e))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn boot() -> Presenter<()> {
        let (p, error) = Presenter::boot_with(
            &crate::test_plan("component App\n  view\n    box width=100 height=100\n"),
            (),
            (200., 200.),
            1.,
            std::path::PathBuf::new(),
            crate::presenter::PainterChoice::Cpu,
        )
        .unwrap();
        assert!(error.is_none(), "{error:?}");
        p
    }

    #[test]
    fn mixed_swipes_cannot_answer_a_device_ticket_or_enter_the_world_router() {
        let mut p = boot();
        let owner = p.host().preorder()[0];
        let ticket =
            p.host_mut()
                .runner_mut()
                .hold("sample", Some(owner), r#"{"id":"request"}"#, &[], true);
        let ask = |p: &mut Presenter<()>, request: serde_json::Value| -> serde_json::Value {
            serde_json::from_str(&handle(p, &request.to_string())).unwrap()
        };
        let pending = ask(&mut p, serde_json::json!({"op": "state"}))["pending"].clone();
        assert_eq!(pending.as_array().unwrap().len(), 1);
        assert_eq!(pending[0]["ticket"], ticket);
        for fields in [
            serde_json::json!({"ticket": ticket, "choice": "cancel"}),
            serde_json::json!({"world": true}),
            serde_json::json!({"entity": "player"}),
            serde_json::json!({"world": true, "ticket": ticket, "choice": "cancel"}),
        ] {
            for direction in [serde_json::json!("down"), serde_json::Value::Null] {
                let mut request = serde_json::json!({"op": "tap", "id": 1, "swipe": direction});
                request
                    .as_object_mut()
                    .unwrap()
                    .extend(fields.as_object().unwrap().clone());
                let reply = ask(&mut p, request.clone());
                assert_eq!(reply["malformed"], true, "{request}: {reply}");
                assert!(reply.get("delivery").is_none(), "{reply}");
                assert_eq!(
                    ask(&mut p, serde_json::json!({"op": "state"}))["pending"],
                    pending
                );
            }
        }
        let answer = serde_json::json!({"op": "tap", "ticket": ticket, "choice": "cancel"});
        let reply = ask(&mut p, answer.clone());
        assert_eq!(reply["delivery"], "substituted", "{reply}");
        assert_eq!(reply["answered"], "cancel");
        assert_eq!(reply["ticket"], ticket);
        assert_eq!(
            ask(&mut p, serde_json::json!({"op": "state"}))["pending"],
            serde_json::json!([])
        );
        let again = ask(&mut p, answer);
        assert!(
            again["error"].as_str().unwrap().contains("not pending"),
            "{again}"
        );
    }

    #[test]
    fn direct_requests_are_validated_before_any_input_and_desktop_swipes_are_refused() {
        let mut p = boot();
        let valid = serde_json::json!({"op": "tap", "id": 1, "swipe": "down"});
        for change in [
            serde_json::json!({"swipe": null}),
            serde_json::json!({"swipe": "sideways"}),
            serde_json::json!({"id": -1}),
            serde_json::json!({"id": 1.5}),
            serde_json::json!({"at": [0, 1e100]}),
            serde_json::json!({"at": [true, 0]}),
            serde_json::json!({"at": [0]}),
            serde_json::json!({"phase": "down"}),
            serde_json::json!({"mouse": true}),
            serde_json::json!({"holdState": "active"}),
            serde_json::json!({"check": true}),
        ] {
            let mut request = valid.clone();
            request
                .as_object_mut()
                .unwrap()
                .extend(change.as_object().unwrap().clone());
            let r: serde_json::Value =
                serde_json::from_str(&handle(&mut p, &request.to_string())).unwrap();
            assert_eq!(r["malformed"], true, "{request}: {r}");
        }
        if !cfg!(target_os = "android") {
            let r = handle(&mut p, &valid.to_string());
            assert!(r.contains("makes no swipe"), "{r}");
        }
    }
}
