# Observe

Sends Expo Observe's performance metrics and custom events from an Exact app, under Observe's metric names. It works on iOS, macOS, the web and Linux.

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

## Time to interactive

TTI is the first frame where nothing on screen is loading. Loading means any of these:
- a resource showing its placeholder (its `else`), until its answer lands;
- a stream, until its first message;
- an `after(ms)` task with `ms` ≤ 1000, until it runs;
- the host still drawing: images, canvas, SVG;
- an element marked `aria-busy="true"`.

These don't hold TTI:
- **A background refresh.** This is a request for a resource already showing an answer (kept from the last launch, baked, or settled).
- **A mutation the app sends.**

`aria-busy` is how an app marks anything else as still loading, for example `column aria-busy=(not ready)`. TTI waits until no element is busy. It can delay TTI, never advance it.

The TTI metric carries `exact.tti.trace`, which lists what was outstanding over time, in ms from process start.

## Custom events

```
observe("checkout.completed", Checkout(items=n, total=t), "info")
observeAttributes(Tier(tier="pro"))   // merged into every later event
observeError("cart unavailable", "CartError")
```

The attributes are a shape constructed in place. These follow Observe's rules:
- an event name is 1–256 characters and doesn't start with `expo.`;
- keys starting with `expo.` and the keys `session.id` and `event.name` are dropped;
- at most 128 attributes are kept.

## Tests

`modules/observe/tests/wire.json` is one fixture that all three encoders must produce:
- Swift and JS: `bun test ./modules/observe/tests/wire.test.mjs`;
- Rust: `cargo test -p exact-linux --test observe`.
