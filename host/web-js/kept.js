// Kept answers on the JS target (LLP 1027 D4, as ruled 2026-09-03), for
// rt.js: a store-reading resource's last fresh answer, kept in the page's
// storage so the next launch's first frame paints what the device last knew,
// before any source answers; the resource is asked as always, and its fresh
// answer replaces the kept one. As the runner keeps them
// (runner/src/runner/kept.rs): one entry a resource, by its name, holding
// its arguments (one canonical list) and its value, hex, joined by `|`, at
// most 8 KB; never the runner's facts; never the app's (the store's secrets
// are "exact.secret.<name>", these "exact.kept.<name>", out of its reach).
// Shown when its identifying arguments (those before a `with`) equal the
// resource's at boot and its value still fits the declared shape; anything
// else is simply not used. Each entry also names its source, so a resource
// redirected to another source does not show the old one's answer (the
// runner's reload rule, LLP 1007).
//
// The web's own rule beside the runner's: when the store's set of names
// changes (a secret kept that was absent, or forgotten — signing in or out,
// a demo left for a real account), every kept answer is forgotten, in the
// commit that changed it, so a reload never paints the last account's data;
// answers asked afterwards are kept again. A refreshed token, a secret
// rewritten, leaves them.
import { conforms, eq, skip } from "./shape.js";

const PREFIX = "exact.kept.";
/** The largest kept answer, encoded (`MAX_KEPT_BYTES`): a session, a list of names — never a feed. */
const MAX = 8 * 1024;
const utf8 = new TextEncoder(), text = new TextDecoder("utf-8", { fatal: true });

/** Canonical bytes (`Value::encode`, plan/src/value.rs) of `v`, by type code `t` from `i`. */
function put(out, v, t, i) {
  if (out.length > MAX) throw out;
  const c = t[i[0]++];
  if (c === "n") { const b = new DataView(new ArrayBuffer(8)); b.setFloat64(0, v, true); out.push(0, ...new Uint8Array(b.buffer)); }
  else if (c === "b") out.push(1, v ? 1 : 0);
  else if (c === "s") { const b = utf8.encode(v); out.push(2); u32(out, b.length); for (const x of b) out.push(x); }
  else if (c === "u") out.push(3);
  else if (c === "?") { if (v == null) { out.push(4); skip(t, i); } else { out.push(5); put(out, v, t, i); } }
  else if (c === "[") { out.push(6); u32(out, v.length); const at = i[0]; for (const x of v) { i[0] = at; put(out, x, t, i); } i[0] = at; skip(t, i); }
  else if (c === "{") { out.push(7); u32(out, v.length); for (const x of v) put(out, x, t, i); i[0]++; }
}
const u32 = (out, n) => out.push(n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24);
const hex = bytes => { let s = ""; for (const b of bytes) s += (b < 16 ? "0" : "") + b.toString(16); return s; };

/** One value from canonical bytes, as the runtime holds it: lists and
 * records arrays, unit and `none` null, `some(v)` v. Bounded in depth, and
 * refusing a non-finite number, as `Value::decode`; throws on damage. */
function get(b, at, depth) {
  if (depth > 64) throw 0;
  const tag = b[at[0]++], n = () => { const d = new DataView(b.buffer, b.byteOffset + at[0], 4); at[0] += 4; return d.getUint32(0, true); };
  if (tag === 0) { const v = new DataView(b.buffer, b.byteOffset + at[0], 8).getFloat64(0, true); at[0] += 8; if (!isFinite(v)) throw 0; return v; }
  if (tag === 1) return b[at[0]++] !== 0;
  if (tag === 2) { const k = n(); if (at[0] + k > b.length) throw 0; at[0] += k; return text.decode(b.subarray(at[0] - k, at[0])); }
  if (tag === 3 || tag === 4) return null;
  if (tag === 5) return get(b, at, depth + 1);
  if (tag === 6 || tag === 7) { const k = n(), out = []; for (let j = 0; j < k; j++) { if (at[0] >= b.length) throw 0; out.push(get(b, at, depth + 1)); } return out; }
  throw 0;
}
function value(h) {
  if (!/^(?:[0-9a-fA-F]{2})*$/.test(h)) throw 0;
  const b = new Uint8Array(h.length / 2);
  for (let k = 0; k < b.length; k++) b[k] = parseInt(h.substr(k * 2, 2), 16);
  const at = [0], v = get(b, at, 0);
  if (at[0] !== b.length) throw 0;
  return v;
}

/** `res`'s `keep` (rt.js) is [the identifying arguments' count, the
 * source's parameter type codes, the bake's reader flag]; a resource the
 * bake did not see read the store is kept once an answer of its does. */
export const Kept = {
  /** Off under the agent and in a render (a drive's state is its own); read at the first resource's. */
  on: undefined,
  /** What storage holds, by resource name (read once, at boot). */
  held: new Map(),
  /** This commit's writes: [name, text] or [name, null], and `null` to forget every one. */
  writes: [],
  load(on) {
    this.on = on;
    if (on) try { for (let k = 0; k < localStorage.length; k++) { const n = localStorage.key(k); if (n.startsWith(PREFIX)) this.held.set(n.slice(PREFIX.length), localStorage.getItem(n)); } } catch {}
  },
  /** The answer kept for `name` from `source`: [args, value], the value
   * fitting `type` and the arguments `params` (the source's parameter type
   * codes, concatenated), else nothing. */
  seed(name, source, type, params, driven) {
    if (this.on === undefined) this.load(!driven());
    const e = this.on && this.held.get(name);
    if (!e || !e.startsWith(source + "|")) return;
    try {
      const [a, v] = e.slice(source.length + 1).split("|"), args = value(a), val = value(v);
      const i = [0];
      if (!Array.isArray(args) || !args.every(x => i[0] < params.length && conforms(x, params, i)) || i[0] !== params.length) return;
      if (conforms(val, type)) return [args, val];
    } catch {}
  },
  /** Whether a kept answer for `kept` stands for the arguments `args`: the
   * same count, and the first `identity` equal (all of them without a `with`). */
  stands: (kept, args, identity) => kept.length === args.length && eq(kept.slice(0, identity), args.slice(0, identity)),
  /** Keep a fresh answer, unless it is too large to keep. */
  keep(name, source, params, args, v, type) {
    if (!this.on) return;
    try {
      const a = [6], b = [];
      u32(a, args.length);
      const i = [0];
      for (const x of args) put(a, x, params, i);
      put(b, v, type, [0]);
      if (2 * (a.length + b.length) + 1 > MAX) return;
      this.writes.push([name, `${source}|${hex(a)}|${hex(b)}`]);
    } catch {}
  },
  /** The store's names changed: forget every kept answer. */
  forget() { if (this.on) this.writes.push(null); },
  save() { return this.writes.length; },
  restore(n) { this.writes.length = n; },
  /** After a commit stands, as the store's secrets. */
  persist() {
    for (const w of this.writes.splice(0)) try {
      if (w === null) {
        for (const n of this.held.keys()) localStorage.removeItem(PREFIX + n);
        this.held.clear();
      } else if (this.held.get(w[0]) !== w[1]) { localStorage.setItem(PREFIX + w[0], w[1]); this.held.set(w[0], w[1]); }
    } catch {}
  },
};
