# Grouping Liquid Glass: `-exact-apple-glass-container`

**Status:** prototyped on the iOS 27 simulator, not merged. 2026-10-01.

## Problem

On iOS 26+, Liquid Glass shapes that belong together *merge*. Glass buttons
next to each other blend into one surface when they come within a set
distance. When one is pressed and swells, it flows into its neighbours. When
one is swapped for another, the glass morphs instead of cutting.

Exact draws every glass node (`backgroundMaterial: glass`, and now a button's
`-exact-apple-button-style: glass`) as its own independent glass view. There's
no way to say "these belong together", so a row of glass buttons is a row of
separate islands. The buttons never merge, and pressing one leaves the others
untouched. Next to native apps, the difference is obvious.

## How the platform does it

Merging only happens inside a glass container:

| Framework | Container | Members |
|---|---|---|
| SwiftUI | `GlassEffectContainer(spacing:)` | views with `.glassEffect()` / `.buttonStyle(.glass)`; a `glassEffectID` in a shared `Namespace` makes swaps morph |
| UIKit | `UIVisualEffectView(effect: UIGlassContainerEffect())`, `spacing` property | glass views (`UIGlassEffect` effect views, and `UIButton.Configuration.glass()`) placed in its `contentView` |

`spacing` is not layout. It's the **merge distance**: shapes closer than this
start to blend. A common setting is spacing equal to the row's `gap`. At rest
the members sit just at the threshold, so they look separate, but a pressed,
swelling member crosses it and flows into its neighbours.

## Proposal

```
-exact-apple-glass-container: auto | <length>    /* none by default */
```

- **A vendor property, read only by the Apple hosts.** The `-exact-` prefix
  says Exact defines the behaviour. `apple` says it's Apple's vocabulary.
  WebKit's own private glass property (`-apple-visual-effect:
  -apple-system-glass-material`) is prefixed by the platform whose look it is.
  Here Apple doesn't define this behaviour, so the prefix is Exact's.
- **It declares a rendering group, not layout.** It's in the family of CSS's
  `isolation: isolate` and `container-type`. The kernel and layout never read
  it, and the web ignores it.
- **Its value is the merge distance in points.** Not inherited.
- **The box's descendants' glass joins the group, at any depth.** That covers
  glass materials and glass-styled buttons.

### Example

```
row gap=8 -exact-apple-glass-container=8
  column flex=1
    button -exact-apple-button-style="glass" …   // Lock
  column flex=1
    button -exact-apple-button-style="glass" …   // Unlock
  column flex=1
    button -exact-apple-button-style="glass" …   // Start
```

## Implementation (the prototype)

The iOS host already gives every node a `container` indirection: its children
live in the node itself, a scroll view, a clip box, or a glass material's
`contentView`. A glass container is one more case of that.

- **`Backdrop.swift`**
  - `materialRequest` returns a reserved kind, `exact-glass-container`, when
    the property is ≥ 0 (iOS only).
  - `Materials.glass(_:)` counts that kind as glass, so the node's children
    move into the effect view's `contentView`.
  - `materialEffect` returns `UIGlassContainerEffect` with `spacing` set from
    the property.
- **`kernel/tables/schema.json`:** style bit 155, `exact_apple_glass_container`,
  `f32`, default `-1` (none).
- **`contract/lower/src/tags.rs`:** maps `-exact-apple-glass-container` to that
  style. The Contract lexer now accepts `-exact-…` names: Exact's prefix only,
  after a space, so a negation such as `-x` is never read as one.

That's about 20 lines. Hit testing, clipping and the list-row pool already
understand glass content views, because they handle `backgroundMaterial:
glass` the same way.

## What the prototype showed

- **Members merge.** With `spacing` set larger than the gap (40 on an 8pt
  gap), three glass buttons render as one continuous glass shape at rest, the
  same as SwiftUI's container. With `spacing` equal to the gap they render
  separately at rest.
- **Depth doesn't matter.** Each button sits inside a wrapper `column`, two
  views below the container's `contentView`, and still merges.
- **`UIButton.Configuration.glass()` takes part.** No separate glass view is
  needed for buttons.

Not yet verified:

- **Press-and-flow on a device.** The simulator driver can't hold a touch.
  The at-rest result above shows the grouping works; how the press interaction
  looks still needs a person on a phone.
- **Overflow.** A pressed member swells past its box, and the container must
  not clip it. The container's effect view doesn't set `clipsToBounds`, but a
  container node that also has `overflow: hidden` or a corner radius would
  clip. That's probably a lint: warn when both are set.

## Open questions

1. **`auto`** *(built since)*: spacing equal to the box's gap is the common
   case. The kernel stores `auto` as a sentinel row value, and the iOS host
   takes the smallest space between neighbouring children as laid out,
   updating the container when layout changes.
2. **Morphing on swap** (SwiftUI's `glassEffectID`). When a member is replaced,
   e.g. Start becomes Stop, SwiftUI morphs the glass. In UIKit that comes from
   animating the change inside the container. Exact's replacement is a destroy
   and a create in one batch, so the host would need to match old and new
   members, probably by a key. Out of scope for the first cut.
3. **Changing spacing.** The prototype sets `spacing` when the effect is made.
   A change to the property must update the effect in place, without
   rebuilding the view, or the members flash.
4. **macOS.** AppKit's `NSGlassEffectContainerView` is the counterpart. The
   prototype ignores the property on macOS; it should map there too.
5. **Nesting containers.** A container inside a container: UIKit's behaviour
   is unknown. Probably the innermost wins; to be checked.
6. **Other platforms.** Material has no merging glass. Following the
   per-platform vendor-property convention (`-exact-apple-button-style` beside
   a future `-exact-android-button-style`), there's no neutral spelling; each
   platform reads its own property or none.

## Testing

- **UIKit XCTest:**
  - a node with the property gets a `UIVisualEffectView` whose effect is
    `UIGlassContainerEffect` with the given `spacing`
  - its node children live in that view's `contentView`
  - removing the property moves them back
- **Pool:** a list row holding a container parks and comes back with a fresh
  effect view, as `testAMaterialRowComesBackWithANewEffectView` checks for
  glass today.
- **Agent:** `state`'s material report names the container kind.
