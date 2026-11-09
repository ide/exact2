surfaces: ios, macos, web
agent: Codex
task: let UIKit own arrangement presentation

### Rough

- Arrangement adoption disabled navigation-bar safe-area changes, including an app's explicit native setting. Removing that override leaves the navigation item with UIKit's default or the route hatch's configuration.
- Peer-position checks must allow UIKit's safe-area changes. They now measure content position relative to the native inset.
- Layout projection could replace a hatch's native content-scroll selection. Explicit UIKit selections now own their edges, including nil and all-edge requests.
- UIKit's content-scroll getter returns nil for automatic selection. Exact keeps the automatic scroll-to-top target while leaving the native edge unset.
- Native selections need to retain collection ownership and expose app-owned scrollers to route hatches. A weak target reference also clears their scroll-to-top state when selection changes, Inspect starts or navigation ends.
- Panes can own different edges when UIKit changes the split axis or hides a pane. An interior pane's own safe area must clear an edge before the other panes' scrollers can own its inset.

### Lean in

- UIKit owns arrangement allocation, bar minimization, scroll-edge effects and navigation transitions. The hatch retains authored pane content and supplies its native child controllers.
- Other hosts keep the authored responsive CSS layout.
- The API takes UIKit's controller and configurations directly. Exact owns the authored content slots and refuses controllers whose slots already contain app content.

### Needed

- Native navigation configuration: provided through the route hatch
- Independent pane scrolling and retained content: provided
- Intrinsic pane dimensions: authored content measurement is not connected to UIKit's fitting measurement; use native automatic, absolute or fractional dimensions

### Checkpoints

- UIKit: native policy, scroll-selection, axis-change, peer-inset and native-backend tests pass on an open iOS 27.1 Duo simulator (6 tests, no skips). They cover collection ownership, native inset policies, hatch values, scroll-to-top replacement, Inspect and navigation reset. Existing containment and focus cases pass too.
- The standalone UIKit reference app's automatic and fixed-header gesture tests pass (2 tests, no skips). AppDrop build 5 removes the programmatic scroll menu commands.
- Duo Lab: the arrangement smoke passes in 59.5 seconds through open, folded and closed poses in Split, Overlay and Authored modes, with retained state, independent scrolling, confirmation retention, and cancelled and completed native Back gestures.
- tvOS: Caltrain builds with the shared navigation changes.
- Repository: all six checks pass, including the full Cargo test suite.
