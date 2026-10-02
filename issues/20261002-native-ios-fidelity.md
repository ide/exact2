# Native iOS fidelity: what the `fetch-redirect` branch adds

**Status:** this branch, all checks green (cargo build/test/clippy/fmt,
caps, 110 UIKit XCTests). 2026-10-02.

These changes came from building a production-style iOS app on Exact and
comparing it, screen by screen, with the same app written natively. Each one
fixes a place where an Exact app looked or behaved unlike a native one. They
are ordered roughly by how much they change.

## Data

### `resource … with` (Contract, plan, runner)
`resource status = status(car) with rev, time.epochAtZero + now()`. The
call's own arguments say what the answer is; the `with` values say how it is
asked. The plan records each resource's identifying-argument count. At boot,
before the data module can answer, a kept answer whose identifying arguments
match is shown (stale), then asked again at `data_ready` with the current
arguments. Without this, any resource taking a revision or the time never
used its kept answer, and every launch painted placeholders and then jumped.

Plan and rationale: `issues/20261001-resource-with.md`.

Tests:
- `runner/tests/it/kept_identity.rs`
- `contract/cli/tests/it/resource_with.rs`

### `fetch` redirect mode (prelude, runner, Apple executor)
`redirect: "manual"` now reaches the transport. Before, every native fetch
followed redirects, so an OAuth authorize step that 302s to an app scheme
lost its code.

### Simulator entitlements (`host/apple/build.mjs`)
Simulator builds link simulated entitlements, so the Keychain works there.
Diagnosis: `issues/20261001-simulator-builds-have-no-entitlements.md`.

## Navigation (`NavigationIOS.swift`, `TabContainersIOS.swift`, `ModalIOS.swift`)

- **A route can show UIKit's navigation bar:**
  - its title, large or inline
  - collapse with the route's first scroll view
  - a minimal back button
  - a trailing bar button that presses an authored control by HTML id
- **Tabs project into a `UITabBarController`.** Each tab is a retained
  container:
  - `stack`, a `UINavigationController`
  - `screen`
  - or a controller an app module registers in `ExactModule.controllers`

  Contract still selects tabs and owns every route.
- **Sheets present over the whole tab bar controller,** owned by its parent.
  This fixed a view-hierarchy assertion.
- **`navigationDetent` takes several heights** (`medium large` or points). A
  resizable sheet shows the grabber, as the HIG asks.
- **No route left retires native containment.** A signed-out app showing
  plain content no longer leaves a stale stack on top, swallowing every
  touch.

## Controls (`NativeButtonIOS.swift`, `MenusIOS.swift`, `ControlsIOS.swift`)

- **Every `button` is a `UIButton`.** UIKit owns the touch: highlight,
  drag-off, scroll cancel, disabled state and accessibility. An
  author-styled button keeps its look and dims while held, or eases to its
  `press-scale`. Scroll views still scroll when a drag starts on a button.
- **`-exact-apple-button-style`** (`glass`, `prominent-glass`, `filled`,
  `gray`, `tinted`, `plain`) draws a button with `UIButton.Configuration`,
  from its one text and one symbol image:
  - the symbol keeps its authored size
  - the configured styles dim their label while pressed, as SwiftUI's
    bordered styles do
  - interactive glass in a scroll view waits for the scroll view's
    delayed-touch recognizer

  It's a vendor property. Each platform would have its own
  (`-exact-android-button-style`); the web ignores it. The Contract lexer
  accepts `-exact-…` names.
- **`-exact-apple-glass-container`** groups descendants' Liquid Glass so it
  merges (`UIGlassContainerEffect`); `auto` merges across the box's own
  laid-out gap. Write-up:
  `issues/20261001-apple-glass-container.md`.
- **Confirmations are native.**
  - A modal `dialog` of texts, actions and a cancel is UIKit's centred
    alert, with the first text as its title.
  - A confirmation popover is an action sheet anchored to its invoker,
    titled by `aria-label`, with any number of actions.
  - `dialog open=…` presents an alert from state.
  - The choice applies on the next turn, not after the dismissal animation.
  - Invokers are pressed as themselves, not under a transparent overlay that
    swallowed their touch feedback.
- **Controls write UIKit properties only when they change.** A Liquid Glass
  `UISwitch` restarted its thumb animation on every batch, and a switch's
  value is never written while it's being held.
- **An empty `backgroundMaterial`, `commandfor` or `popovertarget` names
  nothing.**

## Rendering

- **`image "symbol:apple:<name>"`** draws any SF Symbol in the Apple hosts,
  as a portable role is drawn. That puts symbols on the first frame without a
  native module.
- **`pointer-events: none`** is honoured by iOS hit testing.
- **Cached images:** a stored response within `stale-while-revalidate` is
  shown at once and refreshed in the background.
- **`host.ios.queriesSchemes`** writes `LSApplicationQueriesSchemes`.
- **Native module views** can size themselves (`sizes`) and take their box at
  every layout.

## Not done (worth doing)

- **Glass morphing when a member is replaced** (SwiftUI's `glassEffectID`).
- **The web target** doesn't read `with` identity for its own kept answers
  yet. It keeps today's behaviour.
- **macOS** counterparts for the glass container and the button styles.
