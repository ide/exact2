//! Startup timestamps for the display path (a headless run reports none).
//!
//! All marks are seconds on `CLOCK_BOOTTIME`, the clock `/proc/self/stat`
//! counts the process start in (ticks of 1/`CLK_TCK`, usually 10 ms).
//! A suspend during startup therefore counts toward the numbers.
//! DRM flip timestamps are `CLOCK_MONOTONIC` and are converted on read.

use std::time::Duration;

fn clock(id: libc::clockid_t) -> f64 {
    let mut t = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: clock_gettime writes the timespec it is given.
    #[allow(unsafe_code)]
    unsafe {
        libc::clock_gettime(id, &mut t);
    }
    t.tv_sec as f64 + t.tv_nsec as f64 / 1e9
}

/// Seconds on `CLOCK_BOOTTIME`.
pub fn boottime() -> f64 {
    #[cfg(target_os = "linux")]
    {
        clock(libc::CLOCK_BOOTTIME)
    }
    #[cfg(not(target_os = "linux"))]
    {
        clock(libc::CLOCK_MONOTONIC)
    }
}

/// Converts a `CLOCK_MONOTONIC` instant, such as a DRM flip's, to BOOTTIME seconds.
fn monotonic_to_boottime(t: Duration) -> f64 {
    t.as_secs_f64() + (boottime() - clock(libc::CLOCK_MONOTONIC))
}

/// The process start in seconds since boot, and the tick length in ms.
fn process_start() -> Option<(f64, f64)> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    // Field 22 (starttime). Count from the last ')' since the command name may contain spaces.
    let after = &stat[stat.rfind(')')? + 2..];
    let ticks: f64 = after.split(' ').nth(19)?.parse().ok()?;
    // SAFETY: sysconf reads a constant.
    #[allow(unsafe_code)]
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    (hz > 0.0).then(|| (ticks / hz, 1000.0 / hz))
}

/// The runner's outstanding work as `kind:name` items, named as on the Apple host.
pub fn items(o: &exact_runner::runner::outstanding::Outstanding) -> Vec<String> {
    let mut out = Vec::new();
    for (key, list) in [
        ("requests", &o.requests),
        ("streams", &o.streams),
        ("awaiting", &o.awaiting),
        ("oneShots", &o.one_shots),
        ("busy", &o.busy),
    ] {
        out.extend(list.iter().map(|n| format!("{key}:{n}")));
    }
    if !o.data_ready {
        out.push("activation".into());
    }
    out
}

/// One launch's marks, from process start to time to interactive (TTI).
#[derive(Default)]
pub struct LaunchMarks {
    process: Option<f64>,
    resolution_ms: f64,
    launch_end: Option<f64>,
    commit: Option<f64>,
    present: Option<f64>,
    activated: Option<f64>,
    interactive: Option<f64>,
    outcome: Option<&'static str>,
    /// A frame was submitted since the screen was last presented.
    changed: bool,
    trace: Vec<String>,
    reported: bool,
}

impl LaunchMarks {
    /// Reads the process start from the kernel.
    pub fn new() -> Self {
        let (process, resolution_ms) = process_start().map_or((None, 0.0), |(p, r)| (Some(p), r));
        LaunchMarks {
            process,
            resolution_ms,
            ..Default::default()
        }
    }

    /// Marks launch end: the display is open and Exact is about to build its first tree.
    pub fn launch_end(&mut self) {
        self.launch_end.get_or_insert_with(boottime);
    }

    /// A frame went to the display. The first frame uses a synchronous
    /// modeset, so it is on screen when submit returns.
    pub fn submitted(&mut self, first: bool) {
        let now = boottime();
        if first && self.present.is_none() {
            self.commit = Some(now);
            self.present = Some(now);
        } else {
            self.changed = true;
        }
    }

    /// A flip completed at `at` (`CLOCK_MONOTONIC`). If nothing is outstanding
    /// and the data module is active, TTI is this flip's time.
    pub fn flipped(&mut self, at: Duration, outstanding: &[String]) {
        self.changed = false;
        if self.outcome.is_none() && outstanding.is_empty() && self.activated.is_some() {
            self.interactive = Some(monotonic_to_boottime(at));
            self.outcome = Some("settled");
        }
    }

    /// The data module is active.
    pub fn activated(&mut self) {
        self.activated.get_or_insert_with(boottime);
    }

    /// The end of a loop turn, with the outstanding work. TTI settles here when
    /// nothing is outstanding and no submitted frame awaits its flip.
    pub fn turn(&mut self, outstanding: &[String]) {
        let (None, Some(present)) = (self.outcome, self.present) else {
            return;
        };
        let line = outstanding.join(", ");
        if self.trace.len() < 32
            && self
                .trace
                .last()
                .is_none_or(|l| !l.ends_with(&format!("[{line}]")))
        {
            let at = self.process.map_or(0.0, |p| (boottime() - p) * 1000.0);
            self.trace.push(format!("{at:.1} [{line}]"));
        }
        if outstanding.is_empty() && self.activated.is_some() && !self.changed {
            self.interactive = Some(boottime().max(present));
            self.outcome = Some("settled");
        }
    }

    /// Whether TTI is decided.
    pub fn done(&self) -> bool {
        self.outcome.is_some()
    }

    /// True once, the first time this is asked after TTI was decided.
    pub fn take_done(&mut self) -> bool {
        let fresh = self.outcome.is_some() && !self.reported;
        self.reported |= fresh;
        fresh
    }

    /// The journal's `startup` fields, shaped like ExactKit's `report()`.
    /// Metrics are in seconds: cold launch from process start, TTR and TTI from
    /// launch end. A Linux launch is always cold. Marks are ms from process start.
    pub fn report(&self) -> serde_json::Map<String, serde_json::Value> {
        use serde_json::{json, Map, Value};
        let mut metrics = Map::new();
        let mut metric = |name: &str, a: Option<f64>, b: Option<f64>| {
            if let Some((a, b)) = a.zip(b) {
                metrics.insert(name.into(), json!(a - b));
            }
        };
        metric("coldLaunchTime", self.launch_end, self.process);
        metric("timeToFirstRender", self.present, self.launch_end);
        metric("timeToInteractive", self.interactive, self.launch_end);
        let mut marks = Map::new();
        if let Some(p) = self.process {
            for (name, at) in [
                ("process", self.process),
                // Linux has one launch-end mark. It fills both Apple mark names.
                ("didFinishLaunching", self.launch_end),
                ("boot", self.launch_end),
                ("commit", self.commit),
                ("present", self.present),
                ("activated", self.activated),
                ("interactive", self.interactive),
            ] {
                if let Some(at) = at {
                    marks.insert(name.into(), json!(((at - p) * 10_000.0).round() / 10.0));
                }
            }
        }
        let mut out = Map::new();
        out.insert("metrics".into(), Value::Object(metrics));
        out.insert("marks".into(), Value::Object(marks));
        out.insert("launchType".into(), "cold".into());
        out.insert("bootPath".into(), "display".into());
        out.insert("tti".into(), self.outcome.unwrap_or("pending").into());
        out.insert("trace".into(), json!(self.trace));
        out.insert("processResolutionMs".into(), json!(self.resolution_ms));
        out
    }

    /// A one-line summary for stderr, in ms.
    pub fn line(&self) -> String {
        let ms = |a: Option<f64>, b: Option<f64>| {
            a.zip(b)
                .map(|(a, b)| format!("{:.1}", (a - b) * 1000.0))
                .unwrap_or("?".into())
        };
        format!(
            "{} launchTime {} ms; timeToFirstRender {} ms; timeToInteractive {} ms; process resolution {:.0} ms; ledger {}",
            self.outcome.unwrap_or("pending"),
            ms(self.launch_end, self.process),
            ms(self.present, self.launch_end),
            ms(self.interactive, self.launch_end),
            self.resolution_ms,
            self.trace.join(" → ")
        )
    }
}
