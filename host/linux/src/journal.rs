//! The launch journal and launch parts, the Linux counterpart of ExactKit's `LaunchParts.swift`.
//!
//! Each module listed under `launch` in `app.json` provides `modules/<name>/linux/launch.rs`,
//! compiled into the app and run at the start of `main`, before the display opens.
//! A launch part only subscribes and installs hooks. File and network work goes
//! through [`after_startup`] so it cannot delay the startup marks.
//! Subscribers run on the display loop's thread and must only hand events off.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub use serde_json;
use serde_json::{Map, Value};

/// Events kept for a subscriber that arrives later.
const CAPACITY: usize = 4096;

/// One journal event.
#[derive(Debug, Clone)]
pub struct Event {
    /// `startup`, `app.event`, `app.attributes`, `app.error`, …
    pub kind: String,
    /// Seconds on `CLOCK_BOOTTIME`, the launch marks' clock.
    pub at: f64,
    /// Seconds since the Unix epoch.
    pub wall: f64,
    /// Kind-specific fields.
    pub fields: Map<String, Value>,
}

impl Event {
    /// The fields plus `kind`, `at` and `wall` in one object, the shape the
    /// Apple and web journals produce.
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
type Flush = Arc<dyn Fn(std::time::Duration) + Send + Sync>;

#[derive(Default)]
struct Journal {
    events: VecDeque<Arc<Event>>,
    subscribers: Vec<Subscriber>,
    deferred: Vec<Deferred>,
    flushes: Vec<Flush>,
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

/// Records an event. The first `startup` event starts the [`after_startup`] work.
pub fn record(kind: &str, fields: Map<String, Value>) {
    record_at(kind, fields, crate::launch_marks::boottime());
}

/// Records an event that happened at `at`, seconds on `CLOCK_BOOTTIME`: its
/// `wall` is that moment's, as a service stamps a metric at its mark.
pub fn record_at(kind: &str, fields: Map<String, Value>, at: f64) {
    let now = crate::launch_marks::boottime();
    let e = Arc::new(Event {
        kind: kind.into(),
        at,
        wall: wall() - (now - at),
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

/// Calls `f` with the retained events, then with each new one.
pub fn subscribe(f: impl Fn(&Event) + Send + 'static) {
    with(|j| {
        for e in &j.events {
            f(e);
        }
        j.subscribers.push(Box::new(f));
    });
}

/// Registers `f`, which returns once its launch part has stored the events it was
/// given so far, or once the bound it is passed has run out.
pub fn on_flush(f: impl Fn(std::time::Duration) + Send + Sync + 'static) {
    with(|j| j.flushes.push(Arc::new(f)));
}

/// Waits, `bound` at most in all, until each launch part that registered a flush has
/// stored the events recorded so far. The process is about to end.
pub fn flush(bound: std::time::Duration) {
    let flushes = with(|j| j.flushes.clone());
    let deadline = std::time::Instant::now() + bound;
    for f in flushes {
        f(deadline.saturating_duration_since(std::time::Instant::now()));
    }
}

/// Runs `f` on its own thread once startup is recorded, or at once if it already was.
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

/// The time all launch parts together should take, as on Apple. Overruns are
/// logged to stderr, not enforced.
const LAUNCH_BUDGET: std::time::Duration = std::time::Duration::from_micros(500);

/// Records how long the generated `launch_parts()` took. Logs it when over
/// budget or when `EXACT_OBSERVE_LOG=1`.
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

/// What a launch part receives, like ExactKit's `ExactLaunchContext`.
pub struct LaunchContext {
    /// The module's name in `app.json`'s `launch` list.
    pub module: &'static str,
    /// `app.json`'s `moduleConfig[module]`, JSON (`{}` when none).
    pub config: &'static str,
    /// The app's identity: `{"id","name","version"}` from `app.json`.
    pub app: &'static str,
    /// Whether this is a development build. Observe sends nothing from one
    /// unless configured to.
    pub development: bool,
}

impl LaunchContext {
    /// The context for `module`. `compat` is the baked compatibility id.
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

    /// `$XDG_STATE_HOME/exact/<app id>/<module>`, defaulting to `~/.local/state`.
    /// Not created here, because launch does no I/O.
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

/// POSTs `body` to `url` with the host's existing transport. Returns the
/// status and the `Retry-After` header.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_event_recorded_at_its_mark_carries_that_moments_wall() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let kept = seen.clone();
        subscribe(move |e| {
            if e.kind == "test.mark" {
                kept.lock().unwrap().push((e.at, e.wall));
            }
        });
        let at = crate::launch_marks::boottime() - 2.5;
        record_at("test.mark", Map::new(), at);
        let (marked, stamped) = seen.lock().unwrap()[0];
        assert_eq!(marked, at);
        assert!((stamped - (wall() - 2.5)).abs() < 0.1, "{stamped}");
    }

    #[test]
    fn a_flush_asks_each_part_within_one_bound() {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let kept = asked.clone();
        on_flush(move |bound| kept.lock().unwrap().push(bound));
        flush(std::time::Duration::from_secs(2));
        let asked = asked.lock().unwrap();
        assert_eq!(asked.len(), 1);
        assert!(asked[0] <= std::time::Duration::from_secs(2));
        assert!(asked[0] > std::time::Duration::from_millis(1900));
    }
}
