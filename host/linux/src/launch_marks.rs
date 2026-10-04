//! The Linux launch marks (Exact Observe design §3.1–3.5), for the display
//! path (a headless run renders no frame and reports none).
//!
//! Every startup mark is on `CLOCK_BOOTTIME`: the process start the kernel
//! keeps in `/proc/self/stat` counts ticks of it (1/`CLK_TCK`, usually 10 ms,
//! carried as the resolution), and a suspend in the middle is then inside the
//! numbers rather than silently subtracted. A flip's timestamp comes from the
//! kernel on `CLOCK_MONOTONIC` and is moved onto BOOTTIME with the offset
//! sampled when it is read.
//!
//! - launch end: `boot_presenter` begins — the display open, Exact about to
//!   produce its first tree.
//! - first pixel: the first frame's `set_crtc` returned (a synchronous modeset).
//! - TTI: the runner's settle ledger clear and the data module active, at the
//!   end of a loop turn; the next flip's own timestamp if the screen changed
//!   since its last frame, else now.

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

/// A `CLOCK_MONOTONIC` instant (a DRM event's) on BOOTTIME.
pub fn monotonic_to_boottime(t: Duration) -> f64 {
    t.as_secs_f64() + (boottime() - clock(libc::CLOCK_MONOTONIC))
}

/// The process's start, seconds since boot, and the clock's resolution.
fn process_start() -> Option<(f64, f64)> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    // Field 22, counted after the command's closing parenthesis.
    let after = &stat[stat.rfind(')')? + 2..];
    let ticks: f64 = after.split(' ').nth(19)?.parse().ok()?;
    // SAFETY: sysconf reads a constant.
    #[allow(unsafe_code)]
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    (hz > 0.0).then(|| (ticks / hz, 1000.0 / hz))
}

/// The runner's ledger as named items (the same names the Apple host uses).
pub fn items(o: &exact_runner::runner::outstanding::Outstanding) -> Vec<String> {
    let mut out = Vec::new();
    for (key, list) in [
        ("requests", &o.requests),
        ("streams", &o.streams),
        ("awaiting", &o.awaiting),
        ("deferred", &o.deferred),
        ("oneShots", &o.one_shots),
        ("thens", &o.thens),
        ("busy", &o.busy),
    ] {
        out.extend(list.iter().map(|n| format!("{key}:{n}")));
    }
    if !o.data_ready {
        out.push("activation".into());
    }
    out
}

/// One launch's marks, from process start to time-to-interactive.
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
    /// The process start read from the kernel, nothing marked yet.
    pub fn new() -> Self {
        let (process, resolution_ms) = process_start().map_or((None, 0.0), |(p, r)| (Some(p), r));
        LaunchMarks {
            process,
            resolution_ms,
            ..Default::default()
        }
    }

    /// `boot_presenter` begins: the end of the platform's launch.
    pub fn launch_end(&mut self) {
        self.launch_end.get_or_insert_with(boottime);
    }

    /// A frame went to the display; the first one is on screen when its
    /// synchronous modeset returns.
    pub fn submitted(&mut self, first: bool) {
        let now = boottime();
        if first && self.present.is_none() {
            self.commit = Some(now);
            self.present = Some(now);
        } else {
            self.changed = true;
        }
    }

    /// A flip completed at `at` (the kernel's MONOTONIC timestamp).
    pub fn flipped(&mut self, at: Duration, ready: Option<&[String]>) {
        self.changed = false;
        if self.outcome.is_none() && ready.is_some_and(|r| r.is_empty()) && self.activated.is_some()
        {
            self.interactive = Some(monotonic_to_boottime(at));
            self.outcome = Some("settled");
        }
    }

    /// The data module answers.
    pub fn activated(&mut self) {
        self.activated.get_or_insert_with(boottime);
    }

    /// The end of a loop turn: the ledger as named items.
    pub fn turn(&mut self, outstanding: &[String]) {
        if self.outcome.is_some() || self.present.is_none() {
            return;
        }
        let line = outstanding.join(", ");
        if self
            .trace
            .last()
            .map(|l| !l.ends_with(&format!("[{line}]")))
            .unwrap_or(true)
            && self.trace.len() < 32
        {
            let at = self.process.map_or(0.0, |p| (boottime() - p) * 1000.0);
            self.trace.push(format!("{at:.1} [{line}]"));
        }
        if outstanding.is_empty() && self.activated.is_some() && !self.changed {
            self.interactive = Some(boottime().max(self.present.unwrap_or(0.0)));
            self.outcome = Some("settled");
        }
    }

    /// TTI is decided.
    pub fn done(&self) -> bool {
        self.outcome.is_some()
    }

    /// True once, the first time this is asked after TTI was decided.
    pub fn take_done(&mut self) -> bool {
        let fresh = self.outcome.is_some() && !self.reported;
        self.reported |= fresh;
        fresh
    }

    /// One line: Observe's metrics (ms) and the marks from process start.
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
