# Observe

Sends Expo Observe's performance metrics and custom events from an Exact app, under Observe's metric names. It works on iOS, macOS, the web and Linux. A game's web build is the wasm host, which does not run it: a game reports nothing on the web.

## Turning it on

```json
"launch": ["observe"],
"moduleConfig": { "observe": { "projectId": "<EAS project id>" } }
```

These settings are optional:
- `endpoint` (default `https://o.expo.dev`);
- `sampleRate` (0–1, decided per install);
- `dispatchingEnabled`;
- `dispatchInDebug`. A development build sends nothing unless this is true.

## Metrics

| Metric | From | To |
|---|---|---|
| `expo.app_startup.cold_launch_time` / `warm_launch_time` | process start | launch end: didFinishLaunching on Apple, the display opening on Linux |
| `expo.app_startup.ttr` | launch end (page activation on the web) | the first frame on screen |
| `expo.app_startup.tti` | launch end | the first frame where nothing on screen is loading (below) |
| `expo.navigation.cold_ttr` / `warm_ttr` / `tti` | the input (or commit) that changed the route | the same marks for the new screen |
| `expo.updates.download_time` (Apple) | the first file requested | the update staged |

Each metric is stamped with the time its end mark happened, as Observe stamps a metric when it records it. On Apple each row carries the update that ran when it was recorded (`expo.app.update_id`, Exact's envelope digest), and none for the embedded app: a refused update leaves none, and an update activated while the app runs labels only the rows after it.

**Startup.** Each process measures one startup, in the main session (one per process). Launch time uses Observe's iOS formula: the time from process start to a late constructor, plus the time from the app delegate's init to didFinishLaunching. A launch is warm when the previous one was the same build in the same OS boot and stderr is not a terminal; otherwise it is cold. Linux applies the same rule, and there a launch is the previous one from launch end on, also when it panics before its startup report.
- **Interrupted.** If the app goes to the background (on macOS, is hidden; on the web, the page is hidden) or quits before TTI, what was measured before stays: the launch time, and TTR if its frame was presented before. Nothing after it is measured. On quitting, the rows are stored and sent at the next launch. A crash keeps them too: the crash record carries the launch time and TTR measured before it (Apple and Linux; it carries no TTI), and the next launch stores for the crashed session, with `exact.launch.crashed`, each one its startup reports did not store, such as the TTR of a first frame after the timeout's report.
- **Late.** If TTI has not come 30 s after launch end, the startup report goes out without it. A first frame that came after the report sends its TTR at once, and a TTI reached later sends it then, with `exact.tti.late`. Each metric is sent once.
- **Poisoned.** If the runtime is poisoned (a tree update threw, so no action can commit), startup reports no TTI, and a navigation waiting for its TTI is cancelled.
- **No metrics** for a prewarmed launch, a launch into the background (its scene connects after the main thread has run, when the user opens the app, where a foreground launch's connects within the launch), a Mac app launched hidden, or a web page that opens hidden (a background tab). A prerendered page measures from its activation.

**TTI's parameters.** The route shown at TTI is its `expo.route_name`, with `routeParams` and `url`, as Observe names the screen whose marker fired. Device and network state come from the launch. On Apple, `expo.frameRate.slowFrames` (17 ms or more), `frozenFrames` (700 ms or more) and `totalDelay` cover the frames from didFinishLaunching to TTI.

**Navigation.** A screen is a router visit at its URL. A navigation is cold when its screen has not been on screen in the session: a push, a tab seen for the first time, or a replace that shows another URL. A screen counts as shown when its first frame is presented, so a screen replaced before its frame stays cold. On iOS that frame is the first after UIKit begins to show the screen's view controller (`viewIsAppearing`), so a sheet presented after another, or a screen a fullscreen cover still hides, waits for UIKit to show it. A screen shown before (a back, a tab seen before) is warm, and a router change that leaves the same screen on top is no navigation. A navigation has a `tti` until its screen has once been interactive, as Observe records one per screen: the first frame after the screen was shown where nothing on screen is loading, as for startup. The launch screen is interactive at startup's TTI, which is its `tti` when it is still on top then and nothing was navigated to before. Until a frame shows the launch screen, a router change replaces it (a redirect at launch) and is no navigation. The launch screen's `cold_ttr` is startup's TTR, the app's first frame, also when the launch route is a sheet UIKit presents after that frame.
- **Its start** is the input whose dispatch changed the router (any touch, click, context menu, pointer event including its entering and leaving, wheel event, key, or field edit whose handler navigated, the tab bar's press of its tab, Enter's submit), else the commit. An input does not cause what came before or after its dispatch: a redirect after a response, or a timer that came due before the input's handler, is timed from its commit. A transition UIKit makes itself (its Back button, a back or dismissal swipe) starts at the last touch or press before UIKit began it (for a swipe, the touch that moved), as only one begins such a transition, and its TTI is the first frame after the transition ended with nothing loading.
- **Cancelled.** A newer navigation or the app going to the background cancels a measurement still waiting. A router change while the app is in the background is not measured; the screen on top at the first frame after the app returns is shown.

**Sending.** Rows are stored until the server accepts them and sent within 5 s of being recorded and when the app goes to the background (on iOS inside a background task). Metrics and logs each have their own retry gate, as expo-observe keeps one per endpoint; a retryable answer (429, 502–504, a transport error) closes the gate for its `Retry-After` (60–900 s) or a jittered backoff, and the service sends again when it opens. On the web each tab's session has its own queue, held by a Web Lock while the tab is open; a tab also sends the queues of tabs that closed, and the events of a page that closed before its services loaded, which it keeps in `localStorage` when it is hidden. Web Locks exist only in a secure context (HTTPS, or localhost): a page served over plain HTTP sends only its own session's rows, and what an earlier page left stays unsent.

**Memory (iOS).** Each memory warning the system sends is an `expo.memory.warning` log with `expo.memory.allocated` (the footprint iOS limits the app by), `physical`, `available` and `warningsCount`.

**Where Exact measures more exactly than expo-observe:**
- TTR ends at the first presented frame, where Observe's ends at a React mount effect. On Linux a frame whose paint failed shows a fallback, not the screen: it ends neither TTR nor TTI.
- TTI is the first frame where nothing on screen is loading, where Observe's is the time the app calls `markInteractive`.
- A navigation starts at the input that caused it, where Observe's starts when the navigation action is enqueued.
- A screen is cold until a frame of it has been presented, where Observe's turns warm when the router focuses or preloads it (`expo-router/init.ts`).

**Not sent:** `bundle_load_time` (an Exact app has no JS bundle on its boot path), TTI's network-request summary, and Observe's session-duration rows (`expo.unknown.duration`).

## Time to interactive

TTI is the first frame where nothing on screen is loading. Loading means any of these:
- a resource showing its placeholder (its `else`), until its answer lands, wherever it is read: also one only a screen beneath the top or an unselected tab reads, as the runner does not track where a resource is read;
- a stream, until its first message;
- an `after(ms)` task with `ms` ≤ 1000, until it runs;
- the host still drawing: images on screen (on the web, as the browser reports them: one clipped, scrolled away or not displayed, by `IntersectionObserver`, or with `visibility: hidden`, by `checkVisibility`, is not), canvas, SVG;
- an element marked `aria-busy="true"` on a shown screen (not one beneath a stack's top or in a tab not selected).

These don't hold TTI:
- **A background refresh.** This is a request for a resource already showing an answer (kept from the last launch, baked, or settled).
- **A mutation the app sends**, and the data module's storage operations.

`aria-busy` is how an app marks anything else as still loading, for example `column aria-busy=(not ready)`. TTI waits until no element on a shown screen is busy. It can delay TTI, never advance it.

The TTI metric carries `exact.tti.trace`, which lists what was outstanding over time, in ms from process start.

## Custom events

An app has no way to send its own events yet; that API is still to be designed. The services already encode Observe's event, attribute and error records (`app.event`, `app.attributes`, `app.error` in the journal), and the web reports uncaught errors and unhandled rejections as `js.exception`. Records follow Observe's rules:
- an event name is 1–256 characters and doesn't start with `expo.`;
- keys starting with `expo.` and the keys `session.id` and `event.name` are dropped;
- at most 128 attributes are kept.

## Tests

`modules/observe/tests/wire.json` is one fixture that all three encoders must produce:
- Swift and JS: `bun test ./modules/observe/tests/wire.test.mjs`;
- Rust: `cargo test -p exact-linux --test observe`.
