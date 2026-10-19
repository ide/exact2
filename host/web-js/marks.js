// Web launch and navigation timing, imported only when app.json names launch
// modules. Times are performance.now(), the clock Event.timeStamp and
// Performance entries share. A prerendered page measures from its activation;
// a page that opens hidden (a background tab) reports no startup, as a native
// background launch does. Time-to-first-render (TTR) is the boot tree's first
// paint. Time-to-interactive (TTI) is the first frame after which nothing on
// screen is outstanding. A navigation starts at the input whose dispatch changed
// the router, else at the commit; it is cold when its screen, a router visit at
// its URL, was not painted before, and has a TTI until that screen was once
// interactive (NavigationMarks.swift). Until a frame paints the launch screen, a
// router change replaces it and is no navigation. A page hidden during startup
// reports what it measured before; one hidden during a navigation cancels it, and
// a change while it is hidden is not measured.
// Events go to each launch module's web service, which receives earlier events first.
// Nothing here may throw into the app: each hook the runtime calls is guarded.
import { inflight, InflightDrops, lazyWaiting, Undrawn, Resources, clock, After, Routes, RouterChanges, routeAt, busy, inactive, poisoned, Advancing, InputScope } from './rt.js';

const STARTUP_TIMER_WINDOW_MS = 1000, TTI_TIMEOUT_MS = 30000;
const events = [], services = [];
const marks = {};
let launch = [], outcome = null, reported = false, late = false, suppressed = null, dirty = false, lastTrace = '', trace = [], nav = null, hidden = false;
/** The earliest timestamp of the inputs dispatched in this task (a click follows its pointerup), and the input a
 * deferred commit runs as (`InputScope.run`). */
let taskInput = null, scoped = null, current = null;
/** The events whose handlers run actions: a pointer's press, motion, release and cancel, its entering and leaving
 * (`onHover`), a click, a context menu, the wheel, a key's press and release, and a field's edit (`onValue`, `onBeforeInput`). */
const INPUTS = new Set(['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'pointerenter', 'pointerleave', 'click', 'contextmenu', 'wheel', 'keydown', 'keyup', 'beforeinput', 'input', 'change']);
/** The input whose dispatch is running now, as its handlers commit at once: the latest input while it is still being
 * dispatched (its `eventPhase`, also through an event it nests, such as a `popstate` or `focusout`; none once it is done,
 * in timers, frames and answers), unless it is due work its handler runs first (`Advancing`). */
const inputNow = () => (Advancing ? null : scoped ?? (current && current.eventPhase !== Event.NONE ? taskInput : null));
/** Each change to the screen; a frame wait that a newer change overtook does not count. */
let generation = 0;
/** This page's session, which its services use, and the journal a hide before they load leaves. */
const session = crypto.randomUUID?.() // a secure context's; on plain HTTP, a UUID from `getRandomValues`
  ?? '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, c => (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16));
let journalKey = null;

/** Journals an event; `at` is when it happened (performance.now()), by default now. */
const record = (kind, fields = {}, at = performance.now()) => {
  const e = { kind, at, wall: performance.timeOrigin + at, ...fields };
  events.push(e);
  if (events.length > 4096) events.shift();
  for (const s of services) s.event(e);
};
const guarded = f => (...a) => { try { return f(...a); } catch (e) { console.error(`exact: observe marks: ${e?.message ?? e}`); } };

/** Each loading image's visibility as the browser reports it: `IntersectionObserver` for the viewport, an ancestor's clip,
 * scrolling and `display: none`, and `checkVisibility` for CSS `visibility`. Not in a navigation pane that is not shown.
 * An intersection change re-evaluates TTI; until its first report an image counts as on screen. */
const intersecting = new WeakMap();
let watcher;
const onScreen = img => {
  watcher ??= typeof IntersectionObserver === 'function'
    ? new IntersectionObserver(guarded(entries => { for (const e of entries) intersecting.set(e.target, e.isIntersecting); changed(); queueMicrotask(evaluate); }))
    : null;
  if (watcher && !intersecting.has(img)) { intersecting.set(img, true); watcher.observe(img); }
  return intersecting.get(img) !== false && img.checkVisibility?.({ visibilityProperty: true }) !== false && !inactive(img);
};

/** What the screen still lacks, by name. A request, or the wait for the Rust data module (`waiting`, which a failed load
 * never ends), counts only for a resource showing its placeholder: a refresh behind a shown answer and a mutation the app
 * sent don't hold TTI. A one-shot timer counts only when due within 1 s. */
export function outstanding() {
  const out = [];
  for (const r of Resources) if ((r.ticket || r.waiting) && r.placeholder) out.push(`requests:${r.name}`);
  // Everything else in flight is the page's own loading (Markdown, canvas, motion, GPU), but not what
  // draws nothing (`Undrawn`), nor rows waiting to adopt: they show their values and adopt on the first input that reaches them.
  const own = inflight.n - Undrawn.tickets - Undrawn.storage - lazyWaiting();
  if (own > 0) out.push(`loading:${own}`);
  // Images on screen still loading (a failed one is complete).
  let images = 0;
  for (const img of document.getElementById('exact-root')?.getElementsByTagName('img') ?? []) if (!img.complete && onScreen(img)) images++;
  if (images) out.push(`images:${images}`);
  for (const t of clock.timers) if (t.once && t.ms <= STARTUP_TIMER_WINDOW_MS) out.push(`oneShots:${t.ms}`);
  for (const id of busy()) out.push(`busy:${id}`);
  return out;
}

/** The next rendering opportunity: when it is past, and the screen generation its frame painted. */
const nextOpportunity = () => new Promise(r => requestAnimationFrame(() => { const painted = generation; setTimeout(() => r({ at: performance.now(), painted })); }));

const here = () => location.pathname + location.search;

/** Ends startup with outcome `o`. The startup report goes once; a TTI reached after it (the
 * timeout reported first) goes on its own, as `startup.tti`. */
function finish(o) {
  if (outcome) return;
  outcome = o;
  // The screen on top at startup's TTI has been interactive.
  if (marks.interactive !== undefined) { const s = topScreen(); if (s) s.interactive = true; }
  if (!reported) reportStartup(o);
  else if (marks.interactive !== undefined) record('startup.tti', report(o));
}

function reportStartup(o) {
  if (reported) return;
  reported = true;
  record('startup', report(o));
  loadServices();
}

/** Each metric in seconds, with `walls`, the time of its end mark in ms since 1970. A mark
 * before a prerendered page's activation counts as at it: the page shows on activation. */
function report(o) {
  const metrics = {}, walls = {}, from = marks.activation ?? 0;
  const metric = (name, t) => { const end = Math.max(t, from); metrics[name] = (end - from) / 1000; walls[name] = performance.timeOrigin + end; };
  if (!suppressed && marks.present !== undefined) metric('timeToFirstRender', marks.present);
  if (!suppressed && marks.interactive !== undefined) metric('timeToInteractive', marks.interactive);
  const r = { metrics, walls, marks: { ...marks }, tti: o, trace, presentMethod: marks.presentMethod, bootPath: 'web' };
  // The screen that became interactive.
  if (marks.interactive !== undefined) { r.route = { ...route(here()), url: here() }; if (late) r.late = true; }
  if (hidden) r.interrupted = true;
  if (suppressed) r.suppressed = suppressed;
  return r;
}

/** Runs after each commit and when loading ends. Records TTI once nothing is outstanding after
 * the first paint; if the screen changed, at the next rendering opportunity. */
const evaluate = () => evaluateNow().catch(e => console.error(`exact: observe marks: ${e?.message ?? e}`));
async function evaluateNow() {
  if (failed()) return;
  const out = outstanding(), line = out.join(', ');
  if (line !== lastTrace && trace.length < 32) trace.push(`${Math.round(performance.now())} [${line}]`);
  lastTrace = line;
  if (!outcome && !suppressed && !out.length) {
    const declared = trace.length > 1 && /^\d+ \[(busy:[^,\]]*(, )?)+\]$/.test(trace[trace.length - 2]);
    let at = performance.now();
    if (dirty) {
      const frame = await nextOpportunity();
      // A change after that frame painted needs the next one; its own evaluation follows it.
      if (frame.painted !== generation || failed()) return;
      at = frame.at;
    }
    if (outstanding().length || outcome) return;
    // Before the first paint is marked (the fallback waits for a better entry), keep the TTI it would be.
    if (marks.present === undefined) { candidate = { at, painted: generation, declared }; return; }
    interactiveAt(at, declared);
  }
  const n = nav;
  if (n && n.presented !== undefined && !n.done && !out.length) {
    // A screen changed since it was shown reaches TTI at the frame that shows the change.
    let at = performance.now();
    if (n.dirty) {
      const frame = await nextOpportunity();
      if (frame.painted !== generation || failed()) return;
      at = frame.at;
    }
    if (nav !== n || n.done || outstanding().length) return;
    n.done = true;
    n.screen.interactive = true;
    const t = Math.max(at, n.presented);
    record('navigation', { ...n.fields, name: 'tti', value: (t - n.start) / 1000 }, t);
  }
}

/** Whether the runtime is poisoned (a tree update threw), so it handles no action again: startup
 * ends without TTI (`logic_failed`, as on Apple) and a navigation waiting for TTI is cancelled. */
function failed() {
  if (!poisoned()) return false;
  if (!outcome) finish('logic_failed');
  if (nav) nav.done = true;
  return true;
}

/** The TTI startup reached before its first paint was marked, and the screen it was for. */
let candidate = null;
function interactiveAt(at, declared) {
  marks.interactive = Math.max(at, marks.present);
  dirty = false;
  finish(declared ? 'declared' : 'settled');
}

/** A location's route pattern (`/photo/:photo`) and its bound parameters, as the native hosts send. */
function route(url) {
  const r = Routes[routeAt(url)];
  if (!r || r.notfound) return { route: url.split('?')[0], routeParams: {} };
  const decode = s => { try { return decodeURIComponent(s); } catch { return s; } };
  const params = {}, pat = r.pattern.split('/'), parts = url.split('?')[0].split('/');
  pat.forEach((s, i) => { if (s[0] === ':' && parts[i]) params[s.slice(1)] = decode(parts[i]); });
  return { route: r.pattern, routeParams: params };
}

/** Each router visit's screens, by URL: `{ shown, interactive }` (ScreenHistory in
 * NavigationMarks.swift). A screen is shown when its frame is painted. */
const screens = new Map();
let onTop = null;
function routerChanged({ top, url, removed }) {
  for (const id of removed) screens.delete(id);
  const key = `${top} ${url}`;
  // The same screen still on top (a change in another tab): nothing was navigated to.
  if (key === onTop) return;
  const first = onTop === null;
  onTop = key;
  const urls = screens.get(top) ?? new Map();
  screens.set(top, urls);
  const screen = urls.get(url) ?? { shown: false, interactive: false };
  urls.set(url, screen);
  // The first is the launch route, which startup covers. Until a frame paints it, a change replaces it (a redirect
  // at launch) and is no navigation; the screen on top at that frame is the one shown.
  if (first || launching) {
    record('navigation.launch', { ...route(url), url });
    const mine = launching = (launching ?? 0) + 1;
    nextOpportunity().then(guarded(() => { if (launching !== mine) return; launching = null; const s = topScreen(); if (s) s.shown = true; }));
    return;
  }
  startNavigation(screen, url, !screen.interactive);
}
/** The launch screen's changes while no frame has painted it yet, or null once one has. */
let launching = null;
const topScreen = () => { if (onTop === null) return null; const i = onTop.indexOf(' '); return screens.get(Number(onTop.slice(0, i)))?.get(onTop.slice(i + 1)); };

function startNavigation(screen, url, measuresTTI) {
  const now = performance.now();
  // The input being dispatched when the router changed, else the commit; what came due before its handler is not its doing.
  const input = inputNow();
  const fields = { ...route(url), url, 'exact.nav.cause': input !== null ? 'input' : 'program', 'exact.present.method': 'raf' };
  if (nav && !nav.done) record('navigation.superseded', { route: fields.route });
  nav = null;
  // A hidden page shows nothing: nothing is measured until it is seen again.
  if (document.visibilityState === 'hidden') return;
  const cold = !screen.shown;
  const n = nav = { start: input ?? now, fields, cold, measuresTTI, screen, dirty: false };
  nextOpportunity().then(guarded(({ at: t, painted }) => {
    if (nav !== n || n.done) return;
    // A change after this frame painted shows in a later one.
    if (painted !== generation) n.dirty = true;
    n.presented = t;
    screen.shown = true;
    record('navigation', { ...fields, name: cold ? 'cold_ttr' : 'warm_ttr', value: (t - n.start) / 1000 }, t);
    // A screen interactive before has no TTI (NavigationMarks.swift).
    if (!measuresTTI) { n.done = true; return; }
    evaluate();
  }));
}

/** The screen changed: startup's TTI and a shown navigation's wait for the frame that shows it. */
function changed() {
  dirty = true;
  generation++;
  if (nav?.presented !== undefined) nav.dirty = true;
}

function presentFrom(c0, served) {
  // The first of: Element Timing on the boot tree's first text leaves, the
  // first-contentful-paint at or after the commit, or the next rendering
  // opportunity. A server-rendered page painted before this script ran, so
  // its first-contentful-paint counts even though it precedes the commit.
  let done = false;
  const take = (t, method) => {
    if (done || hidden) return;
    done = true; marks.present = method === 'served_fcp' ? t : Math.max(t, c0); marks.presentMethod = method; record('mark', { mark: 'present', method });
    // A first paint after the timeout's report goes now, as Observe records one on its own, not with a TTI that may never come.
    if (reported && !outcome) record('startup.tti', report('pending'));
    // Settled before the paint was marked, with nothing changed since: TTI is when it settled.
    const c = candidate;
    candidate = null;
    if (c && c.painted === generation && !outcome && !failed() && !outstanding().length) interactiveAt(c.at, c.declared);
    else evaluate();
  };
  try {
    new PerformanceObserver(list => { for (const e of list.getEntries()) if (e.identifier?.startsWith('exact-boot')) take(e.renderTime || e.loadTime, 'element'); }).observe({ type: 'element', buffered: true });
  } catch {}
  try {
    new PerformanceObserver(list => { for (const e of list.getEntries()) if (e.name === 'first-contentful-paint' && (served || e.startTime >= c0)) take(e.startTime, served ? 'served_fcp' : 'paint'); }).observe({ type: 'paint', buffered: true });
  } catch {}
  // The fallback waits 200 ms for a better entry; a hide meanwhile takes it at once: that frame came before the hide.
  nextOpportunity().then(({ at }) => { takeFallback = () => take(at, served ? 'raf_served' : 'raf'); setTimeout(takeFallback, 200); });
}
/** The first paint the fallback saw, marked now (before a hide), if no better entry came. */
let takeFallback = () => {};

/** The navigation entry's activation start: 0 for a page not prerendered. */
const activationStart = () => { const e = performance.getEntriesByType?.('navigation')?.[0]; return e?.activationStart > 0 ? e.activationStart : 0; };

/** Called by main.js before the app boots, then with `mounted()` after. */
export function install(modules) {
  launch = modules;
  marks.activation = activationStart();
  marks.process = 0;
  const background = () => { record('background'); for (const s of services) s.background(); };
  document.addEventListener('visibilitychange', guarded(() => {
    // Seen again: the screen on top at the next frame, which a change while hidden put there, is painted.
    if (document.visibilityState !== 'hidden') {
      // The screen on top when the frame is made, if still on top after it: not one a later task or a later callback
      // of the same frame replaced.
      requestAnimationFrame(guarded(() => { const s = topScreen(); setTimeout(() => { if (s && topScreen() === s && document.visibilityState !== 'hidden') s.shown = true; }); }));
      return;
    }
    // Report first, so a service's flush on hide carries it.
    if (!outcome && !document.prerendering) { takeFallback(); hidden = true; finish('interrupted'); }
    if (nav) nav.done = true;
    background();
    keepJournal();
  }));
  const timeout = () => setTimeout(guarded(() => { if (!outcome) { late = true; reportStartup('timeout'); } }), TTI_TIMEOUT_MS);
  if (document.prerendering) {
    // Startup is measured from activation, so its timeout starts then too.
    document.addEventListener('prerenderingchange', guarded(() => { marks.activation = activationStart() || performance.now(); timeout(); }), { once: true });
  } else if (document.visibilityState === 'hidden') {
    // Opened hidden: no one saw it start. The services still load, for what follows.
    suppressed = 'hidden';
    finish('hidden');
  } else {
    timeout();
  }
  RouterChanges.push(guarded(routerChanged));
  addEventListener('pagehide', guarded(() => { background(); keepJournal(); }));
  // This page's journal key, under a lock its services' successors read: held while the page is open.
  const app = modules[0]?.config?.['app.CFBundleIdentifier'] ?? location.host;
  journalKey = `exact-journal:${app}:${session}`;
  navigator.locks?.request(journalKey, () => new Promise(() => {})).catch(() => {});
  // Each input's timestamp, heard first (capture, also for one that does not bubble), until its task ends.
  let inputTask = 0;
  const begin = e => { current = e; taskInput = Math.min(taskInput ?? e.timeStamp, e.timeStamp); const task = ++inputTask; setTimeout(() => { if (inputTask === task) { taskInput = null; current = null; } }); };
  for (const t of INPUTS) addEventListener(t, begin, { capture: true, passive: true });
  // A commit an input deferred is that input's: Enter's submit (after the key's other handlers), a tree update a view
  // transition runs later. What it commits it commits at once.
  InputScope.capture = inputNow;
  InputScope.run = (at, f) => { const outer = scoped; scoped = at; try { return f(); } finally { scoped = outer; } };
  // An image's load or error (which do not bubble, so heard as they descend) can end the screen's loading.
  for (const t of ['load', 'error']) document.addEventListener(t, e => { if (e.target?.localName === 'img') { watcher?.unobserve(e.target); intersecting.delete(e.target); changed(); queueMicrotask(evaluate); } }, { capture: true, passive: true });
  // Uncaught errors and unhandled rejections.
  addEventListener('error', e => record('app.error', { source: 'global', type: e.error?.name ?? 'Error', message: e.message, stack: e.error?.stack }));
  addEventListener('unhandledrejection', e => record('app.error', { source: 'global', type: e.reason?.name ?? 'UnhandledRejection', message: String(e.reason?.message ?? e.reason), stack: e.reason?.stack }));
  globalThis.exact = Object.assign(globalThis.exact ?? {}, { observe: () => ({ marks: { ...marks }, outcome, trace, events: events.length }) });
  // A server-rendered document carries capture.js's checkpoint script.
  const served = !!document.querySelector('script[type="application/vnd.exact.checkpoint"]');
  return {
    mounted: guarded(() => {
      const c0 = performance.now();
      marks.boot = marks.commit = c0;
      record('mark', { mark: 'commit' });
      // Mark the first few text leaves for Element Timing (before this task ends, so before their paint).
      const root = document.getElementById('exact-root');
      let n = 0;
      for (const el of root?.querySelectorAll('*') ?? []) {
        if (n >= 4) break;
        if (el.childElementCount === 0 && el.textContent.trim()) el.setAttribute('elementtiming', `exact-boot-${n++}`);
      }
      presentFrom(c0, served);
      After.push(guarded(() => { changed(); queueMicrotask(evaluate); }));
      // The boot tree committed before these hooks: evaluate it, so a page that settles at once has its TTI candidate.
      changed(); queueMicrotask(evaluate);
      // Loading can end with no commit after it (a module, a canvas): evaluate then too, as a change.
      InflightDrops.push(guarded(() => { if (!outcome || (nav && !nav.done)) { changed(); queueMicrotask(evaluate); } }));
      // An app with no router has no router change to name its launch route.
      if (onTop === null) record('navigation.launch', { ...route(here()), url: here() });
    }),
  };
}

/** A page hidden before its services loaded keeps its journal, so the next page's services send it. */
function keepJournal() {
  if (services.length || !launch.length || !journalKey) return;
  try { localStorage.setItem(journalKey, JSON.stringify({ session, config: launch[0].config, events: events.slice(-512) })); } catch {}
}

function loadServices() {
  for (const m of launch) {
    import(/* @vite-ignore */ m.url).then(mod => {
      const s = mod.start(m.config, { boot: marks.activation, session });
      services.push(s);
      for (const e of events) s.event(e);
    }).catch(e => console.error(`exact: ${m.name} service: ${e}`));
  }
}
