// The page around the app, after each commit (the JS target's document.js
// `markDocument`) or batch (glue.js): what the browser draws outside the
// app's own boxes, and the few controls whose look the base sheet
// (index.html) needs a fact for.
//
// - The canvas and the browser's bars take the app's background: `<html>`
//   is painted in the root view's background, and `theme-color` (Safari's
//   status bar and toolbar tint, a standalone page's status bar) in the
//   background under the top edge, the top page's, so no band of another
//   colour shows in the safe areas a `viewport-fit=cover` root draws under.
//   Both follow the scheme as the app's colours do (`light-dark()`).
// - A `dialog` whose `open` the app holds (`data-open`, element.rs's name
//   for the prop) is shown modally while it is true and closed when it
//   turns false, as the native hosts present a held dialog as their alert.
// - A range's filled track: `--exact-range-fill`, its value's fraction of
//   `min`…`max`, which the slider's track reads.
// - Safari applies `:active` (the press feedback the sheet draws) only to a
//   touch that some listener hears, and still pinch-zooms a page that says
//   `user-scalable=no`: a passive listener, and a `gesturestart` refused.

let Installed = false, Tint = null, Canvas = null;

function install() {
  Installed = true;
  addEventListener("touchstart", () => {}, { passive: true });
  if (/user-scalable=no/.test(document.querySelector('meta[name="viewport"]')?.content ?? "")) {
    document.addEventListener("gesturestart", ev => ev.preventDefault());
  }
  document.addEventListener("input", ev => { if (ev.target.type === "range") fill(ev.target); }, true);
  matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", () => requestAnimationFrame(tint));
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
  if (canvas !== Canvas) { Canvas = canvas; document.documentElement.style.backgroundColor = canvas ?? ""; }
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
