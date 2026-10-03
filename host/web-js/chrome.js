// The navigation chrome the native hosts project from a navigation root's
// `navigation*` props (LLP 1038; NavigationIOS.swift, ModalIOS.swift), drawn
// by the page: a tab bar over the tabs' rows (`navigationTab…`), a bar per
// route that declares a `navigationTitle` (large or inline, a back button,
// a `navigationTrailing` bar button), push and pop as slides, and a
// `navigationPresentation="modal"` route as a sheet at its
// `navigationDetent` heights. Loaded by document.js once a root's routes
// name one of these, after each projection (navigation.js `project`), which
// stays the authority for which route shows; this module only draws.
//
// Contract owns every route, as on iOS: a tab tap presses the tab's
// `navigationTabControl`, a back button (or the sheet's backdrop, or a drag
// down) presses the root's `navigationBack` control in the active route, a
// bar button the control its `navigationTrailing` names — the hidden
// controls an app authors for UIKit's chrome. The chrome's insets reach
// the route as `--exact-nav-top` and `--exact-nav-bottom`, and pad the
// route's first scroller (or the route), as UIKit insets it.
import * as Symbols from "./symbols.js";

const NAV = "[data-exact-navbar]", BAR = 44, SHEET_BAR = 56, LARGE = 52;
const TAB_BOTTOM = "max(calc(env(safe-area-inset-bottom, 0px) - 12px), 10px)", TAB_H = 62;
const STYLE = `
[data-exact-inset]{box-sizing:border-box!important;padding-top:calc(var(--exact-own-pt,0px) + var(--exact-nav-top,0px))!important;padding-bottom:calc(var(--exact-own-pb,0px) + var(--exact-nav-bottom,0px))!important;scroll-padding-top:var(--exact-nav-top,0px);scroll-padding-bottom:var(--exact-nav-bottom,0px)}
${NAV}{position:absolute;top:0;left:0;right:0;z-index:20;pointer-events:none;font:17px/1.3 system-ui,-apple-system,sans-serif;color:var(--exact-label,light-dark(#000,#fff));-webkit-user-select:none;user-select:none;--bar-top:env(safe-area-inset-top,0px)}
[data-exact-sheet]>${NAV}{--bar-top:0px}
${NAV}>.bg{position:absolute;inset:0 0 auto;height:calc(var(--bar-top) + var(--bar-h));background:light-dark(#f9f9f9c7,#1d1d1dc7);-webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);box-shadow:0 .5px 0 var(--exact-separator,light-dark(#3c3c434a,#54545899));opacity:0;transition:opacity .2s}
${NAV}[data-scrolled]>.bg{opacity:1}
${NAV}>.bar{position:absolute;left:0;right:0;top:var(--bar-top);height:var(--bar-h);display:flex;align-items:center;padding:0 16px;gap:8px;box-sizing:border-box}
${NAV} .title{position:absolute;left:96px;right:96px;text-align:center;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:opacity .15s}
${NAV}[data-large]:not([data-collapsed]) .title{opacity:0}
${NAV} .lead,${NAV} .trail{display:flex;align-items:center;pointer-events:auto}
${NAV} .trail{margin-left:auto}
${NAV} button{all:unset;box-sizing:border-box;display:flex;align-items:center;justify-content:center;gap:2px;min-width:44px;height:44px;border-radius:22px;color:var(--exact-label,light-dark(#000,#fff));cursor:pointer;-webkit-tap-highlight-color:transparent;background:light-dark(#ffffffb8,#2c2c2eb8);-webkit-backdrop-filter:blur(12px) saturate(160%);backdrop-filter:blur(12px) saturate(160%);box-shadow:0 2px 10px #0000001a,inset 0 0 0 .5px light-dark(#0000000f,#ffffff1f)}
${NAV} button[data-label]{padding:0 14px 0 10px}
${NAV} button:active{opacity:.6}
${NAV} button:focus-visible{outline:2px solid var(--exact-accent,AccentColor);outline-offset:2px}
${NAV} svg{flex:none}
${NAV}>.large{position:absolute;left:0;right:0;top:calc(var(--bar-top) + var(--bar-h));height:${LARGE}px;clip-path:inset(0 0 -200px 0);pointer-events:none}
${NAV}>.large>h1{margin:0;padding:0 16px;font:700 34px/${LARGE}px system-ui,-apple-system,sans-serif;letter-spacing:.01em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transform:translateY(calc(var(--exact-y,0px) * -1));transform-origin:16px 50%}
${NAV} .grab{position:absolute;top:5px;left:50%;width:36px;height:5px;margin-left:-18px;border-radius:3px;background:var(--exact-tertiary-label,light-dark(#3c3c434d,#ebebf54d))}
${NAV}[data-drag]{pointer-events:auto;touch-action:none}
[data-exact-sheet]{top:var(--exact-sheet-top,0px)!important;z-index:40!important;border-radius:28px 28px 0 0;overflow:hidden;box-shadow:0 0 30px #00000026}
[data-exact-sheet="fullscreen"]{border-radius:0}
[data-exact-sheet]::before{content:none!important}
[data-exact-backdrop]{position:absolute;inset:0;z-index:35;background:light-dark(#00000033,#00000066);-webkit-tap-highlight-color:transparent}
[data-exact-ghost]{pointer-events:none}
[data-exact-tabbar]{position:absolute;left:50%;transform:translateX(-50%);width:min(calc(100% - 42px),calc(var(--tabs) * 90px + 8px));bottom:${TAB_BOTTOM};height:${TAB_H}px;z-index:30;display:flex;padding:4px;box-sizing:border-box;border-radius:${TAB_H / 2}px;background:light-dark(#ffffffe0,#1c1c1ee0);-webkit-backdrop-filter:blur(24px) saturate(180%);backdrop-filter:blur(24px) saturate(180%);box-shadow:0 8px 30px #0000001f,inset 0 0 0 .5px light-dark(#0000000f,#ffffff1f);font:500 10px/1.2 system-ui,-apple-system,sans-serif;-webkit-user-select:none;user-select:none}
[data-exact-tabbar] button{all:unset;flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;border-radius:${TAB_H / 2 - 4}px;color:var(--exact-label,light-dark(#000,#fff));cursor:pointer;-webkit-tap-highlight-color:transparent;transition:background-color .2s}
[data-exact-tabbar] button[aria-selected="true"]{color:var(--exact-system-blue,light-dark(#007aff,#0a84ff));background:var(--exact-tertiary-fill,light-dark(#7676801f,#7676803d))}
[data-exact-tabbar] button:focus-visible{outline:2px solid var(--exact-accent,AccentColor);outline-offset:-2px}
[data-exact-tabbar] .icon{height:28px;display:flex;align-items:center;justify-content:center}
`;
// Bar glyphs the page draws itself when no symbol table has them.
const OWN = {
  "chevron.left": "M15 4.5 7.5 12l7.5 7.5",
  xmark: "M6 6l12 12M18 6 6 18",
};

const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
const attr = (e, k) => e.getAttribute(k) ?? "";
const data = (e, k) => e.getAttribute("data-navigation" + k) ?? "";
const presentation = r => ["modal", "fullscreen"].includes(attr(r, "navigationPresentation")) ? attr(r, "navigationPresentation") : "";
const routesOf = nav => [...nav.children].filter(r => r.hasAttribute("navigationKey"));
const States = new Map();
let Styled = false, Probe = null;

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

/** A symbol by SF Symbols name at `size` points: the SF table's
 * (symbols.js `symbolSVG`, the glyphs `image "symbol:sf/…"` draws), the
 * page's own bar glyphs, or nothing (a tab then shows its title alone). */
function glyph(name, size) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  if (name && Symbols.hasSymbol?.(name)) {
    const t = document.createElement("template");
    t.innerHTML = Symbols.symbolSVG(name, { size, weight: 500 });
    return t.content.firstElementChild;
  }
  if (!OWN[name]) return null;
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("width", size); svg.setAttribute("height", size);
  svg.innerHTML = `<path d="${OWN[name]}" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>`;
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

export function update(root) {
  if (!Styled) { Styled = true; document.head.append(Object.assign(document.createElement("style"), { textContent: STYLE })); addEventListener("resize", () => update(root)); }
  for (const nav of root.querySelectorAll("[navigationBack]")) project(nav);
  for (const [nav, st] of States) if (!nav.isConnected) { st.tabbar?.remove(); States.delete(nav); }
}

function project(nav) {
  const routes = routesOf(nav);
  let st = States.get(nav);
  const chromed = routes.some(r => r.hasAttribute("data-navigationtitle") || data(r, "tab"));
  if (!chromed) {
    if (st) { settle(st); st.tabbar?.remove(); st.backdrop?.remove(); States.delete(nav); }
    return;
  }
  if (!st) States.set(nav, st = { tab: null, top: null, stack: [], anims: [], shown: new Set() });
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
  tabBar(nav, st, tabbed ? routes : [], tab);
  backdrop(nav, st, stack.find(r => presentation(r) === "modal"));
  transition(nav, st, tab, stack);
  for (const e of st.shown) if (e.isConnected) e.style.visibility = "";
}

/** One route's bar (when it has a title), its sheet, and its insets. */
function route(nav, r, previous, sheet, tabbed) {
  const title = r.getAttribute("data-navigationtitle");
  const inSheet = !!sheet, kind = sheet ? presentation(sheet) : "";
  if (inSheet) { r.setAttribute("data-exact-sheet", kind); sheetTop(nav, r, sheet); }
  else if (r.hasAttribute("data-exact-sheet")) { r.removeAttribute("data-exact-sheet"); r.style.removeProperty("--exact-sheet-top"); }
  let bar = r.$bar;
  if (title == null || title === "") { bar?.remove(); r.$bar = null; }
  else {
    if (!bar || bar.parentNode !== r) bar = r.$bar = makeBar(nav, r);
    if (bar !== r.lastElementChild) r.append(bar);
    fillBar(nav, r, bar, title, previous, inSheet && kind === "modal" && detents(sheet).length > 1 && r === sheet);
  }
  const large = !!r.$bar && data(r, "largetitle") !== "false";
  const top = !r.$bar ? "0px" : `calc(${inSheet ? "0px" : "env(safe-area-inset-top, 0px)"} + ${(inSheet ? SHEET_BAR : BAR) + (large ? LARGE : 0)}px)`;
  const bottom = inSheet ? "env(safe-area-inset-bottom, 0px)" : tabbed ? `calc(${TAB_BOTTOM} + ${TAB_H + 8}px)` : "0px";
  if (r.style.getPropertyValue("--exact-nav-top") !== top) r.style.setProperty("--exact-nav-top", top);
  if (r.style.getPropertyValue("--exact-nav-bottom") !== bottom) r.style.setProperty("--exact-nav-bottom", bottom);
  scroller(r);
}

function makeBar(nav, r) {
  const bar = document.createElement("div");
  bar.setAttribute("data-exact-navbar", "");
  bar.innerHTML = '<div class="bg"></div><div class="bar"><div class="lead"></div><div class="title" role="heading" aria-level="1"></div><div class="trail"></div></div><div class="large"><h1 aria-hidden="true"></h1></div>';
  const lead = bar.querySelector(".lead"), trail = bar.querySelector(".trail");
  lead.addEventListener("click", ev => { ev.stopPropagation(); if (ev.target.closest("button")) back(nav, r); });
  trail.addEventListener("click", ev => { ev.stopPropagation(); if (ev.target.closest("button") && !press(r, data(r, "trailing"))) press(nav, data(r, "trailing")); });
  return bar;
}

function fillBar(nav, r, bar, title, previous, draggable) {
  const large = data(r, "largetitle") !== "false", inSheet = r.hasAttribute("data-exact-sheet");
  bar.style.setProperty("--bar-h", `${inSheet ? SHEET_BAR : BAR}px`);
  bar.toggleAttribute("data-large", large);
  const t = title.trim();
  const inline = bar.querySelector(".title"), h1 = bar.querySelector("h1");
  if (inline.textContent !== t) inline.textContent = t;
  if (h1.textContent !== t) h1.textContent = t;
  bar.querySelector(".large").hidden = !large;
  // Back: over a route below it in its stack, the chevron alone when
  // `navigationBackButton` is "minimal", else with the previous title.
  const lead = bar.querySelector(".lead");
  // (None without an enabled back control to press: a back that would be refused.)
  const pressable = [...r.querySelectorAll("[id]")].some(n => n.id === attr(nav, "navigationBack") && !n.matches(":disabled"));
  const label = !previous || !pressable ? null : data(r, "backbutton") === "minimal" ? "" : ((previous.getAttribute("data-navigationtitle") ?? "").trim() || "Back");
  if (lead.$label !== label) {
    lead.$label = label; lead.textContent = "";
    if (label != null) {
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("aria-label", label || "Back");
      b.append(glyph("chevron.left", 20));
      if (label) { b.setAttribute("data-label", ""); b.append(label); }
      lead.append(b);
    }
  }
  const trail = bar.querySelector(".trail"), target = data(r, "trailing"), symbol = data(r, "trailingsymbol");
  const want = target ? `${target}|${symbol}` : "";
  if (trail.$want !== want) {
    trail.$want = want; trail.textContent = "";
    if (target) {
      const b = document.createElement("button"), g = glyph(symbol, 19);
      b.type = "button";
      const control = [...r.querySelectorAll("[id]")].find(n => n.id === target);
      b.setAttribute("aria-label", control?.getAttribute("aria-label") || symbol || target);
      if (g) b.append(g); else { b.setAttribute("data-label", ""); b.textContent = control?.getAttribute("aria-label") || target; }
      trail.append(b);
    }
  }
  let grab = bar.querySelector(".grab");
  if (draggable && !grab) { grab = document.createElement("div"); grab.className = "grab"; bar.prepend(grab); }
  else if (!draggable && grab) grab.remove();
  if (r.hasAttribute("data-exact-sheet") && !bar.$drag) { bar.$drag = true; bar.setAttribute("data-drag", ""); drag(nav, r, bar); }
  else if (!r.hasAttribute("data-exact-sheet") && bar.$drag) { bar.$drag = false; bar.removeAttribute("data-drag"); }
}

/** The route's first scroller (or the route itself) takes the insets, its
 * own padding kept; its scroll collapses the large title. */
function scroller(r) {
  let s = r.$scroller;
  if (!s || !s.isConnected || !r.contains(s)) {
    const queue = [...r.children];
    s = null;
    while (queue.length && !s) {
      const e = queue.shift();
      if (e === r.$bar || e.hasAttribute("popover") || !e.getClientRects().length) continue;
      if (e.hasAttribute("data-scroll") || /auto|scroll/.test(getComputedStyle(e).overflowY)) s = e;
      else queue.push(...e.children);
    }
    s ??= r;
    if (r.$scroller && r.$scroller !== s) unmark(r.$scroller);
    r.$scroller = s;
    if (!s.hasAttribute("data-exact-inset")) {
      const cs = getComputedStyle(s);
      s.style.setProperty("--exact-own-pt", cs.paddingTop); s.style.setProperty("--exact-own-pb", cs.paddingBottom);
      s.setAttribute("data-exact-inset", "");
    }
    if (s !== r) {
      const follow = () => { r.$y = s.scrollTop; collapse(r); };
      s.addEventListener("scroll", follow, { passive: true });
      s.$unfollow = () => s.removeEventListener("scroll", follow);
    }
  }
  collapse(r);
}
function unmark(s) {
  s.removeAttribute("data-exact-inset"); s.style.removeProperty("--exact-own-pt"); s.style.removeProperty("--exact-own-pb");
  s.$unfollow?.(); s.$unfollow = null;
}
function collapse(r) {
  const bar = r.$bar, s = r.$scroller;
  if (!bar) return;
  const y = s && s !== r ? s.scrollTop : 0, large = bar.hasAttribute("data-large");
  bar.style.setProperty("--exact-y", `${Math.max(-200, Math.min(y, LARGE + 8))}px`);
  bar.toggleAttribute("data-collapsed", large && y > LARGE - 12);
  bar.toggleAttribute("data-scrolled", large ? y > LARGE - 2 : y > 0);
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

/** A sheet's bar drags it between its heights, and below the smallest
 * dismisses it (its back pressed), as UIKit's sheet does. */
function drag(nav, r, bar) {
  let start = null;
  bar.addEventListener("pointerdown", ev => {
    if (ev.target.closest("button") || !r.hasAttribute("data-exact-sheet") || presentation(r) === "fullscreen") return;
    const heights = detents(r), H = nav.clientHeight;
    start = { y: ev.clientY, t: performance.now(), top: H - heights[r.$detent ?? heights.length - 1], tops: heights.map(h => H - h), last: ev.clientY, lt: performance.now(), v: 0 };
    ev.preventDefault(); bar.setPointerCapture(ev.pointerId);
    r.style.transition = "none";
  });
  bar.addEventListener("pointermove", ev => {
    if (!start) return;
    const now = performance.now();
    start.v = (ev.clientY - start.last) / Math.max(1, now - start.lt); start.last = ev.clientY; start.lt = now;
    const min = Math.min(...start.tops), max = Math.max(...start.tops);
    let top = start.top + ev.clientY - start.y;
    if (top < min) top = min - Math.pow(min - top, 0.7);
    r.style.setProperty("--exact-sheet-top", `${Math.min(top, max)}px`);
    r.$drop = Math.max(0, top - max);
    r.style.transform = r.$drop ? `translateY(${r.$drop}px)` : "";
  });
  const end = ev => {
    if (!start) return;
    const { tops } = start, H = nav.clientHeight, max = Math.max(...tops);
    const top = start.top + (start.last - start.y) + Math.max(-2.5, Math.min(2.5, start.v)) * 80;
    start = null;
    r.style.transition = reduced() ? "" : "top .3s cubic-bezier(.2,.8,.2,1), transform .3s cubic-bezier(.2,.8,.2,1)";
    if (top > max + (H - max) * 0.35 && back(nav, r)) return;
    let best = 0;
    tops.forEach((t, i) => { if (Math.abs(t - top) < Math.abs(tops[best] - top)) best = i; });
    r.$detent = best; r.$drop = 0; r.style.transform = "";
    r.style.setProperty("--exact-sheet-top", `${tops[best]}px`);
  };
  bar.addEventListener("pointerup", end);
  bar.addEventListener("pointercancel", end);
}

function backdrop(nav, st, sheet) {
  if (!sheet) { if (st.backdrop && !st.anims.length) { st.backdrop.remove(); st.backdrop = null; } return; }
  if (!st.backdrop) {
    const b = st.backdrop = document.createElement("div");
    b.setAttribute("data-exact-backdrop", "");
    b.addEventListener("click", ev => { ev.stopPropagation(); const top = routesOf(nav).find(r => attr(r, "navigationKey") === attr(nav, "navigationKey")); if (top) back(nav, top); });
  }
  if (st.backdrop.parentNode !== nav || st.backdrop.nextElementSibling !== null) nav.append(st.backdrop);
}

/** The tab bar: one item per tab, in its rows' order, from its first
 * row's `navigationTab…`; a tap presses that tab's control. */
function tabBar(nav, st, routes, selected) {
  const tabs = [];
  for (const r of routes) { const t = data(r, "tab"); if (t && !tabs.some(x => x.tab === t)) tabs.push({ tab: t, r }); }
  if (!tabs.length) { st.tabbar?.remove(); st.tabbar = null; return; }
  let bar = st.tabbar;
  if (!bar) {
    bar = st.tabbar = document.createElement("div");
    bar.setAttribute("data-exact-tabbar", ""); bar.setAttribute("role", "tablist");
    bar.addEventListener("click", ev => {
      ev.stopPropagation();
      const b = ev.target.closest("button");
      if (b) press(nav, b.$control);
    });
  }
  const want = tabs.map(({ tab, r }) => [tab, data(r, "tabtitle"), data(r, "tabsymbol"), data(r, "tabselectedsymbol"), data(r, "tabcontrol"), tab === selected].join("|")).join("\n");
  if (bar.$want !== want) {
    bar.$want = want; bar.textContent = "";
    for (const { tab, r } of tabs) {
      const b = document.createElement("button"), on = tab === selected;
      b.type = "button"; b.setAttribute("role", "tab"); b.setAttribute("aria-selected", String(on));
      b.$control = data(r, "tabcontrol");
      const title = data(r, "tabtitle") || tab, g = glyph(on ? data(r, "tabselectedsymbol") || data(r, "tabsymbol") : data(r, "tabsymbol"), 24);
      if (g) { const icon = document.createElement("span"); icon.className = "icon"; icon.append(g); b.append(icon); }
      b.append(Object.assign(document.createElement("span"), { textContent: title }));
      bar.append(b);
    }
  }
  bar.style.setProperty("--tabs", tabs.length);
  if (st.tabbar.parentNode !== nav) nav.append(st.tabbar);
  // Under a sheet the bar stays below it (the backdrop is appended after).
  if (st.backdrop?.parentNode === nav) nav.append(st.backdrop);
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
  if (sheetIn) {
    const t = presentation(top) === "fullscreen" ? "100%" : "110%";
    run(top, [{ transform: `translateY(${t})` }, { transform: "translateY(0)" }]);
    if (st.backdrop) run(st.backdrop, [{ opacity: 0 }, { opacity: 1 }]);
  } else if (sheetOut) {
    show(leaving);
    const drop = leaving.$drop || 0;
    run(leaving, [{ transform: `translateY(${drop}px)` }, { transform: "translateY(110%)" }], { duration: 320, fill: "forwards" });
    if (!st.backdrop) { backdrop(nav, st, leaving); nav.insertBefore(st.backdrop, leaving); }
    run(st.backdrop, [{ opacity: 1 }, { opacity: 0 }], { duration: 320, fill: "forwards" });
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
  Promise.all(anims.map(a => a.finished.catch(() => {}))).then(() => { if (st.anims === anims) settle(st); });
}

/** Ends any transition: animations finish, ghosts leave, and what showed
 * only for it hides again as the projection had it. */
function settle(st) {
  const anims = st.anims;
  st.anims = [];
  for (const a of anims) { try { a.cancel(); } catch {} }
  for (const e of st.shown) {
    if (e.hasAttribute("data-exact-ghost")) { e.$scroller && unmark(e.$scroller); e.remove(); continue; }
    const under = !!st.top && !!presentation(st.top) && st.stack[st.stack.length - 2] === e;
    if (e !== st.top && !under) e.style.visibility = "hidden";
  }
  st.shown.clear();
  if (st.backdrop && !st.stack.some(r => presentation(r) === "modal")) { st.backdrop.remove(); st.backdrop = null; }
}

/** A route Contract removed, back in its root for its exit only: inert,
 * no longer a route, its scroll where it was. */
function ghost(nav, e) {
  e.setAttribute("data-exact-ghost", "");
  e.removeAttribute("navigationKey"); e.removeAttribute("data-testid");
  e.inert = true;
  nav.append(e);
  if (e.$scroller && e.$scroller !== e && e.$y) e.$scroller.scrollTop = e.$y;
}
