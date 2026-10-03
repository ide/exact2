//! Platform colours the kernel resolves itself (LLP 1081 D1, D6).
//!
//! A row naming a role or a `platform-color()` crosses as its name, and the
//! presenter resolves it per view (`SystemColor.swift`). What the kernel
//! resolves before it crosses — paint motion's endpoints, gradient stops,
//! an SVG scene's paint and filter colours — the presenter resolves too and
//! reports: every reference, light and dark, under the traits it shows
//! (Increased Contrast is process-wide), again on every trait change. A new
//! report re-targets paint motion (it transitions, as an appearance change
//! does), rebuilds SVG scenes and re-sends styles with a reference in a
//! gradient, so nothing the platform adjusts is a frozen fallback.

use super::Host;
use crate::batch::Batch;
use crate::style;
use exact_kernel::gradient::Gradient;
use exact_kernel::motion::motion_node;
use exact_kernel::style::{roles, Color, ColorValue, RowValue};
use exact_kernel::{StyleId, ViewId};
use exact_runner::DataSource;

fn is_reference(c: ColorValue) -> bool {
    matches!(c, ColorValue::Role(_) | ColorValue::Platform(_))
}

fn refers(g: &Gradient) -> bool {
    g.stops.iter().any(|s| is_reference(s.color))
}

impl<D: DataSource> Host<D> {
    /// Take the presenter's resolutions; when anything resolves differently,
    /// re-present what the kernel resolved from the old ones.
    pub fn set_colors(&mut self, report: Vec<(ColorValue, bool, Color)>) -> String {
        let mut batch = Batch::new();
        if roles::set_reported(report) {
            self.repaint_colors(&mut batch);
            self.svg.all_dirty();
            let kernel = self.runner.kernel();
            let env = kernel.env();
            let views: Vec<ViewId> = self.keys.values().copied().collect();
            for view in views {
                let Some(node) = kernel.node(view) else {
                    continue;
                };
                let gradient = [StyleId::BackgroundImage, StyleId::MaskImage]
                    .into_iter()
                    .any(|id| match node.computed(id) {
                        RowValue::BackgroundImage(b) => b.layers().iter().any(refers),
                        RowValue::MaskImage(m) => m.gradient().is_some_and(refers),
                        _ => false,
                    });
                if gradient {
                    let shown = self.shown_paint(motion_node(node.key));
                    batch.style(view, &style::style_json_presented(&node, &env, &shown).0);
                }
            }
            self.present(&mut batch, false);
        }
        self.finish(batch, None)
    }
}
