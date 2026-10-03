// SF Symbols on the web (LLP 1035.004.000 D4, amended 2026-10-03): a
// `symbol:sf/<name>` draws the Material Symbols Rounded glyph sf-material.mjs
// pairs with it. The glyphs arrive from the build's `sf.js`, which imports
// this and registers them; a name with none draws nothing (D2's em square).
// Sized as SF sizes a symbol image: the glyph's own box at the point size
// (a circle's diameter is 1.12 em, as SF's is), its weight from the font's
// (400 is the drawn weight; heavier strokes the outline thicker).
const Glyphs = {};
/** `table`: SF name → [path, x, y, width, height] in Material's 960 box. */
export const sfGlyphs = table => Object.assign(Glyphs, table);
export const hasSymbol = name => Object.hasOwn(Glyphs, name);
const UNIT = 19 / 800 / 17; // SF's 17-point circle is 19 points; Material's is 800 units
/** The glyph's natural box and drawing at `size` (a point size, CSS px) and
 * `weight`, or null for a name without one: `{ width, height, viewBox, path, stroke }`. */
export function sfGlyph(name, size, weight = 400) {
  const g = Object.hasOwn(Glyphs, name) && Glyphs[name];
  if (!g) return null;
  const [path, x, y, w, h] = g, scale = size * UNIT;
  // Heavier than the drawn 400: Material's 700 strokes are half again 400's
  // 80 units, so the outline grows by that share, half outside the fill.
  const stroke = Math.max(0, Math.min(900, weight) - 400) * 40 / 300;
  const vw = w + stroke, vh = Math.max(h + stroke, size / scale);
  return { width: vw * scale, height: vh * scale, viewBox: `${x - (vw - w) / 2} ${y - (vh - h) / 2} ${vw} ${vh}`, path, stroke };
}
const svg = (g, paint) => `<svg xmlns="http://www.w3.org/2000/svg" width="${g.width}" height="${g.height}" viewBox="${g.viewBox}"><path d="${g.path}" fill="${paint}"${g.stroke ? ` stroke="${paint}" stroke-width="${g.stroke}" stroke-linejoin="round"` : ""}/></svg>`;
/** A symbol image's mask (`url(…)`) and transparent natural-size source, or null. */
export function sfMask(name, size, weight) {
  const g = sfGlyph(name, size, weight);
  if (!g) return null;
  return { width: g.width, height: g.height, mask: `url("data:image/svg+xml,${encodeURIComponent(svg(g, "black"))}")`,
    placeholder: `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${g.width}" height="${g.height}"/>`)}` };
}
/** Inline SVG markup for chrome the host draws itself (a tab bar, a nav
 * bar button): `name` at `size` points in `color` (CSS; `currentColor` by
 * default) at `weight`. A name without a glyph is an empty `size` square. */
export function symbolSVG(name, { size = 17, color = "currentColor", weight = 400 } = {}) {
  const g = sfGlyph(name.startsWith("symbol:sf/") ? name.slice(10) : name, size, weight);
  return g ? svg(g, color).replace("<svg ", '<svg aria-hidden="true" ') : `<svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" width="${size}" height="${size}"/>`;
}
