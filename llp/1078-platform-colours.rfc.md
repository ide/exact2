# LLP 1078: Platform colours: semantic roles, every native colour, and app themes

**Type:** RFC
**Status:** Draft r2, 2026-10-03. r1 (2026-10-02) was reviewed adversarially against the source and found NOT READY; §8 folds every finding. Not implemented.
**Systems:**
- Kernel: the colour value, an interned reference; the role table; resolutions the host reports
- Contract: role keywords, `platform-color()`, `theme`
- Apple host: trait-set resolution in every paint path
- Web host and the web JS target: system colours, the role sheet
- Linux host: fallbacks
- Agent API: resolution report; contrast and elevation in `prefer`
**Author:** Claude (Opus 5.5)
**Implementer:** Claude (Opus 5.5), when accepted
**Date:** 2026-10-03
**Related:**
- LLP 1034: scheme-aware colour, the `light-dark()` pair.
- LLP 1062: paint motion. D4: an appearance change transitions. D9: keyframe colours known at compile time.
- LLP 1066: gradients.
- LLP 1077 D13: the `-apple-system-*` colours, which this replaces.
- LLP 1053.000: materials, the table shape this reuses.
- LLP 1001: the style table and its declared deviations.
- LLP 1030 D3a: the compatibility id.
- LLP 1076: Android rendering research.
- CSS Color 4 §6.2 (system colours); CSS Color 5 `light-dark()`; WebKit's `-apple-system-*` keywords.

## Summary

An Exact app names a colour as RGBA, or as a `light-dark()` pair of RGBA
(LLP 1034). LLP 1077 D13 added six WebKit names, such as
`-apple-system-secondary-label`, but each is also just a pair of UIKit's
light and dark values, frozen in `kernel/src/style/symbols.rs`. So a colour
an app means as "the platform's secondary label" is really a hex copy of it.
The copy misses:
- Increased Contrast
- elevated surfaces (a sheet's lighter dark greys)
- every colour an OS adds or retunes after Exact was built

This RFC makes a colour able to **name** a platform colour, and keeps the
kernel and every host working with it. Three layers, in the order an author
should reach for them:

1. **Semantic roles, built in.** `color="secondary-label"`,
   `background-color="grouped-background"`. A curated vocabulary, plus CSS's
   own system colours (`CanvasText`, `LinkText`, …). Each host resolves a
   role to its native dynamic colour.
2. **Any platform colour, by native name.**
   `platform-color(ios systemMintColor, macos systemMintColor, light-dark(#00c7be, #63e6e2))`.
   It is looked up at runtime, so a colour a new OS adds works without an
   Exact release. The required CSS fallback covers every other case.
3. **App themes.** `theme` names the app's own colours once and may override
   a role. Screens use the names.

r1 scope (§7) is Apple and the web. The design is written so Android and
Windows hosts can join without changing it (Appendix A, non-normative).

## 1. Motivation

**Native apps do not write hex for system colours.** UIKit's
`secondaryLabel` is one name whose value depends on the trait collection:
- appearance
- Increased Contrast
- the user-interface level (base or elevated)
- a material's vibrancy

Copied values drift from the platform:
- in accessibility modes
- on elevated surfaces
- whenever the OS retunes its palette, as iOS 26 did

**The web is the standard (CLAUDE.md), and CSS has system colours.**
`Canvas`, `CanvasText`, `LinkText`, `GrayText`, `Highlight`, … are resolved
by the browser against the OS and `color-scheme`. CSS's list is small and
form-oriented. It has no "secondary label" or "grouped background", so Exact
needs more roles than CSS has, and a way past any fixed list.

**Three requirements from the people who will write Exact apps:**
1. the semantically correct thing must be the easiest to write
2. every colour a platform provides must be reachable, including future ones
3. a new OS must not need a new Exact to use its colours

## 2. Decisions

### D1 — A colour can be a reference: interned, with a fallback pair the kernel always has

`ColorValue` today is `Copy + Eq`, with `const fn resolve(dark)`
(`kernel/src/style.rs:716-746`). It is embedded in `Paint`, gradients,
shadows, strokes, `symbol-palette` and filter primitives, and it is
dereferenced throughout the kernel. A boxed, recursive reference would break
all of that.

So a reference is **interned**. The plan carries a reference table, and a
colour holds an index:

```rust
enum ColorValue {
    Fixed(Color),
    Pair(Color, Color),                        // light-dark(); LLP 1034
    Ref(RefId),                                // this RFC: u16 into the plan's table
}
struct Reference {                             // the plan's table, one row per distinct reference
    kind: RefKind,                             // Role(RoleId) | Platform { ios, macos, web: Option<Name> }
    fallback: (Color, Color),                  // light and dark: what the kernel and fallback hosts use
}
```

**`ColorValue` stays `Copy + Eq`**, the wire grows by one discriminant and a
`u16`, and D5's per-host cache has a natural key: `(RefId, trait set)`.

**Every reference carries a fallback pair**:
- a role's comes from the role table (D2)
- a `platform-color`'s comes from its CSS fallback, itself a colour or pair,
  never another reference (D3)

So **every reference has a deterministic RGBA for any appearance without
asking a host**. That is the property the kernel needs, because the kernel
does resolve colours today:
- **Native paint motion** seeds its engine from resolved colours in Rust
  (`Kernel::paint_sync`/`paint_resync`, `color_targets(node, dark)`,
  `kernel/src/motion.rs:207, 388-421`).
- **SVG filter primitives** resolve flood, lighting and drop-shadow colours
  (`kernel/src/svg/scene/filter.rs:355, 732, 742`), as does
  `Paint::resolve` (`kernel/src/svg/mod.rs:266`).
- **The Linux painter** resolves through `ColorValue::resolve(dark)`
  (`host/linux/src/paint.rs`).

**The kernel resolves a reference to what the host reported, else the
fallback.** A host that resolves dynamic colours reports, per reference and
per trait set it is showing, the RGBA it resolved. This is the same shape
as `exact_scheme`/`exact_view_scheme`, which report the scheme today
(`host/apple/src/abi/exports.rs:459-466`). Concretely:
- the call is `exact_color_resolved(ref, traits, rgba)`
- the kernel keeps a small map, `(RefId, traits) → Color`
- a new report for a reference that motion or a filter is using re-seeds it,
  as `paint_resync` does on a scheme change

So paint motion animates a role toward the colour the platform actually
shows, and an SVG filter's flood follows the system colour. Where no host
reports (Linux, the agent's headless runs), the fallback pair is used, and
it is the documented value.

`currentcolor` keeps its meaning and inherits the reference, not a resolved
value. A child under a different trait context (an elevated sheet) resolves
it itself.

A reference is valid in **every colour row** (the `color`, `color2`,
`current-color`, `auto-color` and `paint` codecs in
`kernel/tables/schema.json`) and in every embedded colour:
- `box-shadow` and `text-shadow` colours
- `-webkit-text-stroke-color`
- `stop-color`, `flood-color`, `lighting-color`, the filter `drop-shadow`
  colour
- `symbol-palette`
- gradient and `mask-image` stops

The parsers that learn the new form are:
- `shadow.rs:115, 205`
- `stroke.rs:45`
- `gradient.rs:750`
- `svg/mod.rs:225`
- `style/symbols.rs:42`
- the filter `drop-shadow` parser
- `parse_light_dark`

A reference is **not** valid inside a `light-dark()` half. A pair of
references is a reference whose fallback is a pair, so nothing is lost.

### D2 — Semantic roles: one table, CSS's names where CSS has them

Roles live in **one table in `kernel/tables/schema.json`**, shaped like the
`materials` table (LLP 1053.000). Each row has:
- the role's name
- its Apple names (UIKit, AppKit; Objective-C spellings)
- its web form
- its fallback light and dark colours

`kernel/build.rs` generates the role ids. The table **replaces**
`SYSTEM_COLORS` (`kernel/src/style/symbols.rs:63-72`), which is deleted
(RULES: delete, don't deprecate). Its six WebKit names become aliases of the
roles below, so `-apple-system-secondary-label` is now a reference, not a
copied pair. LLP 1077 D13 is amended.

**Roles are colour keywords, written as strings.** They are not bare
identifiers:
- `color=secondary-label` lexes as a variable reference in Contract
  (`contract/syntax/src/lexer.rs:213-222`)
- `label`, `fill` and `background` are common local names
- `theme` is the most-used local in the repo's apps

So a role is written as CSS writes a keyword: `color="secondary-label"`,
the same as `color="#ffffff"` today. Contract checks every literal colour
string, so a misspelt role is a compile error.

**CSS system colours** (CSS Color 4 §6.2) are roles, case-insensitive as
CSS keywords are. Each has an Apple mapping, because the web is the oracle
and native must answer too:

| Keyword | iOS (UIKit) | macOS (AppKit) | Web |
|---|---|---|---|
| `Canvas` | `systemBackgroundColor` | `textBackgroundColor` | as is |
| `CanvasText` | `labelColor` | `textColor` | as is |
| `LinkText` | `linkColor` | `linkColor` | as is |
| `GrayText` | `tertiaryLabelColor` | `disabledControlTextColor` | as is |
| `Highlight`, `HighlightText` | the tint at 0.2 alpha (stand-in), `labelColor` | `selectedTextBackgroundColor`, `selectedTextColor` | as is |
| `AccentColor`, `AccentColorText` | the inherited `tintColor`, white | `controlAccentColor`, `alternateSelectedControlTextColor` | as is |
| `Field`, `FieldText` | `secondarySystemBackgroundColor`, `labelColor` | `textBackgroundColor`, `textColor` | as is |
| `ButtonFace`, `ButtonText` | `secondarySystemFillColor`, `linkColor` | `controlColor`, `controlTextColor` | as is |

**Declared deviation:** dark `Canvas` is `#000000` on iOS (`systemBackground`)
and `#121212` in Chrome. Native follows the platform; LLP 1001 records it.

CSS's remaining system colours are **refused** in r1 as having no
meaningful Apple counterpart:
- `ButtonBorder`, `Mark`, `MarkText`
- `SelectedItem`, `SelectedItemText`
- `ActiveText`, `VisitedText`

CSS's deprecated system colours (`Background`, `Window`, …) are refused too.

**Exact roles**, where CSS has no name: lowercase, hyphenated, and closed.

| Role | iOS (UIKit) | macOS (AppKit) | Web (Safari: WebKit's own keyword) | Fallback light / dark |
|---|---|---|---|---|
| `label` | `labelColor` | `labelColor` | `-apple-system-label` | `#000000` / `#ffffff` |
| `secondary-label` | `secondaryLabelColor` | `secondaryLabelColor` | `-apple-system-secondary-label` | `#3c3c4399` / `#ebebf599` |
| `tertiary-label` | `tertiaryLabelColor` | `tertiaryLabelColor` | `-apple-system-tertiary-label` | `#3c3c434d` / `#ebebf54d` |
| `quaternary-label` | `quaternaryLabelColor` | `quaternaryLabelColor` | `-apple-system-quaternary-label` | `#3c3c432e` / `#ebebf529` |
| `placeholder` | `placeholderTextColor` | `placeholderTextColor` | `-apple-system-placeholder-text` | `#3c3c434d` / `#ebebf54d` |
| `separator` | `separatorColor` | `separatorColor` | `-apple-system-separator` | `#3c3c434a` / `#54545899` |
| `background` | `systemBackgroundColor` | `windowBackgroundColor` | `-apple-system-background` | `#ffffff` / `#000000` |
| `secondary-background` | `secondarySystemBackgroundColor` | `controlBackgroundColor` (lighter than the window in light mode: declared) | `-apple-system-secondary-background` | `#f2f2f7` / `#1c1c1e` |
| `grouped-background` | `systemGroupedBackgroundColor` | `windowBackgroundColor` | `-apple-system-grouped-background` | `#f2f2f7` / `#000000` |
| `secondary-grouped-background` | `secondarySystemGroupedBackgroundColor` | `controlBackgroundColor` | `-apple-system-secondary-grouped-background` | `#ffffff` / `#1c1c1e` |
| `fill` | `systemFillColor` | `systemFillColor` | `-apple-system-fill` | `#78788033` / `#7878805c` |
| `secondary-fill` | `secondarySystemFillColor` | `secondarySystemFillColor` | `-apple-system-secondary-fill` | `#78788029` / `#78788052` |
| `system-red`, `-orange`, `-yellow`, `-green`, `-mint`, `-teal`, `-cyan`, `-blue`, `-indigo`, `-purple`, `-pink`, `-brown`, `-gray` | `systemRedColor`, … | `systemRedColor`, … | `-apple-system-red`, … | Apple's published light / dark values |

The macOS rows are AppKit's own semantics, which are not iOS's. Where they
differ visibly (`controlBackgroundColor`), the table says so. Open question
§6.3 asks for a side-by-side on macOS 26.

**There is no `accent` role.** `AccentColor` is the accent: on iOS it is
the view's inherited `tintColor`, which is what an app's `accent-color` row
already sets. So `accent-color` stays the way to *set* the accent, and
`AccentColor` the way to *use* it. A row cannot be both, so there is no
cycle (`accent-color: AccentColor` is refused).

**The web** emits a CSS system colour as is. For an Exact role it emits
`var(--exact-<role>)`, defined by a stylesheet Exact ships:
- **Safari:** WebKit's `-apple-system-*` keyword, which is the dynamic colour
  itself.
- **Elsewhere:** `light-dark(<fallback>)`, redefined under
  `@media (prefers-contrast: more)` with the higher-contrast values, so the
  web does not ignore Increased Contrast.

The web JS target, which writes bound values through JS maps
(`host/web-js/src/rows.rs:208-214`), uses the same names, generated from
the same table.

### D3 — `platform-color()`: every platform colour, safely, with a CSS fallback

```
platform-color(<platform> <name> [, <platform> <name>]* , <fallback>)
<platform> = ios | macos | web        (r1; android, windows in Appendix A)
<name>     = an Objective-C class colour property (ios, macos) | named:<Asset> | a CSS colour (web)
<fallback> = a literal colour or light-dark() pair; not a reference
```

**Literal only in r1.** `platform-color()` may not come from a data source
or a bound expression. Contract refuses it in dynamic values
(`lower-platform-color-literal`), and the kernel's runtime parser does not
accept it. A plan's names are fixed when the app compiles, so data can never
choose which selector is called.

**Safe runtime lookup on Apple:**
- **Spelling:** names are the Objective-C class properties, the
  `…Color` spelling, one canonical form on both platforms.
- **Refused by Contract:** a leading `_`, and any name that is not
  `[a-z][A-Za-z0-9]*Color`.
- **Checked at runtime:** the host resolves a name only if
  `class_getClassMethod` finds a zero-argument class method on
  `UIColor`/`NSColor` returning an object, and the result `isKindOfClass:` a
  colour. Anything else is the fallback, logged once.
- **What can and can't be reached:** private selectors and `+new`/`+alloc`
  are unreachable. A colour added in iOS N resolves on iOS N with no Exact
  change.
- **`named:<Asset>`:** `UIColor(named:)` / `NSColor(named:)`, from the app's
  asset catalogue.

A platform with no entry, a name the OS lacks, or a name that is not a
colour: **the fallback**. The fallback is **required**
(`lower-platform-color-fallback`), and it is also the reference's kernel
fallback pair (D1).

### D4 — `theme`: an app's own colours, named once, able to override a role

```
theme
  brand = platform-color(ios named:BrandColor, macos named:BrandColor, #c8102e)
  card = "secondary-grouped-background"
  defrost-on = light-dark(#d0e2f7, #27394f)
  secondary-label = platform-color(ios secondaryLabelColor, light-dark(#6b6b73, #a1a1aa))
```

- **Declared once**, at the app root, like `keyframes` and `style`. Theme
  names are colour keywords too, written as strings: `color="brand"`.
- **An entry may be any colour:** a role, a `platform-color`, a pair, hex.
- **An entry named like a role overrides that role for the whole app.**
- **Cycles are refused:** an entry that reaches itself through
  others (`a = "b"`, `b = "a"`), and a role override that names its own role
  (`secondary-label = platform-color(ios secondaryLabelColor, "secondary-label")`,
  which has a reference as a fallback and is refused there as well).

**The theme ships in the plan** as part of the reference table: each entry
is a reference row, and a role an app overrides has its row replaced. So
"the whole app" really is the whole app, on every target:
- the kernel's runtime parser resolves a dynamic `"brand"` or
  `"secondary-label"` from a data source against the plan's table
- the web JS target resolves against the same table, emitted as generated
  JS

A dynamic string that names neither a role nor a theme entry is an invalid
colour, as a malformed hex is today.

This replaces a per-app palette function (`c(name)` returning hex pairs)
with declarations Contract checks.

### D5 — The host resolves per view, against a trait set, everywhere it paints

A reference resolves against the **view that shows it**, and re-resolves
when that view's traits change. The trait set is:
- **style:** light or dark
- **contrast:** normal or increased
- **level:** base or elevated (iOS)
- **material:** under a material or not (vibrancy, LLP 1077 D13)

**The Apple host is built on `drawsDark: Bool` and RGBA arrays today.**
These sites change from `dark: Bool` to a trait set, and from RGBA to
"RGBA or reference":
- `BatchValue.channels(dark:)` / `isSchemeColor` (`Batch.swift:20-25`) and
  `TextEngine.color([Double])` (`Text.swift:717`)
- the text spec's `color: [Double]` (`Text.swift:83`) and the `TextPaint`
  cache key (`TextResidency.swift:116-123`)
- inline runs (`InlineText`) and their dark colours
- `BoxShadowSpec.list(dark:)`, `gradient.apply(…dark:)`, and the
  `BoxMaskState.Key(dark:)` cache
- `SvgScene.color(_:dark:)`
- the symbol look key (`Affordances.swift:22, 35`)
- `RegionController.appearance` / `RegionTextSource.capture(dark:)`
  (`RegionController.swift:164, 276`)
- on the Rust side, `style_json_presented` and `push_color_value`
  (`host/apple/src/style.rs:401, 647`), which carry a reference across the
  ABI as `{"ref": <RefId>}` beside its fallback pair

**On iOS:**
- **Resolution:** `UIColor(dynamicProvider:)`-backed system colours are
  resolved with `resolvedColor(with: traitCollection)`. Exact draws boxes as
  `CGColor` layers and never sets `UIView.backgroundColor`
  (`NodeViewIOS.swift:489-490`), so every site above resolves explicitly.
- **Trait changes:** registered with `registerForTraitChanges` on
  `userInterfaceStyle`, `accessibilityContrast` and `userInterfaceLevel`.
  These invalidate the text caches (`invalidateText`, as LLP 1034 D2 does
  for a scheme change) and the layer colours.

**On macOS:**
- **Resolution:** under the view's `effectiveAppearance`, using
  `NSAppearance.performAsCurrentDrawingAppearance`.
- **Increased Contrast:** changes `effectiveAppearance` to a high-contrast
  variant, so `drawsDark`'s `bestMatch([.aqua, .darkAqua])`
  (`NodeViewMac.swift:766`) becomes a trait set that keeps contrast.
- **Accent and selection colours:** changes post
  `NSColor.systemColorsDidChangeNotification`, which the host observes too.

**After resolving,** the host **reports** (D1) any reference that the kernel
uses for motion or a filter on that view, and caches resolutions per
`(RefId, trait set)`. A thousand rows of `secondary-label` resolve once per
trait set.

### D6 — Motion follows LLP 1062: a trait change transitions; keyframes keep their values

LLP 1062 settled colour motion, and r1 contradicted it:

- **A trait change transitions, as an appearance change does.** LLP 1062 D4:
  "An appearance change transitions, as in Chrome", implemented by
  `paint_resync`. A reported resolution (D1) for a trait set the view has
  just entered is the new target, so a `transition` on a role row eases from
  the old platform colour to the new one. With no `transition`, it changes
  at once.
- **Keyframe colours stay compile-time** (LLP 1062 D9). A reference is
  refused inside `keyframes` in r1 (`lower-keyframe-color-ref`). The engine
  folds keyframe colours to floats when the app compiles
  (`motion/src/color.rs`), and a reference has no value then. The natural
  follow-up is a keyframe holding a reference and seeded from its reported
  resolution; it is not needed for roles to be useful.
- **The web** transitions a system-colour change under `transition`, as
  LLP 1062 D4 records for appearance; nothing here widens that.

### D7 — The agent pins traits, so tests are deterministic

UIKit and AppKit dynamic colours resolve against real traits and ignore
Exact's display preferences (`DisplayPreferences.agentContrast`,
`Agent.swift:311, 329`). Under the agent:
- **iOS:** `prefer contrast more` applies
  `traitOverrides.accessibilityContrast` (iOS 17, the deployment target) to
  the session's window scene. `prefer elevation elevated` applies
  `traitOverrides.userInterfaceLevel`.
- **macOS:** `prefer contrast more` sets a high-contrast `NSAppearance` on
  the session's window.
- **The accent:** pinned to the system default under the agent, and reported.
- **`layout <node>`** reports each colour row's reference, what it resolved
  to and from where. For example:
  `{"ref": "secondary-label", "resolved": "#3c3c4399", "source": "secondaryLabelColor", "traits": "light/normal/base"}`,
  or `"source": "fallback"`.
- **Linux and headless runs only ever show fallbacks**, stated, so a Linux
  screenshot is the fallback palette by definition.

## 3. The compatibility id and the wire

**The cost:**
- The colour codec gains a discriminant, and the plan gains its reference
  table.
- The kernel schema digest changes, so every native host needs a new
  compatibility id and a new binary (LLP 1030 D3a), as LLP 1034 D5 did.
  Pre-1.0, that is the cost.

**What needs a binary and what doesn't:**
- **A new role** is a schema change, so it needs a binary. That is
  deliberate: roles are curated.
- **A `platform-color` name or a theme entry** is plan data, which a bundle
  can carry and update over the air. That is the point: the open-ended set
  never needs a binary.

## 4. What this deliberately does not do

- **No `color-mix()` or relative colour syntax** over references. This is
  the natural follow-up; mixing needs resolution first on every host.
- **No per-element `color-scheme`** (LLP 1034 §3 stands).
- **No automatic contrast correction.** A role is what the platform says.
- **No asset-catalogue generation.** `named:` reads what the bundle already
  has.
- **No vibrancy beyond LLP 1077 D13's scope.** A role under a material
  resolves with the material in its trait set, where 1077 nests the view in
  an effect.

## 5. Landing order

1. **Kernel:**
   - `ColorValue::Ref` and the reference table.
   - The role table replaces `SYSTEM_COLORS`.
   - Every parser in D1 learns the new form.
   - `exact_color_resolved`.
   - Motion re-seeding.
   - **Tests:**
     - every role parses
     - the fallback resolves without a host
     - a report re-targets a running transition
     - a filter flood uses the report
2. **Contract:**
   - Role strings, `platform-color()` (literal only, with its grammar and
     refusals), `theme` (plan table, overrides, cycles).
   - The keyframe refusal.
   - **Tests:** each refusal; a theme override reaching a dynamic value.
3. **Web and the web JS target:** system colours as is, the role sheet
   (WebKit keywords, `light-dark()`, `prefers-contrast`). Conformance
   fixtures.
4. **Apple:**
   - Every site in D5, trait registration, the cache, the report, and the
     agent's trait overrides.
   - **XCTests:** each role resolved in light, dark, increased contrast and
     elevated, compared with UIKit's own colour; a `platform-color` with an
     unknown name falls back; a private or non-colour selector falls back.
5. **Linux:** fallbacks only.
6. **First app: Lexy** (`exact/lexy`):
   - Its `c()` palette, which copies UIKit values into pairs, becomes roles
     and a small theme.
   - Screenshots in light, dark, Increased Contrast and an elevated sheet
     match a hand-built UIKit screen.

## 6. Open questions

1. **`Highlight` on iOS.** UIKit has no selection colour; the stand-in is the
   tint at 0.2 alpha. Is that what UIKit's own text selection shows, on
   iOS 26?
2. **Should a role ever be vibrant by default?** LLP 1077 D13 makes the
   `-apple-system-*` labels vibrant under a material. With the trait set
   including the material, roles inherit that. Confirm it reads right on
   glass.
3. **macOS grouped backgrounds.** `windowBackgroundColor` for both grouped
   roles, or `underPageBackgroundColor`? Needs a side-by-side on macOS 26.
4. **A lint for missing platforms.** Should Contract warn when
   `platform-color` names `ios` but not `macos` in an app that ships both?
   Recommendation: a lint, not an error.

## 7. Scope of r1

**In:**
- the reference value and its table
- Apple and web roles, with CSS's admitted keywords
- `platform-color` for `ios`, `macos` and `web`, literal only
- `theme`, shipped in the plan
- the kernel report path
- the agent's trait pinning

**Out, until a host or a need exists:**
- Android and Windows columns, keywords and lookups (Appendix A)
- `platform-color` in dynamic values
- references in keyframes
- the Linux desktop accent

## 8. Review fold (r1 → r2)

One adversarial review of r1 against the source (NOT READY). Every finding
is taken:

| Finding | r2 |
|---|---|
| The kernel resolves colours (paint motion, SVG filters, Linux); "never resolves" was false (BLOCKER) | D1: every reference has a fallback pair; hosts report resolutions; motion and filters use them |
| D6 contradicted LLP 1062 D4 and D9 (BLOCKER) | D6 follows 1062: trait changes transition; keyframe references refused |
| CSS system colours had no native mapping (MAJOR) | D2: a row for every admitted keyword; the rest refused; the `Canvas` deviation declared |
| LLP 1077 D13's `SYSTEM_COLORS` already shipped copied pairs (MAJOR) | D2: the role table replaces it; the six names become aliases |
| A boxed reference breaks `ColorValue`'s `Copy` semantics (MAJOR) | D1: interned `Ref(u16)`; the parsers to change are listed |
| The Apple host's `dark: Bool` sites were unnamed; `backgroundColor` was assumed (MAJOR) | D5: each site listed; resolution is explicit everywhere |
| Theme semantics contradicted for dynamic values and the web JS target; no cycle rule (MAJOR) | D4: the theme ships in the plan on every target; cycles refused |
| Data could choose an Objective-C selector (MAJOR) | D3: literal only; Objective-C spellings; introspection checks; `_` refused |
| The agent could not pin contrast or elevation (MAJOR) | D7 |
| Platform facts (AppKit fills, `controlBackgroundColor`, `systemColorsDidChangeNotification`, Android MDC attributes, WinUI lookup) | D2, D5, Appendix A corrected |
| CSS: §6.3 citation, `AccentColor` support, case, `prefers-contrast` | Related fixed; D2's web sheet; deprecated keywords refused |
| Role names collide with Contract variables | D2: roles are strings |
| `accent` contradicted itself | D2: no `accent` role; `AccentColor` uses, `accent-color` sets |
| The colour row list was wrong (`outline-color` has no row; filter and stop colours missing) | D1 |
| No Implementer; first app unnamed | header; §5.6 |
| Scope: cut Android, Windows and dynamic `platform-color` from r1 | §7 |

## Appendix A — Android and Windows (non-normative)

The design admits these hosts without change: a column per platform in the
role table, a keyword in `platform-color`, and a host lookup. What the
review found, recorded for when those hosts exist (LLP 1076):

**Android:**
- **Material 3's container roles** (`?attr/colorSurfaceContainerLow` and
  the rest) are Material Components attributes. They need an MDC
  `Theme.Material3` host theme. Without MDC, use the framework attributes
  (`?android:attr/textColorPrimary`, `textColorSecondary`, `textColorHint`)
  or API 34's `@android:color/system_surface_container_*` resources.
- **Lookup:** `?attr` names need `Resources.getIdentifier` to find the
  attribute id before `Theme.resolveAttribute`, which may return a
  `ColorStateList` reference to resolve in turn.
- **Shrinking:** `getIdentifier` lookups of `@color/…` are stripped by
  `shrinkResources` unless the names are kept.
- **The system hues** have no Material counterpart. A role needs a declared
  fixed tone.

**Windows (WinUI):**
- **The brush names** (`TextFillColorPrimaryBrush`, …) are real.
- **`SystemFillColor*`** names statuses (Critical, Caution, Success), not
  hues, so the system hues need stand-ins.
- **Lookup:** `Application.Current.Resources[name]` resolves against the
  app's theme, not an element's `ActualTheme`, and throws on a missing name.
  Use the element's resources and `TryGetValue`.
- **The TextBox placeholder** uses the secondary text fill, not the tertiary.
