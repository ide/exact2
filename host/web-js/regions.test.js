// A bound length's layout regions as the browser's safe area (LLP 1123 D10), and each edge's `env()` through the
// page's name for it (LLP 1115.000 D4.8). `bun test ./host/web-js/regions.test.js`.
import { test, expect } from "bun:test";
import { regions } from "./regions.js";

const read = (edge, env) => `var(--exact-safe-area-inset-${edge}, ${env})`;

test("each region is its edge's safe area, inside calculations and behind a fallback", () => {
  expect(regions("calc(env(-exact-layout-margins-inset-left) + 7px)")).toBe(`calc(${read("left", "env(safe-area-inset-left)")} + 7px)`);
  expect(regions("max(16px, env( -exact-readable-content-corners-inset-left, 30px))")).toBe(`max(16px, ${read("left", "env( safe-area-inset-left, 30px)")})`);
  expect(regions("calc(1px /* \" url( */ + env(/**/-exact-layout-margins-inset-left, 30px))")).toBe(`calc(1px /* " url( */ + ${read("left", "env(/**/safe-area-inset-left, 30px)")})`);
  for (const region of ["safe-area-corners", "layout-margins", "layout-margins-corners", "readable-content", "readable-content-corners"]) {
    for (const edge of ["top", "right", "bottom", "left"]) expect(regions(`env(-exact-${region}-inset-${edge})`)).toBe(read(edge, `env(safe-area-inset-${edge})`));
  }
});

test("an edge's env() is read through the page's name for it, which falls back to the browser's", () => {
  for (const edge of ["top", "right", "bottom", "left"]) expect(regions(`env(safe-area-inset-${edge})`)).toBe(read(edge, `env(safe-area-inset-${edge})`));
  expect(regions("max(16px, env(safe-area-inset-bottom))")).toBe(`max(16px, ${read("bottom", "env(safe-area-inset-bottom)")})`);
  expect(regions("max(env(safe-area-inset-left, calc(1px + 2px)), 3px)")).toBe(`max(${read("left", "env(safe-area-inset-left, calc(1px + 2px))")}, 3px)`);
  expect(regions("env(safe-area-inset-top, env(safe-area-inset-left))")).toBe(read("top", `env(safe-area-inset-top, ${read("left", "env(safe-area-inset-left)")})`));
  expect(regions("env(safe-area-inset-left, -exact-layout-margins-inset-left)")).toBe(read("left", "env(safe-area-inset-left, -exact-layout-margins-inset-left)"));
  // One the text leaves open is closed where it ends, as CSS closes it, the `var()` too
  expect(regions("calc(env(safe-area-inset-left")).toBe("calc(var(--exact-safe-area-inset-left, env(safe-area-inset-left");
  // Another variable is the browser's
  for (const text of ["env(viewport-segment-width 0 0)", "calc(env(viewport-segment-width 0 0) + env(titlebar-area-height, 0px))", "env(safe-area-inset-middle)"]) expect(regions(text)).toBe(text);
});

test("escaped names are read decoded, as CSS tokenizes them", () => {
  expect(regions("max(16px, env(-exact-\\6c ayout-margins-inset-left, 8px))")).toBe(`max(16px, ${read("left", "env(safe-area-inset-left, 8px)")})`);
  expect(regions("e\\6e v(-exact-layout-margins-inset-left, 30px)")).toBe(read("left", "e\\6e v(safe-area-inset-left, 30px)"));
  expect(regions("calc(E\\NV(-exact-\\73 afe-area-corners-inset-\\74op) + 1px)")).toBe(`calc(${read("top", "E\\NV(safe-area-inset-top)")} + 1px)`);
  // An escape ends at one whitespace character; CR LF, CR and form feed are read as a newline first
  for (const [end, seen] of [[" ", " "], ["\t", "\t"], ["\n", "\n"], ["\r", "\n"], ["\f", "\n"], ["\r\n", "\n"]]) {
    expect(regions(`calc(e\\6e${end}v(-exact-layout-margins-inset-left) + 7px)`)).toBe(`calc(${read("left", `e\\6e${seen}v(safe-area-inset-left)`)} + 7px)`);
  }
});

test("only env()'s first argument is renamed", () => {
  for (const text of ['"env -exact-layout-margins-inset-left", serif', "'-exact-layout-margins-inset-left'", '"env \\\r\n-exact-layout-margins-inset-left", serif',
    "env -exact-layout-margins-inset-left, serif", "env, é-exact-layout-margins-inset-left, serif", "url(-exact-layout-margins-inset-left)",
    "url( a/-exact-layout-margins-inset-left.png )", "u\\72 l(-exact-layout-margins-inset-left)", 'url("-exact-layout-margins-inset-left")',
    "env(-exact-layout-margins-inset-middle)", "env(x-exact-layout-margins-inset-left)",
    "var(--exact-layout-margins-inset-left)", "env(-exact-\\e9 -inset-left)", "16px", "\\31 0px", '"font \\61\nenv(-exact-layout-margins-inset-left)", serif',
    "url(a\\29\nenv(-exact-layout-margins-inset-left))",
    // Not functions, as CSS tokenizes them: a hash, an at-keyword, a dimension, CDO before a name, NUL (U+FFFD) in a name
    "#env(-exact-layout-margins-inset-left)", "@env(-exact-layout-margins-inset-left)", "1\\65nv(-exact-layout-margins-inset-left)",
    "<!--url(%\tenv(-exact-layout-margins-inset-left)", "\0env(-exact-layout-margins-inset-left)", "env(-exact-layout-margins-inset-left\0)",
    // A backslash at the end is an escape (U+FFFD), part of the name
    "env(-exact-layout-margins-inset-left\\"]) expect(regions(text)).toBe(text.replace(/\r\n?/g, "\n"));
  expect(regions("-->env(-exact-layout-margins-inset-left)")).toBe(`-->${read("left", "env(safe-area-inset-left)")}`);
  expect(regions('url( "a)-exact-layout-margins-inset-left" ) env(-exact-layout-margins-inset-left)')).toBe(`url( "a)-exact-layout-margins-inset-left" ) ${read("left", "env(safe-area-inset-left)")}`);
  expect(regions("url(x) env(-exact-layout-margins-inset-left)")).toBe(`url(x) ${read("left", "env(safe-area-inset-left)")}`);
});
