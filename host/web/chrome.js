// The page around the app, after each commit (the JS target's document.js
// `markDocument`) or batch (glue.js): what the browser draws outside the
// app's own boxes, and the few controls whose look the base sheet
// (index.html) needs a fact for.
//
// - The canvas and the browser's bars take the app's background: `<html>`
//   is painted in the root view's background (also `--exact-canvas`, which
//   a sheet's backdrop dims for Safari's top bar, nav-chrome.css), and
//   `theme-color` (the status bar and toolbar tint of Safari before 26,
//   which tints its bars from the canvas and fixed boxes at the edges) in
//   the background under the top edge, the top page's, so no band of
//   another colour shows in the safe areas a `viewport-fit=cover` root
//   draws under. Both follow the scheme as the app's colours do
//   (`light-dark()`). A Home Screen app is marked `data-standalone` (the
//   sheet's body fills its screen).
// - A `dialog` whose `open` the app holds (`data-open`, element.rs's name
//   for the prop) is shown modally while it is true and closed when it
//   turns false, as the native hosts present a held dialog as their alert.
// - A range's filled track: `--exact-range-fill`, its value's fraction of
//   `min`…`max`, which the slider's track reads.
// - A hairline box (css.rs `hairline`) is one device pixel where the browser draws a
//   thin border a whole point: `--exact-hairline` and `--exact-hairline-fill`.
// - Safari applies `:active` (a native button's look) only to a touch that
//   some listener hears, and still pinch-zooms a page that says
//   `user-scalable=no`: a passive listener, and a `gesturestart` refused.
//   (A press, held and let go as UIKit's are, is touch.js's, loaded after
//   first paint: the sheet draws its `data-held`.)

let Installed = false, Tint = null, Canvas = null;

function install() {
  Installed = true;
  addEventListener("touchstart", () => {}, { passive: true });
  if (navigator.standalone) document.documentElement.setAttribute("data-standalone", "");
  if (/user-scalable=no/.test(document.querySelector('meta[name="viewport"]')?.content ?? "")) {
    document.addEventListener("gesturestart", ev => ev.preventDefault());
  }
  document.addEventListener("input", ev => { if (ev.target.type === "range") fill(ev.target); }, true);
  hairlines();
  matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", () => requestAnimationFrame(tint));
}

/** A hairline box is a border one device pixel thick (css.rs `hairline`), as WebKit snaps
 * a thin border; where the browser draws it a whole point instead (Chromium), it is its
 * background one device pixel tall, which a layout in device pixels keeps whole. */
function hairlines() {
  if (devicePixelRatio <= 1) return;
  const probe = document.createElement("div");
  probe.style.cssText = "position:absolute;visibility:hidden;height:0;border-top:.5px solid";
  document.body.append(probe);
  const thick = probe.getBoundingClientRect().height >= 1;
  probe.remove();
  if (!thick) return;
  const s = document.documentElement.style;
  s.setProperty("--exact-hairline", "0px");
  s.setProperty("--exact-hairline-fill", `${1 / devicePixelRatio}px`);
}

function fill(e) {
  const min = e.min === "" ? 0 : +e.min, max = e.max === "" ? 100 : +e.max;
  const f = max > min ? Math.min(1, Math.max(0, (e.valueAsNumber - min) / (max - min))) : 0;
  const v = String(Math.round(f * 1e4) / 1e4);
  if (e.style.getPropertyValue("--exact-range-fill") !== v) e.style.setProperty("--exact-range-fill", v);
}

const clear = c => !c || c === "transparent" || /^rgba\(.*,\s*0\)$/.test(c) || /\/\s*0\)$/.test(c);
/** The first painted background at or above `e`, within the app (the page's
 * own, which this paints, never answers). */
function under(e) {
  for (; e && e.nodeType === 1 && e.id !== "exact-root"; e = e.parentElement) {
    const c = getComputedStyle(e).backgroundColor;
    if (!clear(c)) return c;
  }
  return null;
}

function tint() {
  const root = document.getElementById("exact-root")?.firstElementChild;
  if (!root) return;
  const canvas = under(root);
  if (canvas !== Canvas) {
    Canvas = canvas;
    const s = document.documentElement.style;
    s.backgroundColor = canvas ?? "";
    if (canvas) s.setProperty("--exact-canvas", canvas); else s.removeProperty("--exact-canvas");
  }
  // A modal's backdrop is not the page: the bars keep the page's colour.
  if (document.querySelector("dialog:modal")) return;
  const top = under(document.elementFromPoint(innerWidth / 2, 0)) ?? canvas;
  if (top === Tint) return;
  Tint = top;
  let m = document.querySelector('meta[name="theme-color"]');
  if (!top) return m?.remove();
  if (!m) { m = document.createElement("meta"); m.name = "theme-color"; document.head.append(m); }
  m.content = top;
}

export function pageChrome() {
  if (typeof getComputedStyle !== "function" || globalThis.__exactRender) return;
  if (!Installed) install();
  // A dialog takes focus itself as it opens, as a native alert shows no focused button
  // (a keyboard's Tab still reaches them, ringed).
  for (const d of document.querySelectorAll("dialog:not([autofocus])")) d.autofocus = true;
  for (const d of document.querySelectorAll("dialog[data-open]")) {
    const held = d.getAttribute("data-open") === "true";
    if (held && !d.open && d.isConnected) { try { d.showModal(); } catch {} }
    else if (!held && d.open && d.$held) d.close();
    d.$held = held;
  }
  for (const e of document.querySelectorAll('input[type="range"]')) fill(e);
  tint();
}
// The wasm host loads this after first paint (glue.js `loadAfterPaint`).
if (typeof globalThis.document !== "undefined") (globalThis.exact ??= {}).pageChrome = pageChrome;
