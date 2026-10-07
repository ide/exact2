# Visibility: "back to the foreground" is not "visible"

**Status:** Writeup, 2026-10-06. Nothing changed yet.
**Context:** Lexy's TTI trace lists a task `onVisible` at launch. It is meant to run when the app returns from the background.

## 1. What each platform does

| Moment | iOS | Web (Page Visibility) |
|---|---|---|
| Cold launch / page load | not running → inactive → active. `sceneWillEnterForeground` and `didBecomeActive` are called. `UIApplication.willEnterForegroundNotification` is **not** posted. | `visibilityState` is already `"visible"`. `visibilitychange` does **not** fire. |
| App or tab goes away | `didEnterBackground` | `visibilitychange` → `"hidden"` |
| It comes back | `willEnterForeground`, then `didBecomeActive` | `visibilitychange` → `"visible"` |
| Covered but still on screen (Control Center, an alert, a call banner) | `willResignActive` → inactive, but not background | stays `"visible"` |

Both platforms agree: "visible" is a state, and "came back" is a change of that state. Neither reports a return at launch.

## 2. What Exact does

- **`page.visibilityState`** is the web's state on every host.
  - **iOS:** `"hidden"` while the app is in the background (`AppBackground`, from `UIApplication.applicationState`; inactive counts as visible, as on the web).
  - **macOS:** hidden, or every window fully occluded.
  - **Web:** `document.visibilityState`.
- **A gated task arms when its condition becomes true, and at boot when it is already true.** That's LLP 1092 D8's table: "true, was false (or boot) → armed".

So `task returned when page.visibilityState == "visible"` with `after(1, onVisible)` runs once at launch and once after each real return. A `when` task follows a state. It is not an event.

## 3. What it costs Lexy

`onVisible` guards itself (`if lastTick > 0`), so the launch run does nothing. But it is an `after(1)` one-shot, so TTI waits for it. On a device it ran 313–346 ms from process start, alongside `start`. The real cost is small. The meaning is wrong, though, and the next app's "on return" logic won't have the guard.

## 4. Options

**A. In the app: gate on a real return.**
- Track a hide with `task hid when page.visibilityState == "hidden"` (one-shot → `wasHidden = true`).
- Gate the return task on `wasHidden and page.visibilityState == "visible"`, and clear `wasHidden` in `onVisible`.
- Works today. Every app has to know the trick.

**B. In Exact: the web's event.** A root handler, `visibilitychange=onVisibility`, called with the new state only when it changes, never at load.
- The DOM's name and timing, so the web host is just `document`'s event.
- **iOS mapping:**
  - `"hidden"` at `didEnterBackground`
  - `"visible"` at `willEnterForeground`
  - not at launch, not for inactive
- **macOS mapping:** hide or unhide, occlusion.
- `page.visibilityState` stays the state, for gates and derives. The event is for "something happened".

**C. Change gated tasks not to arm at boot.** Rejected: it would break every `when` task that rightly starts with the app (a toast already showing, a pulse already on).

## 5. Recommendation

- **B in Exact:** it's the web standard and it fits both platforms' own lifecycles. Document beside the gated-task section that a `when` on a state is not an event, and point to `visibilitychange` for "came back".
- **Until then, A in Lexy:** it takes `onVisible` out of the launch TTI.
