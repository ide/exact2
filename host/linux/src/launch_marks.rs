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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    ] {
        out.extend(list.iter().map(|n| format!("{key}:{n}")));
    }
    out
}

/// What TTI reads at one moment: the outstanding work, and the tree it was read against.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Ledger {
    /// Outstanding work as `kind:name` items: the runner's, then `activation`
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
    /// The launch screen was still on top at TTI, with nothing navigated to.
    launch_screen: bool,
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
            launch_screen: false,
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

    /// The startup report, with the route on top at TTI and whether it is the launch screen.
    pub fn report(&self) -> serde_json::Map<String, serde_json::Value> {
        let mut r = self.launch.report(self.route.as_ref());
        if self.launch_screen {
            r.insert("launchScreen".into(), true.into());
        }
        r
    }

    /// Once startup reaches TTI: the route on top then, whether it is the launch screen,
    /// and its screen is interactive.
    fn interactive_route(&mut self) {
        if self.route.is_none() && self.launch.interactive.is_some() {
            self.route = self.navigation.current().cloned();
            self.launch_screen = self.navigation.on_launch_screen();
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
    /// The resources failed at the last ledger read.
    failed: Vec<String>,
    /// How many metrics the startup reports journaled so far carried.
    journaled: usize,
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
        LAUNCH_ENDED.store(true, Ordering::Relaxed);
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

    /// Keeps what TTI's reason reads from a ledger, as the Apple host does: the
    /// failed resources.
    fn read(&mut self, now: &Ledger) {
        if self.failed != now.failed {
            self.failed.clone_from(&now.failed);
        }
    }

    /// TTI at `at`, never before the first render: `failed` when a resource
    /// failed, else `settled`.
    fn interactive(&mut self, at: f64) {
        self.interactive = Some(self.present.map_or(at, |p| at.max(p)));
        self.outcome = Some(if self.failed.is_empty() {
            "settled"
        } else {
            "failed"
        });
    }

    /// The process is ending (SIGTERM, SIGINT): an unfinished startup ends as
    /// `terminated`, with no TTI, as the Apple host's does at `willTerminate`.
    pub fn terminated(&mut self) {
        if self.outcome.is_none() {
            self.outcome = Some("terminated");
        }
    }

    /// Whether TTI is decided.
    pub fn done(&self) -> bool {
        self.outcome.is_some()
    }

    /// True when the startup report has a metric it lacked when last journaled: it is
    /// journaled each time it gains one (launch time, TTR, TTI), as Observe records each
    /// at its own mark, and the services store each metric once.
    pub fn take_grown(&mut self) -> bool {
        let measured = [
            self.process.and(self.launch_end),
            self.launch_end.and(self.present),
            self.launch_end.and(self.interactive),
        ]
        .iter()
        .flatten()
        .count();
        let grown = measured > self.journaled;
        self.journaled = self.journaled.max(measured);
        grown
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
        out.insert("launchType".into(), "cold".into());
        out.insert("bootPath".into(), "display".into());
        if let Some(outcome) = self.outcome {
            out.insert("tti".into(), outcome.into());
        }
        out.insert("trace".into(), json!(self.trace));
        if !self.failed.is_empty() {
            out.insert("failed".into(), json!(self.failed));
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

/// Launch end was marked ([`LaunchMarks::launch_end`]), which a panic hook reads.
static LAUNCH_ENDED: AtomicBool = AtomicBool::new(false);

/// Whether launch end was marked: from then on, this launch is the previous one for the next.
pub fn launch_ended() -> bool {
    LAUNCH_ENDED.load(Ordering::Relaxed)
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
pub(crate) mod tests {
    use super::*;

    /// The startup report goes each time it gains a metric: launch time at launch end,
    /// TTR at the first frame, TTI when reached, each at its own end mark, and a TTI
    /// long after launch still reports.
    #[test]
    fn the_startup_report_goes_each_time_it_gains_a_metric() {
        let now = boottime();
        let mut m = LaunchMarks {
            process: Some(now - 40.0),
            launch_end: Some(now - 39.0),
            ..Default::default()
        };
        assert!(m.take_grown() && !m.take_grown(), "launch time, once");
        let launched = m.report(None);
        assert!(launched["metrics"]["coldLaunchTime"].is_number());
        assert!(launched["metrics"]["timeToFirstRender"].is_null());
        assert!(launched.get("tti").is_none(), "startup goes on");

        m.presented(now - 38.9);
        let loading = Ledger {
            items: vec!["requests:feed".into()],
            ..Default::default()
        };
        m.turn(&loading, true, now);
        assert!(
            m.take_grown() && !m.take_grown(),
            "TTR, while loading continues"
        );
        let shown = m.report(None);
        assert!(shown["metrics"]["timeToFirstRender"].is_number());
        assert!(shown["metrics"]["timeToInteractive"].is_null());
        let walls = shown["walls"].as_object().unwrap();
        let wall = |k: &str| walls[k].as_f64().unwrap();
        assert!(
            (wall("timeToFirstRender") - wall("coldLaunchTime") - 0.1).abs() < 1e-6,
            "each at its own mark"
        );

        m.turn(&Ledger::default(), true, now);
        assert!(
            m.take_grown() && !m.take_grown(),
            "TTI, 39 s after launch end"
        );
        let interactive = m.report(None);
        assert_eq!(interactive["tti"], "settled");
        assert!(
            interactive["metrics"]["timeToInteractive"]
                .as_f64()
                .unwrap()
                >= 39.0
        );
        m.terminated();
        assert!(!m.take_grown());
    }

    /// A poisoned runner or a failed activation ends startup without TTI, as the
    /// process's end does: what was measured before stays, and nothing more goes.
    #[test]
    fn a_failed_or_ended_launch_reports_no_tti() {
        let failures = [
            Ledger {
                poisoned: true,
                ..Ledger::default()
            },
            Ledger {
                items: vec!["activation".into()],
                activation_failed: true,
                ..Ledger::default()
            },
        ];
        for (failure, outcome) in failures.into_iter().map(Some).chain([None]).zip([
            "logic_failed",
            "activation_failed",
            "terminated",
        ]) {
            let now = boottime();
            let mut m = LaunchMarks {
                process: Some(now - 1.0),
                launch_end: Some(now - 0.9),
                commit: Some(now - 0.8),
                present: Some(now - 0.8),
                ..Default::default()
            };
            assert!(m.take_grown(), "launch time and TTR");
            match &failure {
                Some(failure) => {
                    m.shown(now, &Ledger::default(), failure);
                    assert!(!m.done(), "a failed app does not settle");
                    m.turn(failure, true, boottime());
                }
                None => m.terminated(),
            }
            assert!(m.done());
            assert!(!m.take_grown(), "{outcome}: nothing more");
            let report = m.report(None);
            assert_eq!(report["tti"], outcome);
            assert!(report["metrics"]["timeToInteractive"].is_null());
            m.turn(&Ledger::default(), true, boottime());
            assert!(!m.take_grown(), "{outcome}: no TTI after it");
        }
    }

    /// TTI's reason: `failed` when a resource failed, else `settled`.
    #[test]
    fn tti_says_how_it_was_reached() {
        for (failed, outcome) in [(None, "settled"), (Some("feed"), "failed")] {
            let now = boottime();
            let mut m = LaunchMarks {
                present: Some(now - 0.5),
                ..Default::default()
            };
            let loading = Ledger {
                items: vec!["requests:feed".into()],
                ..Ledger::default()
            };
            m.turn(&loading, true, boottime());
            let clear = Ledger {
                failed: failed.into_iter().map(String::from).collect(),
                ..Ledger::default()
            };
            m.shown(now, &clear, &clear);
            let report = m.report(None);
            assert_eq!(report["tti"], outcome, "{failed:?}");
            assert_eq!(report.get("failed").is_some(), failed.is_some());
        }
    }

    /// An app whose screen loads `item` (0 until it answers).
    const LOADING: &str = r#"component App
  resource item = item() as shape number else fallback()
  view
    text `${item}` testId="screen"
"#;

    /// Answers `fallback` now with 0 and every other source later with 1, once
    /// the test sends the reply the executor hands over ([`land`]): a request
    /// that holds TTI until the test lets it land.
    pub(crate) struct Held(pub(crate) std::sync::mpsc::Sender<exact_runner::Reply>);

    impl DataSource for Held {
        fn query(
            &mut self,
            source: &str,
            _: &[exact_runner::Value],
        ) -> Result<exact_runner::Value, exact_runner::DataError> {
            Err(exact_runner::DataError::UnknownSource(source.into()))
        }
        fn answer(
            &mut self,
            _: &mut exact_runner::Store,
            source: &str,
            _: &[exact_runner::Value],
        ) -> Result<exact_runner::Answer, exact_runner::DataError> {
            Ok(match source {
                "fallback" => exact_runner::Answer::Now(exact_runner::Value::Number(0.0)),
                _ => exact_runner::Answer::Later(exact_runner::Request::continuation(1)),
            })
        }
        fn dispatch(&mut self, _: u64, _: &exact_runner::Store) -> exact_runner::Dispatch {
            let replies = self.0.clone();
            exact_runner::Dispatch::Run(exact_runner::Work::Later(Box::new(move |reply| {
                let _ = replies.send(reply);
            })))
        }
        fn parse(
            &mut self,
            _: &mut exact_runner::Store,
            _: &str,
            _: &[exact_runner::Value],
            _: exact_runner::Outcome,
        ) -> Result<exact_runner::Answer, exact_runner::DataError> {
            Ok(exact_runner::Answer::Now(exact_runner::Value::Number(1.0)))
        }
    }

    /// An app booted on a [`Held`] source, and the replies its executor hands over.
    pub(crate) fn boot(
        source: &str,
    ) -> (
        crate::Presenter<Held>,
        std::sync::mpsc::Receiver<exact_runner::Reply>,
    ) {
        let (replies, handed) = std::sync::mpsc::channel();
        let (p, error) = crate::Presenter::boot_with(
            &crate::test_plan(source),
            Held(replies),
            (400., 800.),
            1.,
            std::path::PathBuf::new(),
            crate::presenter::PainterChoice::Cpu,
        )
        .unwrap();
        assert!(error.is_none(), "{error:?}");
        (p, handed)
    }

    /// Lands the request a [`Held`] source holds: waits for the executor to hand
    /// over its reply, sends it, and pumps the answer into the runner.
    pub(crate) fn land(
        p: &mut crate::Presenter<Held>,
        handed: &std::sync::mpsc::Receiver<exact_runner::Reply>,
    ) {
        let reply = handed
            .recv_timeout(Duration::from_secs(20))
            .expect("the executor hands over the request");
        reply.send(exact_runner::Outcome::Storage(b"1".to_vec()));
        assert_eq!(p.pump(0.0), None);
        assert!(ledger(p).clear(), "landed: {:?}", ledger(p).items);
    }

    /// TTI is the presentation of the first frame built with nothing
    /// outstanding: not the flip of a frame built while loading, though the work
    /// cleared before it, and not a turn whose change is not yet on screen.
    #[test]
    fn startup_settles_on_the_frame_that_shows_it() {
        let (mut p, handed) = boot(LOADING);
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
        assert_eq!(ledger(&p).items, ["requests:item"]);
        assert!(!m.launch.done());

        m.frame(&mut p);
        let loading = p.display_frame().unwrap();
        land(&mut p, &handed);
        m.turn(&mut p, true);
        assert!(!m.launch.done(), "a frame awaits its flip");
        m.shown(t + 0.016, &p);
        p.display_complete(&loading);
        assert!(!m.launch.done(), "that frame was built while loading");
        m.turn(&mut p, false);
        assert!(!m.launch.done(), "the change is not on screen yet");

        m.frame(&mut p);
        let settled = p.display_frame().unwrap();
        m.shown(t + 0.033, &p);
        p.display_complete(&settled);
        assert_eq!(m.launch.interactive, Some(t + 0.033));
        assert_eq!(m.launch.outcome, Some("settled"));
    }

    /// A frame whose paint failed shows a fallback, not the tree: the screen that
    /// settled in it is not interactive until a paint of it succeeds.
    #[test]
    fn a_failed_paint_of_the_settled_screen_is_not_interactive() {
        let (mut p, handed) = boot(LOADING);
        let mut m = Marks::new();
        m.launch.launch_end();
        let t = boottime();
        m.frame(&mut p);
        let first = p.display_frame().unwrap();
        m.shown(t, &p);
        p.display_complete(&first);
        m.turn(&mut p, false);

        land(&mut p, &handed);
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
        let (mut p, _handed) = boot(LOADING);
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
        let report = m.report();
        assert_eq!(report["tti"], "terminated");
        assert!(report["metrics"]["timeToFirstRender"].is_null());

        // It came after the first frame and before the frame that settles.
        let (mut p, handed) = boot(LOADING);
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
        land(&mut p, &handed);
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
        assert!(m.launch.take_grown(), "the TTR before the signal");
        let report = m.report();
        assert_eq!(report["tti"], "terminated");
        assert!(report["metrics"]["timeToFirstRender"].is_number());
        assert!(report["metrics"]["timeToInteractive"].is_null());
    }
}
