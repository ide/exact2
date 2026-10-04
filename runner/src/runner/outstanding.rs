//! What the app is still doing (Exact Observe design §3.5): the runner's half
//! of the settle ledger that time-to-interactive reads. Clockless and pure:
//! the host stamps when it changes.
//!
//! Counted: requests in flight (minus device holds, which wait on a person),
//! streams before their first message, resources showing a placeholder until
//! their source can answer, compiled answers still to be asked again, armed
//! `after` tasks due within [`STARTUP_TIMER_WINDOW_MS`] (load on appear),
//! armed mutation `then`s, and mounted elements marked `aria-busy`. A resource whose current arguments failed is
//! terminal, not outstanding, until something asks again.

use super::{Runner, Target};

use crate::DataSource;

/// An `after` task armed with at most this delay is startup work; a longer
/// one (a promotion in a minute) is not.
pub const STARTUP_TIMER_WINDOW_MS: f64 = 1000.0;

/// The runner's outstanding work, by kind, named for the agent and the log.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outstanding {
    /// Requests in flight, by resource or mutation name.
    pub requests: Vec<String>,
    /// Streams that have not delivered their first message.
    pub streams: Vec<String>,
    /// Resources showing a placeholder until their source can answer.
    pub awaiting: Vec<String>,
    /// Compiled answers shown until the source is asked again.
    pub deferred: Vec<String>,
    /// Armed one-shot tasks due within the startup window, by action name.
    pub one_shots: Vec<String>,
    /// Mutations whose `then` action is armed.
    pub thens: Vec<String>,
    /// Resources whose current arguments failed: settled, but in error.
    pub failed: Vec<String>,
    /// Mounted elements marked `aria-busy` (by test id, else view id): the
    /// app's own word that a region is still loading.
    pub busy: Vec<String>,
    /// The data source can answer.
    pub data_ready: bool,
    /// A refused commit poisoned the runner: every action now fails.
    pub poisoned: bool,
}

impl Outstanding {
    /// `{"clear":…,"requests":[…],…}`: the agent's `outstanding` reply, and
    /// what a host's TTI reads.
    pub fn json(&self) -> String {
        let list = |name: &str, items: &[String], out: &mut String| {
            out.push_str(&format!(",\"{name}\":["));
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                crate::agent::quote(item, out);
            }
            out.push(']');
        };
        let mut out = format!(
            "{{\"clear\":{},\"dataReady\":{},\"poisoned\":{}",
            self.is_clear(),
            self.data_ready,
            self.poisoned
        );
        list("requests", &self.requests, &mut out);
        list("streams", &self.streams, &mut out);
        list("awaiting", &self.awaiting, &mut out);
        list("deferred", &self.deferred, &mut out);
        list("oneShots", &self.one_shots, &mut out);
        list("thens", &self.thens, &mut out);
        list("failed", &self.failed, &mut out);
        list("busy", &self.busy, &mut out);
        out.push('}');
        out
    }

    /// Nothing the app started is still on its way.
    pub fn is_clear(&self) -> bool {
        self.requests.is_empty()
            && self.streams.is_empty()
            && self.awaiting.is_empty()
            && self.deferred.is_empty()
            && self.one_shots.is_empty()
            && self.thens.is_empty()
            && self.busy.is_empty()
    }
}

impl<D: DataSource> Runner<D> {
    /// What the app is still doing, as of the last commit.
    pub fn outstanding(&self) -> Outstanding {
        let mut out = Outstanding {
            data_ready: self.data.ready(),
            poisoned: self.poisoned,
            ..Outstanding::default()
        };
        for p in &self.pending {
            if !p.in_flight() || self.device_holds.iter().any(|h| h.ticket == p.ticket) {
                continue;
            }
            let name = self.target_name(p.target);
            if p.stream.is_some() {
                out.streams.push(name);
            } else {
                out.requests.push(name);
            }
        }
        let asked = |i: usize| self.pending.iter().any(|p| p.target == Target::Resource(i));
        for i in 0..self.plan.resources.len() {
            let name = || self.plan.str(self.plan.resources[i].name).to_string();
            let failed = match (&self.failed_args[i], &self.resources[i]) {
                (Some(failed), Some(state)) => failed == &state.args,
                _ => false,
            };
            if failed {
                out.failed.push(name());
            } else if self.awaiting[i] {
                out.awaiting.push(name());
            } else if self.stale[i] && !asked(i) {
                out.deferred.push(name());
            }
        }
        for (i, t) in self.timers.iter().enumerate() {
            let row = &self.plan.timers[i];
            if row.once
                && t.next_ms.is_finite()
                && row.interval_ms as f64 <= STARTUP_TIMER_WINDOW_MS
            {
                out.one_shots
                    .push(self.plan.str(self.plan.action(row.action).name).to_string());
            }
        }
        // `aria-busy` on a mounted element: what the app says is not final.
        let mut stack: Vec<u32> = self.kernel.roots().into_iter().rev().collect();
        while let Some(id) = stack.pop() {
            let Some(node) = self.kernel.node(id) else {
                continue;
            };
            if node.props.bool(exact_kernel::PropId::AccessibilityBusy) == Some(true) {
                let name = node
                    .props
                    .str(exact_kernel::PropId::TestId)
                    .map_or_else(|| id.to_string(), str::to_owned);
                out.busy.push(name);
            }
            stack.extend(node.children().into_iter().rev());
        }
        for (m, due) in self.then_due.iter().enumerate() {
            if due.is_finite() {
                out.thens
                    .push(self.plan.str(self.plan.mutations[m].name).to_string());
            }
        }
        out
    }
}
