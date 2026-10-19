//! The runner's outstanding work: time-to-interactive (TTI) is reached when it
//! is clear. It has no clock; the host timestamps the moment it clears.
//! Only what the screen still lacks counts: a request for a resource already
//! showing an answer (kept, baked or settled) is a background refresh, and a
//! mutation the app sent is a write, so neither holds TTI. Device holds don't
//! count because they wait on a person, and timers don't because they are the
//! app's logic, not loading its screen shows. A resource whose current arguments
//! failed counts as done. `aria-busy` doesn't count: reading it walks the
//! whole tree, and TTI reads the ledger each turn until it is reached.

use super::{Runner, Target};

use crate::DataSource;

/// The runner's outstanding work, by kind.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outstanding {
    /// Requests in flight for resources showing no answer yet.
    pub requests: Vec<String>,
    /// Streams for resources showing no answer, before their first message.
    pub streams: Vec<String>,
    /// Resources showing a placeholder until their source can answer.
    pub awaiting: Vec<String>,
    /// Resources whose current arguments failed: settled, but in error.
    pub failed: Vec<String>,
    /// The data source can answer.
    pub data_ready: bool,
    /// A refused commit poisoned the runner: every action now fails.
    pub poisoned: bool,
}

impl Outstanding {
    /// `{"clear":…,"requests":[…],…}`: the agent's `outstanding` reply.
    pub fn json(&self) -> String {
        let mut out = format!(
            "{{\"clear\":{},\"dataReady\":{},\"poisoned\":{}",
            self.is_clear(),
            self.data_ready,
            self.poisoned
        );
        for (name, items) in [
            ("requests", &self.requests),
            ("streams", &self.streams),
            ("awaiting", &self.awaiting),
            ("failed", &self.failed),
        ] {
            out.push_str(&format!(",\"{name}\":["));
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                crate::agent::quote(item, &mut out);
            }
            out.push(']');
        }
        out.push('}');
        out
    }

    /// Nothing the app started is still on its way.
    pub fn is_clear(&self) -> bool {
        self.requests.is_empty() && self.streams.is_empty() && self.awaiting.is_empty()
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
            let Target::Resource(i) = p.target else {
                continue;
            };
            if matches!(&self.resources[i], Some(s) if !s.placeholder) {
                continue;
            }
            let name = self.target_name(p.target);
            if p.stream.is_some() {
                out.streams.push(name);
            } else {
                out.requests.push(name);
            }
        }
        for i in 0..self.plan.resources.len() {
            let name = || self.plan.str(self.plan.resources[i].name).to_string();
            if matches!((&self.failed_args[i], &self.resources[i]), (Some(f), Some(s)) if f == &s.args)
            {
                out.failed.push(name());
            } else if self.awaiting[i] {
                out.awaiting.push(name());
            }
        }
        out
    }
}
