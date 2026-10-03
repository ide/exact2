// Stdlib entries the JS target keeps out of rt.js: an app's module imports
// this only when its plan calls one (LLP 1047 D1's pay-for-what-you-use).
//
// `formatDate` and `formatNumber` are the browser's `Intl` in `en-US`, with
// the options the runner's Rust copies (runner/src/format.rs, LLP
// 1054.000.003 D2, D3). The wasm target and native keep the Rust: the JS
// target's strings follow the browser's ICU, a deviation LLP 1001 declares.

const FIRST = -62135596800000, LAST = 253402300799999;
let medium, monthYear, compact;
/** `Sep 26, 2026` or `September 2026` of (epoch ms, UTC offset minutes east); `""` out of range (D7). */
export function x_formatDate(ms, off, style) {
  if (!Number.isFinite(ms) || !Number.isFinite(off) || Math.abs(off) > 1080) return "";
  const wall = Math.trunc(ms) + off * 60000;
  if (wall < FIRST || wall > LAST) return "";
  const f = style === "month-year"
    ? monthYear ??= new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric", timeZone: "UTC" })
    : medium ??= new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeZone: "UTC" });
  return f.format(wall);
}
/** `1.2K`, `999K`, `0.29`, `-1.2K`: compact, truncated, `0` for `-0`; `""` when not finite (D7). */
export function x_formatNumber(n, style) {
  if (!Number.isFinite(n)) return "";
  compact ??= new Intl.NumberFormat("en-US", { notation: "compact", roundingMode: "trunc", signDisplay: "negative" });
  return compact.format(n);
}
/** `at(list, i)`: the item at `i` truncated toward zero, from the end when negative; `null` past either end. */
export function x_at(l, i) {
  const t = Math.trunc(i), k = t < 0 ? l.length + t : t;
  return k >= 0 && k < l.length ? l[k] : null;
}
