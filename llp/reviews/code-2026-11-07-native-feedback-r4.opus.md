# Native feedback: Opus review, round 4

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Ocho account `claude:ide@expo.dev`, in a frozen worktree at `2e864051a1` on `72c8cabfe8`.
- **Method:** one brief (sha256 `8807cca3304cec324687538ad70486bf135cc5f9e8271d76ac72707d9e512fa7`), one reviewer, with four passes: correctness, simplification, writing and verification. The reviewer read source only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited.

---

# Native feedback: Opus review, round 4

I reviewed HEAD `2e864051a1a9dc97de0160c2305b98c92f80c5af` against `72c8cabfe8ce1ee03eb16b9da6ac5e2ab5e155e0`. This is a source review only. I ran no builds, tests or apps, I changed no files and I started no agents. I used Git and `wc` only. All runtime evidence below is the evidence you supplied, not my reproduction.

**Result: one concrete P2 defect remains (UIKit). One P3 is plausible but narrow (AppKit).**

## Findings

### 1. [P2, confirmed from source] A direct UIKit `configuration` write loses its transformer while an active color is set

- **Where:** `host/apple/Sources/ExactKit/IOS/ButtonConfigurationIOS.swift:36-45` (`removeActive`) and the handler wrapper at `host/apple/Sources/ExactKit/IOS/NativeButtonsIOS.swift:27-38`.
- **Cause:** `removeActive` always writes the saved base transformer back, for example `config.titleTextAttributesTransformer = previous.value` at line 40. It does not check whether the current transformer is still Exact's wrapper.
- **How the code reaches it:** The `element` hatch gives app code the `NativeButtonIOS` itself (`host/apple/Sources/ExactKit/ElementHatches.swift:305-311`). App code can then set `button.configuration` directly, not through `configurationUpdateHandler`.
- **Failure sequence:**
  1. A button has `:active { color: blue }`, so `activeTitle` holds the base transformer.
  2. A hatch sets a new `configuration` whose `titleTextAttributesTransformer` sets a custom font.
  3. On the next configuration update (a press or `setNeedsUpdateConfiguration`), the wrapper calls `removeActive`. `removeActive` puts back the old base transformer.
  4. `syncActive` then wraps that old base.
  5. The app's transformer is lost permanently. Clearing the active color does not bring it back.

  The same applies to `subtitleTextAttributesTransformer`, `imageColorTransformer` and `background.backgroundColorTransformer`.
- **Conflicts with:** "authored CSS properties override only their own field", "each host retains its full native capabilities", and the guide's sentence "Clearing a target restores the current native configuration". AppKit already handles this case: its `bezelColor`, `contentTintColor` and `attributedTitle` setters save native writes made during a hold.
- **Test gap:** `NativeButtonsIOSTests.swift:27-30` writes `configuration` directly but changes only `strokeWidth` and `contentInsets`. It changes the transformer only inside the handler, so this case is not tested.
- **Fix:** Use the AppKit pattern. Override the `configuration` setter on `NativeButtonIOS`. When the write is not Exact's own (add a flag like AppKit's `applyingActive` around `removeActive`, `syncActive`, `updateActiveImage` and `tintColorDidChange`), treat each incoming transformer in an owned slot as the new base, then wrap it again. Add a regression that sets a font transformer through `button.configuration =` while the active color is set, presses, releases and clears.

### 2. [P3, plausible] AppKit checks stale toolbar and status menu items, not the live popover rows

- **Where:** `MenusMac.swift:536-538` and `StatusItemsMac.swift:127` walk `item.menu.items`.
- **Cause:** `InvokerMenu` keeps the items from its last `fill` after the menu closes. `fill` removes them only at the next open (`MenusMac.swift:791-792`). The item is replaced only when the source node changes (`ToolbarMac.swift:618`, `StatusItemsMac.swift:122`).
- **Effect:** Suppose a row leaves the popover after a fill, for example a `children` op moves it into the page, and it carries `:active opacity` as an ordinary button. `sync` then records a false refusal ("cannot be represented by NSMenuItem") for a node that draws the override correctly. The same happens if the invoker retargets and the old rows are shown elsewhere in a form that is not a menu (agent painting).
- **Severity:** Only the journal is affected; native behavior is not. I did not trace whether moving a row this way occurs in practice.
- **Fix:** Use the same strategy as UIKit. Check the rows of `toolbarPopover(of: source)` instead of the stale `NSMenuItem` owners. No reconstruction is needed.

## Cache-boundary trace (final fixes)

**UIKit bar menus.** The check now runs in `prepareRoutes` (`NavigationBarIOS.swift:518-524`), before the `projectedSource` comparison at line 538. I traced the callers:

- `prepareRoutes` runs from `NavigationIOS.sync` for each owner (line 772).
- `NavigationIOS.sync` runs from `batchApplied` (`NavigationTabsIOS.swift:458`), which is gated by `rowsOnly`.
- `onlyListRows` (`ListRowsIOS.swift:24-37`) treats a popover named by a header button's `popovertarget` or `commandfor` as projected. A style op on a row in that popover therefore never counts as rows-only. The outer gate does not skip the check.

Remaining deferrals (`changing`, a modal transition, a held stack that waits) set `pendingSync`. The check then runs on the next sync. This is acceptable.

Because `rejectNativeActiveProperties` keeps one message per component, running the check on every batch does not repeat the journal entry.

Submenus with a menu role are covered by the menu-role scan in `MenusIOS.sync` (line 131). UIKit fills bar rows through `UIDeferredMenuElement.uncached` (`MenusIOS.swift:398`), which checks them again at each open.

**AppKit.** `MenuHost.sync` (line 1243) runs before `toolbar.sync` (line 1247) in `PresenterMac`. A toolbar item made in the current batch has an empty, unopened menu, so this order loses no case. Status items are checked in `place` after `item.menu` is set. Apart from finding 2, the path is correct.

**The new tests.**
- The UIKit regression installs its own `UIMenu(children: p.menus.items(of: pop))` on the bar item. Its identity assertions therefore show that Exact does not replace *a* menu. They do not show that the production `pullDown` menu is kept. Its negative case (no refusal before the fix) is still meaningful, because the refusal assertion depends on the moved check.
- The Mac regression asserts item, menu and action identity for the toolbar. For the status item it asserts only `places(source)`.

## Settlements

**R1**
1. Callback composition: **agree** for callbacks. The nesting guard handles a client that wraps the previous handler. Finding 1 is a separate path: direct writes.
2. Linux single background painter: **agree.** `presented.rs:258-264` skips generic press paint only for `Control` + `type=button`, which is exactly the native button lowering (`controls.rs:507-520`).
3. AppKit keeps intervening native writes: **agree.**
4. Live alerts and confirmations: **agree.**
5. Source cap and extractions: **agree.** The largest changed counted sources are `NodeViewMac.swift` at 1,498 lines and `GroupedListIOSTests.swift` at 1,497 lines.
6. Prose: **agree**, except that the guide's "restores the current native configuration" is not yet true on UIKit for direct writes (finding 1).

**R2**
1. AppKit held precedence: **agree.** The setters keep authored colors during the hold and save native values for release.
2. Linux neutral tab fill: **agree.** The `bordered`/`gray` branch fills `background` before it returns ink.
3. Retained-menu refusal: **disagreed at R3, now agreed, with finding 2 as a narrow exception.**

**R3**
1. UIKit bar menu without a menu role: **agree that the fix settles it** (trace above).
2. AppKit toolbar menu without a menu role: **agree that it settles the missing refusal.** Finding 2 is the reverse risk: a false refusal from stale items.
3. Final test-only delta (`MenuStabilityIOSTests`): **agree.**

## The four passes

- **Correctness:** Findings 1 and 2. I checked these and found no other defect:
  - retarget and clear while held on UIKit, AppKit and grouped rows;
  - viewless face color ownership (`NativeButtonState.colorOwnership`, `GroupedPressIOS` through `nativeButtonColorOwnership`);
  - disabled gating;
  - transform origin, including the `transform_origin` that grouped rows now include in their signature;
  - grouped rows pass the unmodified `state`, so the native highlight stays;
  - the Exact curve is removed: `ActivePresentation` holds without timing, and Linux `press_progress` returns `f.to` for native buttons.

  `NativeButtonState` copies the active rows, but `draws(as:)` drops the `written` masks. That is correct only because the `else if` branch compares `active.properties(over:)`, which reads those masks. It does.
- **Simplification:** Native writes are reconciled two ways: setters on AppKit, and slot restore on UIKit. Retained menus are also checked two ways: popover rows on UIKit, `NSMenuItem` owners on AppKit. Using one pattern each (fix 1, fix 2) removes both findings. No new API, registry or renderer is needed.
- **Writing:** The guide, grammar, RFC and schema comments are clear and consistent. Border color and shadow appear only as an extension path. The guide paragraph near `contract-for-agents.md:3076` has one overlong source line. That is cosmetic.
- **Verification:**
  - `git diff --check` reports only the three intentional hard-break spaces in the R2 transcript.
  - The working tree is clean at HEAD.
  - Changed counted sources are at most 1,498 lines.
  - Delta since `191c6a7751`: three source files and two test files changed, plus the R3 record.
  - Not covered by any supplied test: direct `configuration` transformer writes on UIKit, and stale AppKit `InvokerMenu` items.
  - All runtime results (the Mac/UIKit suites, tvOS, Linux, the six checks, difftest, Chrome/WebKit) are your supplied evidence, not mine. Firefox was skipped.