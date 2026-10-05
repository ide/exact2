// The navigation chrome the iOS host projects from a navigation root's
// routes (LLP 1075.003; NavigationBarIOS.swift, NavigationTabsIOS.swift),
// drawn by the page where the app asks for it (app.json
// `host.web.navigationChrome: "ios"`; the build then imports this): a bar
// per header-shaped route — its first child a `header` holding one heading,
// which is the bar's title (large for a level-1 heading, inline otherwise),
// the header's buttons before the heading its leading items and those after
// it its trailing ones, the root's Back control in the route UIKit's back
// button — and a tab bar from the root's own tablist (each tab names its
// tabpanel with `aria-controls`; the panel's routes are the tab's stack),
// push and pop as slides, and a `navigationPresentation="modal"` route as a
// sheet at its `navigationDetent` heights. The header and the tablist it
// stands in for are not painted while it does (`data-exact-lifted`), as iOS
// lifts them; under the agent (`?agent`) it draws nothing and the page paints
// them as authored (LLP 1021 D4). It draws in each projection (document.js
// `projectRoots`, after navigation.js `project`, which stays the authority
// for which route shows), the first one included, so the chrome is in the
// app's first paint, and its rules are in the page's sheet (nav-chrome.css).
// Its markup is built from attributes alone, with the DOM a render has
// (dom.js); a page's own copy takes over markup it finds. The browser
// animates the large title on scroll (the CSS); script adds only behaviour:
// presses, transitions, a sheet's drag.
//
// In a browser, the page's own root (the outermost, in no route or scroller)
// scrolls the document, as UIKit's window scrolls its top screen: its top
// route's first scroller is the page's (`data-exact-doc`), so Safari draws
// it under its status bar and toolbar and a tap on the status bar scrolls
// it to the top.
// The other routes keep their DOM, undisplayed, each with the offset it had
// when it left the page, which it has again when it returns (a tab switch,
// a push, a pop); one shown beside the page's (a slide's two, a pop's
// ghost) is a box in the document where the viewport is, with its own
// scroller at that offset, and a sheet a fixed box. A sheet locks the
// document while it is up.
//
// Contract owns every route, as on iOS: a tab tap clicks the authored tab, a
// back button (or the sheet's backdrop, or a drag down) presses the root's
// `navigationBack` control in the active route, a bar item the authored
// button it stands for.
import { navChrome } from "./document.js";
import * as Symbols from "./symbols.js";

const SVG = "http://www.w3.org/2000/svg";
const Live = typeof getComputedStyle === "function";
// Bar glyphs the page draws itself when no symbol table has them.
const OWN = {
  "chevron.left": ["0 0 24 24", "M15 4.5 7.5 12l7.5 7.5"],
  xmark: ["0 0 24 24", "M6 6l12 12M18 6 6 18"],
};

const attr = (e, k) => e.getAttribute(k) ?? "";
const presentation = r => ["modal", "fullscreen"].includes(attr(r, "navigationPresentation")) ? attr(r, "navigationPresentation") : "";
const kids = e => [...e.childNodes].filter(n => n.nodeType === 1);
/** Every element under `e` in document order, not entering `stop`. */
function* below(e, stop = () => false) { for (const k of kids(e)) { yield k; if (!stop(k)) yield* below(k, stop); } }
const isRoute = e => e.hasAttribute("navigationKey");
const routesIn = e => kids(e).filter(isRoute);
/** The root's own tablist (not one inside a route) and the tabs naming a
 * tabpanel of this root, in tab order — the stacks, as navigation.js and
 * the iOS host find them (NavigationTabs.swift). */
function tabsOf(nav) {
  const list = [...below(nav, isRoute)].find(e => attr(e, "role") === "tablist");
  if (!list) return [];
  const panels = new Map([...below(nav, isRoute)].filter(e => attr(e, "role") === "tabpanel").map(e => [attr(e, "id"), e]));
  return kids(list).filter(t => attr(t, "role") === "tab" && panels.has(attr(t, "aria-controls")))
    .map(tab => ({ tab, panel: panels.get(attr(tab, "aria-controls")), name: attr(tab, "aria-controls") }));
}
const tablistOf = nav => [...below(nav, isRoute)].find(e => attr(e, "role") === "tablist") ?? null;
const routesOf = nav => { const tabs = tabsOf(nav); return tabs.length ? tabs.flatMap(t => routesIn(t.panel)) : routesIn(nav); };
/** A route's tab: the tabpanel holding it, by id ("" without tabs). */
const tabOf = r => attr(r.parentNode, "role") === "tabpanel" ? attr(r.parentNode, "id") : "";
/** The SF name a node's symbol image draws, if it has one. */
const symbolIn = e => { const i = [e, ...below(e)].find(k => attr(k, "data-symbol-source").startsWith("symbol:sf/")); return i ? attr(i, "data-symbol-source").slice(10) : ""; };
const pressable = e => e.localName === "button" || attr(e, "data-exact-on").split(" ").includes("press");
const heading = e => /^h[1-6]$/.test(e.localName) || e.hasAttribute("aria-level");
/** A header-shaped route's bar (HeaderShape, NavigationBarIOS.swift): its
 * first child a `header` holding exactly one heading; the header's buttons
 * before the heading lead, those after it trail. */
function shapeOf(r) {
  const header = kids(r).find(k => !k.hasAttribute("data-exact-navbar"));
  if (header?.localName !== "header") return null;
  const heads = [], lead = [], trail = [];
  for (const e of below(header, k => pressable(k) || heading(k) || attr(k, "role") === "tablist")) {
    if (heading(e)) heads.push(e);
    else if (pressable(e)) (heads.length ? trail : lead).push(e);
  }
  if (heads.length !== 1) return null;
  const level = Number(attr(heads[0], "aria-level") || heads[0].localName.slice(1)) || 2;
  return { header, title: heads[0].textContent.trim(), large: level === 1, lead, trail };
}
const reduced = () => Live && matchMedia("(prefers-reduced-motion: reduce)").matches;
const States = new Map();
// A Home Screen app keeps its routes' own scrollers: there iOS 26 lays the
// page out in a viewport the status bar's height short of the screen and
// pans the fixed bars away with the document's first scroll.
const Standalone = Live && (navigator.standalone === true || matchMedia("(display-mode: standalone)").matches);
const Agent = Live && new URLSearchParams(location.search).has("agent");
let Probe = null;

/** An element of `tag` with class `cls`, attributes and children. */
function el(tag, cls, attrs = {}, ...children) {
  const e = document.createElement(tag);
  if (cls) e.setAttribute("class", cls);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  e.append(...children);
  return e;
}
const part = (e, cls) => kids(e).find(k => attr(k, "class") === cls);
function setText(e, t) { if (e.textContent !== t) e.textContent = t; }
function setAttr(e, k, v) { if (v == null) { if (e.hasAttribute(k)) e.removeAttribute(k); } else if (e.getAttribute(k) !== String(v)) e.setAttribute(k, v); }

/** The page's safe-area insets, as numbers (sheet heights are computed). */
function safe() {
  if (!Probe) {
    Probe = document.createElement("div");
    Probe.style.cssText = "position:fixed;inset:0;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top,0px) 0 env(safe-area-inset-bottom,0px)";
    document.body.append(Probe);
  }
  const cs = getComputedStyle(Probe);
  return { top: parseFloat(cs.paddingTop) || 0, bottom: parseFloat(cs.paddingBottom) || 0 };
}
/** The height a root's sheets rise in: the viewport's where the root
 * scrolls the page (the root is then as tall as its page), else its own. */
const tall = nav => nav.hasAttribute("data-exact-page") ? (safe(), Probe.getBoundingClientRect().height) : nav.clientHeight;

/** A symbol by SF Symbols name at `size` points: the SF table's (the
 * glyphs `image "symbol:sf/…"` draws), the page's own bar glyphs, or
 * nothing (a tab then shows its title alone). */
function glyph(name, size) {
  const g = name ? Symbols.sfGlyph?.(name, size, 500) : null;
  const [box, d] = g ? [g.viewBox, g.path] : OWN[name] ?? [];
  if (!d) return null;
  const svg = document.createElementNS(SVG, "svg"), path = document.createElementNS(SVG, "path");
  const w = g ? g.width : size, h = g ? g.height : size;
  for (const [k, v] of [["aria-hidden", "true"], ["width", +w.toFixed(2)], ["height", +h.toFixed(2)], ["viewBox", box]]) svg.setAttribute(k, v);
  path.setAttribute("d", d);
  if (g) { path.setAttribute("fill", "currentColor"); if (g.stroke) for (const [k, v] of [["stroke", "currentColor"], ["stroke-width", g.stroke], ["stroke-linejoin", "round"]]) path.setAttribute(k, v); }
  else for (const [k, v] of [["fill", "none"], ["stroke", "currentColor"], ["stroke-width", "2.2"], ["stroke-linecap", "round"], ["stroke-linejoin", "round"]]) path.setAttribute(k, v);
  svg.append(path);
  return svg;
}

/** Presses the control with HTML id `id` (in `scope`), as a UIKit bar
 * button or tab would; false when there is none to press. */
function press(scope, id) {
  if (!id) return false;
  const c = [...scope.querySelectorAll("[id]")].find(n => n.id === id && !n.closest("[data-exact-ghost]"));
  if (!c || c.matches(":disabled") || c.closest("[inert]")) return false;
  c.click();
  return true;
}
/** The root's back, from its active route (navigation.js `pressBack`). */
function back(nav, route) {
  if (presentation(route) && attr(route, "closedby") === "none") return false;
  return press(route, attr(nav, "navigationBack"));
}
/** The control with HTML id `id` in a route (outside its bar and popovers). */
function control(route, id) {
  const stack = kids(route);
  while (stack.length) {
    const e = stack.pop();
    if (e.hasAttribute("data-exact-navbar") || e.hasAttribute("popover")) continue;
    if (id && attr(e, "id") === id) return e;
    stack.push(...kids(e));
  }
  return null;
}

/** Whether `el` is a control this chrome stands in for (a lifted tab or
 * header button): a tap on it is delivered as the chrome's (agent.js), as
 * the iOS host's `activate`. Under the agent the chrome draws nothing, so
 * there it is never one. */
function standsIn(e) {
  const nav = e.closest("[navigationBack]");
  if (!nav || !States.has(nav)) return false;
  return !!e.closest("[data-exact-lifted]");
}

/** The chrome of every navigation root under `root`, after a projection. */
export function update(root) {
  // Under the agent the page paints the authored header and tablist (LLP 1021 D4).
  if (Agent) return;
  if (Live) (globalThis.exact ??= {}).chrome ??= { standsIn };
  const navs = Live ? root.querySelectorAll("[navigationBack]") : root.getElementsByTagName("*").filter(e => e.hasAttribute("navigationBack"));
  for (const nav of navs) project(nav);
  for (const [nav, st] of States) if (!nav.isConnected) States.delete(nav);
  if (Live) {
    const page = [...States.keys()].find(n => n.hasAttribute("data-exact-page"));
    setAttr(document.documentElement, "data-exact-docnav", page ? "" : null);
    if (page && Paged === false) floor();
    Paged = !!page;
    // The page keeps each route's offset itself: the browser's own restoring, as its Back
    // pops a route, would scroll the document under a slide's two boxes.
    if (page && history.scrollRestoration !== "manual") history.scrollRestoration = "manual";
    const locked = !!page && States.get(page).locked;
    setAttr(document.documentElement, "data-exact-locked", locked ? "" : null);
    if (locked !== Locked) {
      Locked = locked;
      const on = locked ? addEventListener : removeEventListener;
      on("touchstart", aim, { passive: true }); on("touchmove", hold, { passive: false });
    }
  }
}
/** Whether the page scrolled the document at the last projection (null before the first). */
let Paged = null;
/** Safari paints the band under its toolbar in the colour of the fixed box it last read at the
 * viewport's bottom edge, and keeps it while that element is still rendered, even no longer
 * fixed: before the page scrolls the document the body is fixed (index.html), and the app's
 * root, which stays as the page's root, was that box (Lexy's sign-in screen, then Try Demo:
 * the band stayed the canvas over the content until a reload). A strip in the canvas at the
 * bottom edge for a second (Safari reads the edges only now and then: 400 ms was not always
 * read, 800 ms was), then gone, is the last box Safari read there, and it is no longer
 * rendered, so the band shows the page again. */
function floor() {
  const e = el("div", "", { "data-exact-floor": "", "aria-hidden": "true" });
  document.body.append(e);
  setTimeout(() => e.remove(), 1000);
}
/** While a sheet is up, a touch pans only a scroller in the sheet that can
 * scroll (Safari pans a document whose overflow is hidden, and hands it a
 * pan in a sheet with nothing to scroll); the listeners are there only then. */
let Locked = false, Pans = false;
function aim(ev) {
  Pans = false;
  const sheet = ev.target.closest?.("[data-exact-sheet]");
  for (let e = ev.target; sheet && e && e !== sheet.parentNode; e = e.parentElement)
    if (e.scrollHeight > e.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(e).overflowY)) { Pans = true; break; }
}
const hold = ev => { if (!Pans && ev.cancelable) ev.preventDefault(); };
navChrome(update);

// Safari reads its status bar's colour from the page's edge strip (`page`)
// again only as the set of fixed boxes changes: as the scheme changes, the
// strip is a new box, made once the page's canvas (chrome.js, a frame after
// the change) is the new one.
if (Live) matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", () => requestAnimationFrame(() => requestAnimationFrame(() => {
  for (const e of document.querySelectorAll("[data-exact-page] > [data-exact-edge]")) e.replaceWith(edge());
})));

function project(nav) {
  const routes = routesOf(nav), tabs = tabsOf(nav);
  const chromed = tabs.length > 0 || routes.some(r => shapeOf(r));
  let st = States.get(nav);
  if (!chromed) {
    if (st) { settle(st); States.delete(nav); }
    for (const k of kids(nav)) if (k.hasAttribute("data-exact-tabbar") || k.hasAttribute("data-exact-backdrop") || k.hasAttribute("data-exact-edge")) k.remove();
    for (const r of routes) for (const k of ["data-exact-doc", "data-exact-off"]) r.removeAttribute(k);
    for (const e of below(nav)) if (e.hasAttribute("data-exact-lifted")) e.removeAttribute("data-exact-lifted");
    nav.removeAttribute("data-exact-page");
    return;
  }
  if (!st) { States.set(nav, st = { tab: null, top: null, stack: [], anims: [], shown: new Set(), doc: null, over: new Set() }); if (Live && !nav.$listened) { nav.$listened = true; listen(nav, st); } }
  const paged = Live && !Standalone && !nav.parentElement?.closest("[navigationKey], [data-scroll]");
  setAttr(nav, "data-exact-page", paged ? "" : null);
  if (!paged) for (const k of kids(nav)) if (k.hasAttribute("data-exact-edge")) k.remove();
  const key = attr(nav, "navigationKey"), selected = routes.find(r => attr(r, "navigationKey") === key);
  if (!selected) return;
  const tabbed = tabs.length > 0;
  const tab = tabbed ? tabOf(selected) : null;
  const lane = tab == null ? routes : routes.filter(r => tabOf(r) === tab);
  const stack = lane.slice(0, lane.indexOf(selected) + 1);
  // The page's offset, kept by the route leaving it while it is still there.
  if (paged && st.doc && (st.doc !== pageRoute(stack) || st.top !== stack[stack.length - 1]) && st.doc.isConnected && st.doc.hasAttribute("data-exact-doc")) st.doc.$docY = scrollY;
  // Each route's bar, insets and sheet, the hidden tabs' too (they keep theirs).
  const lanes = new Map();
  for (const r of routes) { const t = tab == null ? "" : tabOf(r); if (!lanes.has(t)) lanes.set(t, []); lanes.get(t).push(r); }
  for (const rows of lanes.values()) {
    let sheet = null;
    rows.forEach((r, i) => {
      if (presentation(r)) sheet = r;
      route(nav, r, i > 0 && !presentation(r) ? rows[i - 1] : null, sheet, tabbed);
    });
  }
  tabBar(nav, tabs, tab);
  backdrop(nav, st, stack.find(r => presentation(r) === "modal"));
  if (Live) transition(nav, st, tab, stack);
  for (const e of st.shown) if (e.isConnected) e.style.visibility = "";
  if (paged) page(nav, st, routes, stack);
}

/** The route whose scroller is the page's: the stack's top, or the route a
 * sheet (or a full-screen cover) is over. */
const pageRoute = stack => stack.findLast(r => !presentation(r)) ?? null;

/** The page's top edge, for Safari's status bar (nav-chrome.css). */
const edge = () => el("div", "", { "data-exact-edge": "", "aria-hidden": "true" });

/** Which route scrolls the document, which show beside it (each at its
 * own offset), and which are not displayed; on a change, the document has
 * the offset of the route that now scrolls it. During a slide none does:
 * both routes are boxes over the viewport (`place`), as a ghost is. */
function page(nav, st, routes, stack) {
  const top = stack[stack.length - 1];
  if (!kids(nav).some(k => k.hasAttribute("data-exact-edge"))) nav.append(edge());
  const want = st.anims.length && st.slide ? null : pageRoute(stack);
  const was = st.doc;
  let y = null;
  if (want !== was) {
    if (was && !want) place(nav);
    if (was) was.removeAttribute("data-exact-doc");
    // A route shown beside the page during a slide arrives at the offset it scrolled to there.
    if (want) { y = st.over.has(want) && want.$inset && want.$inset !== want ? want.$inset.scrollTop : want.$docY ?? 0; want.setAttribute("data-exact-doc", ""); }
    st.doc = want;
  }
  const over = new Set();
  for (const r of routes) {
    const off = r !== want && r !== top && !st.shown.has(r) && !(presentation(top) && r === stack[stack.length - 2]);
    setAttr(r, "data-exact-off", off ? "" : null);
    if (!off && r !== want) over.add(r);
  }
  for (const e of st.shown) if (e.isConnected && e !== want) over.add(e);
  // A route newly shown beside the page scrolls its own scroller to where it
  // left the page, its bar drawn as at that offset: Safari starts a scroll
  // timeline that was undisplayed only when its scroller next scrolls.
  for (const r of over) if (!st.over.has(r) && !presentation(r)) {
    if (r.$inset && r.$inset !== r && r.$docY != null) r.$inset.scrollTop = r.$docY;
    freeze(r, r.$docY ?? 0);
  }
  for (const r of st.over) if (!over.has(r)) freeze(r, null);
  st.over = over;
  st.locked = !!presentation(top);
  // The boxes between the root and the page's route (a tab's panel) are in
  // flow and grow with it, as the root does (nav-chrome.css `data-exact-docpath`).
  const path = new Set();
  for (let e = want?.parentNode; e && e !== nav; e = e.parentNode) path.add(e);
  for (const e of st.path ?? []) if (!path.has(e)) e.removeAttribute("data-exact-docpath");
  for (const e of path) setAttr(e, "data-exact-docpath", "");
  st.path = path;
  if (want) overlays(want);
  if (y != null && Math.abs(scrollY - y) > 0.5) scrollTo(0, y);
}

/** Where the routes shown beside the page are boxes in the document: the
 * viewport's top and height, read while the page's route still holds the
 * document's offset, and how far below it the browser may draw the page,
 * under its toolbar (the screen's height past the viewport's; nav-chrome.css). */
function place(nav) {
  const h = tall(nav);
  nav.style.setProperty("--exact-page-y", `${-nav.getBoundingClientRect().top}px`);
  nav.style.setProperty("--exact-page-h", `${h}px`);
  nav.style.setProperty("--exact-page-below", `${Math.min(Math.max(0, (screen?.height ?? 0) - h), 240)}px`);
}

/** A box the route lays over its scroller (absolute, outside the scroller:
 * a floating note, as a UIKit view over a scroll view) stays where it is on
 * the screen while the page scrolls: fixed, as long as the route is the page. */
function overlays(r) {
  const walk = e => {
    for (const k of e.children) {
      if (k === r.$inset || k.hasAttribute("data-exact-navbar")) continue;
      if (getComputedStyle(k).position === "absolute") k.setAttribute("data-exact-overlay", "");
      else walk(k);
    }
  };
  walk(r);
}

/** One route's bar (when it has a title), its sheet, and the attributes
 * its insets follow (nav-chrome.css). */
function route(nav, r, previous, sheet, tabbed) {
  const shape = shapeOf(r);
  const title = shape ? shape.title || " " : "";
  const large = !!shape?.large;
  // The header the bar stands in for is not painted (iOS lifts it into its bar).
  if (shape) setAttr(shape.header, "data-exact-lifted", "");
  else for (const k of kids(r)) if (k.hasAttribute("data-exact-lifted")) k.removeAttribute("data-exact-lifted");
  setAttr(r, "data-exact-chromed", "");
  setAttr(r, "data-exact-bar", title !== "" ? "" : null);
  setAttr(r, "data-exact-large", large ? "" : null);
  setAttr(r, "data-exact-tabbed", tabbed ? "" : null);
  setAttr(r, "data-exact-sheet", sheet ? presentation(sheet) : null);
  if (sheet && Live) sheetTop(nav, r, sheet);
  let bar = kids(r).find(k => k.hasAttribute("data-exact-navbar"));
  if (title === "") bar?.remove();
  else {
    if (!bar) { bar = makeBar(); r.append(bar); }
    fillBar(nav, r, bar, shape, title, large, previous, !!sheet && presentation(sheet) === "modal" && r === sheet && attr(sheet, "data-navigationdetent").trim().split(/\s+/).length > 1);
  }
  scroller(r, bar);
}

function makeBar() {
  return el("div", "", { "data-exact-navbar": "" },
    el("div", "bg"),
    el("div", "bar", {}, el("div", "lead"), el("div", "title", { role: "heading", "aria-level": "1" }), el("div", "trail")),
    el("div", "large", { "aria-hidden": "true" }, el("h1")));
}

/** A bar item for an authored button: its symbol, else its label or text. */
function item(c, nav) {
  const label = attr(c, "aria-label") || c.textContent.trim();
  const g = glyph(symbolIn(c), 20), b = el("button", "", { type: "button", "data-exact-nav": nav, "aria-label": label });
  if (g) b.append(g); else b.append(el("span", "", {}, label));
  b.$control = c;
  if (c.matches?.(":disabled")) b.setAttribute("disabled", "");
  return b;
}
/** Items for these buttons, rebuilt only when what they show changes. */
function items(box, controls, nav, extra = "") {
  const want = extra + controls.map(c => `${attr(c, "id")}|${attr(c, "aria-label")}|${symbolIn(c)}|${c.textContent.trim()}|${c.matches?.(":disabled") ?? false}`).join("\n");
  if (attr(box, "data-want") === want && kids(box).length === controls.length + (extra ? 1 : 0)) {
    // The same faces: their controls may be other nodes now (a re-render).
    kids(box).slice(extra ? 1 : 0).forEach((b, i) => { b.$control = controls[i]; });
    return false;
  }
  box.setAttribute("data-want", want); box.textContent = "";
  return true;
}

function fillBar(nav, r, bar, shape, title, large, previous, grabber) {
  setAttr(bar, "data-large", large ? "" : null);
  const row = part(bar, "bar"), t = title.trim();
  setText(part(row, "title"), t);
  setText(kids(part(bar, "large"))[0], t);
  // Back: over a route below it in its stack (and with an enabled back
  // control to press), UIKit's back button: the chevron alone when the
  // control's face is a symbol alone, else with its text (LLP 1075.003,
  // the iOS host's projection). Without a route below (a sheet's root), the
  // Back control is a leading item like the others.
  const lead = part(row, "lead"), back = attr(nav, "navigationBack");
  const backs = control(r, back);
  const text = backs?.textContent.trim() ?? "";
  const label = !previous || !backs || backs.hasAttribute("disabled") ? null : text;
  const leading = (shape?.lead ?? []).filter(c => !(previous && attr(c, "id") === back));
  if (items(lead, leading, "lead", label == null ? "" : `back:${label}\n`)) {
    if (label != null) {
      const b = el("button", "", { type: "button", "data-exact-nav": "back", "aria-label": label ? `Back to ${label}` : "Back" }, glyph("chevron.left", 22));
      if (label) b.append(el("span", "", {}, label));
      lead.append(b);
    }
    for (const c of leading) lead.append(item(c, "item"));
  }
  const trail = part(row, "trail"), trailing = shape?.trail ?? [];
  if (items(trail, trailing, "trail")) for (const c of trailing) trail.append(item(c, "item"));
  const grab = part(bar, "grab");
  if (grabber && !grab) bar.prepend(el("div", "grab"));
  else if (!grabber && grab) grab.remove();
  setAttr(bar, "data-drag", r.hasAttribute("data-exact-sheet") && presentation(r) === "modal" ? "" : null);
}

/** The route's first scroller (`data-scroll`, outside a popover), or the
 * route itself, takes its insets and names the timeline its bar animates on. */
function scroller(r, bar) {
  const queue = kids(r);
  let s = null;
  while (queue.length && !s) {
    const e = queue.shift();
    if (e === bar || e.hasAttribute("popover")) continue;
    if (attr(e, "data-scroll") === "true") s = e;
    else queue.push(...kids(e));
  }
  const at = s ?? r;
  if (r.$inset && r.$inset !== at) r.$inset.removeAttribute("data-exact-inset");
  r.$inset = at;
  setAttr(at, "data-exact-inset", s ? "" : "route");
}

/** A large title's bar as the scroll-driven animations draw it at offset
 * `y` (nav-chrome.css `data-exact-frozen`), or animated again (null). */
function freeze(r, y) {
  setAttr(r, "data-exact-frozen", y == null ? null : "");
  if (y == null) return;
  const L = parseFloat(getComputedStyle(r).getPropertyValue("--exact-nav-large-height")) || 52;
  r.style.setProperty("--exact-frozen-lift", `${-Math.min(Math.max(y, 0), L)}px`);
  r.style.setProperty("--exact-frozen-in", String(Math.min(1, Math.max(0, (y - (L - 26)) / 16))));
}

/** `navigationDetent`'s heights, in points, in its order. */
function detents(sheet) {
  if (presentation(sheet) === "fullscreen") return [Infinity];
  const H = (sheet.parentNode && tall(sheet.parentNode)) || innerHeight, { top, bottom } = safe();
  const large = H - top - 10;
  const all = attr(sheet, "data-navigationdetent").split(/\s+/).map(t => t === "medium" ? H / 2 : t === "large" ? large : Number(t) > 0 ? Math.min(Number(t) + bottom, large) : null).filter(h => h != null);
  return all.length ? all : [large];
}
function sheetTop(nav, r, sheet) {
  const heights = detents(sheet), H = tall(nav);
  // It opens at its first height, as the iOS host's sheet does (ModalIOS.swift).
  sheet.$detent = Math.min(sheet.$detent ?? 0, heights.length - 1);
  const top = heights[sheet.$detent] === Infinity ? 0 : Math.max(0, H - heights[sheet.$detent]);
  const v = `${top}px`;
  if (r.style.getPropertyValue("--exact-sheet-top") !== v) r.style.setProperty("--exact-sheet-top", v);
}

/** A root's behaviour, once: presses on its bars and tab bar, a sheet bar's
 * drag, the backdrop's tap, and each scroller's resting offset (for a
 * route's exit, kept as it leaves). */
function listen(nav, st) {
  nav.addEventListener("click", ev => {
    const b = ev.target.closest?.("[data-exact-navbar] button, [data-exact-tabbar] button, [data-exact-backdrop]");
    if (!b || !nav.contains(b)) return;
    ev.stopPropagation();
    const r = b.closest("[navigationKey]");
    if (b.hasAttribute("data-exact-backdrop")) { const top = routesOf(nav).find(x => attr(x, "navigationKey") === attr(nav, "navigationKey")); if (top) back(nav, top); }
    else if (b.getAttribute("data-exact-nav") === "back") back(nav, r);
    else if (b.$control) { if (!b.$control.matches?.(":disabled")) b.$control.click(); }
  });
  nav.addEventListener("scrollend", ev => { const s = ev.target; if (s.hasAttribute?.("data-exact-inset")) s.$y = s.scrollTop; }, { capture: true, passive: true });
  // The page's offset, as a press or the browser's Back may take its route
  // away (the commit that removes it clamps the document's): at each, and
  // where a scroll ends, never per frame.
  const keep = () => { if (st.doc?.isConnected && st.doc.hasAttribute("data-exact-doc")) st.doc.$docY = scrollY; };
  for (const t of ["pointerdown", "keydown", "popstate", "scrollend"]) addEventListener(t, keep, { capture: true, passive: true });
  let drag = null;
  nav.addEventListener("pointerdown", ev => {
    const bar = ev.target.closest?.("[data-exact-navbar][data-drag]"), r = bar?.parentNode;
    if (!bar || ev.target.closest("button") || !nav.contains(bar)) return;
    const heights = detents(r), H = tall(nav);
    drag = { r, bar, y: ev.clientY, top: H - heights[r.$detent ?? 0], tops: heights.map(h => H - h), last: ev.clientY, lt: performance.now(), v: 0 };
    ev.preventDefault(); bar.setPointerCapture(ev.pointerId);
    r.style.transition = "none";
  });
  nav.addEventListener("pointermove", ev => {
    if (!drag) return;
    const { r } = drag, now = performance.now();
    drag.v = (ev.clientY - drag.last) / Math.max(1, now - drag.lt); drag.last = ev.clientY; drag.lt = now;
    const min = Math.min(...drag.tops), max = Math.max(...drag.tops);
    let top = drag.top + ev.clientY - drag.y;
    if (top < min) top = min - Math.pow(min - top, 0.7);
    r.style.setProperty("--exact-sheet-top", `${Math.min(top, max)}px`);
    r.$drop = Math.max(0, top - max);
    r.style.transform = r.$drop ? `translateY(${r.$drop}px)` : "";
  });
  const end = () => {
    if (!drag) return;
    const { r, tops } = drag, H = tall(nav), max = Math.max(...tops);
    const top = drag.top + (drag.last - drag.y) + Math.max(-2.5, Math.min(2.5, drag.v)) * 80;
    drag = null;
    r.style.transition = reduced() ? "" : "top .3s cubic-bezier(.2,.8,.2,1), transform .3s cubic-bezier(.2,.8,.2,1)";
    if (top > max + (H - max) * 0.35 && back(nav, r)) return;
    let best = 0;
    tops.forEach((t, i) => { if (Math.abs(t - top) < Math.abs(tops[best] - top)) best = i; });
    r.$detent = best; r.$drop = 0; r.style.transform = "";
    r.style.setProperty("--exact-sheet-top", `${tops[best]}px`);
  };
  nav.addEventListener("pointerup", end);
  nav.addEventListener("pointercancel", end);
}

/** A sheet's backdrop. */
const dimmer = () => el("div", "", { "data-exact-backdrop": "" });
function backdrop(nav, st, sheet) {
  let b = kids(nav).find(k => k.hasAttribute("data-exact-backdrop"));
  if (!sheet) { if (b && !st.anims.length) b.remove(); return; }
  b ??= dimmer();
  if (b.parentNode !== nav || b.nextSibling) nav.append(b);
}

/** The tab bar: one item per tab of the root's tablist, a symbol over its
 * label (its `-fill` symbol when selected, as iOS draws it); a tap clicks
 * the authored tab, whose action selects it. The tablist it stands in for
 * is not painted (iOS's tab bar adopts it). */
function tabBar(nav, tabs, selected) {
  let bar = kids(nav).find(k => k.hasAttribute("data-exact-tabbar"));
  const list = tablistOf(nav);
  if (!tabs.length) { bar?.remove(); if (list) setAttr(list, "data-exact-lifted", null); return; }
  setAttr(list, "data-exact-lifted", "");
  bar ??= el("div", "", { "data-exact-tabbar": "", role: "tablist" });
  const face = t => [t.name, attr(t.tab, "aria-label") || t.tab.textContent.trim(), symbolIn(t.tab), t.name === selected];
  const want = tabs.map(t => face(t).join("|")).join("\n");
  if (attr(bar, "data-want") !== want) {
    bar.setAttribute("data-want", want); bar.textContent = "";
    for (const t of tabs) {
      const [, title, symbol, on] = face(t);
      const b = el("button", "", { type: "button", role: "tab", "aria-selected": String(on) });
      const g = (on && glyph(symbol + ".fill", 22)) || glyph(symbol, 22);
      if (g) b.append(el("span", "icon", {}, g));
      b.append(el("span", "", {}, title));
      bar.append(b);
    }
    bar.style.setProperty("--tabs", String(tabs.length));
  }
  kids(bar).forEach((b, i) => { b.$control = tabs[i]?.tab; });
  if (bar.parentNode !== nav) nav.append(bar);
  // Under a sheet the bar stays below it (the backdrop is appended after).
  const b = kids(nav).find(k => k.hasAttribute("data-exact-backdrop"));
  if (b) nav.append(b);
}

/** Push, pop, present and dismiss: the stack's top changing within one tab
 * slides or rises; a tab change swaps at once (as UIKit's does). */
function transition(nav, st, tab, stack) {
  const top = stack[stack.length - 1], from = st.top, before = st.stack;
  st.stack = stack; st.top = top;
  if (from === top || !from || st.tab !== tab) { st.tab = tab; return; }
  st.tab = tab;
  settle(st);
  st.slide = false;
  if (reduced()) return;
  const popped = stack.includes(from) === false && before.includes(top);
  const pushed = !popped && stack.includes(from);
  if (!popped && !pushed) return;
  const leaving = popped ? from : null;
  const sheetIn = pushed && presentation(top) && !presentation(from);
  const sheetOut = popped && presentation(from) && !presentation(top);
  const ease = "cubic-bezier(.2,.8,.2,1)", duration = 380;
  const show = e => { if (!e.isConnected) ghost(nav, e); st.shown.add(e); e.style.visibility = ""; };
  const run = (e, frames, extra = {}) => { const a = e.animate(frames, { duration, easing: ease, ...extra }); st.anims.push(a); return a; };
  const dim = () => kids(nav).find(k => k.hasAttribute("data-exact-backdrop"));
  if (sheetIn) {
    run(top, [{ transform: `translateY(${presentation(top) === "fullscreen" ? "100%" : "110%"})` }, { transform: "translateY(0)" }]);
    if (dim()) run(dim(), [{ opacity: 0 }, { opacity: 1 }]);
  } else if (sheetOut) {
    show(leaving);
    run(leaving, [{ transform: `translateY(${leaving.$drop || 0}px)` }, { transform: "translateY(110%)" }], { duration: 320, fill: "forwards" });
    const b = dim() ?? dimmer();
    nav.insertBefore(b, leaving);
    run(b, [{ opacity: 1 }, { opacity: 0 }], { duration: 320, fill: "forwards" });
  } else if (pushed) {
    st.slide = true;
    show(from);
    run(top, [{ transform: "translateX(100%)", boxShadow: "0 0 0 #0000" }, { transform: "translateX(0)", boxShadow: "-8px 0 24px #00000026" }]);
    run(from, [{ transform: "translateX(0)", filter: "brightness(1)" }, { transform: "translateX(-30%)", filter: "brightness(.9)" }]);
  } else {
    st.slide = true;
    show(leaving);
    run(leaving, [{ transform: "translateX(0)", boxShadow: "-8px 0 24px #00000026" }, { transform: "translateX(100%)", boxShadow: "0 0 0 #0000" }], { fill: "forwards" });
    run(top, [{ transform: "translateX(-30%)", filter: "brightness(.9)" }, { transform: "translateX(0)", filter: "brightness(1)" }]);
  }
  const anims = st.anims;
  Promise.all(anims.map(a => a.finished.catch(() => {}))).then(() => { if (st.anims === anims) { settle(st); project(nav); } });
}

/** Ends any transition: animations finish, ghosts leave, and what showed
 * only for it hides again as the projection had it. */
function settle(st) {
  const anims = st.anims;
  st.anims = [];
  for (const a of anims) { try { a.cancel(); } catch {} }
  for (const e of st.shown) {
    if (e.hasAttribute("data-exact-ghost")) { e.remove(); continue; }
    const under = !!st.top && !!presentation(st.top) && st.stack[st.stack.length - 2] === e;
    if (e !== st.top && !under) e.style.visibility = "hidden";
  }
  st.shown.clear();
}

/** A route Contract removed, back in its root for its exit only: inert,
 * no longer a route, its scroll where it was. */
function ghost(nav, e) {
  e.setAttribute("data-exact-ghost", "");
  e.removeAttribute("navigationKey"); e.removeAttribute("data-testid");
  for (const k of ["data-exact-doc", "data-exact-off"]) e.removeAttribute(k);
  e.inert = true;
  nav.append(e);
  const s = e.$inset, y = e.$docY ?? s?.$y;
  if (s && s !== e && y) s.scrollTop = y;
}
