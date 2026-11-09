//! The sizes a native host laid a list's mounted rows out at, taken in by
//! the commit that laid them out (@ref LLP 1072 §8.7). The kernel lays out
//! the rows the runner mounts in the same turn as the commit, and the rows
//! take their real sizes there, while the index still holds estimates for
//! the ones not yet measured: the rows after them move by the difference.
//! Taking the sizes in at once, and keeping the anchor where it was, lets
//! the batch that moves them carry the extent and the correction that move
//! implies, where the host's next report would come a frame later. A
//! measurement changes no layout: spacers stand only for rows not mounted.
//! Nothing else a report does happens here: no window, edge, target or pin.
use super::*;

impl Collection {
    /// Take in each row's size, from `rows` (a mounted row's wrapper, its
    /// size along the list's axis and its size across it), and restore the
    /// anchor; the list's revision after them. A row laid out across other
    /// than the reported cross size is left out, as the host's report
    /// leaves it out. A list the host has not reported, or one opening at a
    /// kept position, previewing a reorder or taking a row into view, waits
    /// for the host's report, which owns those.
    pub(super) fn take_measured(
        &mut self,
        rows: &[(ViewId, f64, f64)],
    ) -> Result<u64, InstanceError> {
        let Some(cross) = self.geometry.as_ref().map(|g| g.cross) else {
            return Ok(self.revision);
        };
        if self.target.is_some()
            || self.restored_at.is_some()
            || self.preview.is_some()
            || self.incoming.is_some()
        {
            return Ok(self.revision);
        }
        let by_view: BTreeMap<ViewId, usize> = (self.mounted.iter().enumerate())
            .map(|(i, r)| (r.wrapper, i))
            .collect();
        let mut fresh: Vec<RowMeasurement> = Vec::new();
        for &(view, size, across) in rows {
            let Some(&i) = by_view.get(&view) else {
                continue;
            };
            let row = &self.mounted[i];
            if across != cross || !size.is_finite() || size < 0.0 {
                continue;
            }
            // The size the index holds already, measured: nothing to take in
            let same = self.index.is_measured_at(row.position)
                && (self.index.height(row.position)).is_some_and(|h| {
                    h.to_bits() == self.index.denoised(row.position, size).to_bits()
                });
            if !same {
                fresh.push(RowMeasurement {
                    view,
                    epoch: row.epoch,
                    size,
                });
            }
        }
        if fresh.is_empty() {
            return Ok(self.revision);
        }
        let largest = fresh
            .iter()
            .map(|m| m.size)
            .fold(self.index.total_height(), f64::max);
        if !self.index.padded_extent_definitely_fits(largest) {
            // The host's report checks the extent against what native
            // geometry holds before it changes anything
            return Ok(self.revision);
        }
        let previous = self.snapshot();
        // @ref LLP 1070 H4 — a row list anchors only an estimate replaced by
        // a first measurement; a row measured again moves what follows it
        if self.axis == ListAxis::Horizontal {
            let (again, first): (Vec<_>, Vec<_>) = (fresh.into_iter()).partition(|m| {
                self.index
                    .is_measured_at(self.mounted[by_view[&m.view]].position)
            });
            for measurement in again {
                self.measure(&by_view, measurement)?;
            }
            fresh = first;
        }
        let anchor = self.anchor()?;
        for measurement in fresh {
            self.measure(&by_view, measurement)?;
        }
        self.restore(anchor)?;
        let mut now = self.snapshot();
        now.scroll_sequence = previous.scroll_sequence;
        if previous != now {
            advance(&mut self.revision)?;
        }
        Ok(self.revision)
    }
}
