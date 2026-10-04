//! The launch journal and launch parts (Exact Observe design §4.6), Linux's
//! twin of ExactKit's `LaunchParts.swift`.
//!
//! A module the app's `app.json` names under `launch` ships one Rust file,
//! `modules/<name>/linux/launch.rs`, that the app's build compiles into the
//! executable (`contract::linux_launch_parts`); its `launch` runs first thing
//! in `main`, before the host opens the display, and must be small: subscribe
//! to this journal, perhaps install a panic hook. Anything that stores or
//! sends waits for [`after_startup`], which runs it on a thread of its own
//! once the startup report is in, so it never delays a mark.
//!
//! The journal keeps the last [`CAPACITY`] events and replays them to a new
//! subscriber, so a module that starts late misses nothing. Subscribers are
//! called on the thread that records — the display loop — and must only hand
//! the event off (a channel send).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub use serde_json;
use serde_json::{Map, Value};

/// Events kept for a subscriber that arrives later.
pub const CAPACITY: usize = 4096;

/// One journal event: its kind, when (seconds on `CLOCK_BOOTTIME`, the
/// marks' clock, and Unix seconds), and its fields.
#[derive(Debug, Clone)]
pub struct Event {
    /// `startup`, `app.event`, `app.attributes`, `app.error`, …
    pub kind: String,
    /// Seconds on `CLOCK_BOOTTIME`.
    pub at: f64,
    /// Seconds since the Unix epoch.
    pub wall: f64,
    /// The kind's fields.
    pub fields: Map<String, Value>,
}

impl Event {
    /// The event as one JSON object: its fields beside `kind`, `at`, `wall`
    /// (the shape the Apple and web journals hand a service).
    pub fn json(&self) -> Value {
        let mut o = self.fields.clone();
        o.insert("kind".into(), self.kind.clone().into());
        o.insert("at".into(), self.at.into());
        o.insert("wall".into(), self.wall.into());
        Value::Object(o)
    }
}

type Subscriber = Box<dyn Fn(&Event) + Send>;
type Deferred = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct Journal {
    events: VecDeque<Arc<Event>>,
    subscribers: Vec<Subscriber>,
    deferred: Vec<Deferred>,
    started: bool,
}

static JOURNAL: Mutex<Option<Journal>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut Journal) -> R) -> R {
    let mut j = JOURNAL.lock().unwrap_or_else(|e| e.into_inner());
    f(j.get_or_insert_with(Journal::default))
}

/// Unix seconds now.
pub fn wall() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// Record an event; the first `startup` releases [`after_startup`]'s work.
pub fn record(kind: &str, fields: Map<String, Value>) {
    let e = Arc::new(Event {
        kind: kind.into(),
        at: crate::launch_marks::boottime(),
        wall: wall(),
        fields,
    });
    let deferred = with(|j| {
        if j.events.len() == CAPACITY {
            j.events.pop_front();
        }
        j.events.push_back(e.clone());
        for s in &j.subscribers {
            s(&e);
        }
        if kind == "startup" && !j.started {
            j.started = true;
            std::mem::take(&mut j.deferred)
        } else {
            Vec::new()
        }
    });
    for d in deferred {
        std::thread::spawn(d);
    }
}

/// Every event from now on, after the ones already recorded.
pub fn subscribe(f: impl Fn(&Event) + Send + 'static) {
    with(|j| {
        for e in &j.events {
            f(e);
        }
        j.subscribers.push(Box::new(f));
    });
}

/// Run `f` on a thread of its own once startup is reported (at once if it
/// already was): where a module stores and sends.
pub fn after_startup(f: impl FnOnce() + Send + 'static) {
    let f: Deferred = Box::new(f);
    let ready = with(|j| {
        if j.started {
            Some(f)
        } else {
            j.deferred.push(f);
            None
        }
    });
    if let Some(f) = ready {
        std::thread::spawn(f);
    }
}

/// What every launch part may take together, as on Apple
/// (`runLaunchParts`): more is said on stderr, never refused.
pub const LAUNCH_BUDGET: std::time::Duration = std::time::Duration::from_micros(500);

/// The generated `launch_parts()` ran in `took`: journaled, and said when
/// it was over budget or `EXACT_OBSERVE_LOG=1` asks.
pub fn launch_parts_ran(took: std::time::Duration) {
    let micros = took.as_secs_f64() * 1e6;
    if took > LAUNCH_BUDGET || std::env::var("EXACT_OBSERVE_LOG").as_deref() == Ok("1") {
        eprintln!(
            "exact: launch parts took {micros:.0} µs (budget {} µs)",
            LAUNCH_BUDGET.as_micros()
        );
    }
    let mut f = Map::new();
    f.insert("micros".into(), micros.into());
    record("launch.parts", f);
}

/// What a launch part is told (ExactKit's `ExactLaunchContext`).
pub struct LaunchContext {
    /// The module's name in `app.json`'s `launch`.
    pub module: &'static str,
    /// `app.json`'s `moduleConfig[module]`, JSON (`{}` when none).
    pub config: &'static str,
    /// The app's identity: `{"id","name","version"}` from `app.json`.
    pub app: &'static str,
    /// A development build (not production trust) — Observe sends nothing
    /// from one unless asked.
    pub development: bool,
}

impl LaunchContext {
    /// The context for `module`, from the baked compatibility id.
    pub fn new(
        module: &'static str,
        config: &'static str,
        app: &'static str,
        compat: &str,
    ) -> Self {
        LaunchContext {
            module,
            config,
            app,
            development: !exact_runner::delivery::production(compat),
        }
    }

    /// Where the module keeps its files: `$XDG_STATE_HOME/exact/<app id>/<module>`
    /// (`~/.local/state` when unset). Not created here: launch does no I/O.
    pub fn state_dir(&self) -> std::path::PathBuf {
        let app: Value = serde_json::from_str(self.app).unwrap_or_default();
        let id = app["id"].as_str().unwrap_or("app");
        let base = std::env::var_os("XDG_STATE_HOME")
            .map(std::path::PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".local/state"))
            })
            .unwrap_or_else(std::env::temp_dir);
        base.join("exact").join(id).join(self.module)
    }
}

/// A Contract value as JSON, for `observe` commands' arguments.
pub fn value_json(v: &exact_plan::Value) -> Value {
    if let Some(s) = v.as_str() {
        return s.into();
    }
    match v {
        exact_plan::Value::Number(n) => {
            serde_json::Number::from_f64(*n).map_or(Value::Null, Value::Number)
        }
        exact_plan::Value::Bool(b) => (*b).into(),
        exact_plan::Value::Unit => Value::Null,
        other => format!("{other:?}").into(),
    }
}

/// Contract's `observe`, `observeAttributes` and `observeError` (design
/// §5.2): names, then a record's fields as key/value pairs.
pub fn host_command(name: &str, args: &[exact_plan::Value]) {
    let pairs = |from: usize| {
        let mut o = Map::new();
        let mut i = from;
        while i + 1 < args.len() {
            if let Some(k) = args[i].as_str() {
                o.insert(k.into(), value_json(&args[i + 1]));
            }
            i += 2;
        }
        Value::Object(o)
    };
    let text = |i: usize, or: &str| {
        args.get(i)
            .and_then(|v| v.as_str())
            .unwrap_or(or)
            .to_string()
    };
    let mut f = Map::new();
    match name {
        "observe" => {
            f.insert("name".into(), text(0, "").into());
            f.insert("severity".into(), text(1, "info").into());
            f.insert("attributes".into(), pairs(2));
            record("app.event", f);
        }
        "observeAttributes" => {
            f.insert("attributes".into(), pairs(0));
            record("app.attributes", f);
        }
        _ => {
            f.insert("source".into(), "reportedByUser".into());
            f.insert("message".into(), text(0, "").into());
            f.insert("type".into(), text(1, "ContractError").into());
            record("app.error", f);
        }
    }
}

/// POST `body` to `url`: the status and the `Retry-After` header, through
/// the transport the host already links (rustls off Apple).
pub fn post(
    url: &str,
    headers: &[(&str, &str)],
    body: Vec<u8>,
) -> Result<(u16, Option<String>), String> {
    let transport = ibex2::transport::default_transport();
    let mut req = ibex2::stdlib::fetch::Request::get(url);
    req.method = "POST".into();
    for (k, v) in headers {
        req.headers.set(k, v);
    }
    req.body = Some(body);
    req.max_body = Some(64 * 1024);
    let r = transport.send(&req).map_err(|e| format!("{url}: {e}"))?;
    Ok((r.status, r.headers.get("retry-after").map(str::to_string)))
}
