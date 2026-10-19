//! Startup timestamps for the display path (a headless run reports none).
//!
//! All marks are seconds on `CLOCK_BOOTTIME`, the clock `/proc/self/stat`
//! counts the process start in (ticks of 1/`CLK_TCK`, usually 10 ms).
//! A suspend during startup therefore counts toward the numbers.
//! DRM flip timestamps are `CLOCK_MONOTONIC` and are converted on read.
//!
//! Time to interactive (TTI) is the presentation of the first frame built
//! with nothing outstanding and no change after it: each frame carries the
//! [`Ledger`] it was built from, and its presentation settles TTI when that
//! ledger was clear and the tree has not changed since. When work clears
//! without a change to the screen (a timer that changes nothing, activation
//! with nothing to commit), TTI is the loop turn that sees it, once the
//! screen shows the latest tree.

use exact_runner::DataSource;
use std::sync::atomic::{AtomicU64, Ordering};
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

/// When the process was told to end (SIGTERM, SIGINT): the `f64` bits of its
/// [`boottime`], 0 until then.
static ENDING: AtomicU64 = AtomicU64::new(0);

/// Notes that the process is told to end now; a later call keeps the first
/// time. Async-signal-safe: `clock_gettime` and an atomic exchange.
pub fn told_to_end() {
    let _ = ENDING.compare_exchange(
        0,
        boottime().to_bits(),
        Ordering::Relaxed,
        Ordering::Relaxed,
    );
}

/// When the process was told to end, if it was.
pub fn ending() -> Option<f64> {
    Some(ENDING.load(Ordering::Relaxed))
        .filter(|&bits| bits != 0)
        .map(f64::from_bits)
}

/// Converts a `CLOCK_MONOTONIC` instant, such as a DRM flip's, to BOOTTIME seconds.
pub fn monotonic_to_boottime(t: Duration) -> f64 {
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
    out
}

/// What TTI reads at one moment: the outstanding work, and the tree it was read against.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Ledger {
    /// Outstanding work as `kind:name` items: the runner's, then the host's
    /// (`host:images` while a picture in view is loading), then `activation`
    /// while the data module is not active.
    pub items: Vec<String>,
    /// Resources whose current arguments failed: settled, but in error.
    pub failed: Vec<String>,
    /// A refused commit poisoned the runner: every action now fails.
    pub poisoned: bool,
    /// The data module failed to activate.
    pub activation_failed: bool,
    /// The host generation, the kernel incarnation and the kernel epoch: a
    /// frame built at one shows every commit up to it.
    pub tree: [u64; 3],
}

impl Ledger {
    /// Nothing is outstanding, and the app can still answer.
    pub fn clear(&self) -> bool {
        self.items.is_empty() && !self.poisoned && !self.activation_failed
    }

    /// Whether a frame built from this ledger shows a settled screen when it is
    /// presented, `now` being the ledger then: nothing was outstanding when it was
    /// built, and nothing has changed or started since.
    pub fn settles(&self, now: &Ledger) -> bool {
        self.clear() && now.clear() && self.tree == now.tree
    }
}

/// The presenter's ledger.
pub fn ledger<D: DataSource>(p: &crate::Presenter<D>) -> Ledger {
    let host = p.host();
    let o = host.runner().outstanding();
    let mut items = items(&o);
    if p.images().loading_on_screen() > 0 {
        items.push("host:images".into());
    }
    if !o.data_ready || host.data_pending() {
        items.push("activation".into());
    }
    let kernel = host.kernel();
    Ledger {
        items,
        failed: o.failed,
        poisoned: o.poisoned,
        activation_failed: p.activation_failed(),
        tree: [p.hosts, kernel.incarnation(), kernel.epoch()],
    }
}

/// The display loop's marks, startup's and navigation's, and the ledger of the
/// frame awaiting its flip.
pub struct Marks {
    /// The startup marks.
    pub launch: LaunchMarks,
    /// The navigation marks.
    pub navigation: crate::navigation_marks::NavigationMarks,
    /// What the frame last built was built from, while a mark waits for it.
    built: Option<Ledger>,
    /// The route on top when TTI was reached. The report goes out a turn later,
    /// after the router changes that turn takes.
    route: Option<serde_json::Map<String, serde_json::Value>>,
    /// When the process was told to end, if it was ([`ending`]; tests replace it).
    pub(crate) ending: fn() -> Option<f64>,
}

impl Marks {
    /// Reads the process start from the kernel.
    pub fn new() -> Self {
        Marks {
            launch: LaunchMarks::new(),
            navigation: Default::default(),
            built: None,
            route: None,
            ending,
        }
    }

    /// The process was told to end at or before `at`: nothing that happens
    /// then is measured.
    fn ended_by(&self, at: f64) -> bool {
        (self.ending)().is_some_and(|end| end <= at)
    }

    fn waiting(&self) -> bool {
        !self.launch.done() || self.navigation.waiting()
    }

    /// The presenter is about to build a frame for the display: it shows every
    /// change so far.
    pub fn frame<D: DataSource>(&mut self, p: &mut crate::Presenter<D>) {
        self.routes(p);
        self.navigation.submitted();
        self.built = self.waiting().then(|| ledger(p));
    }

    /// The frame last built went on screen at `at`: its flip, or the first
    /// frame's synchronous modeset. A frame shown once the process was told to
    /// end is not measured.
    pub fn shown<D: DataSource>(&mut self, at: f64, p: &crate::Presenter<D>) {
        if self.ended_by(at) {
            return;
        }
        self.launch.presented(at);
        self.navigation.presented();
        let Some(built) = self.built.take() else {
            return;
        };
        let now = ledger(p);
        self.launch.shown(at, &built, &now);
        self.interactive_route();
        self.navigation.shown(at, &built, &now);
    }

    /// The end of a loop turn after first pixel. `flip_pending`: a submitted
    /// frame awaits its flip. The screen is still when its last paint succeeded
    /// and is on screen, with nothing to paint. A turn that ends once the process
    /// was told to end measures nothing.
    pub fn turn<D: DataSource>(&mut self, p: &mut crate::Presenter<D>, flip_pending: bool) {
        self.routes(p);
        let at = boottime();
        if !self.waiting() || self.ended_by(at) {
            return;
        }
        let now = ledger(p);
        let still = !p.dirty() && !flip_pending && p.paint_succeeded();
        self.launch.turn(&now, still, at);
        self.interactive_route();
        self.navigation.turn(&now, still, at);
    }

    /// The startup report, with the route on top at TTI.
    pub fn report(&self) -> serde_json::Map<String, serde_json::Value> {
        self.launch.report(self.route.as_ref())
    }

    /// Once startup reaches TTI: the route on top then, and its screen is interactive.
    fn interactive_route(&mut self) {
        if self.route.is_none() && self.launch.interactive.is_some() {
            self.route = self.navigation.current().cloned();
            self.navigation.startup_interactive();
        }
    }

    /// Hands the navigation marks the router changes committed since the last call.
    fn routes<D: DataSource>(&mut self, p: &mut crate::Presenter<D>) {
        for (change, at, input) in p.host_mut().routes.take() {
            self.navigation.changed(&change, at, input);
        }
    }
}

impl Default for Marks {
    fn default() -> Self {
        Self::new()
    }
}

/// Seconds after launch end at which the startup report goes out without TTI;
/// a TTI reached later is reported on its own (`startup.tti`).
pub const TTI_TIMEOUT: f64 = 30.0;

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
    trace: Vec<String>,
    /// The outstanding items the last ledger read showed.
    last: Vec<String>,
    /// Work cleared after only the app's `aria-busy` elements were outstanding.
    declared: bool,
    /// The resources failed at the last ledger read.
    failed: Vec<String>,
    reported: bool,
    /// The timeout passed first: the startup report went out without TTI.
    late: bool,
    /// The timeout's report carried TTR: its first frame came before.
    ttr_reported: bool,
    /// The process was told to end before TTI.
    terminated: Option<f64>,
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

    /// A frame went on screen at `at`. The first is the first render: its
    /// synchronous modeset shows it when submit returns.
    pub fn presented(&mut self, at: f64) {
        if self.present.is_none() {
            self.commit = Some(at);
            self.present = Some(at);
        }
    }

    /// A frame built from `built` went on screen at `at`, `now` being the
    /// ledger then. TTI is this presentation when the frame settles.
    pub fn shown(&mut self, at: f64, built: &Ledger, now: &Ledger) {
        if self.outcome.is_some() {
            return;
        }
        self.read(now);
        if built.settles(now) {
            self.interactive(at);
        }
    }

    /// The end of a loop turn after first pixel at `at`, with the ledger then.
    /// `still`: the screen shows the latest tree and no frame awaits its flip,
    /// so TTI is `at` once nothing is outstanding. A poisoned runner or a
    /// failed activation ends startup without TTI, as on the Apple host.
    pub fn turn(&mut self, now: &Ledger, still: bool, at: f64) {
        let (None, Some(_)) = (self.outcome, self.present) else {
            return;
        };
        let line = now.items.join(", ");
        if self.trace.len() < 32
            && self
                .trace
                .last()
                .is_none_or(|l| !l.ends_with(&format!("[{line}]")))
        {
            let ms = self.process.map_or(0.0, |p| (at - p) * 1000.0);
            self.trace.push(format!("{ms:.1} [{line}]"));
        }
        self.read(now);
        if now.poisoned {
            self.outcome = Some("logic_failed");
            return;
        }
        if now.activation_failed {
            self.outcome = Some("activation_failed");
            return;
        }
        if !now.items.iter().any(|i| i == "activation") {
            self.activated.get_or_insert(at);
        }
        if still && now.clear() {
            self.interactive(at);
        }
    }

    /// Keeps what TTI's reason reads from a ledger, as the Apple host does: whether
    /// work cleared after only `aria-busy` was outstanding, and the failed resources.
    fn read(&mut self, now: &Ledger) {
        if now.items.is_empty()
            && !self.last.is_empty()
            && self.last.iter().all(|i| i.starts_with("busy:"))
        {
            self.declared = true;
        }
        if self.last != now.items {
            self.last.clone_from(&now.items);
        }
        if self.failed != now.failed {
            self.failed.clone_from(&now.failed);
        }
    }

    /// TTI at `at`, never before the first render: `failed` when a resource
    /// failed, `declared` when the app's `aria-busy` was the last work, else `settled`.
    fn interactive(&mut self, at: f64) {
        self.interactive = Some(self.present.map_or(at, |p| at.max(p)));
        self.outcome = Some(if !self.failed.is_empty() {
            "failed"
        } else if self.declared {
            "declared"
        } else {
            "settled"
        });
    }

    /// The process is ending (SIGTERM, SIGINT): an unfinished startup ends as
    /// `terminated`, keeping its launch time and TTR, with no TTI, as the Apple
    /// host's does at `willTerminate`.
    pub fn terminated(&mut self) {
        if self.outcome.is_none() {
            self.terminated = Some(boottime());
            self.outcome = Some("terminated");
        }
    }

    /// Publishes the marks [`standing`] reads: the display loop's, after each mark.
    pub fn publish(&self) {
        for (slot, mark) in PUBLISHED
            .iter()
            .zip([self.process, self.launch_end, self.present])
        {
            slot.store(mark.map_or(0, f64::to_bits), Ordering::Relaxed);
        }
    }

    /// Whether TTI is decided.
    pub fn done(&self) -> bool {
        self.outcome.is_some()
    }

    /// True when a startup report is due: once, when TTI is decided, and after
    /// the timeout's report only with a metric that one lacked. A first frame
    /// after the timeout goes at once, as Observe records one on its own, not
    /// with a TTI that may never come; a later TTI goes when reached. A failure
    /// after the timeout reports nothing new.
    pub fn take_done(&mut self) -> bool {
        let frame = self.late && self.present.is_some() && !self.ttr_reported;
        let decided = self.outcome.is_some()
            && !self.reported
            && (!self.late || frame || self.interactive.is_some());
        self.reported |= decided;
        self.ttr_reported |= frame;
        frame || decided
    }

    /// True once, when [`TTI_TIMEOUT`] passes without TTI: the startup report goes now.
    pub fn take_timeout(&mut self) -> bool {
        let due = self.outcome.is_none()
            && !self.late
            && self
                .launch_end
                .is_some_and(|l| boottime() - l >= TTI_TIMEOUT);
        self.late |= due;
        self.ttr_reported |= due && self.present.is_some();
        due
    }

    /// Milliseconds until [`TTI_TIMEOUT`], while it is still ahead.
    pub fn timeout_in_ms(&self) -> Option<i32> {
        let l = self
            .launch_end
            .filter(|_| self.outcome.is_none() && !self.late)?;
        Some((((l + TTI_TIMEOUT - boottime()) * 1000.0).ceil().max(0.0)) as i32)
    }

    /// The journal kind of the report [`take_done`](Self::take_done) announced:
    /// `startup.tti` after the timeout reported first.
    pub fn done_kind(&self) -> &'static str {
        if self.late {
            "startup.tti"
        } else {
            "startup"
        }
    }

    /// The journal's `startup` fields, shaped like ExactKit's `report()`.
    /// Metrics are in seconds: cold launch from process start, TTR and TTI from
    /// launch end. A Linux launch is always cold. Marks are ms from process start.
    /// Once TTI is reached, `route` is the route on top (`route`, `url`, `routeParams`).
    pub fn report(
        &self,
        route: Option<&serde_json::Map<String, serde_json::Value>>,
    ) -> serde_json::Map<String, serde_json::Value> {
        use serde_json::{json, Map, Value};
        let (metrics, walls) = metrics_and_walls(
            self.process,
            self.launch_end,
            self.present,
            self.interactive,
        );
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
        out.insert("walls".into(), Value::Object(walls));
        out.insert("marks".into(), Value::Object(marks));
        if self.late && self.interactive.is_some() {
            out.insert("late".into(), true.into());
        }
        out.insert("launchType".into(), "cold".into());
        out.insert("bootPath".into(), "display".into());
        out.insert(
            "tti".into(),
            self.outcome
                .unwrap_or(if self.late { "timeout" } else { "pending" })
                .into(),
        );
        out.insert("trace".into(), json!(self.trace));
        if !self.failed.is_empty() {
            out.insert("failed".into(), json!(self.failed));
        }
        if let Some(t) = self.terminated {
            out.insert("interrupted".into(), true.into());
            if let Some(p) = self.process {
                out.insert(
                    "interruptedAt".into(),
                    json!(((t - p) * 10_000.0).round() / 10.0),
                );
            }
        }
        out.insert("processResolutionMs".into(), json!(self.resolution_ms));
        // The screen that became interactive, as Observe names the screen whose marker fired.
        if let (Some(route), Some(_)) = (route, self.interactive) {
            out.insert("route".into(), Value::Object(route.clone()));
        }
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

/// The marks [`standing`] reads, as the display loop last published them
/// ([`LaunchMarks::publish`]): the process start, launch end and the first
/// frame's presentation, each the `f64` bits of its [`boottime`], 0 for none.
static PUBLISHED: [AtomicU64; 3] = [const { AtomicU64::new(0) }; 3];

/// The startup report's `metrics` and `walls` as they stand, from the published
/// marks: the launch time once launch ended, and TTR once its frame was presented,
/// never TTI. A panic hook reads it, so a crash before the report keeps what was
/// measured. `None` while there is no metric.
pub fn standing() -> Option<serde_json::Map<String, serde_json::Value>> {
    let [process, launch_end, present] = PUBLISHED.each_ref().map(|slot| {
        Some(slot.load(Ordering::Relaxed))
            .filter(|&bits| bits != 0)
            .map(f64::from_bits)
    });
    let (metrics, walls) = metrics_and_walls(process, launch_end, present, None);
    (!metrics.is_empty()).then(|| {
        let mut out = serde_json::Map::new();
        out.insert("metrics".into(), metrics.into());
        out.insert("walls".into(), walls.into());
        out
    })
}

/// Whether the display loop published launch end. Once it has, it stays published, so
/// this is true after [`standing`] returned a metric.
pub fn launch_ended() -> bool {
    PUBLISHED[1].load(Ordering::Relaxed) != 0
}

/// The report's `metrics`, in seconds (launch time from process start, TTR and TTI
/// from launch end), and `walls`: each one's time in seconds since 1970, when its
/// end mark happened.
fn metrics_and_walls(
    process: Option<f64>,
    launch_end: Option<f64>,
    present: Option<f64>,
    interactive: Option<f64>,
) -> (
    serde_json::Map<String, serde_json::Value>,
    serde_json::Map<String, serde_json::Value>,
) {
    let offset = crate::journal::wall() - boottime();
    let mut metrics = serde_json::Map::new();
    let mut walls = serde_json::Map::new();
    for (name, end, start) in [
        ("coldLaunchTime", launch_end, process),
        ("timeToFirstRender", present, launch_end),
        ("timeToInteractive", interactive, launch_end),
    ] {
        if let Some((end, start)) = end.zip(start) {
            metrics.insert(name.into(), serde_json::json!(end - start));
            walls.insert(name.into(), serde_json::json!(end + offset));
        }
    }
    (metrics, walls)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A launch that stays loading past [`TTI_TIMEOUT`] reports what it has then,
    /// and its TTI later on its own, each metric at its own end mark.
    #[test]
    fn a_late_tti_is_reported_after_the_timeout_report() {
        let now = boottime();
        let mut m = LaunchMarks {
            process: Some(now - 40.0),
            launch_end: Some(now - 39.0),
            commit: Some(now - 38.9),
            present: Some(now - 38.9),
            ..Default::default()
        };
        assert!(m.timeout_in_ms().is_some_and(|ms| ms == 0), "already due");
        assert!(m.take_timeout(), "due once");
        assert!(!m.take_timeout(), "and only once");
        assert!(m.timeout_in_ms().is_none());
        let first = m.report(None);
        assert_eq!(first["tti"], "timeout");
        assert!(first["metrics"]["timeToInteractive"].is_null());
        assert!(first["metrics"]["coldLaunchTime"].is_number());
        assert!(first.get("late").is_none(), "no TTI yet");
        let walls = first["walls"].as_object().unwrap();
        let wall = |k: &str| walls[k].as_f64().unwrap();
        assert!(
            (wall("timeToFirstRender") - wall("coldLaunchTime") - 0.1).abs() < 1e-6,
            "each at its own mark"
        );

        m.turn(&Ledger::default(), true, boottime());
        assert!(m.take_done());
        assert_eq!(m.done_kind(), "startup.tti");
        let late = m.report(None);
        assert_eq!(late["tti"], "settled");
        assert_eq!(late["late"], true);
        assert!(late["metrics"]["timeToInteractive"].as_f64().unwrap() >= 39.0);
    }

    /// A first frame after the timeout: the timeout's report has no TTR. The TTR
    /// goes once, at once while loading continues, then the TTI on its own; or
    /// with the TTI or the end that comes in the same turn.
    #[test]
    fn a_first_frame_after_the_timeout_reports_its_ttr_late() {
        let now = boottime();
        let launch = || LaunchMarks {
            process: Some(now - 40.0),
            launch_end: Some(now - 39.0),
            ..Default::default()
        };
        let mut m = launch();
        assert!(m.take_timeout());
        assert!(m.report(None)["metrics"]["timeToFirstRender"].is_null());
        m.presented(now - 1.0);
        m.turn(&Ledger::default(), true, now);
        assert!(m.take_done() && !m.take_done(), "once");
        assert_eq!(m.done_kind(), "startup.tti");
        let late = m.report(None);
        assert!(late["metrics"]["timeToFirstRender"].is_number());
        assert!(late["metrics"]["timeToInteractive"].is_number());

        let mut ended = launch();
        assert!(ended.take_timeout());
        ended.presented(now - 1.0);
        ended.terminated();
        assert!(ended.take_done(), "the TTR the timeout's report lacked");
        let late = ended.report(None);
        assert_eq!(late["tti"], "terminated");
        assert!(late["metrics"]["timeToFirstRender"].is_number());
        assert!(late["metrics"]["timeToInteractive"].is_null());

        let mut loading = launch();
        assert!(loading.take_timeout());
        loading.presented(now - 1.0);
        let busy = Ledger {
            items: vec!["busy:list".into()],
            ..Default::default()
        };
        loading.turn(&busy, true, now);
        assert!(
            loading.take_done() && !loading.take_done(),
            "the TTR at once, while loading continues"
        );
        let ttr = loading.report(None);
        assert!(ttr["metrics"]["timeToFirstRender"].is_number());
        assert!(ttr["metrics"]["timeToInteractive"].is_null());
        loading.turn(&Ledger::default(), true, now);
        assert!(loading.take_done() && !loading.take_done(), "then the TTI");
        assert!(loading.report(None)["metrics"]["timeToInteractive"].is_number());
    }

    /// TTI before the timeout is the ordinary startup report.
    #[test]
    fn a_timely_tti_needs_no_timeout() {
        let now = boottime();
        let mut m = LaunchMarks {
            process: Some(now - 1.0),
            launch_end: Some(now - 0.9),
            commit: Some(now - 0.8),
            present: Some(now - 0.8),
            ..Default::default()
        };
        m.turn(&Ledger::default(), true, boottime());
        assert!(!m.take_timeout());
        assert!(m.take_done());
        assert_eq!(m.done_kind(), "startup");
        assert!(m.report(None).get("late").is_none());
    }

    /// A poisoned runner or a failed activation ends startup without TTI; after
    /// the timeout's report, it reports nothing more.
    #[test]
    fn a_failed_launch_reports_no_tti() {
        for (failure, outcome) in [
            (
                Ledger {
                    poisoned: true,
                    ..Ledger::default()
                },
                "logic_failed",
            ),
            (
                Ledger {
                    items: vec!["activation".into()],
                    activation_failed: true,
                    ..Ledger::default()
                },
                "activation_failed",
            ),
        ] {
            let now = boottime();
            let mut m = LaunchMarks {
                process: Some(now - 1.0),
                launch_end: Some(now - 0.9),
                commit: Some(now - 0.8),
                present: Some(now - 0.8),
                ..Default::default()
            };
            m.shown(now, &Ledger::default(), &failure);
            assert!(!m.done(), "a failed app does not settle");
            m.turn(&failure, true, boottime());
            assert!(m.take_done() && !m.take_done(), "reported once");
            assert_eq!(m.done_kind(), "startup");
            let report = m.report(None);
            assert_eq!(report["tti"], outcome);
            assert!(report["metrics"]["timeToInteractive"].is_null());
            assert!(report["metrics"]["timeToFirstRender"].is_number());

            let mut late = LaunchMarks {
                launch_end: Some(now - 31.0),
                present: Some(now - 30.9),
                ..Default::default()
            };
            assert!(late.take_timeout());
            late.turn(&failure, true, boottime());
            assert!(
                late.done() && !late.take_done(),
                "{outcome} after the timeout"
            );
        }
    }

    /// What a crash keeps of the published marks: the launch time, and TTR once its
    /// frame was presented, each as the report has it, never TTI.
    #[test]
    fn the_standing_report_keeps_launch_time_and_ttr_never_tti() {
        LaunchMarks::default().publish();
        assert!(standing().is_none(), "no metric before launch end");
        let now = boottime();
        let mut m = LaunchMarks {
            process: Some(now - 1.0),
            launch_end: Some(now - 0.9),
            ..Default::default()
        };
        m.publish();
        let launched = standing().unwrap();
        assert!(launched["metrics"]["coldLaunchTime"].is_number());
        assert!(
            launched["metrics"]["timeToFirstRender"].is_null(),
            "no frame yet"
        );
        m.presented(now - 0.8);
        m.turn(&Ledger::default(), true, now);
        assert!(m.done(), "interactive");
        m.publish();
        let shown = standing().unwrap();
        let report = m.report(None);
        let names =
            |o: &serde_json::Value| o.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
        assert_eq!(
            names(&shown["metrics"]),
            ["coldLaunchTime", "timeToFirstRender"]
        );
        assert_eq!(names(&shown["walls"]), names(&shown["metrics"]));
        for name in ["coldLaunchTime", "timeToFirstRender"] {
            assert_eq!(shown["metrics"][name], report["metrics"][name]);
            let wall = |o: &serde_json::Map<_, _>| o["walls"][name].as_f64().unwrap();
            assert!(
                (wall(&shown) - wall(&report)).abs() < 1e-3,
                "at its own mark"
            );
        }
    }

    /// A startup the process ends before TTI reports what it measured, once; one
    /// that reached TTI, or whose timeout report went out, reports nothing more.
    #[test]
    fn a_terminated_startup_keeps_what_it_measured() {
        let now = boottime();
        let launch = || LaunchMarks {
            process: Some(now - 1.0),
            launch_end: Some(now - 0.9),
            commit: Some(now - 0.8),
            present: Some(now - 0.8),
            ..Default::default()
        };
        let mut m = launch();
        m.terminated();
        assert!(m.take_done() && !m.take_done());
        assert_eq!(m.done_kind(), "startup");
        let report = m.report(None);
        assert_eq!(report["tti"], "terminated");
        assert_eq!(report["interrupted"], true);
        assert!(report["metrics"]["coldLaunchTime"].is_number());
        assert!(report["metrics"]["timeToFirstRender"].is_number());
        assert!(report["metrics"]["timeToInteractive"].is_null());

        let mut settled = launch();
        settled.turn(&Ledger::default(), true, boottime());
        assert!(settled.take_done());
        settled.terminated();
        assert!(!settled.take_done());
        assert_eq!(settled.report(None)["tti"], "settled");

        let mut late = LaunchMarks {
            launch_end: Some(now - 31.0),
            present: Some(now - 30.9),
            ..Default::default()
        };
        assert!(late.take_timeout());
        late.terminated();
        assert!(!late.take_done(), "the timeout's report went out");
    }

    /// TTI's reason: `failed` when a resource failed, `declared` when the app's
    /// `aria-busy` was the last outstanding work, else `settled`.
    #[test]
    fn tti_says_how_it_was_reached() {
        for (outstanding, failed, outcome) in [
            ("requests:feed", None, "settled"),
            ("busy:screen", None, "declared"),
            ("requests:feed", Some("feed"), "failed"),
            ("busy:screen", Some("feed"), "failed"),
        ] {
            let now = boottime();
            let mut m = LaunchMarks {
                present: Some(now - 0.5),
                ..Default::default()
            };
            let loading = Ledger {
                items: vec![outstanding.into(), "busy:list".into()],
                ..Ledger::default()
            };
            m.turn(&loading, true, boottime());
            m.turn(
                &Ledger {
                    items: vec![outstanding.into()],
                    ..Ledger::default()
                },
                false,
                boottime(),
            );
            let clear = Ledger {
                failed: failed.into_iter().map(String::from).collect(),
                ..Ledger::default()
            };
            m.shown(now, &clear, &clear);
            let report = m.report(None);
            assert_eq!(report["tti"], outcome, "{outstanding} {failed:?}");
            assert_eq!(report.get("failed").is_some(), failed.is_some());
        }
    }

    /// An app whose screen is busy until `done` is pressed.
    const BUSY: &str = r#"component App
  state busy = true
  action done
    busy = false
  view
    column aria-busy=(busy) testId="screen"
      button press=done testId="done"
        text "Done"
"#;

    fn boot(source: &str) -> crate::Presenter<()> {
        let (p, error) = crate::Presenter::boot_with(
            &crate::test_plan(source),
            (),
            (400., 800.),
            1.,
            std::path::PathBuf::new(),
            crate::presenter::PainterChoice::Cpu,
        )
        .unwrap();
        assert!(error.is_none(), "{error:?}");
        p
    }

    fn press(p: &mut crate::Presenter<()>, test_id: &str) {
        let kernel = p.host().kernel();
        let key = kernel.find_by_test_id(test_id)[0];
        let id = kernel.node_by_key(key).unwrap().id;
        p.dispatch_press(id, 0., false);
    }

    /// TTI is the presentation of the first frame built with nothing
    /// outstanding: not the flip of a frame built while busy, though the work
    /// cleared before it, and not a turn whose change is not yet on screen.
    #[test]
    fn startup_settles_on_the_frame_that_shows_it() {
        let mut p = boot(BUSY);
        let mut m = Marks::new();
        m.launch.launch_end();
        let t = boottime();
        m.frame(&mut p);
        let first = p.display_frame().unwrap();
        m.shown(t, &p);
        p.display_complete(&first);
        m.turn(&mut p, false);
        assert_eq!(m.launch.present, Some(t), "the modeset is the first render");
        assert!(
            m.launch.activated.is_some(),
            "the first frame activates data"
        );
        assert_eq!(ledger(&p).items, ["busy:screen"]);
        assert!(!m.launch.done());

        m.frame(&mut p);
        let busy = p.display_frame().unwrap();
        press(&mut p, "done");
        m.turn(&mut p, true);
        assert!(!m.launch.done(), "a frame awaits its flip");
        m.shown(t + 0.016, &p);
        p.display_complete(&busy);
        assert!(!m.launch.done(), "that frame was built while busy");
        m.turn(&mut p, false);
        assert!(!m.launch.done(), "the change is not on screen yet");

        m.frame(&mut p);
        let settled = p.display_frame().unwrap();
        m.shown(t + 0.033, &p);
        p.display_complete(&settled);
        assert_eq!(m.launch.interactive, Some(t + 0.033));
        assert_eq!(
            m.launch.outcome,
            Some("declared"),
            "aria-busy was the last work"
        );
    }

    /// A frame whose paint failed shows a fallback, not the tree: the screen that
    /// settled in it is not interactive until a paint of it succeeds.
    #[test]
    fn a_failed_paint_of_the_settled_screen_is_not_interactive() {
        let mut p = boot(BUSY);
        let mut m = Marks::new();
        m.launch.launch_end();
        let t = boottime();
        m.frame(&mut p);
        let first = p.display_frame().unwrap();
        m.shown(t, &p);
        p.display_complete(&first);
        m.turn(&mut p, false);

        press(&mut p, "done");
        p.brush
            .replace_backend(Box::new(crate::presenter::fail_backend::Failure));
        m.frame(&mut p);
        let failed = p.display_frame().unwrap();
        assert!(!p.paint_succeeded() && !p.dirty());
        p.display_complete(&failed);
        m.turn(&mut p, false);
        assert_eq!(m.launch.interactive, None, "the fallback is on screen");

        p.brush
            .replace_backend(Box::new(crate::raster::Raster::new()));
        p.repaint();
        m.frame(&mut p);
        let settled = p.display_frame().unwrap();
        m.shown(t + 0.033, &p);
        p.display_complete(&settled);
        assert_eq!(m.launch.interactive, Some(t + 0.033));
    }

    thread_local! {
        /// When this test's process was told to end.
        static ENDED: std::cell::Cell<Option<f64>> = const { std::cell::Cell::new(None) };
    }

    fn ended() -> Option<f64> {
        ENDED.with(std::cell::Cell::get)
    }

    /// Nothing shown or settled at or after the termination signal's arrival is
    /// measured: a first frame then has no TTR, a settled frame then no TTI, and
    /// startup ends as terminated with what came before.
    #[test]
    fn nothing_after_the_termination_signal_is_measured() {
        // The signal came before the first frame's modeset returned.
        let mut p = boot(BUSY);
        let mut m = Marks {
            ending: ended,
            ..Marks::new()
        };
        m.launch.launch_end();
        let t = boottime();
        ENDED.with(|e| e.set(Some(t)));
        m.frame(&mut p);
        let first = p.display_frame().unwrap();
        m.shown(t, &p);
        p.display_complete(&first);
        m.turn(&mut p, false);
        assert_eq!(
            m.launch.present, None,
            "a frame at the signal is not measured"
        );
        m.launch.terminated();
        assert!(m.launch.take_done());
        let report = m.report();
        assert_eq!(report["tti"], "terminated");
        assert!(report["metrics"]["timeToFirstRender"].is_null());

        // It came after the first frame and before the frame that settles.
        let mut p = boot(BUSY);
        let mut m = Marks {
            ending: ended,
            ..Marks::new()
        };
        ENDED.with(|e| e.set(None));
        m.launch.launch_end();
        let t = boottime();
        m.frame(&mut p);
        let first = p.display_frame().unwrap();
        m.shown(t - 0.1, &p);
        p.display_complete(&first);
        m.turn(&mut p, false);
        press(&mut p, "done");
        ENDED.with(|e| e.set(Some(t)));
        m.frame(&mut p);
        let settled = p.display_frame().unwrap();
        m.shown(t + 0.016, &p);
        p.display_complete(&settled);
        m.turn(&mut p, false);
        assert_eq!(m.launch.present, Some(t - 0.1));
        assert_eq!(
            m.launch.interactive, None,
            "nothing settles after the signal"
        );
        m.launch.terminated();
        assert!(m.launch.take_done());
        let report = m.report();
        assert_eq!(report["tti"], "terminated");
        assert!(report["metrics"]["timeToFirstRender"].is_number());
        assert!(report["metrics"]["timeToInteractive"].is_null());
    }
}
