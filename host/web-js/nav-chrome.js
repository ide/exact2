// The navigation chrome the native hosts project from a navigation root's
// `navigation*` props (LLP 1038; NavigationIOS.swift, ModalIOS.swift), drawn
// by the page: a tab bar over the tabs' rows (`navigationTab…`), a bar per
// route that declares a `navigationTitle` (large or inline, a back button,
// a `navigationTrailing` bar button), push and pop as slides, and a
// `navigationPresentation="modal"` route as a sheet at its
// `navigationDetent` heights. An app's module imports this when its plan
// names a title or a tab (emit.rs); it draws in each projection
// (document.js `projectRoots`, after navigation.js `project`, which stays
// the authority for which route shows), the first one included, so the
// chrome is in the app's first paint, and its rules are in the page's sheet
// (nav-chrome.css). Its markup is built from attributes alone, with the
// DOM a render has (dom.js); a page's own copy takes over markup it finds.
// The browser animates the large title on scroll (the CSS); script adds
// only behaviour: presses, transitions, a sheet's drag.
//
// Contract owns every route, as on iOS: a tab tap presses the tab's
// `navigationTabControl`, a back button (or the sheet's backdrop, or a drag
// down) presses the root's `navigationBack` control in the active route, a
// bar button the control its `navigationTrailing` names — the hidden
// controls an app authors for UIKit's chrome.
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
const data = (e, k) => e.getAttribute("data-navigation" + k) ?? "";
const presentation = r => ["modal", "fullscreen"].includes(attr(r, "navigationPresentation")) ? attr(r, "navigationPresentation") : "";
const kids = e => [...e.childNodes].filter(n => n.nodeType === 1);
const routesOf = nav => kids(nav).filter(r => r.hasAttribute("navigationKey"));
const reduced = () => Live && matchMedia("(prefers-reduced-motion: reduce)").matches;
const States = new Map();
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
    Probe.style.cssText = "position:fixed;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top,0px) 0 env(safe-area-inset-bottom,0px)";
    document.body.append(Probe);
  }
  const cs = getComputedStyle(Probe);
  return { top: parseFloat(cs.paddingTop) || 0, bottom: parseFloat(cs.paddingBottom) || 0 };
}

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

/** Whether `el` is a control this chrome presses (a tab's, a route's
 * `navigationTrailing`, the root's back under a bar's back button): the
 * agent's tap on it is delivered as the chrome's (agent.js), as the iOS
 * host's `activate`. */
function standsIn(e) {
  const nav = e.id && e.closest("[navigationBack]");
  if (!nav || !States.has(nav)) return false;
  const routes = routesOf(nav), route = routes.find(r => r.contains(e));
  if (routes.some(r => data(r, "tabcontrol") === e.id)) return true;
  if (route && data(route, "trailing") === e.id) return true;
  return !!route && e.id === attr(nav, "navigationBack") && !!route.querySelector(":scope > [data-exact-navbar] [data-exact-nav=back]");
}

/** The chrome of every navigation root under `root`, after a projection. */
export function update(root) {
  if (Live) (globalThis.exact ??= {}).chrome ??= { standsIn };
  const navs = Live ? root.querySelectorAll("[navigationBack]") : root.getElementsByTagName("*").filter(e => e.hasAttribute("navigationBack"));
  for (const nav of navs) project(nav);
  for (const [nav, st] of States) if (!nav.isConnected) States.delete(nav);
}
navChrome(update);

function project(nav) {
  const routes = routesOf(nav);
  const chromed = routes.some(r => r.hasAttribute("data-navigationtitle") || data(r, "tab"));
  let st = States.get(nav);
  if (!chromed) {
    if (st) { settle(st); States.delete(nav); }
    for (const k of kids(nav)) if (k.hasAttribute("data-exact-tabbar") || k.hasAttribute("data-exact-backdrop")) k.remove();
    return;
  }
  if (!st) { States.set(nav, st = { tab: null, top: null, stack: [], anims: [], shown: new Set() }); if (Live && !nav.$listened) { nav.$listened = true; listen(nav, st); } }
  const key = attr(nav, "navigationKey"), selected = routes.find(r => attr(r, "navigationKey") === key);
  if (!selected) return;
  const tabbed = routes.some(r => data(r, "tab"));
  const tab = tabbed ? data(selected, "tab") : null;
  const lane = tab == null ? routes : routes.filter(r => data(r, "tab") === tab);
  const stack = lane.slice(0, lane.indexOf(selected) + 1);
  // Each route's bar, insets and sheet, the hidden tabs' too (they keep theirs).
  const lanes = new Map();
  for (const r of routes) { const t = tab == null ? "" : data(r, "tab"); if (!lanes.has(t)) lanes.set(t, []); lanes.get(t).push(r); }
  for (const rows of lanes.values()) {
    let sheet = null;
    rows.forEach((r, i) => {
      if (presentation(r)) sheet = r;
      route(nav, r, i > 0 && !presentation(r) ? rows[i - 1] : null, sheet, tabbed);
    });
  }
  tabBar(nav, tabbed ? routes : [], tab);
  backdrop(nav, st, stack.find(r => presentation(r) === "modal"));
  if (Live) transition(nav, st, tab, stack);
  for (const e of st.shown) if (e.isConnected) e.style.visibility = "";
}

/** One route's bar (when it has a title), its sheet, and the attributes
 * its insets follow (nav-chrome.css). */
function route(nav, r, previous, sheet, tabbed) {
  const title = r.getAttribute("data-navigationtitle") ?? "";
  const large = title !== "" && data(r, "largetitle") !== "false";
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
    fillBar(nav, r, bar, title, large, previous, !!sheet && presentation(sheet) === "modal" && r === sheet && attr(sheet, "data-navigationdetent").trim().split(/\s+/).length > 1);
  }
  scroller(r, bar);
}

function makeBar() {
  return el("div", "", { "data-exact-navbar": "" },
    el("div", "edge"), el("div", "bg"),
    el("div", "bar", {}, el("div", "lead"), el("div", "title", { role: "heading", "aria-level": "1" }), el("div", "trail")),
    el("div", "large", { "aria-hidden": "true" }, el("h1")));
}

function fillBar(nav, r, bar, title, large, previous, grabber) {
  setAttr(bar, "data-large", large ? "" : null);
  const row = part(bar, "bar"), t = title.trim();
  setText(part(row, "title"), t);
  setText(kids(part(bar, "large"))[0], t);
  // Back: over a route below it in its stack (and with an enabled back
  // control to press), the chevron with the previous title, or alone when
  // `navigationBackButton` is "minimal".
  const lead = part(row, "lead");
  const backs = control(r, attr(nav, "navigationBack"));
  const label = !previous || !backs || backs.hasAttribute("disabled") ? null
    : data(r, "backbutton") === "minimal" ? "" : ((previous.getAttribute("data-navigationtitle") ?? "").trim() || "Back");
  if (attr(lead, "data-want") !== (label == null ? "" : `back:${label}`)) {
    lead.setAttribute("data-want", label == null ? "" : `back:${label}`); lead.textContent = "";
    if (label != null) {
      const b = el("button", "", { type: "button", "data-exact-nav": "back", "aria-label": label ? `Back to ${label}` : "Back" }, glyph("chevron.left", 22));
      if (label) b.append(el("span", "", {}, label));
      lead.append(b);
    }
  }
  const trail = part(row, "trail"), target = data(r, "trailing"), symbol = data(r, "trailingsymbol");
  const want = target ? `${target}|${symbol}` : "";
  if (attr(trail, "data-want") !== want) {
    trail.setAttribute("data-want", want); trail.textContent = "";
    if (target) {
      const g = glyph(symbol, 20), b = el("button", "", { type: "button", "data-exact-nav": "trailing", "aria-label": control(r, target)?.getAttribute("aria-label") || symbol || target });
      if (g) b.append(g); else b.append(el("span", "", {}, target));
      trail.append(b);
    }
  }
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

/** `navigationDetent`'s heights, in points, smallest first. */
function detents(sheet) {
  if (presentation(sheet) === "fullscreen") return [Infinity];
  const H = sheet.parentNode?.clientHeight || innerHeight, { top, bottom } = safe();
  const large = H - top - 10;
  const all = attr(sheet, "data-navigationdetent").split(/\s+/).map(t => t === "medium" ? H / 2 : t === "large" ? large : Number(t) > 0 ? Math.min(Number(t) + bottom, large) : null).filter(h => h != null);
  return all.length ? all : [large];
}
function sheetTop(nav, r, sheet) {
  const heights = detents(sheet), H = nav.clientHeight;
  sheet.$detent = Math.min(sheet.$detent ?? heights.length - 1, heights.length - 1);
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
    else if (b.getAttribute("data-exact-nav") === "trailing") { if (!press(r, data(r, "trailing"))) press(nav, data(r, "trailing")); }
    else press(nav, b.getAttribute("data-control"));
  });
  nav.addEventListener("scrollend", ev => { const s = ev.target; if (s.hasAttribute?.("data-exact-inset")) s.$y = s.scrollTop; }, { capture: true, passive: true });
  let drag = null;
  nav.addEventListener("pointerdown", ev => {
    const bar = ev.target.closest?.("[data-exact-navbar][data-drag]"), r = bar?.parentNode;
    if (!bar || ev.target.closest("button") || !nav.contains(bar)) return;
    const heights = detents(r), H = nav.clientHeight;
    drag = { r, bar, y: ev.clientY, top: H - heights[r.$detent ?? heights.length - 1], tops: heights.map(h => H - h), last: ev.clientY, lt: performance.now(), v: 0 };
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
    const { r, tops } = drag, H = nav.clientHeight, max = Math.max(...tops);
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

function backdrop(nav, st, sheet) {
  let b = kids(nav).find(k => k.hasAttribute("data-exact-backdrop"));
  if (!sheet) { if (b && !st.anims.length) b.remove(); return; }
  b ??= el("div", "", { "data-exact-backdrop": "" });
  if (b.parentNode !== nav || b.nextSibling) nav.append(b);
}

/** The tab bar: one item per tab, in its rows' order, from its first
 * row's `navigationTab…`; a tap presses that tab's control. */
function tabBar(nav, routes, selected) {
  const tabs = [];
  for (const r of routes) { const t = data(r, "tab"); if (t && !tabs.some(x => x.tab === t)) tabs.push({ tab: t, r }); }
  let bar = kids(nav).find(k => k.hasAttribute("data-exact-tabbar"));
  if (!tabs.length) { bar?.remove(); return; }
  bar ??= el("div", "", { "data-exact-tabbar": "", role: "tablist" });
  const want = tabs.map(({ tab, r }) => [tab, data(r, "tabtitle"), data(r, "tabsymbol"), data(r, "tabselectedsymbol"), data(r, "tabcontrol"), tab === selected].join("|")).join("\n");
  if (attr(bar, "data-want") !== want) {
    bar.setAttribute("data-want", want); bar.textContent = "";
    for (const { tab, r } of tabs) {
      const on = tab === selected, title = data(r, "tabtitle") || tab;
      const b = el("button", "", { type: "button", role: "tab", "aria-selected": String(on), "data-control": data(r, "tabcontrol") });
      const g = glyph(on ? data(r, "tabselectedsymbol") || data(r, "tabsymbol") : data(r, "tabsymbol"), 22);
      if (g) b.append(el("span", "icon", {}, g));
      b.append(el("span", "", {}, title));
      bar.append(b);
    }
    bar.style.setProperty("--tabs", String(tabs.length));
  }
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
    const b = dim() ?? el("div", "", { "data-exact-backdrop": "" });
    nav.insertBefore(b, leaving);
    run(b, [{ opacity: 1 }, { opacity: 0 }], { duration: 320, fill: "forwards" });
  } else if (pushed) {
    show(from);
    run(top, [{ transform: "translateX(100%)", boxShadow: "0 0 0 #0000" }, { transform: "translateX(0)", boxShadow: "-8px 0 24px #00000026" }]);
    run(from, [{ transform: "translateX(0)", filter: "brightness(1)" }, { transform: "translateX(-30%)", filter: "brightness(.9)" }]);
  } else {
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
  e.inert = true;
  nav.append(e);
  const s = e.$inset;
  if (s && s !== e && s.$y) s.scrollTop = s.$y;
}
