//! The clock across the app's life on the device: back from the
//! background, a timer that slept through several beats fires once
//! (`exact_runner::Runner::coalesce_missed`).

use super::Bridge;
use exact_runner::DataSource;

impl<D: DataSource> Bridge<D> {
    /// `exact_coalesce_missed`: the app is back at `now_ms`.
    pub fn coalesce_missed(&mut self, now_ms: f64) {
        if let Some(h) = self.host.as_mut() {
            h.coalesce_missed(now_ms);
        }
    }
}
