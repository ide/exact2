# Native buttons: what a real app could not express

**Status:** Report and request, 2026-10-02. Nothing here is built.
**Context:** main at `a6d8e8e7`. LLP 1069.011 (native buttons), LLP
1069.011.000 (native buttons everywhere).

## 1. What was tried

An app's sign-in, verification, settings and account screens were moved from
custom buttons to `button appearance="auto"`. Nine buttons were moved:

| Kind | Style |
|---|---|
| Primary actions (Sign In, Verify, Save) | `filled` |
| Secondary actions (Resend Code, Use a Different Method) | `gray` |
| A choice between two methods, each a symbol and a title | `tinted` |
| Link-like actions | `plain` |

The link-like actions were:
- a demo link
- a link out to another app
- Sign Out, with a symbol
- a symbol-only Clear button in a text field
- a two-line "manage your subscriptions" link

Every move compiled. Each screen was then compared, on an iOS 27 simulator,
with the same screen drawn by a `UIButton.Configuration` the app configured
itself, which is what the platform's own apps look like. Five differences are
visible.

## 2. The limitations

1. **No space between the symbol and the title.** A button with a symbol and
   a title draws them touching. `imagePadding` is left at 0. UIKit's own
   apps put about 6–8 pt there, depending on size.
2. **No size and no corner shape.** Every button is the `medium` size with
   `dynamic` corners. A full-width primary action that should be a large
   capsule (`buttonSize = .large`, `cornerStyle = .capsule`), as in
   Settings, Health or the App Store sign-in sheets, cannot be written.
3. **No title font.** The title is the configuration's default font for the
   size. A small, semibold link under a paragraph grows and loses its
   weight; a primary action loses its semibold.
4. **The title never wraps.** A long link title truncates in the middle of a
   word. `UIButton.Configuration` wraps by default, and so does a browser's
   `<button>`.
5. **`gray` ignores `accent-color`.** Its title draws in the label colour
   (LLP 1069.011 D7, as measured). The platform's gray secondary button
   takes a tint for its title (`baseForegroundColor`), which is how a gray
   secondary action reads as an action.

Each of these makes the native button look less native than a custom one,
so the app keeps its custom buttons for now.

## 3. What not to do

The branch these screens came from has an earlier, Apple-only answer to the
same need: the vendor property `-exact-apple-button-style`. It reads the
button's own `border-radius` for a capsule, and its text child's
`font-size`/`font-weight` for the title font. It also measures the laid-out
symbol and title boxes for the padding. It works for one app on one
platform. **It should not be adopted as the fix.**
- It is a vendor property where CSS has names.
- It reads the author's box styles that LLP 1069.011 D6 deliberately refuses
  on a native button.
- It has no web, macOS or Linux meaning.

## 4. The request: one general design, in Exact's terms

These five should be designed together, as a revision of LLP 1069.011, by
the same rules the native button already follows:

- **The web is the standard.** Where CSS has a name, use it. A browser's
  `<button>` keeps its native look under most of these, so the web host
  stays the oracle and needs no new vocabulary:
  - `gap` (or `column-gap`) between a button's children is the space
    between symbol and title
  - `font-size` / `font-weight` set the title's font
  - `white-space` / `line-clamp` govern wrapping
  - `accent-color` is the tint
- **The platform draws; the author chooses among the platform's options.**
  Size and corner shape are not CSS lengths on a native button; they are the
  platform's choices. A table, like `buttonStyles`, is the natural place:
  for example a `buttonSize` of `small | medium | large`. Corner shape is
  either another column, or CSS `border-radius` admitted on a native button
  with a declared mapping (`50%` → capsule) and refused otherwise.
- **One meaning on every host.** Each of the above needs:
  - an iOS mapping (`imagePadding`, `buttonSize`, `cornerStyle`,
    `titleTextAttributesTransformer`, `titleLineBreakMode`,
    `baseForegroundColor`)
  - a macOS mapping (`NSButton.controlSize`, `bezelStyle`, `font`,
    `imageHugsTitle`)
  - a web mapping (the CSS itself)
  - a Linux look
  - the stand-ins, and where each is a declared approximation
- **Defaults that look like the platform with nothing authored.** The gap,
  in particular, should default to the platform's own spacing, not 0, so an
  author who writes nothing gets what UIKit's apps get.
- **The first layout is right.** Size, font and wrapping all change the
  button's natural size. They have to reach the measurement the kernel uses
  on frame one (LLP 1069.011 D3 still lays a native button out at 64 × 34
  until UIKit reports), or every one of these shows as a jump on the second
  frame.
- **Refuse what cannot be honoured.** As today, anything a platform cannot
  draw is a Contract error that names the alternative, not a silent
  difference.

## 5. How to check it

The use cases in §1 make a fixture; `scripts/fixtures/native-buttons.contract`
is the natural home. For each case:
- a screenshot of the native button
- a screenshot of a hand-configured `UIButton.Configuration` / `NSButton`
  of the same intent
- a web render

They should match, and no frame should move after the first.
