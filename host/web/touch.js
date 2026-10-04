// A press as UIKit delivers one (UIControl's tracking, UIScrollView's
// `delaysContentTouches`), for the page's controls: the browser's `:active`
// and its click on lift are the web's, which iOS Safari shows at the touch
// down, in a scroller too, and fires after the finger has left the control.
// Loaded after first paint (the input glue installs it; the JS target's
// document.js, where no input glue loads); the base sheet (index.html,
// nav-chrome.css) draws a held control from `data-held`, the input glue
// its `press-scale`.
//
// - The control is the innermost pressable under the contact. With a mouse
//   it is held at once and while the pointer is inside its box.
// - A touch in a scroller is held only after DELAY ms without moving
//   (a quick tap shows it as it lifts); one that moves past SLOP first, or
//   whose scroller moves, or that the browser takes for a pan
//   (`pointercancel`), was a scroll: never held, never activated.
// - A touch in a scroller that lands while a scroller is still moving (a
//   flick's momentum, the frames after a scroll) only stops it. Fixed chrome
//   (a bar, the tab bar) is in no scroller: held at once, even then.
// - A touch activates only when it lifts within OUTSIDE px of the control's
//   box (UIKit's touch-up-inside): the click that follows any other touch
//   is refused, so a checkbox keeps its value and no `press` runs.
//
// Keyboard and assistive activation make clicks no tracked touch precedes,
// and pass. No scroll listener runs per frame: one hears the first scroll
// event, then is away for REARM ms.

const PRESSABLE = 'button, a[href], input[type="checkbox"], input[type="radio"], summary, [data-exact-on~="press"]';
const SLOP = 10, OUTSIDE = 24, DELAY = 120, RECENT = 150, REARM = 60;
const OPTS = { capture: true, passive: true };
const Watchers = new Set();
let G = null, Verdict = null, Scrolled = -Infinity, Installed = false;

/** `{ held(el, down), box?(el) }`: told as a control is held and let go. */
export function watchHeld(w) { Watchers.add(w); }
/** Ends the press without activation (input-glue.js: a pan began). */
export function cancelHeld() { if (G) kill(); }

function scrolled() {
  Scrolled = performance.now();
  removeEventListener("scroll", scrolled, OPTS);
  setTimeout(() => addEventListener("scroll", scrolled, OPTS), REARM);
}

/** The scrollers a touch on `el` could move: ancestors with overflow to scroll, up to
 * a fixed box (a bar, the tab bar, a sheet: chrome over the page, which no scroller
 * outside it moves, as a UIKit bar is no scroll view's content). */
function scrollers(el) {
  const out = [];
  if (getComputedStyle(el).position === "fixed") return out;
  for (let e = el.parentElement; e; e = e.parentElement) {
    const cs = getComputedStyle(e);
    if ((/auto|scroll/.test(cs.overflowY) && e.scrollHeight > e.clientHeight) || (/auto|scroll/.test(cs.overflowX) && e.scrollWidth > e.clientWidth)) out.push(e);
    if (cs.position === "fixed") return out;
  }
  const doc = document.scrollingElement;
  if (doc && doc.scrollHeight > doc.clientHeight && getComputedStyle(document.documentElement).overflowY !== "hidden") out.push(doc);
  return out;
}

function show(down) {
  if (!G || G.shown === down) return;
  G.shown = down;
  G.el.toggleAttribute("data-held", down);
  for (const w of Watchers) w.held(G.el, down);
}
function inside(ev) {
  const [l, t, r, b] = G.box, o = G.touch ? OUTSIDE : 0;
  return ev.clientX >= l - o && ev.clientX <= r + o && ev.clientY >= t - o && ev.clientY <= b + o;
}
const moved = () => G.scrolls.some(([s, y, x]) => s.scrollTop !== y || s.scrollLeft !== x);
function kill() { clearTimeout(G.timer); show(false); G.dead = true; }
function end(ok) {
  clearTimeout(G.timer);
  if (G.touch) Verdict = { ok, at: performance.now() };
  // A quick tap in a scroller shows its press as it lifts, as UIKit's.
  if (ok && !G.shown) { show(true); const g = G; setTimeout(() => { if (G === g) { show(false); G = null; } }, 100); return; }
  show(false); G = null;
}

function down(ev) {
  if (!ev.isPrimary || ev.button !== 0) return;
  Verdict = null;
  if (G) { clearTimeout(G.timer); show(false); G = null; }
  const el = ev.target.closest?.(PRESSABLE);
  if (!el || el.closest(':disabled, [disabled="true"], [inert]')) return;
  const touch = ev.pointerType !== "mouse";
  const scrolls = touch ? scrollers(el) : [];
  let box = null;
  for (const w of Watchers) box ??= w.box?.(el);
  const r = box ?? el.getBoundingClientRect();
  G = { el, id: ev.pointerId, touch, x: ev.clientX, y: ev.clientY, box: [r.left, r.top, r.right, r.bottom],
    scrolls: scrolls.map(s => [s, s.scrollTop, s.scrollLeft]), shown: false, armed: !scrolls.length, timer: 0,
    dead: touch && scrolls.length > 0 && performance.now() - Scrolled < RECENT };
  if (G.dead) return;
  if (G.armed) show(true);
  else G.timer = setTimeout(() => { if (moved()) return kill(); G.armed = true; show(true); }, DELAY);
}
function move(ev) {
  if (ev.pointerId !== G?.id || G.dead) return;
  if (!G.armed && Math.hypot(ev.clientX - G.x, ev.clientY - G.y) > SLOP) return kill();
  show(G.armed && inside(ev));
}
function up(ev) {
  if (ev.pointerId !== G?.id) return;
  if (G.dead) { end(false); return; }
  end(inside(ev) && !moved());
}
function cancel(ev) { if (ev.pointerId === G?.id) { kill(); end(false); } }

function click(ev) {
  const v = Verdict;
  if (!v || !ev.isTrusted) return;
  Verdict = null;
  if (v.ok || performance.now() - v.at > 1000) return;
  ev.preventDefault();
  ev.stopImmediatePropagation();
}

export function installTouch() {
  if (Installed) return;
  Installed = true;
  addEventListener("pointerdown", down, OPTS);
  addEventListener("pointermove", move, OPTS);
  addEventListener("pointerup", up, OPTS);
  addEventListener("pointercancel", cancel, OPTS);
  addEventListener("scroll", scrolled, OPTS);
  addEventListener("keydown", () => { Verdict = null; }, OPTS);
  addEventListener("click", click, { capture: true });
}
