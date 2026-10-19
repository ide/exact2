use super::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

/// Requests the sink received: path, row count and JSON body.
type Seen = Arc<Mutex<Vec<(String, usize, Value)>>>;

/// A local HTTP sink on a free port. It replies with the status and headers
/// that `answer(path, row count)` returns.
fn sink(answer: impl Fn(&str, usize) -> (u16, &'static str) + Send + 'static) -> (String, Seen) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let path = line.split(' ').nth(1).unwrap_or("").to_string();
            let mut length = 0;
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).unwrap();
                if h.trim().is_empty() {
                    break;
                }
                if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let body: Value = serde_json::from_slice(&body).unwrap();
            let rows = body.to_string().matches("\"timeUnixNano\"").count();
            let (status, headers) = answer(&path, rows);
            log.lock().unwrap().push((path, rows, body));
            let mut out = stream;
            let _ = write!(
                out,
                "HTTP/1.1 {status} X\r\n{headers}Content-Length: 0\r\nConnection: close\r\n\r\n"
            );
        }
    });
    (url, seen)
}

impl Service {
    fn metrics(&self) -> Vec<Row> {
        lock(&self.queue).metrics.clone()
    }

    fn logs(&self) -> Vec<Row> {
        lock(&self.queue).logs.clone()
    }

    fn sessions(&self) -> Map<String, Value> {
        lock(&self.queue).sessions.clone()
    }
}

fn service(endpoint: &str, name: &str) -> Service {
    let dir =
        std::env::temp_dir().join(format!("exact-observe-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let config = json!({ "projectId": "p1", "endpoint": endpoint, "dispatchInDebug": true });
    let app = json!({ "id": "com.example.test", "name": "Test", "version": "1.2" });
    Service::new(
        config.as_object().unwrap().clone(),
        &app,
        true,
        dir,
        "s-1".into(),
        1_700_000_000.0,
    )
}

fn startup(s: &mut Service, n: usize) {
    for i in 0..n {
        let e = json!({ "kind": "startup", "wall": 1_700_000_001.0 + i as f64, "tti": "settled",
            "metrics": { "coldLaunchTime": 0.004, "timeToFirstRender": 0.1, "timeToInteractive": 0.2 },
            "marks": { "process": 0.0, "boot": 4.0, "commit": 50.0, "present": 104.0, "activated": 60.0, "interactive": 204.0 } });
        s.event(&e);
    }
}

#[test]
fn startup_becomes_observes_metrics_on_its_wire() {
    let (url, seen) = sink(|_, _| (200, ""));
    let mut s = service(&url, "wire");
    let mut out = s.sender();
    startup(&mut s, 2);
    out.dispatch();
    assert!(s.metrics().is_empty(), "acknowledged rows leave the queue");
    let seen = seen.lock().unwrap();
    let (path, rows, body) = &seen[0];
    assert_eq!((path.as_str(), *rows), ("/p1/v1/metrics", 6));
    let resource = &body["resourceMetrics"][0];
    assert_eq!(resource["schemaUrl"], SCHEMA_URL);
    assert_eq!(resource["scopeMetrics"][0]["scope"]["name"], "expo-observe");
    let attrs = resource["resource"]["attributes"].as_array().unwrap();
    let attr = |k: &str| {
        attrs
            .iter()
            .find(|a| a["key"] == k)
            .map(|a| a["value"]["stringValue"].clone())
    };
    assert_eq!(attr("service.name"), Some(json!("com.example.test")));
    assert_eq!(attr("telemetry.sdk.name"), Some(json!("exact-observe")));
    assert_eq!(attr("os.type"), Some(json!("linux")));
    let metrics = resource["scopeMetrics"][0]["metrics"].as_array().unwrap();
    let names: Vec<&str> = metrics
        .iter()
        .map(|m| m["name"].as_str().unwrap())
        .collect();
    // A service is one launch, so its second report keeps the type its first decided
    assert_eq!(
        names[..4],
        [
            "expo.app_startup.cold_launch_time",
            "expo.app_startup.ttr",
            "expo.app_startup.tti",
            "expo.app_startup.cold_launch_time"
        ]
    );
    assert!(metrics.iter().all(|m| m["unit"] == "s"));
    let tti = &metrics[2]["gauge"]["dataPoints"][0];
    assert_eq!(tti["timeUnixNano"], 1_700_000_001_000_000_000u64);
    let params = tti["attributes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["key"] == "expo.custom_params")
        .unwrap();
    let params: Value =
        serde_json::from_str(params["value"]["stringValue"].as_str().unwrap()).unwrap();
    assert_eq!(params["exact.tti.reason"], "settled");
    assert_eq!(params["exact.phase.present"], json!(0.054));
    assert_eq!(params["exact.since_process_start.tti"], json!(0.204));
    assert!(
        params.get("expo.network.connected").is_some(),
        "TTI carries the device state"
    );
}

/// A router change before the first frame replaces the launch route, and the
/// host journals `navigation.launch` again: the launch metrics name the last one.
#[test]
fn the_launch_route_is_the_last_one_journaled() {
    let (url, _) = sink(|_, _| (200, ""));
    let mut s = service(&url, "launch-route");
    for route in ["/", "/welcome"] {
        s.event(&json!({ "kind": "navigation.launch", "route": route, "url": route, "routeParams": {} }));
    }
    startup(&mut s, 1);
    let metrics = s.metrics();
    let routes: Vec<(&str, &str)> = metrics
        .iter()
        .filter(|r| r["category"] == "navigation")
        .map(|r| (r["name"].as_str().unwrap(), r["route"].as_str().unwrap()))
        .collect();
    assert_eq!(routes, [("cold_ttr", "/welcome"), ("tti", "/welcome")]);
}

/// A late report (`startup.tti`) stores only what the timeout's report did not:
/// the TTI reached later, and the TTR when the first frame came after the timeout.
#[test]
fn a_late_report_stores_each_startup_metric_once() {
    let (url, _) = sink(|_, _| (200, ""));
    let mut s = service(&url, "late");
    s.event(&json!({ "kind": "navigation.launch", "route": "/", "url": "/", "routeParams": {} }));
    s.event(
        &json!({ "kind": "startup", "wall": 1_700_000_031.0, "tti": "timeout",
        "metrics": { "coldLaunchTime": 0.004 },
        "marks": { "process": 0.0, "boot": 4.0 } }),
    );
    s.event(&json!({ "kind": "startup.tti", "wall": 1_700_000_040.0, "tti": "settled", "late": true,
        "metrics": { "coldLaunchTime": 0.004, "timeToFirstRender": 35.0, "timeToInteractive": 36.0 },
        "marks": { "process": 0.0, "boot": 4.0, "commit": 35_000.0, "present": 35_004.0, "interactive": 36_004.0 } }));
    let metrics = s.metrics();
    let rows: Vec<(&str, &str)> = metrics
        .iter()
        .map(|r| (r["category"].as_str().unwrap(), r["name"].as_str().unwrap()))
        .collect();
    assert_eq!(
        rows,
        [
            ("appStartup", "coldLaunchTime"),
            ("appStartup", "timeToFirstRender"),
            ("appStartup", "timeToInteractive"),
            ("navigation", "cold_ttr"),
            ("navigation", "tti")
        ]
    );
}

/// A chunk the server accepted leaves the stored queue before the next request
/// goes out, so an exit during that one does not send the chunk again.
#[test]
fn an_accepted_chunk_leaves_the_stored_queue_at_once() {
    let queue = std::env::temp_dir()
        .join(format!("exact-observe-test-chunks-{}", std::process::id()))
        .join("queue.json");
    let stored = Arc::new(Mutex::new(Vec::new()));
    let read = stored.clone();
    let (url, _) = sink(move |_, _| {
        let saved: Value = serde_json::from_slice(&std::fs::read(&queue).unwrap()).unwrap();
        let count = |k: &str| saved[k].as_array().map_or(0, Vec::len);
        read.lock().unwrap().push((count("metrics"), count("logs")));
        (200, "")
    });
    let mut s = service(&url, "chunks");
    let mut out = s.sender();
    startup(&mut s, 1);
    s.event(&json!({ "kind": "app.event", "name": "stored" }));
    out.dispatch();
    assert_eq!(
        *stored.lock().unwrap(),
        [(3, 1), (0, 1)],
        "on disk at each request: the metrics were gone before the logs went"
    );
}

#[test]
fn a_413_halves_the_chunk_and_drops_a_lone_row() {
    // The sink rejects any request with more than two rows.
    let (url, seen) = sink(|_, rows| if rows > 2 { (413, "") } else { (200, "") });
    let mut s = service(&url, "large");
    let mut out = s.sender();
    startup(&mut s, 2); // six rows
    out.dispatch();
    assert!(s.metrics().is_empty());
    let sizes: Vec<usize> = seen.lock().unwrap().iter().map(|r| r.1).collect();
    assert_eq!(
        sizes,
        [6, 3, 1, 5, 2, 3, 1, 2],
        "halved until accepted; a success resets to the full chunk"
    );
    let (url, seen) = sink(|_, _| (413, ""));
    let mut s = service(&url, "lone");
    let mut out = s.sender();
    startup(&mut s, 1);
    out.dispatch();
    assert!(
        s.metrics().is_empty(),
        "a single row that is still too large is dropped"
    );
    assert_eq!(
        seen.lock().unwrap().iter().map(|r| r.1).collect::<Vec<_>>(),
        [3, 1, 2, 1, 1]
    );
}

#[test]
fn a_retryable_status_keeps_the_rows_and_waits_retry_after() {
    let (url, seen) = sink(|_, _| (503, "Retry-After: 5\r\n"));
    let mut s = service(&url, "retry");
    let mut out = s.sender();
    startup(&mut s, 1);
    out.dispatch();
    assert_eq!(s.metrics().len(), 3, "kept for later");
    let wait = out.gates[0]
        .after
        .unwrap()
        .saturating_duration_since(Instant::now())
        .as_secs_f64();
    assert!(
        (55.0..=60.0).contains(&wait),
        "Retry-After clamped to at least 60 s, got {wait}"
    );
    assert_eq!(
        out.due, out.gates[0].after,
        "the next attempt is at the gate"
    );
    out.dispatch();
    assert_eq!(
        seen.lock().unwrap().len(),
        1,
        "nothing is sent before the gate opens"
    );
    assert_eq!(
        out.due, out.gates[0].after,
        "a closed gate keeps its rows due"
    );
    s.event(&json!({ "kind": "app.event", "name": "tapped" }));
    // Schedule as the event's wake does on the sender's thread
    out.schedule();
    assert!(
        out.due.unwrap() < out.gates[0].after.unwrap(),
        "a new row is due after the debounce"
    );
    let (url, _) = sink(|_, _| (400, ""));
    let mut s = service(&url, "fatal");
    let mut out = s.sender();
    startup(&mut s, 1);
    out.dispatch();
    assert!(
        s.metrics().is_empty(),
        "a status Observe does not retry drops the chunk"
    );
}

/// expo-observe keeps one retry gate per endpoint: a retryable failure of
/// metrics leaves logs going out, before and while the metrics gate is closed.
#[test]
fn metrics_and_logs_back_off_independently() {
    let (url, seen) = sink(|path, _| {
        if path.ends_with("/metrics") {
            (503, "Retry-After: 120\r\n")
        } else {
            (200, "")
        }
    });
    let mut s = service(&url, "gates");
    let mut out = s.sender();
    startup(&mut s, 1);
    s.event(&json!({ "kind": "app.event", "name": "first" }));
    out.dispatch();
    assert_eq!((s.metrics().len(), s.logs().len()), (3, 0));
    let (metrics, logs) = (out.gates[0], out.gates[1]);
    assert_eq!((metrics.failures, logs.failures), (1, 0));
    assert!(logs.after.is_none(), "the logs gate stays open");
    let wait = metrics
        .after
        .unwrap()
        .saturating_duration_since(Instant::now())
        .as_secs_f64();
    assert!((115.0..=120.0).contains(&wait), "Retry-After: {wait}");
    assert_eq!(out.due, metrics.after);
    s.event(&json!({ "kind": "app.event", "name": "second" }));
    out.dispatch();
    assert!(s.logs().is_empty(), "logs go out while metrics wait");
    let paths: Vec<String> = seen.lock().unwrap().iter().map(|r| r.0.clone()).collect();
    assert_eq!(paths, ["/p1/v1/metrics", "/p1/v1/logs", "/p1/v1/logs"]);
    assert_eq!(
        out.due, metrics.after,
        "the metrics rows wait for their gate"
    );
}

/// A gate that opens while the other signal is being sent is sent in the same
/// dispatch, not left for the next event.
#[test]
fn a_gate_that_opens_during_a_send_is_sent_at_once() {
    let (url, seen) = sink(|path, _| {
        if path.ends_with("/logs") {
            // A slow endpoint: the metrics gate opens during this send.
            std::thread::sleep(Duration::from_millis(200));
        }
        (200, "")
    });
    let mut s = service(&url, "reopen");
    let mut out = s.sender();
    startup(&mut s, 1);
    s.event(&json!({ "kind": "app.event", "name": "slow" }));
    out.gates[0] = Gate {
        after: Some(Instant::now() + Duration::from_millis(20)),
        failures: 1,
    };
    out.dispatch();
    assert_eq!((s.metrics().len(), s.logs().len()), (0, 0));
    let paths: Vec<String> = seen.lock().unwrap().iter().map(|r| r.0.clone()).collect();
    assert_eq!(paths, ["/p1/v1/logs", "/p1/v1/metrics"]);
    assert_eq!(out.due, None, "nothing is left to wake for");
}

/// A flush is answered once the events sent before it are stored in the queue
/// file, which the next launch reads.
#[test]
fn a_flush_returns_once_the_events_before_it_are_stored() {
    let (url, _) = sink(|_, _| (200, ""));
    let s = service(&url, "flush");
    let queue = s.dir.join("queue.json");
    let (tx, rx) = mpsc::channel();
    let service = std::thread::spawn(move || s.run(rx));
    let e = json!({ "kind": "startup", "wall": 1_700_000_001.0, "tti": "terminated", "interrupted": true,
        "metrics": { "coldLaunchTime": 0.004, "timeToFirstRender": 0.1 },
        "marks": { "process": 0.0, "boot": 4.0, "commit": 50.0, "present": 104.0 } });
    tx.send(Message::Event(e)).unwrap();
    let (done, stored) = mpsc::channel();
    tx.send(Message::Flush(done)).unwrap();
    stored.recv_timeout(Duration::from_secs(60)).unwrap();
    let saved: Value = serde_json::from_slice(&std::fs::read(&queue).unwrap()).unwrap();
    let names: Vec<&str> = saved["metrics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["name"].as_str().unwrap())
        .collect();
    assert_eq!(names.len(), 2, "{names:?}");
    assert!(names.contains(&"timeToFirstRender"));
    drop(tx);
    service.join().unwrap();
}

/// A request the endpoint stalls holds up no event: the events sent meanwhile are
/// stored and a flush is answered while it waits, and they go out once it ends.
#[test]
fn a_stalled_request_delays_no_event_or_flush() {
    let (arrived, stalled) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let released = Mutex::new(Some(released));
    let (url, seen) = sink(move |_, _| {
        // The first request waits until the test lets it go.
        if let Some(released) = released.lock().unwrap().take() {
            let _ = arrived.send(());
            let _ = released.recv_timeout(Duration::from_secs(60));
        }
        (200, "")
    });
    let mut s = service(&url, "stall");
    startup(&mut s, 1);
    let queue = s.dir.join("queue.json");
    let stored_rows =
        || -> Value { serde_json::from_slice(&std::fs::read(&queue).unwrap()).unwrap() };
    let mut sender = s.sender();
    sender.due = Some(Instant::now());
    let (tx, rx) = mpsc::channel();
    let service = std::thread::spawn(move || s.serve(rx, sender));
    stalled.recv_timeout(Duration::from_secs(60)).unwrap();
    tx.send(Message::Event(
        json!({ "kind": "app.event", "name": "during" }),
    ))
    .unwrap();
    let (done, stored) = mpsc::channel();
    tx.send(Message::Flush(done)).unwrap();
    stored
        .recv_timeout(Duration::from_secs(10))
        .expect("a flush is answered while the request waits");
    let saved = stored_rows();
    assert_eq!(saved["logs"][0]["name"], "during");
    assert_eq!(
        saved["metrics"].as_array().unwrap().len(),
        3,
        "the request in flight has no answer yet"
    );
    release.send(()).unwrap();
    drop(tx);
    service.join().unwrap();
    let saved = stored_rows();
    assert_eq!(
        (
            saved["metrics"].as_array().unwrap().len(),
            saved["logs"].as_array().unwrap().len()
        ),
        (0, 0)
    );
    let paths: Vec<String> = seen.lock().unwrap().iter().map(|r| r.0.clone()).collect();
    assert_eq!(paths, ["/p1/v1/metrics", "/p1/v1/logs"]);
}

/// An accepted chunk leaves the queue by its rows' ids: when a row stored during
/// the request pushes the oldest, a sent one, out of the full queue, the rows
/// after the chunk all stay and are sent.
#[test]
fn an_accepted_chunk_leaves_by_its_rows_ids() {
    let (arrived, stalled) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let released = Mutex::new(Some(released));
    let (url, seen) = sink(move |_, _| {
        if let Some(released) = released.lock().unwrap().take() {
            let _ = arrived.send(());
            let _ = released.recv_timeout(Duration::from_secs(60));
        }
        (200, "")
    });
    let s = service(&url, "identity");
    {
        let mut queue = lock(&s.queue);
        for i in 0..MAX_ROWS {
            let row = json!({ "session": "s-1", "time": 1_700_000_000.0 + i as f64,
                "category": "navigation", "name": "cold_ttr", "value": 0.1 });
            queue.push("metrics", object(row));
        }
    }
    let mut sender = s.sender();
    sender.due = Some(Instant::now());
    let (tx, rx) = mpsc::channel();
    let service = std::thread::spawn(move || s.serve(rx, sender));
    stalled.recv_timeout(Duration::from_secs(60)).unwrap();
    let e = json!({ "kind": "navigation", "name": "tti", "value": 0.2, "route": "/" });
    tx.send(Message::Event(e)).unwrap();
    let (done, stored) = mpsc::channel();
    tx.send(Message::Flush(done)).unwrap();
    stored.recv_timeout(Duration::from_secs(10)).unwrap();
    release.send(()).unwrap();
    drop(tx);
    service.join().unwrap();
    let sent: usize = seen.lock().unwrap().iter().map(|r| r.1).sum();
    assert_eq!(
        sent,
        MAX_ROWS + 1,
        "every row stored, the one pushed out included, was sent once"
    );
}

#[test]
fn retry_after_reads_seconds_and_http_dates() {
    // `Wed, 21 Oct 2026 07:28:00 GMT`
    let date = 1_792_567_680.0;
    let at = |h: &str, now: f64| retry_after(Some(h), now);
    assert_eq!(
        at("Wed, 21 Oct 2026 07:28:00 GMT", date - 120.0),
        Some(120.0)
    );
    assert_eq!(at("Wed, 21 Oct 2026 07:28:00 GMT", date + 5.0), Some(60.0));
    assert_eq!(at("Wed, 21 Oct 2026 07:28:00 GMT", date - 9e3), Some(900.0));
    assert_eq!(
        http_date("Sun, 06 Nov 1994 08:49:37 GMT"),
        Some(784_111_777.0)
    );
    assert_eq!(
        http_date("Tue, 29 Feb 2000 00:00:00 GMT"),
        Some(951_782_400.0)
    );
    assert_eq!(http_date("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0.0));
    assert_eq!(
        http_date("Mon, 01 Mar 2100 00:00:00 GMT"),
        Some(4_107_542_400.0)
    );
    assert_eq!((at("5", 0.0), at(" 300 ", 0.0)), (Some(60.0), Some(300.0)));
    for refused in [
        "",
        "soon",
        "inf",
        "NaN",
        "Wed, 21 Oct 2026 07:28:00 PST",
        "Wed, 21 Oct 26 07:28:00 GMT",
        "Wednesday, 21-Oct-26 07:28:00 GMT",
        "Wed Oct 21 07:28:00 2026",
        "Wed, 21 Oct 2026 24:00:00 GMT",
    ] {
        assert_eq!(at(refused, date), None, "{refused:?}");
    }
    assert_eq!(retry_after(None, date), None);
}

#[test]
fn custom_events_follow_observes_rules() {
    let (url, seen) = sink(|_, _| (200, ""));
    let mut s = service(&url, "events");
    let mut out = s.sender();
    s.event(
        &json!({ "kind": "app.attributes", "attributes": { "tier": "pro", "expo.reserved": 1 } }),
    );
    s.event(&json!({ "kind": "app.event", "name": "  checkout.done ", "severity": "warn", "body": "x".repeat(5000),
        "attributes": { "items": 3, "total": 4.5, "session.id": "spoof", "none": null } }));
    s.event(&json!({ "kind": "app.event", "name": "expo.mine" }));
    s.event(&json!({ "kind": "app.error", "message": "boom", "type": "CartError" }));
    out.dispatch();
    let seen = seen.lock().unwrap();
    let (path, _, body) = seen.iter().find(|r| r.0.ends_with("/logs")).unwrap();
    assert_eq!(path, "/p1/v1/logs");
    let records = body["resourceLogs"][0]["scopeLogs"][0]["logRecords"]
        .as_array()
        .unwrap();
    assert_eq!(records.len(), 2, "an `expo.` name is refused");
    let event = &records[0];
    let attrs: Vec<(&str, &Value)> = event["attributes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| (a["key"].as_str().unwrap(), &a["value"]))
        .collect();
    let keys: Vec<&str> = attrs.iter().map(|a| a.0).collect();
    assert_eq!(keys, ["session.id", "event.name", "items", "tier", "total"]);
    assert_eq!(attrs[1].1["stringValue"], "checkout.done");
    assert_eq!(attrs[2].1, &json!({ "intValue": 3 }));
    assert_eq!(attrs[4].1, &json!({ "doubleValue": 4.5 }));
    assert_eq!(
        event["droppedAttributesCount"], 2,
        "the reserved key and the null"
    );
    assert_eq!(
        (
            event["severityNumber"].clone(),
            event["severityText"].clone()
        ),
        (json!(13), json!("WARN"))
    );
    let body_text = event["body"]["stringValue"].as_str().unwrap();
    assert_eq!(
        (body_text.chars().count(), body_text.ends_with('…')),
        (4096, true)
    );
    let error: Vec<&str> = records[1]["attributes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["key"].as_str().unwrap())
        .collect();
    assert!(error.contains(&"exception.type") && records[1]["severityText"] == "ERROR");
}

#[test]
fn sampling_matches_expo_mains_deterministic_uniform_value() {
    // expo main's `EASClientID.deterministicUniformValue` runs splitmix64 over
    // both halves of the id; expo-eas-client 57.0.1 read the low half alone,
    // so an install there can sample differently. This is the value
    // web/service.js's BigInt splitmix64 gives for the same id.
    assert_eq!(
        uniform("f0e0ebad-d595-40fe-aa76-5ac43756f758"),
        0.2509529660831642
    );
}

/// Each launch is classified against the one `launch.json` names, and deciding names it
/// there instead, once: the same launch decided again keeps its first type.
#[test]
fn a_launch_is_warm_after_one_of_the_same_build_in_the_same_boot() {
    let dir = std::env::temp_dir().join(format!(
        "exact-observe-test-launch-type-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let decide = |this: fn() -> (Value, bool)| LaunchType::new(this).decide(&dir);
    let first = LaunchType::new(|| (json!({ "boot": "b-1", "build": "x" }), false));
    assert_eq!(first.decide(&dir), "cold", "no launch before it");
    assert_eq!(first.decide(&dir), "cold", "not against itself");
    assert_eq!(
        decide(|| (json!({ "boot": "b-1", "build": "x" }), false)),
        "warm"
    );
    assert_eq!(
        decide(|| (json!({ "boot": "b-1", "build": "x" }), true)),
        "cold",
        "stderr is a terminal"
    );
    assert_eq!(
        decide(|| (json!({ "boot": "b-1", "build": "y" }), false)),
        "cold",
        "another build"
    );
    assert_eq!(
        decide(|| (json!({ "boot": "b-2", "build": "y" }), false)),
        "cold",
        "another boot"
    );
    for _ in 0..2 {
        assert_eq!(
            decide(|| (json!({ "boot": null, "build": null }), false)),
            "cold",
            "an unknown boot and build match none"
        );
    }
}

/// A launch that panics after launch end, before its startup report, is the previous
/// launch for the next one, as a launch that reported is.
#[test]
fn a_panic_leaves_a_record_the_next_launch_sends_as_fatal() {
    let state =
        std::env::temp_dir().join(format!("exact-observe-test-panic-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&state);
    std::env::set_var("XDG_STATE_HOME", &state);
    let ctx = LaunchContext {
        module: "observe",
        config: "{}",
        app: r#"{"id":"com.example.crash","name":"Crash","version":"1.0"}"#,
        development: true,
    };
    let dir = ctx.state_dir();
    // The last launch before it was in the boot before
    std::fs::create_dir_all(&dir).unwrap();
    let before = json!({ "boot": "the boot before", "build": "1:1" });
    std::fs::write(dir.join("launch.json"), before.to_string()).unwrap();
    launch(ctx);
    // The first frame showed and startup is still loading.
    let mut marks = exact_linux::launch_marks::LaunchMarks::new();
    marks.launch_end();
    marks.presented(exact_linux::launch_marks::boottime());
    marks.publish();
    let _ = std::panic::catch_unwind(|| panic!("index out of bounds"));
    let pending: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("pending-"))
        .map(|e| e.path())
        .collect();
    assert_eq!(pending.len(), 1);
    let record: Value = serde_json::from_slice(&std::fs::read(&pending[0]).unwrap()).unwrap();
    assert_eq!(record["message"], "index out of bounds");
    assert_eq!(record["metadata"]["appVersion"], "1.0");
    let startup = &record["startup"];
    assert!(startup["metrics"]["timeToFirstRender"].is_number());
    assert!(startup["metrics"]["timeToInteractive"].is_null(), "no TTI");
    assert!(startup["walls"]["timeToFirstRender"].is_number());
    assert_eq!(startup["launchType"], "cold", "after another boot");
    let (this, terminal) = this_launch();
    assert_eq!(
        read_json(&dir.join("launch.json")),
        this,
        "the crashed launch is the previous one now"
    );
    let mut next = Service::new(
        Map::new(),
        &json!({ "id": "com.example.crash", "name": "Crash", "version": "2.0" }),
        true,
        dir,
        "next-session".into(),
        0.0,
    );
    let logs = next.logs();
    assert_eq!(logs.len(), 1);
    let row = &logs[0];
    assert_eq!(
        (row["severity"].as_str(), row["name"].as_str()),
        (Some("fatal"), Some("native.exception"))
    );
    assert_eq!(
        row["session"], record["session"],
        "against the session that crashed"
    );
    assert_eq!(row["attributes"]["expo.error.is_fatal"], true);
    let sessions = next.sessions();
    let crashed = &sessions[row["session"].as_str().unwrap()]["meta"];
    assert_eq!(
        (&crashed["appIdentifier"], &crashed["appVersion"]),
        (&json!("com.example.crash"), &json!("1.0")),
        "the crashed build's, not this launch's"
    );
    assert_eq!(crashed["osVersion"], record["metadata"]["osVersion"]);
    assert_eq!(sessions["next-session"]["meta"]["appVersion"], "2.0");
    let metrics = next.metrics();
    let ttr = metrics
        .iter()
        .find(|r| r["name"] == "timeToFirstRender")
        .unwrap();
    assert_eq!(ttr["session"], record["session"]);
    assert_eq!(ttr["time"], startup["walls"]["timeToFirstRender"]);
    // The same build in the same boot as the crashed launch: warm where /proc names both
    // and stderr is not a terminal (on Linux, not macOS)
    next.event(
        &json!({ "kind": "startup", "wall": 1_700_000_001.0, "tti": "settled",
        "metrics": { "coldLaunchTime": 0.004 }, "marks": { "process": 0.0, "boot": 4.0 } }),
    );
    let warm = !this["boot"].is_null() && !this["build"].is_null() && !terminal;
    let launch_time = next
        .metrics()
        .into_iter()
        .find(|r| r["session"] == "next-session");
    assert_eq!(
        launch_time.unwrap()["name"],
        if warm {
            "warmLaunchTime"
        } else {
            "coldLaunchTime"
        }
    );
    next.sender().dispatch(); // no project id: the rows are dropped, as Observe out of its gate
    assert!(next.logs().is_empty());
}

/// A panic record's startup object becomes the crashed session's startup rows, named
/// as its report would name them and stamped at their marks, once; a session that
/// stored its startup report before it crashed gets none from its record.
#[test]
fn a_crash_stores_its_startup_once_unless_the_session_stored_it() {
    let (url, _) = sink(|_, _| (200, ""));
    let mut reported = service(&url, "crash-startup");
    startup(&mut reported, 1);
    let dir = reported.dir.clone();
    drop(reported);
    let pending = |session: &str| {
        let record = json!({
            "session": session, "sessionStart": 1_700_000_000.0, "time": 1_700_000_002.0,
            "type": "panic", "message": "boom",
            "startup": {
                "metrics": { "coldLaunchTime": 0.004, "timeToFirstRender": 0.1 },
                "walls": { "coldLaunchTime": 1_700_000_000.5, "timeToFirstRender": 1_700_000_000.6 },
                "launchType": "warm",
            },
        });
        let path = dir.join(format!("pending-{session}.json"));
        std::fs::write(path, record.to_string()).unwrap();
    };
    let launch = |session: &str| {
        let app = json!({ "id": "com.example.test", "name": "Test", "version": "1.2" });
        Service::new(Map::new(), &app, true, dir.clone(), session.into(), 0.0)
    };
    let startup_rows = |s: &Service, session: &str| {
        let mut rows: Vec<(String, f64, Value)> = s
            .metrics()
            .iter()
            .filter(|r| r["session"] == session && r["category"] == "appStartup")
            .map(|r| {
                let params = serde_json::from_str(r["params"].as_str().unwrap()).unwrap();
                (
                    r["name"].as_str().unwrap().into(),
                    r["time"].as_f64().unwrap(),
                    params,
                )
            })
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        rows
    };
    pending("crashed");
    pending("s-1");
    let next = launch("next");
    let crash = json!({ "exact.launch.interrupted": true, "exact.launch.crashed": true });
    assert_eq!(
        startup_rows(&next, "crashed"),
        [
            ("timeToFirstRender".into(), 1_700_000_000.6, crash.clone()),
            ("warmLaunchTime".into(), 1_700_000_000.5, crash.clone())
        ]
    );
    assert_eq!(
        startup_rows(&next, "s-1").len(),
        3,
        "its own report's rows, none from its record"
    );
    assert_eq!(
        next.logs().len(),
        2,
        "each crash is still a native.exception"
    );
    drop(next);

    // A record of the session read again stores nothing more.
    pending("crashed");
    let third = launch("third");
    assert_eq!(startup_rows(&third, "crashed").len(), 2, "once");
}

/// A crash after the timeout's report, which stored only the launch time, stores from its
/// record the TTR of the first frame that came after it, each metric once, as the late
/// report would have.
#[test]
fn a_crash_after_a_partial_report_stores_the_metrics_it_left_out() {
    let (url, _) = sink(|_, _| (200, ""));
    let mut crashed = service(&url, "crash-partial");
    crashed.event(
        &json!({ "kind": "startup", "wall": 1_700_000_031.0, "tti": "timeout",
        "metrics": { "coldLaunchTime": 0.004 }, "marks": { "process": 0.0, "boot": 4.0 } }),
    );
    let dir = crashed.dir.clone();
    drop(crashed);
    let record = json!({
        "session": "s-1", "sessionStart": 1_700_000_000.0, "time": 1_700_000_040.0,
        "type": "panic", "message": "boom",
        "startup": {
            "metrics": { "coldLaunchTime": 0.004, "timeToFirstRender": 35.0 },
            "walls": { "coldLaunchTime": 1_700_000_000.5, "timeToFirstRender": 1_700_000_035.5 },
            "launchType": "cold",
        },
    });
    let launch = |session: &str| {
        std::fs::write(dir.join("pending-s-1.json"), record.to_string()).unwrap();
        let app = json!({ "id": "com.example.test", "name": "Test", "version": "1.2" });
        Service::new(Map::new(), &app, true, dir.clone(), session.into(), 0.0)
    };
    let startup_rows = |s: &Service| -> Vec<(String, f64, Option<Value>)> {
        s.metrics()
            .iter()
            .filter(|r| r["session"] == "s-1" && r["category"] == "appStartup")
            .map(|r| {
                let params = r["params"]
                    .as_str()
                    .map(|p| serde_json::from_str(p).unwrap());
                let crashed = params.filter(|p: &Value| p["exact.launch.crashed"] == true);
                (
                    r["name"].as_str().unwrap().into(),
                    r["time"].as_f64().unwrap(),
                    crashed,
                )
            })
            .collect()
    };
    let crash = json!({ "exact.launch.interrupted": true, "exact.launch.crashed": true });
    let next = launch("next");
    assert_eq!(
        startup_rows(&next),
        [
            ("coldLaunchTime".into(), 1_700_000_031.0, None),
            ("timeToFirstRender".into(), 1_700_000_035.5, Some(crash))
        ],
        "the report's launch time, and the record's TTR"
    );
    drop(next);
    let third = launch("third");
    assert_eq!(startup_rows(&third).len(), 2, "once");
}
