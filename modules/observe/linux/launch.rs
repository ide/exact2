// Observe on Linux, compiled into the app's executable. The entry that
// `contract::linux_entry` generates calls `launch_parts`, which runs `launch`.
// `launch` does no I/O. It names the session, forwards journal events to a channel and
// installs a panic hook. From the first startup report, a background thread keeps the queue
// (one bounded JSON file), records earlier crashes and answers flushes, and a second
// sends rows in expo-observe's OTLP/JSON, matching `apple/service/ObserveWire.swift` and
// `web/service.js`, so no request delays storing an event.

use exact_linux::journal::{self, serde_json, LaunchContext};
use serde_json::{json, Map, Value};
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

const SCHEMA_URL: &str = "https://opentelemetry.io/schemas/1.27.0";
const CLIENT_VERSION: &str = "0.1.0";
const CHUNK: usize = 200;
const MAX_ROWS: usize = 2000;
const DEBOUNCE: Duration = Duration::from_secs(5);

/// Observe's `metricNameMap`. Exact emits only these names.
fn metric_name(category: &str, name: &str) -> String {
    match (category, name) {
        ("appStartup", "timeToInteractive") => "expo.app_startup.tti",
        ("appStartup", "timeToFirstRender") => "expo.app_startup.ttr",
        ("appStartup", "coldLaunchTime") => "expo.app_startup.cold_launch_time",
        ("appStartup", "warmLaunchTime") => "expo.app_startup.warm_launch_time",
        ("appStartup", "bundleLoadTime") => "expo.app_startup.bundle_load_time",
        ("updates", "updateDownloadTime") => "expo.updates.download_time",
        ("navigation", "cold_ttr") => "expo.navigation.cold_ttr",
        ("navigation", "warm_ttr") => "expo.navigation.warm_ttr",
        ("navigation", "tti") => "expo.navigation.tti",
        _ => return format!("expo.unknown.{name}"),
    }
    .into()
}

fn severity_number(s: &str) -> Option<u8> {
    Some(match s {
        "trace" => 1,
        "debug" => 5,
        "info" => 9,
        "warn" => 13,
        "error" => 17,
        "fatal" => 21,
        _ => return None,
    })
}

fn log_enabled() -> bool {
    std::env::var("EXACT_OBSERVE_LOG").as_deref() == Ok("1")
}

/// Formats 16 bytes as a lowercase v4 UUID.
fn uuid_v4(mut b: [u8; 16]) -> String {
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}

/// A random v4 UUID.
fn uuid() -> String {
    let mut b = [0u8; 16];
    use std::io::Read;
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .is_err()
    {
        let t = journal::wall().to_bits() ^ u64::from(std::process::id()).rotate_left(32);
        b[..8].copy_from_slice(&t.to_le_bytes());
        b[8..].copy_from_slice(&t.rotate_left(17).to_le_bytes());
    }
    uuid_v4(b)
}

/// A v4-format session id hashed from the clocks and the pid.
/// It avoids reading `/dev/urandom`, since a launch part must do no I/O.
fn session_id() -> String {
    let mix = |mut z: u64| {
        z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    };
    let seed = exact_linux::launch_marks::boottime().to_bits()
        ^ u64::from(std::process::id()).rotate_left(40);
    let (a, b) = (mix(seed), mix(seed ^ journal::wall().to_bits()));
    uuid_v4((u128::from(a) << 64 | u128::from(b)).to_be_bytes())
}

/// The launch part: no I/O, no parsing, no thread until startup is reported.
pub fn launch(ctx: LaunchContext) {
    let session = session_id();
    let start = journal::wall();
    // A panic writes `pending-<session>.json`. The next launch sends it as a
    // fatal `native.exception` for this session.
    let (module, config, app, development) = (ctx.module, ctx.config, ctx.app, ctx.development);
    let context = move || LaunchContext {
        module,
        config,
        app,
        development,
    };
    let crash_session = session.clone();
    let launch_type = LaunchType::new(this_launch);
    let crash_launch_type = launch_type.clone();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_default();
        // The crashed process's app and OS, for a session the service never saved: the
        // launch that reads the record can be another build. The hook runs on the
        // panicking thread, not in a signal handler, so it reads them now.
        let parse = |s: &str| serde_json::from_str::<Value>(s).unwrap_or_default();
        let dir = context().state_dir();
        let _ = std::fs::create_dir_all(&dir);
        // Decide the launch type once launch ended, unless the service did, so that
        // `launch.json` names this launch for the next one although it panics first.
        if exact_linux::launch_marks::launch_ended() {
            crash_launch_type.decide(&dir);
        }
        let record = json!({
            "session": crash_session, "sessionStart": start, "time": journal::wall(),
            "type": "panic", "message": message,
            "location": info.location().map(|l| format!("{}:{}", l.file(), l.line())),
            "thread": std::thread::current().name().map(str::to_string),
            "metadata": metadata(&parse(app), &parse(config), development),
        });
        let _ = std::fs::write(
            dir.join(format!("pending-{crash_session}.json")),
            record.to_string(),
        );
        previous(info);
    }));
    let (tx, rx) = mpsc::channel::<Message>();
    let events = tx.clone();
    journal::subscribe(move |e| {
        let _ = events.send(Message::Event(e.json()));
    });
    // Before the process ends (SIGTERM, SIGINT), the host waits until the service
    // has stored what it was given; the next launch sends it.
    journal::on_flush(move |bound| {
        let (done, stored) = mpsc::channel();
        if tx.send(Message::Flush(done)).is_ok() {
            let _ = stored.recv_timeout(bound);
        }
    });
    journal::after_startup(move || {
        let dir = context().state_dir();
        let config: Map<String, Value> = serde_json::from_str(config).unwrap_or_default();
        let app: Value = serde_json::from_str(app).unwrap_or_default();
        let mut service = Service::new(config, &app, development, dir, session, start);
        service.launch_type = launch_type;
        service.run(rx);
    });
}

/// What the launch part hands the service thread.
enum Message {
    /// A journal event.
    Event(Value),
    /// A reply, once the events sent before it are stored.
    Flush(mpsc::Sender<()>),
}

/// Observe's custom-event validation, copied from expo-app-metrics (`LogEvents`).
mod rules {
    use super::*;

    pub fn name(raw: &str) -> Option<String> {
        let n = raw.trim();
        (!n.is_empty() && !n.starts_with("expo.") && n.chars().count() <= 256)
            .then(|| n.to_string())
    }

    pub fn truncate(s: &str, max: usize) -> String {
        if s.chars().count() <= max {
            return s.into();
        }
        s.chars().take(max - 1).chain(['…']).collect()
    }

    fn reserved(k: &str) -> bool {
        (k.starts_with("expo.") && k.len() > 5) || k == "session.id" || k == "event.name"
    }

    /// Keeps up to 128 attributes in key order. Returns the kept ones and how many were dropped.
    pub fn attributes(raw: &Value) -> (Map<String, Value>, u64) {
        let mut kept = Map::new();
        let mut dropped = 0;
        let mut keys: Vec<&String> = raw
            .as_object()
            .map(|o| o.keys().collect())
            .unwrap_or_default();
        keys.sort();
        for key in keys {
            let k = key.trim();
            if k.is_empty() || reserved(k) || kept.len() >= 128 {
                dropped += 1;
                continue;
            }
            kept.insert(k.into(), raw[key].clone());
        }
        (kept, dropped)
    }
}

/// Same as expo main's `EASClientID.deterministicUniformValue` (splitmix64 over both
/// halves of the id): a stable value in [0, 1) per install.
fn uniform(id: &str) -> f64 {
    let hex: String = id.chars().filter(|c| *c != '-').collect();
    let half = |r: std::ops::Range<usize>| {
        hex.get(r)
            .and_then(|h| u64::from_str_radix(h, 16).ok())
            .unwrap_or(0)
    };
    let mut z = half(0..16) ^ half(16..32);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^= z >> 31;
    (z >> 11) as f64 / (1u64 << 53) as f64
}

/// Observe's jittered exponential backoff, in seconds.
fn backoff(attempt: u32) -> f64 {
    let random = u64::from_str_radix(&uuid().replace('-', "")[..13], 16).unwrap_or(0) as f64
        / (1u64 << 52) as f64;
    (60.0 * 2f64.powi(attempt as i32 - 1)).min(900.0) * random
}

/// The server's Retry-After in seconds from `now` (Unix seconds), clamped to 60-900, as
/// expo-observe's `parseRetryAfter` reads it: delta-seconds or an IMF-fixdate.
fn retry_after(h: Option<&str>, now: f64) -> Option<f64> {
    let raw = h?.trim();
    let s = match raw.parse::<f64>() {
        Ok(s) => s,
        Err(_) => http_date(raw)? - now,
    };
    s.is_finite().then(|| s.clamp(60.0, 900.0))
}

/// The Unix time of an IMF-fixdate (RFC 9110 §5.6.7), `Wed, 21 Oct 2026 07:28:00 GMT`.
fn http_date(s: &str) -> Option<f64> {
    const DAYS: [&str; 7] = ["Mon,", "Tue,", "Wed,", "Thu,", "Fri,", "Sat,", "Sun,"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let [day, date, month, year, time, "GMT"] = s.split(' ').collect::<Vec<_>>()[..] else {
        return None;
    };
    let number = |s: &str, digits: usize| -> Option<i64> {
        if s.len() != digits || !s.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        s.parse().ok()
    };
    let [h, m, sec] = time.split(':').collect::<Vec<_>>()[..] else {
        return None;
    };
    let (d, y) = (number(date, 2)?, number(year, 4)?);
    let (h, m, sec) = (number(h, 2)?, number(m, 2)?, number(sec, 2)?);
    let month = MONTHS.iter().position(|n| *n == month)? as i64 + 1;
    if !DAYS.contains(&day) || !(1..=31).contains(&d) || h > 23 || m > 59 || sec > 60 {
        return None;
    }
    // Days since 1970-01-01 in the proleptic Gregorian calendar, from a year that starts
    // in March (Howard Hinnant's `days_from_civil`).
    let y = if month <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * ((month + 9) % 12) + 2) / 5 + d - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    Some((days * 86_400 + h * 3600 + m * 60 + sec) as f64)
}

/// An OTLP attribute with a string value.
fn string_attr(key: &str, value: &str) -> Value {
    json!({ "key": key, "value": { "stringValue": value } })
}

/// A JSON number, as expo-observe sends it.
fn nanos(seconds: f64) -> u64 {
    (seconds * 1000.0).round() as u64 * 1_000_000
}

/// Observe's `otAnyValue`: a value it can't represent is dropped and counted.
fn any_value(v: &Value) -> Option<Value> {
    Some(match v {
        Value::Bool(b) => json!({ "boolValue": b }),
        Value::Number(n) if n.is_i64() => json!({ "intValue": n.as_i64() }),
        Value::Number(n) => {
            let f = n.as_f64()?;
            if f.fract() == 0.0 && f.abs() < 9.0e15 {
                json!({ "intValue": f as i64 })
            } else {
                json!({ "doubleValue": f })
            }
        }
        Value::String(s) => json!({ "stringValue": s }),
        Value::Array(a) => {
            json!({ "arrayValue": { "values": a.iter().map(any_value).collect::<Option<Vec<_>>>()? } })
        }
        Value::Object(o) => {
            json!({ "kvlistValue": { "values": o.iter().map(|(k, x)| any_value(x).map(|m| json!({ "key": k, "value": m }))).collect::<Option<Vec<_>>>()? } })
        }
        Value::Null => return None,
    })
}

fn read_json(path: &std::path::Path) -> Value {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn read(path: &str) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The device state Observe attaches to TTI, read when the startup report arrives.
/// Low-power mode comes from the ACPI platform profile. Missing hardware is left out.
fn device() -> Map<String, Value> {
    let mut d = Map::new();
    if let Some(profile) = read("/sys/firmware/acpi/platform_profile") {
        d.insert(
            "expo.device.lowPowerMode".into(),
            (profile == "low-power" || profile == "quiet").into(),
        );
    }
    for entry in std::fs::read_dir("/sys/class/power_supply")
        .into_iter()
        .flatten()
        .flatten()
    {
        let p = entry.path();
        if read(&format!("{}/type", p.display())).as_deref() != Some("Battery") {
            continue;
        }
        if let Some(c) =
            read(&format!("{}/capacity", p.display())).and_then(|c| c.parse::<f64>().ok())
        {
            d.insert("expo.device.batteryLevel".into(), json!(c / 100.0));
        }
        if let Some(s) = read(&format!("{}/status", p.display())) {
            d.insert(
                "expo.device.batteryCharging".into(),
                (s == "Charging" || s == "Full").into(),
            );
        }
        break;
    }
    let mut kind = None;
    for entry in std::fs::read_dir("/sys/class/net")
        .into_iter()
        .flatten()
        .flatten()
    {
        let p = entry.path();
        if entry.file_name() == "lo"
            || read(&format!("{}/operstate", p.display())).as_deref() != Some("up")
        {
            continue;
        }
        let wifi = p.join("wireless").exists();
        if kind.is_none() || wifi {
            kind = Some(if wifi {
                "wifi"
            } else if p.join("device").exists() {
                "ethernet"
            } else {
                "other"
            });
        }
    }
    d.insert("expo.network.connected".into(), kind.is_some().into());
    d.insert("expo.network.type".into(), kind.unwrap_or("none").into());
    d
}

type Row = Map<String, Value>;

/// A session's metadata: this process's app, OS and device, and the environment.
fn metadata(app: &Value, config: &Value, development: bool) -> Value {
    let environment = config["environment"].as_str().unwrap_or(if development {
        "development"
    } else {
        "production"
    });
    json!({
        "osName": "Linux",
        "osVersion": read("/proc/sys/kernel/osrelease"),
        "deviceModel": read("/sys/devices/virtual/dmi/id/product_name"),
        // `en_US.UTF-8` becomes `en-US`. `C` and `POSIX` mean no language.
        "language": std::env::var("LANG").ok().map(|l| l.split('.').next().unwrap_or("").replace('_', "-"))
            .filter(|l| !l.is_empty() && l != "C" && l != "POSIX"),
        "clientVersion": CLIENT_VERSION,
        "appIdentifier": app["id"], "appName": app["name"], "appVersion": app["version"],
        "environment": environment,
    })
}

/// The JSON object `v` builds, as a map.
fn object(v: Value) -> Map<String, Value> {
    match v {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}

/// This launch's type, decided once after launch end by the first of the service and a
/// panic, so that both name the same type and neither reads this launch as the previous one.
struct LaunchType {
    decided: OnceLock<&'static str>,
    /// This launch's identity, which the next launch compares, and whether stderr is a
    /// terminal: [`this_launch`], which tests replace.
    this: fn() -> (Value, bool),
}

impl LaunchType {
    fn new(this: fn() -> (Value, bool)) -> Arc<Self> {
        Arc::new(LaunchType {
            decided: OnceLock::new(),
            this,
        })
    }

    /// Warm when the previous launch was the same build in the same OS boot and stderr is
    /// not a terminal, otherwise cold (Observe's iOS rule). The previous launch is the
    /// one `dir`'s `launch.json` names, and deciding names this one there instead, as
    /// Observe saves each launch's state at launch end. It does file I/O, so the service
    /// decides at the startup report, and a panic hook when the panic comes first.
    fn decide(&self, dir: &std::path::Path) -> &'static str {
        // Keep this closure free of panics, since a panic hook on the thread running it
        // would reenter `get_or_init`, which deadlocks
        self.decided.get_or_init(|| {
            let (this, terminal) = (self.this)();
            let path = dir.join("launch.json");
            let previous = read_json(&path);
            let _ = std::fs::write(&path, this.to_string());
            let same = |key: &str| !this[key].is_null() && previous[key] == this[key];
            if same("boot") && same("build") && !terminal {
                "warm"
            } else {
                "cold"
            }
        })
    }
}

/// This launch as Observe's rule compares it: the OS boot and the build (the executable's
/// size and mtime), and whether stderr is a terminal.
fn this_launch() -> (Value, bool) {
    use std::io::IsTerminal;
    let boot = read("/proc/sys/kernel/random/boot_id");
    let build = std::fs::metadata("/proc/self/exe").ok().map(|m| {
        let mtime = m
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
        format!("{}:{}", m.len(), mtime.map_or(0, |d| d.as_nanos()))
    });
    (
        json!({ "boot": boot, "build": build }),
        std::io::stderr().is_terminal(),
    )
}

/// A metric row of `session`'s, stamped `wall`.
fn metric_row(session: &str, category: &str, name: &str, value: f64, wall: f64) -> Row {
    object(json!({
        "session": session, "time": wall, "category": category, "name": name, "value": value,
    }))
}

/// The service thread's state: what turns journal events into rows.
struct Service {
    /// `moduleConfig.observe`. Indexing a missing key gives `null`.
    config: Value,
    development: bool,
    dir: PathBuf,
    session: String,
    client_id: String,
    /// The rows, which the [`Sender`] sends.
    queue: Arc<Mutex<Queue>>,
    globals: Map<String, Value>,
    launch_route: Option<Value>,
    /// The startup metrics stored, by their names in the report: the host journals its
    /// startup report each time it gains a metric.
    startup_metrics: std::collections::BTreeSet<String>,
    /// This launch's type, which the launch part shares with its panic hook.
    launch_type: Arc<LaunchType>,
    /// Reads the device state at TTI. Tests replace it.
    device: fn() -> Map<String, Value>,
}

/// The signals, each sent to its own endpoint.
const SIGNALS: [&str; 2] = ["metrics", "logs"];

/// One endpoint's retry gate, as expo-observe keeps one per endpoint: nothing is
/// sent before `after`, and `failures` retryable failures in a row set the backoff.
#[derive(Clone, Copy, Debug, Default)]
struct Gate {
    after: Option<Instant>,
    failures: u32,
}

impl Service {
    fn new(
        config: Map<String, Value>,
        app: &Value,
        development: bool,
        dir: PathBuf,
        session: String,
        start: f64,
    ) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        let id_file = dir.join("eas-client-id");
        let client_id = read(&id_file.to_string_lossy()).unwrap_or_else(|| {
            let id = uuid();
            let _ = std::fs::write(&id_file, &id);
            id
        });
        let mut s = Service {
            development,
            queue: Arc::new(Mutex::new(Queue::load(dir.clone()))),
            dir,
            client_id,
            globals: Map::new(),
            launch_route: None,
            startup_metrics: Default::default(),
            launch_type: LaunchType::new(this_launch),
            device,
            session,
            config: Value::Object(config),
        };
        let meta = metadata(app, &s.config, development);
        lock(&s.queue)
            .sessions
            .insert(s.session.clone(), json!({ "start": start, "meta": meta }));
        if log_enabled() {
            eprintln!("observe: service started, session {}", s.session);
        }
        s.ingest_crashes();
        lock(&s.queue).save();
        s
    }

    /// What sends this service's rows, its first dispatch after the debounce.
    fn sender(&self) -> Sender {
        Sender {
            queue: self.queue.clone(),
            config: self.config.clone(),
            development: self.development,
            session: self.session.clone(),
            client_id: self.client_id.clone(),
            due: Some(Instant::now() + DEBOUNCE),
            gates: [Gate::default(); 2],
        }
    }

    fn run(self, rx: mpsc::Receiver<Message>) {
        let sender = self.sender();
        self.serve(rx, sender);
    }

    /// Stores each event and answers each flush, while `sender` sends on a thread of
    /// its own, which each stored event wakes.
    fn serve(mut self, rx: mpsc::Receiver<Message>, sender: Sender) {
        let (wake, woken) = mpsc::channel();
        let sending = std::thread::spawn(move || sender.run(woken));
        while let Ok(message) = rx.recv() {
            match message {
                Message::Event(e) => {
                    if self.event(&e) {
                        let _ = wake.send(());
                    }
                }
                // Each event is stored as it is handled, so those before this one are.
                Message::Flush(done) => {
                    let _ = done.send(());
                }
            }
        }
        drop(wake);
        let _ = sending.join();
    }

    fn metric(
        &mut self,
        category: &str,
        name: &str,
        value: f64,
        wall: f64,
        route: Option<&Value>,
        params: Map<String, Value>,
    ) {
        let mut r = metric_row(&self.session, category, name, value, wall);
        if let Some(route) = route.filter(|r| r.is_string()) {
            r.insert("route".into(), route.clone());
        }
        if !params.is_empty() {
            r.insert("params".into(), Value::Object(params).to_string().into());
        }
        lock(&self.queue).push("metrics", r);
    }

    fn log(
        &mut self,
        session: String,
        wall: f64,
        severity: &str,
        name: &str,
        body: Option<String>,
        (attributes, dropped): (Map<String, Value>, u64),
    ) {
        let mut r = object(json!({
            "session": session, "time": wall, "severity": severity, "name": name,
            "attributes": attributes, "dropped": dropped,
        }));
        if let Some(b) = body {
            r.insert("body".into(), b.into());
        }
        lock(&self.queue).push("logs", r);
    }

    /// Stores the rows `e` makes. Whether it stored any.
    fn event(&mut self, e: &Value) -> bool {
        let wall = e["wall"].as_f64().unwrap_or_else(journal::wall);
        match e["kind"].as_str().unwrap_or("") {
            "startup" => self.startup(e, wall),
            "navigation.launch" => {
                self.launch_route = Some(e.clone());
                return false;
            }
            "navigation" => self.navigation(e, wall),
            "app.attributes" => {
                self.globals = rules::attributes(&e["attributes"]).0;
                return false;
            }
            "app.event" => {
                let Some(name) = rules::name(e["name"].as_str().unwrap_or("")) else {
                    eprintln!("observe: dropped an event with an invalid name");
                    return false;
                };
                let (kept, dropped) = rules::attributes(&e["attributes"]);
                let mut attrs = self.globals.clone();
                attrs.extend(kept);
                if let Some(d) = e["displayName"]
                    .as_str()
                    .map(str::trim)
                    .filter(|d| !d.is_empty())
                {
                    attrs.insert(
                        "expo.log.display_name".into(),
                        rules::truncate(d, 128).into(),
                    );
                }
                let severity = e["severity"]
                    .as_str()
                    .filter(|s| severity_number(s).is_some())
                    .unwrap_or("info");
                let body = e["body"].as_str().map(|b| rules::truncate(b, 4096));
                self.log(
                    self.session.clone(),
                    wall,
                    severity,
                    &name,
                    body,
                    (attrs, dropped),
                );
            }
            "app.error" => {
                let mut attrs = self.globals.clone();
                attrs.extend(object(json!({
                    "expo.error.source": e["source"].as_str().unwrap_or("reportedByUser"),
                    "expo.error.is_fatal": false,
                    "exception.type": e["type"].as_str().unwrap_or("Error"),
                    "exception.message": e["message"].as_str().unwrap_or(""),
                })));
                if let Some(stack) = e["stack"].as_str() {
                    attrs.insert("exception.stacktrace".into(), stack.into());
                }
                self.log(
                    self.session.clone(),
                    wall,
                    "error",
                    "js.exception",
                    None,
                    (attrs, 0),
                );
            }
            _ => return false,
        }
        lock(&self.queue).save();
        true
    }

    /// Stores the launch metrics from the host's startup report under Observe's names,
    /// each at the time of its own mark, and each once.
    fn startup(&mut self, e: &Value, wall: f64) {
        let marks = &e["marks"];
        let at = |name: &str| e["walls"][name].as_f64().unwrap_or(wall);
        let ms = |a: &str, b: &str| {
            Some(json!(
                ((marks[a].as_f64()? - marks[b].as_f64()?) * 10.0).round() / 10_000.0
            ))
        };
        let mut phases = Map::new();
        for (k, v) in [
            ("exact.phase.boot", ms("commit", "boot")),
            ("exact.phase.present", ms("present", "commit")),
            ("exact.phase.activate", ms("activated", "commit")),
            ("exact.since_process_start.ttr", ms("present", "process")),
            (
                "exact.since_process_start.tti",
                ms("interactive", "process"),
            ),
        ] {
            if let Some(v) = v {
                phases.insert(k.into(), v);
            }
        }
        // The first frame counts as shown when its synchronous modeset returns.
        phases.insert("exact.present.method".into(), "modeset".into());
        if let Some(path) = e["bootPath"].as_str() {
            phases.insert("exact.boot.path".into(), path.into());
        }
        if let Some(r) = e["processResolutionMs"].as_f64() {
            phases.insert("exact.launch.resolution_ms".into(), json!(r));
        }
        let launch = self.launch_type.decide(&self.dir);
        let mut stored = Vec::new();
        for (name, value) in e["metrics"].as_object().into_iter().flatten() {
            let Some(value) = value.as_f64() else {
                continue;
            };
            if !self.startup_metrics.insert(name.clone()) {
                continue;
            }
            stored.push(name.as_str());
            let wall = at(name);
            let name = &if name == "coldLaunchTime" {
                format!("{launch}LaunchTime")
            } else {
                name.clone()
            };
            let mut params = self.globals.clone();
            params.extend(phases.clone());
            let mut route = None;
            if name == "timeToInteractive" {
                params.extend((self.device)());
                params.insert("exact.tti.reason".into(), e["tti"].clone());
                // What was outstanding over time, ms from process start: shows what held TTI.
                if let Some(trace) = e["trace"].as_array().filter(|t| !t.is_empty()) {
                    let steps: Vec<&str> = trace.iter().filter_map(Value::as_str).collect();
                    params.insert("exact.tti.trace".into(), steps.join(" → ").into());
                }
                // The screen shown at TTI, with Observe's navigation params.
                if e["route"].is_object() {
                    route = Some(e["route"]["route"].clone());
                    let route_params = match &e["route"]["routeParams"] {
                        Value::Null => json!({}),
                        p => p.clone(),
                    };
                    params.insert("routeParams".into(), route_params);
                    if !e["route"]["url"].is_null() {
                        params.insert("url".into(), e["route"]["url"].clone());
                    }
                }
            }
            self.metric("appStartup", name, value, wall, route.as_ref(), params);
        }
        // The launch route's `cold_ttr` and `tti`, measured from boot. Observe measures
        // from its integration start, which has no Exact equivalent.
        if let (Some(route), Some(boot)) = (self.launch_route.clone(), marks["boot"].as_f64()) {
            let mut params = self.nav_params(&route, true);
            params.insert("exact.nav.anchor".into(), "boot".into());
            if let (Some(present), true) = (
                marks["present"].as_f64(),
                stored.contains(&"timeToFirstRender"),
            ) {
                self.metric(
                    "navigation",
                    "cold_ttr",
                    (present - boot) / 1000.0,
                    at("timeToFirstRender"),
                    Some(&route["route"]),
                    params.clone(),
                );
            }
            // Startup's TTI is the launch screen's when that screen stayed on top until it.
            if let (Some(i), true, true) = (
                marks["interactive"].as_f64(),
                e["launchScreen"] == json!(true),
                stored.contains(&"timeToInteractive"),
            ) {
                self.metric(
                    "navigation",
                    "tti",
                    (i - boot) / 1000.0,
                    at("timeToInteractive"),
                    Some(&route["route"]),
                    params,
                );
            }
        }
    }

    /// Observe's navigation params, on top of the global attributes.
    fn nav_params(&self, e: &Value, launch: bool) -> Map<String, Value> {
        let mut params = self.globals.clone();
        let route_params = match &e["routeParams"] {
            Value::Null => json!({}),
            p => p.clone(),
        };
        params.extend(object(
            json!({ "isAppLaunch": launch, "routeParams": route_params }),
        ));
        if !e["url"].is_null() {
            params.insert("url".into(), e["url"].clone());
        }
        params
    }

    fn navigation(&mut self, e: &Value, wall: f64) {
        let (Some(name), Some(value)) = (e["name"].as_str(), e["value"].as_f64()) else {
            return;
        };
        let mut params = self.nav_params(e, false);
        for (k, v) in e
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(k, _)| k.starts_with("exact."))
        {
            params.insert(k.clone(), v.clone());
        }
        self.metric("navigation", name, value, wall, Some(&e["route"]), params);
    }

    /// Turns each pending panic record from an earlier process into a `native.exception` log.
    fn ingest_crashes(&mut self) {
        for entry in std::fs::read_dir(&self.dir).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with("pending-") || name.contains(&self.session) {
                continue;
            }
            let path = entry.path();
            let o = read_json(&path);
            let _ = std::fs::remove_file(&path);
            let Some(crashed) = o["session"].as_str() else {
                continue;
            };
            let mut queue = lock(&self.queue);
            if !queue.sessions.contains_key(crashed) {
                // The crashed process's metadata, over this launch's for what it lacks.
                let mut meta = queue.sessions[&self.session]["meta"].clone();
                if let (Some(meta), Some(crashed)) =
                    (meta.as_object_mut(), o["metadata"].as_object())
                {
                    meta.extend(
                        crashed
                            .iter()
                            .filter(|(_, v)| !v.is_null())
                            .map(|(k, v)| (k.clone(), v.clone())),
                    );
                }
                queue.sessions.insert(
                    crashed.into(),
                    json!({ "start": o["sessionStart"], "meta": meta }),
                );
            }
            drop(queue);
            let mut attrs = object(json!({
                "exception.type": o["type"].as_str().unwrap_or("panic"),
                "exception.message": o["message"].as_str().unwrap_or(""),
                "expo.error.source": "nativeCrash",
                "expo.error.is_fatal": true,
            }));
            if let Some(at) = o["location"].as_str() {
                attrs.insert("exception.stacktrace".into(), format!("at {at}").into());
            }
            let time = o["time"].as_f64().unwrap_or_else(journal::wall);
            self.log(
                crashed.into(),
                time,
                "fatal",
                "native.exception",
                None,
                (attrs, 0),
            );
        }
    }
}

/// The sender thread's state: what sends the queue, without holding its lock during a
/// request, and when it sends next.
struct Sender {
    queue: Arc<Mutex<Queue>>,
    config: Value,
    development: bool,
    session: String,
    client_id: String,
    /// The next dispatch: the debounce after an event, or the earliest retry gate
    /// that holds queued rows.
    due: Option<Instant>,
    /// Each signal's retry gate, in [`SIGNALS`]' order.
    gates: [Gate; 2],
}

impl Sender {
    /// Dispatches when due. Each message on `woken` is an event stored; once the
    /// service thread ends, sends what is left and returns.
    fn run(mut self, woken: mpsc::Receiver<()>) {
        loop {
            let wait = self.due.map_or(Duration::from_secs(3600), |d| {
                d.saturating_duration_since(Instant::now())
            });
            match woken.recv_timeout(wait) {
                Ok(()) => self.schedule(),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return self.dispatch(),
            }
            if self.due.is_some_and(|d| Instant::now() >= d) {
                self.dispatch();
            }
        }
    }

    /// Dispatches after the debounce, or sooner if a dispatch is already due.
    fn schedule(&mut self) {
        let soon = Instant::now() + DEBOUNCE;
        self.due = Some(self.due.map_or(soon, |due| due.min(soon)));
    }

    fn resource(&self, meta: &Value) -> Value {
        let mut a = vec![string_attr("os.type", "linux")];
        let mut s = |k: &str, v: &Value| a.extend(v.as_str().map(|v| string_attr(k, v)));
        s("os.name", &meta["osName"]);
        s("os.version", &meta["osVersion"]);
        s("device.model.name", &meta["deviceName"]);
        s("device.model.identifier", &meta["deviceModel"]);
        s("browser.language", &meta["language"]);
        s("telemetry.sdk.name", &json!("exact-observe"));
        s("telemetry.sdk.version", &meta["clientVersion"]);
        s("telemetry.sdk.language", &json!("rust"));
        s("expo.eas_client.id", &json!(self.client_id));
        s("service.name", &meta["appIdentifier"]);
        s("service.version", &meta["appVersion"]);
        s("expo.app.name", &meta["appName"]);
        s("expo.environment", &meta["environment"]);
        json!({ "attributes": a })
    }

    /// `{"resourceMetrics":[…]}` or `{"resourceLogs":[…]}`, one resource per session.
    fn body(&self, signal: &str, rows: &[Row], sessions: &Map<String, Value>) -> Value {
        let mut by: Vec<(String, Vec<Value>)> = Vec::new();
        for r in rows {
            let session = r["session"].as_str().unwrap_or("").to_string();
            let time = r["time"].as_f64().unwrap_or(0.0);
            let mut attrs = vec![string_attr("session.id", &session)];
            let item = if signal == "metrics" {
                let text = |k: &str| r.get(k).and_then(Value::as_str);
                attrs.extend(text("route").map(|v| string_attr("expo.route_name", v)));
                attrs.extend(text("params").map(|v| string_attr("expo.custom_params", v)));
                let name = metric_name(
                    r["category"].as_str().unwrap_or(""),
                    r["name"].as_str().unwrap_or(""),
                );
                json!({ "unit": "s", "name": name, "gauge": { "dataPoints": [{ "timeUnixNano": nanos(time), "asDouble": r["value"], "attributes": attrs }] } })
            } else {
                let name = r["name"].as_str().unwrap_or("");
                attrs.push(string_attr("event.name", name));
                let mut dropped = r.get("dropped").and_then(Value::as_u64).unwrap_or(0);
                let mut keys: Vec<(&String, &Value)> = r
                    .get("attributes")
                    .and_then(Value::as_object)
                    .into_iter()
                    .flatten()
                    .collect();
                keys.sort_by(|a, b| a.0.cmp(b.0));
                for (k, v) in keys {
                    match any_value(v) {
                        Some(m) => attrs.push(json!({ "key": k, "value": m })),
                        None => dropped += 1,
                    }
                }
                let severity = r["severity"].as_str().unwrap_or("info");
                let mut rec = json!({
                    "timeUnixNano": nanos(time), "observedTimeUnixNano": nanos(time),
                    "severityNumber": severity_number(severity).unwrap_or(9), "severityText": severity.to_uppercase(),
                    "body": { "stringValue": r.get("body").and_then(Value::as_str).unwrap_or("") }, "attributes": attrs,
                });
                if dropped > 0 {
                    rec["droppedAttributesCount"] = dropped.into();
                }
                rec
            };
            match by.iter_mut().find(|(s, _)| *s == session) {
                Some((_, items)) => items.push(item),
                None => by.push((session, vec![item])),
            }
        }
        let (outer, inner, list) = if signal == "metrics" {
            ("resourceMetrics", "scopeMetrics", "metrics")
        } else {
            ("resourceLogs", "scopeLogs", "logRecords")
        };
        let resources: Vec<Value> = by
            .into_iter()
            .filter_map(|(s, items)| {
                let meta = &sessions.get(&s)?["meta"];
                let scope = json!({ "name": "expo-observe", "version": meta["clientVersion"].as_str().unwrap_or("0") });
                Some(json!({ "resource": self.resource(meta), inner: [{ "scope": scope, list: items }], "schemaUrl": SCHEMA_URL }))
            })
            .collect();
        json!({ outer: resources })
    }

    /// Observe's gate: dispatching enabled, this install in the sample, and not a development
    /// build unless `dispatchInDebug`. When it fails, rows are dropped, not kept for later.
    fn should_dispatch(&self) -> bool {
        let c = &self.config;
        let rate = c["sampleRate"].as_f64().unwrap_or(1.0).clamp(0.0, 1.0);
        c["dispatchingEnabled"].as_bool().unwrap_or(true)
            && uniform(&self.client_id) < rate
            && (!self.development || c["dispatchInDebug"] == true)
    }

    /// Sends each signal whose gate is open, until every signal with rows left has its
    /// gate closed: a gate that opens during another signal's send is sent at once, and
    /// so is a row the service thread stores meanwhile. A retryable failure of one
    /// endpoint closes only its own gate, and the rows a closed gate holds are due at
    /// its deadline.
    fn dispatch(&mut self) {
        self.due = None;
        let project = self.config["projectId"].as_str().map(str::to_string);
        let Some(project) = project.filter(|_| self.should_dispatch()) else {
            let mut queue = lock(&self.queue);
            queue.metrics.clear();
            queue.logs.clear();
            return queue.save();
        };
        let base = self.config["endpoint"]
            .as_str()
            .unwrap_or("https://o.expo.dev")
            .trim_end_matches('/')
            .to_string();
        let open = |gate: &Gate| gate.after.is_none_or(|after| after <= Instant::now());
        loop {
            for (i, signal) in SIGNALS.iter().enumerate() {
                if open(&self.gates[i]) {
                    self.send(i, &format!("{base}/{project}/v1/{signal}"));
                }
            }
            let queue = lock(&self.queue);
            let rows = [&queue.metrics, &queue.logs];
            if !rows
                .iter()
                .zip(&self.gates)
                .any(|(r, g)| !r.is_empty() && open(g))
            {
                break;
            }
        }
        let mut queue = lock(&self.queue);
        // Forget sessions no queued row refers to, except the current one.
        let live: std::collections::HashSet<String> = queue
            .metrics
            .iter()
            .chain(&queue.logs)
            .filter_map(|r| r["session"].as_str().map(str::to_string))
            .collect();
        queue
            .sessions
            .retain(|s, _| *s == self.session || live.contains(s));
        queue.save();
        self.due = [&queue.metrics, &queue.logs]
            .iter()
            .zip(&self.gates)
            .filter(|(rows, _)| !rows.is_empty())
            .filter_map(|(_, gate)| gate.after)
            .min();
    }

    /// Sends signal `i`'s rows chunk by chunk, as expo-observe's `DispatchLoop.swift` does,
    /// until none are left or its gate closes. Each chunk is taken from the queue under its
    /// lock and sent without it; the rows it held leave the queue by their ids, wherever
    /// the rows stored meanwhile put them.
    fn send(&mut self, i: usize, url: &str) {
        let signal = SIGNALS[i];
        let mut limit = CHUNK;
        loop {
            let (count, ids, body) = {
                let queue = lock(&self.queue);
                let rows = queue.rows(signal);
                if rows.is_empty() {
                    return;
                }
                let chunk = &rows[..limit.min(rows.len())];
                let ids: Vec<u64> = chunk.iter().filter_map(Queue::id).collect();
                (chunk.len(), ids, self.body(signal, chunk, &queue.sessions))
            };
            let headers = [
                ("content-type", "application/json"),
                ("expo-appmetrics-skip", "1"),
            ];
            let result = journal::post(url, &headers, body.to_string().into_bytes());
            if log_enabled() {
                let status = result
                    .as_ref()
                    .map_or_else(|e| format!("transport error ({e})"), |(s, _)| s.to_string());
                eprintln!("observe: {signal} {count} rows → {status}");
            }
            let gate = &mut self.gates[i];
            match result {
                Ok((413, _)) if count > 1 => {
                    gate.failures = 0;
                    limit = count / 2;
                }
                // Success, a lone 413 row, or a status Observe does not retry: drop the chunk.
                Ok((status, _)) if !matches!(status, 429 | 502 | 503 | 504) => {
                    gate.failures = 0;
                    let mut queue = lock(&self.queue);
                    queue.remove(signal, &ids);
                    // Store the queue without the chunk before the next request, so an exit
                    // during that one does not send it again.
                    queue.save();
                    limit = CHUNK;
                }
                retryable => {
                    gate.failures += 1;
                    let after = retryable.ok().and_then(|(_, after)| after);
                    let wait = retry_after(after.as_deref(), journal::wall())
                        .unwrap_or_else(|| backoff(gate.failures));
                    gate.after = Some(Instant::now() + Duration::from_secs_f64(wait));
                    return;
                }
            }
        }
    }
}

/// The rows waiting to be sent and the sessions they name, stored in one bounded file.
/// The service thread adds rows and the sender removes them, each under the lock.
struct Queue {
    dir: PathBuf,
    sessions: Map<String, Value>,
    metrics: Vec<Row>,
    logs: Vec<Row>,
    /// The next row's `id`, by which the sender removes the rows it sent.
    next: u64,
}

impl Queue {
    /// The queue stored in `dir`, each row with an id.
    fn load(dir: PathBuf) -> Queue {
        let stored = read_json(&dir.join("queue.json"));
        let rows = |k: &str| -> Vec<Row> {
            stored[k]
                .as_array()
                .map(|a| a.iter().filter_map(|r| r.as_object().cloned()).collect())
                .unwrap_or_default()
        };
        let mut queue = Queue {
            sessions: stored["sessions"].as_object().cloned().unwrap_or_default(),
            metrics: rows("metrics"),
            logs: rows("logs"),
            next: 0,
            dir,
        };
        let ids = queue
            .metrics
            .iter()
            .chain(&queue.logs)
            .filter_map(Queue::id);
        queue.next = ids.max().map_or(0, |id| id + 1);
        for row in queue.metrics.iter_mut().chain(queue.logs.iter_mut()) {
            if Queue::id(row).is_none() {
                row.insert("id".into(), queue.next.into());
                queue.next += 1;
            }
        }
        queue
    }

    fn id(row: &Row) -> Option<u64> {
        row.get("id").and_then(Value::as_u64)
    }

    fn rows(&self, signal: &str) -> &[Row] {
        if signal == "metrics" {
            &self.metrics
        } else {
            &self.logs
        }
    }

    fn rows_mut(&mut self, signal: &str) -> &mut Vec<Row> {
        if signal == "metrics" {
            &mut self.metrics
        } else {
            &mut self.logs
        }
    }

    /// Appends `row` to `signal`'s rows with the next id, dropping the oldest past `MAX_ROWS`.
    fn push(&mut self, signal: &str, mut row: Row) {
        row.insert("id".into(), self.next.into());
        self.next += 1;
        let rows = self.rows_mut(signal);
        rows.push(row);
        if rows.len() > MAX_ROWS {
            rows.remove(0);
        }
    }

    /// Removes `signal`'s rows with these ids.
    fn remove(&mut self, signal: &str, ids: &[u64]) {
        self.rows_mut(signal)
            .retain(|row| Queue::id(row).is_none_or(|id| !ids.contains(&id)));
    }

    fn save(&self) {
        let q = json!({ "sessions": self.sessions, "metrics": self.metrics, "logs": self.logs });
        let tmp = self.dir.join("queue.json.tmp");
        if std::fs::write(&tmp, q.to_string()).is_ok() {
            let _ = std::fs::rename(&tmp, self.dir.join("queue.json"));
        }
    }
}

/// The queue, locked, also after a thread panicked while it held it, so the other
/// thread keeps storing or sending.
fn lock(queue: &Mutex<Queue>) -> MutexGuard<'_, Queue> {
    queue.lock().unwrap_or_else(|e| e.into_inner())
}
