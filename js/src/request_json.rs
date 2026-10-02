//! A fetch as the prelude describes it (JSON from `host(1, …)`), as the
//! runner's [`Request`].
use exact_runner::{Redirect, Request};
use serde_json::Value as Json;

pub(crate) fn request_from_json(text: &str) -> Result<Request, String> {
    let j: Json = serde_json::from_str(text).map_err(|e| e.to_string())?;
    let field = |k: &str| j.get(k).and_then(Json::as_str).map(str::to_string);
    let mut headers = Vec::new();
    if let Some(list) = j.get("headers").and_then(Json::as_array) {
        for pair in list {
            match (
                pair.get(0).and_then(Json::as_str),
                pair.get(1).and_then(Json::as_str),
            ) {
                (Some(k), Some(v)) => headers.push((k.to_string(), v.to_string())),
                _ => return Err("a header that is not a name and a value".into()),
            }
        }
    }
    Ok(Request {
        http: match j.get("max_response_bytes") {
            None => exact_runner::HttpScheduling::Ordered,
            Some(value) => exact_runner::HttpScheduling::Independent {
                max_response_bytes: value
                    .as_u64()
                    .filter(|n| (1..=64 << 20).contains(n))
                    .ok_or("invalid independent HTTP response ceiling")?
                    as u32,
            },
        },
        continuation: None,
        storage: None,
        surface: None,
        grants: None,
        method: field("method").ok_or("no method")?,
        url: field("url").ok_or("no url")?,
        headers,
        body: field("body").unwrap_or_default().into_bytes(),
        stream: j.get("stream").and_then(Json::as_bool).unwrap_or(false),
        redirect: Redirect::parse(j.get("redirect").and_then(Json::as_str))?,
    })
}
