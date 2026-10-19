//! Observe's navigation metrics (`cold_ttr`, `warm_ttr`, `tti`) for each
//! router change, by the rules of ExactKit's `NavigationMarks.swift`.
//!
//! A navigation starts at the input whose dispatch committed it, or whose
//! dispatch queued the hatch act that committed it ([`Routes::dispatching`]).
//! Otherwise it starts at the commit: a timer, a frame task or a response
//! that the loop runs after an input's dispatch is not its doing. A screen is
//! a router visit at its URL, so a replace that keeps the visit but shows
//! another URL is a new screen, and a change that leaves the same screen on
//! top is no navigation.
//! Render is the presentation of the first frame built after the change: its
//! DRM flip, or the first frame's synchronous modeset. A navigation is cold
//! when its screen was not shown before in the session, and a screen is shown
//! once a navigation to it rendered: one superseded before its first frame
//! leaves its screen unshown. A navigation has a TTI, by startup's rule
//! ([`Ledger::settles`]) and never before render, unless its screen was
//! interactive before; a screen whose TTI a newer navigation cancelled gets
//! one on its next visit. The screen on top at startup's TTI is interactive
//! then, as on the Apple host.
//!
//! Until the session's first frame is presented, the route on top is the
//! launch route, which startup covers: a router change before then replaces
//! it and is no navigation. Each is journaled as `navigation.launch`, nothing
//! is measured for it, and no screen counts as shown until the first frame
//! shows the one on top then.
//!
//! Times are seconds on `CLOCK_BOOTTIME`, the launch marks' clock.

use crate::launch_marks::{boottime, Ledger};
use exact_runner::RouterChange;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// The changes a host keeps for a loop that takes them. One that nothing takes
/// (a headless run) keeps the latest.
const KEPT: usize = 64;

/// A router change, its commit time, and the time of the input whose dispatch committed it.
pub type Committed = (RouterChange, f64, Option<f64>);

/// The router changes a host committed, and the last one.
#[derive(Default)]
pub struct Routes {
    last: Option<RouterChange>,
    changes: VecDeque<Committed>,
    /// The input being dispatched.
    input: Option<f64>,
}

impl Routes {
    /// Keeps `change`, committed now.
    pub fn push(&mut self, change: RouterChange) {
        if self.changes.len() == KEPT {
            self.changes.pop_front();
        }
        self.changes
            // An input causes a change its event's own commit made, not one a timer the
            // runner fired first made (`RouterChange::from_event`).
            .push_back((
                change.clone(),
                boottime(),
                self.input.filter(|_| change.from_event),
            ));
        self.last = Some(change);
    }

    /// The input at `input` is being dispatched (`None`: none is), so the
    /// changes committed until the next call are its doing. Returns the one
    /// before, for a caller that restores it.
    pub fn dispatching(&mut self, input: Option<f64>) -> Option<f64> {
        std::mem::replace(&mut self.input, input)
    }

    /// The last change, for inspection.
    pub fn last(&self) -> Option<&RouterChange> {
        self.last.as_ref()
    }

    /// The changes since the last take, oldest first.
    pub fn take(&mut self) -> VecDeque<Committed> {
        std::mem::take(&mut self.changes)
    }
}

/// The screens a session has shown, and those that became interactive. A
/// screen is a router visit at its URL: a replace keeps the visit and shows
/// another screen; visit ids are never reused.
#[derive(Default)]
pub struct ScreenHistory {
    /// By visit, the URLs a navigation rendered.
    shown: BTreeMap<u64, BTreeSet<String>>,
    /// By visit, the URLs that reached TTI.
    interactive: BTreeMap<u64, BTreeSet<String>>,
    top: Option<(u64, String)>,
}

/// What a screen the router put on top was before.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Screen {
    /// A navigation to it rendered.
    pub shown: bool,
    /// It reached TTI.
    pub interactive: bool,
}

impl ScreenHistory {
    /// Records the router's top after a change that removed `removed`, whose
    /// screens are forgotten. What that screen was before, or `None` when it is
    /// already the one on top.
    pub fn top(&mut self, visit: u64, url: &str, removed: &[u64]) -> Option<Screen> {
        for id in removed {
            self.shown.remove(id);
            self.interactive.remove(id);
        }
        if self
            .top
            .as_ref()
            .is_some_and(|(v, u)| *v == visit && u == url)
        {
            return None;
        }
        self.top = Some((visit, url.to_string()));
        let has = |screens: &BTreeMap<u64, BTreeSet<String>>| {
            screens.get(&visit).is_some_and(|urls| urls.contains(url))
        };
        Some(Screen {
            shown: has(&self.shown),
            interactive: has(&self.interactive),
        })
    }

    /// A navigation to the screen rendered.
    pub fn shown(&mut self, visit: u64, url: &str) {
        self.shown.entry(visit).or_default().insert(url.into());
    }

    /// The screen reached TTI.
    pub fn interactive(&mut self, visit: u64, url: &str) {
        self.interactive
            .entry(visit)
            .or_default()
            .insert(url.into());
    }
}

/// A navigation waiting for its render or its TTI.
struct Pending {
    start: f64,
    /// `route`, `url`, `routeParams` and `exact.nav.cause`.
    fields: Map<String, Value>,
    /// Its screen, a visit at its URL.
    screen: (u64, String),
    cold: bool,
    /// It measures TTI: its screen was not interactive before.
    tti: bool,
    /// A frame built since the change shows it.
    built: bool,
    presented: Option<f64>,
}

/// One session's navigation marks.
pub struct NavigationMarks {
    screens: ScreenHistory,
    /// The route on top: `route`, `url` and `routeParams`.
    top: Option<Map<String, Value>>,
    /// A frame of the session was presented. Until then a router change
    /// replaces the launch route.
    presented: bool,
    pending: Option<Pending>,
    /// Where the events go, each at its mark: the journal, or a test's collector.
    pub(crate) record: fn(&str, Map<String, Value>, f64),
    log: bool,
}

impl NavigationMarks {
    /// Journals into the launch journal; `EXACT_OBSERVE_LOG=1` also prints each mark.
    pub fn new() -> Self {
        NavigationMarks {
            screens: ScreenHistory::default(),
            top: None,
            presented: false,
            pending: None,
            record: crate::journal::record_at,
            log: std::env::var("EXACT_OBSERVE_LOG").as_deref() == Ok("1"),
        }
    }

    /// Startup reached TTI: the screen on top then is interactive, which is the
    /// launch screen only when no navigation came before.
    pub fn startup_interactive(&mut self) {
        if let Some((visit, url)) = self.screens.top.clone() {
            self.screens.interactive(visit, &url);
        }
    }

    /// A frame went on screen. The first shows the screen on top then.
    pub fn presented(&mut self) {
        if !std::mem::replace(&mut self.presented, true) {
            if let Some((visit, url)) = self.screens.top.clone() {
                self.screens.shown(visit, &url);
            }
        }
    }

    /// The route on top: `route`, `url` and `routeParams`.
    pub fn current(&self) -> Option<&Map<String, Value>> {
        self.top.as_ref()
    }

    /// A navigation waits for its render or its TTI.
    pub fn waiting(&self) -> bool {
        self.pending.is_some()
    }

    /// The router committed `change` at `committed`, during the dispatch of the
    /// input at `input`, if any.
    pub fn changed(&mut self, change: &RouterChange, committed: f64, input: Option<f64>) {
        let mut fields = Map::new();
        fields.insert("route".into(), change.pattern.clone().into());
        fields.insert("url".into(), change.url.clone().into());
        let params = change.params.iter();
        fields.insert(
            "routeParams".into(),
            Value::Object(params.map(|(k, v)| (k.clone(), v.clone().into())).collect()),
        );
        // `None`: the same screen is still on top (a change in another tab).
        let Some(screen) = self.screens.top(change.top, &change.url, &change.removed) else {
            return;
        };
        self.top = Some(fields.clone());
        if !self.presented {
            fields.insert("entry".into(), change.top.into());
            self.note(format!("launch {}", change.pattern));
            (self.record)("navigation.launch", fields, committed);
            return;
        }
        let (start, cause) = match input {
            Some(input) => (input.min(committed), "input"),
            None => (committed, "program"),
        };
        fields.insert("exact.nav.cause".into(), cause.into());
        if self.pending.is_some() {
            let mut superseded = Map::new();
            superseded.insert("route".into(), change.pattern.clone().into());
            (self.record)("navigation.superseded", superseded, committed);
        }
        let kind = if screen.shown { "warm" } else { "cold" };
        self.note(format!(
            "change {} visit {} {kind} {cause}",
            change.pattern, change.top
        ));
        self.pending = Some(Pending {
            start,
            fields,
            screen: (change.top, change.url.clone()),
            cold: !screen.shown,
            tti: !screen.interactive,
            built: false,
            presented: None,
        });
    }

    /// A frame is about to be built: it shows every change so far.
    pub fn submitted(&mut self) {
        if let Some(p) = &mut self.pending {
            p.built = true;
        }
    }

    /// A frame built from `built` went on screen at `at`, `now` being the ledger then.
    pub fn shown(&mut self, at: f64, built: &Ledger, now: &Ledger) {
        let Some(p) = &self.pending else {
            return;
        };
        if p.presented.is_none() {
            if !p.built {
                return;
            }
            self.rendered(at);
        }
        if self.pending.is_some() && built.settles(now) {
            self.interactive(at, now);
        }
    }

    /// The end of a loop turn at `at`, with the ledger now. `still`: the screen
    /// shows the latest tree and no frame awaits its flip. A poisoned runtime
    /// handles no action again: a navigation shown then ends without TTI.
    pub fn turn(&mut self, now: &Ledger, still: bool, at: f64) {
        let Some(p) = &self.pending else {
            return;
        };
        if now.poisoned && p.presented.is_some() {
            self.pending = None;
            return;
        }
        if !still {
            return;
        }
        if p.presented.is_none() {
            if p.built {
                // Its frame is on its way.
                return;
            }
            // The change needed no new frame: the screen shows it already.
            self.rendered(at);
        }
        if self.pending.is_some() && now.clear() {
            self.interactive(at, now);
        }
    }

    /// The change is on screen at `at`: its TTR, and its screen is shown. A
    /// navigation to a screen that was interactive before ends there.
    fn rendered(&mut self, at: f64) {
        let Some(p) = &mut self.pending else {
            return;
        };
        p.presented = Some(at);
        let (fields, value, cold, tti) = (p.fields.clone(), at - p.start, p.cold, p.tti);
        let (visit, url) = p.screen.clone();
        self.screens.shown(visit, &url);
        self.measured(
            fields,
            if cold { "cold_ttr" } else { "warm_ttr" },
            value,
            at,
        );
        if !tti {
            self.pending = None;
        }
    }

    /// Nothing is outstanding at `at`: the navigation's TTI, never before render.
    fn interactive(&mut self, at: f64, now: &Ledger) {
        let Some(p) = self.pending.take() else {
            return;
        };
        self.screens.interactive(p.screen.0, &p.screen.1);
        let mut fields = p.fields;
        if !now.failed.is_empty() {
            fields.insert("exact.tti.failed".into(), now.failed.len().into());
        }
        let at = at.max(p.presented.unwrap_or(at));
        self.measured(fields, "tti", at - p.start, at);
    }

    /// Journals metric `name`, `value` seconds, at its mark `at`.
    fn measured(&self, mut fields: Map<String, Value>, name: &str, value: f64, at: f64) {
        let route = fields["route"].as_str().unwrap_or("");
        self.note(format!("{name} {route} {:.1} ms", value * 1000.0));
        fields.insert("name".into(), name.into());
        fields.insert("value".into(), value.into());
        (self.record)("navigation", fields, at);
    }

    fn note(&self, line: String) {
        if self.log {
            eprintln!("observe: navigation {line}");
        }
    }
}

impl Default for NavigationMarks {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
#[path = "navigation_marks_tests.rs"]
mod tests;
