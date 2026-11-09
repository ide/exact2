# Native feedback: Opus review, round 5

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Ocho account `claude:ide@expo.dev`, in a frozen worktree at `8a326e69b2` on `72c8cabfe8`.
- **Method:** one follow-up brief (sha256 `866bd87f554b5002e954253446e61d2f71acedf4502ec6eadad060e1e6d03f48`), one reviewer, with four passes: correctness, simplification, writing and verification. The reviewer read source only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited.

---

# Native feedback: Opus review, round 5

I reviewed HEAD `8a326e69b2329cda11812194d27d37af94790828` against `72c8cabfe8ce1ee03eb16b9da6ac5e2ab5e155e0`, and the delta from my last reviewed commit, `2e864051a1`. This is a source review only. I ran no builds, tests or apps, I changed no files and I started no agents. I used Git and `wc` only. All runtime results below are your supplied evidence, not mine.

**Result: no concrete defect remains. Both R4 findings are settled.**

Delta since `2e864051a1`: `NativeButtonsIOS.swift` (+29), `ButtonConfigurationIOS.swift` (2 lines), `MenusMac.swift`, `StatusItemsMac.swift`, two test files, one rewrapped guide paragraph, and the R4 record.

## R4 finding 1 (P2, UIKit direct `configuration` writes): settled

**What changed:**
- `NativeButtonIOS` overrides the imported Objective-C property `__configuration` (`NativeButtonsIOS.swift:30-42`).
- On a write that is not Exact's own, it reads the four public transformer properties through KVC. It drops each saved slot whose incoming object is not the object Exact installed. It then calls `syncActive(requestUpdate: false)`, which saves the new value as the base and wraps it again.
- `applyActiveConfiguration` (lines 43-52) guards Exact's own writes. It records `installed` from the getter after the set, so any copy UIKit makes on set is what later writes are compared against.

**Write paths I traced:**
1. **`ButtonConfigurationIOS.apply`** (`:306`, `:368`, `:377`). `resetActiveConfiguration` clears the slots first. The first write therefore installs wrappers over `apply`'s own transformers. Each later write carries `apply`'s local transformers, not Exact's wrappers. Those slots are dropped and rebuilt over the latest local value. Its final `syncActive` then finds no change. The result is correct, at the cost of one extra rewrap per write.
2. **`removeActive` and `syncActive`** now use `applyActiveConfiguration` (`ButtonConfigurationIOS.swift:44`, `:80`). These writes are guarded and do not re-enter `syncActive`.
3. **Composed handler** (`:56-68`).
   - `removeActive` clears the slots.
   - The client's write inside `newValue` goes through the unguarded setter, so the client's transformer becomes the base at once.
   - The outer `syncActive` then finds no change.
   - The nesting guard for a client that wraps the previous handler is unchanged.
4. **`updateActiveImage` and `tintColorDidChange`** read the configuration, change it and write it back unguarded. They keep the transformer objects, so the slots survive. This relies on object identity staying stable across a Swift value round trip. Your simulator probe and the regression's unrelated `titlePadding` write cover that. I cannot confirm it from source.
5. **UIKit's own automatic update.** If UIKit reassigns `configuration.updated(for:)` through the same setter, a shallow copy keeps the block objects. Your press, release and repress results cover this. Source alone does not show it.
6. **Init.** Stored properties have defaults, so they are set before `super.init`. `syncActive` returns early while `written` is nil. A `nil` configuration write drops the slots, and `syncActive` returns at its guard. Both are safe.

**Nesting:** `applyActiveConfiguration` resets its flag in `defer`. Its write cannot reach the unguarded `syncActive`, so no nested call follows from Exact's paths.

The regression replaces all four slots while the button is held. It makes an unrelated write, presses, releases, presses again and clears. It checks the client font and colors at each step. This is the R4 failure sequence. You report that it failed before the fix and passes after; that is supplied evidence.

The fix depends on the `SwiftPrivate` import name `__configuration`/`__UIButtonConfiguration`. That is a maintenance dependency on the SDK, not a defect. Your UIKit results and the tvOS compile cover the current SDK.

## R4 finding 2 (P3, AppKit stale menu items): settled

**What changed:**
- `rejectActiveMenuProperties(in:)` now takes the popover and checks its direct button rows that are not popovers or previews (`MenusMac.swift:528-532`).
- The `row.isButton` filter matches the menu builder (`MenusMac.swift:842`).
- Toolbar items resolve their live popover through `toolbarPopover(of: source)` (`:536-540`). Status items do the same (`StatusItemsMac.swift:127`). Active menu entries check `entry.popover` (`:553`). The menu-role scan uses the same helper (`:541-543`).
- No `NSMenu` or `NSMenuItem` is rebuilt, and no new registry is added.

**Confirmation entries:** this changes what is checked. The old walk visited the `NSMenuItem` owners, which are only the actions that have a press (`ChooserMac.swift:76`, `:117-121`). The new walk also visits the single cancel button, which has no press. AppKit does not draw that cancel row as an item, so refusing an active override on it is still accurate. This is not a defect.

The regression adds a second row so the target stays menu-shaped. It checks the refusal, clears the cache entry, moves the row into the page and changes its opacity, then expects no new refusal. It covers both the toolbar and the status variant. You report that both failed before the fix.

## Prior settlements

- **R1 1–6:** I still agree. R1 #1 (callback composition) now also covers direct writes, through finding 1's fix. R1 #6 (prose): the guide's "Clearing a target restores the current native configuration" is now true on UIKit as well.
- **R2 1–3:** I agree. R2 #3 is fully settled now.
- **R3 1–2:** I agree. The UIKit check before the cache, traced through `batchApplied`/`rowsOnly` in R4, is unchanged.
- **R4 1–2:** settled, as above.

## Passes

- **Correctness:** No concrete defect. I checked the setter's re-entry, init, the composed callback, the `apply` write sequence, retarget and clear while held, and the menu checks for toolbar, status, entry and menu-role popovers.
- **Simplification:** Both hosts now use the same pattern.
  - Native writes: setters that save native values (AppKit) and a setter with an identity check (UIKit).
  - Retained menus: both hosts check the live popover rows.

  No new API, registry or renderer is added.
- **Writing:** The guide paragraph at `contract-for-agents.md:3077-3080` is rewrapped, and its text is unchanged. The new comments in `NativeButtonsIOS.swift:28-29` say why the private-prefixed property is overridden, which the code alone does not show. The R4 record's header and opening match my R4 message. I did not compare the whole record line by line.
- **Verification:**
  - The working tree is clean at HEAD.
  - `git diff --check` reports only the three intentional hard-break spaces in the R2 transcript.
  - Changed source and test files are within the cap. The largest is `MenusMac.swift` at 1,007 lines.
  - Not run by me: the UIKit suites (NativeButtons, Fidelity, GroupedPress, ActiveProjection, MenuStability), the tvOS compile and caps were still running in your report.
  - The earlier six checks, difftest, Linux, Chrome and WebKit results, the foldables cap and the UIKit share failure on main remain as you supplied them. Firefox was skipped.