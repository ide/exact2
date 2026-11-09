# Active-state stack rebase: Opus review, round 1

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Ocho account `claude:ide@expo.dev`, in a frozen worktree at `61ca82d5fb` on `c7662a06ec`.
- **Method:** one brief (sha256 `9911e773285fe7d6c4a4529f4070075afe642b8254024048427121e395a16aea`), one reviewer, with four passes: correctness, simplification, writing and verification. The reviewer read source only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited.

---

# Three-PR stack rebase: Opus review, round 1

I reviewed the rebased stack at `61ca82d5fb9eba2b5150eff8c89a7ffe0fdc6656` on upstream main `c7662a06ec2dc03804525146b56716503a475ed4`. I compared it with the old stack on `70365218ab`. This is a source review only. I ran no builds, tests or apps, I changed no files and I started no agents. I used `git range-diff`, `git diff`, `git show`, `diff`, `grep`, `sed` and `wc` only. All runtime results are your supplied or planned evidence, not mine.

**Result: one concrete finding, in `QUEUE.md`. The code integration is clean. The conflict resolution keeps both sides.**

## Finding

**1. `QUEUE.md`: the foldables cap note is now stale on the new main.** This is low severity.
- The note from the native-feedback layer says: "`docs/recipes/foldables.md` at 3254 bytes against 3072 … byte-identical to upstream main; shorten it".
- Upstream commit `2c78d3cf66` (#1533) rewrote that file (+27/−32). At HEAD it is 3063 bytes, and the cap is `RECIPE_BYTES = 3072` (`scripts/caps.mjs:41`).
- So the note's claims "exceeds its size cap on main" and "byte-identical to upstream main" are false for `c7662a06ec`. Its action is already done.
- This is an inference from file size and the cap constant. I did not run caps.
- Smallest fix: delete the note. Your fresh caps run will confirm it.
- The other baseline notes (Caltrain frame URL, Linux network fixtures, the share test, Mac first-click) name `70365218ab` or a date. They stay true as records, and I cannot check their runtime claims.

## Layer-by-layer integration

- **Layer 1 (active-paints, `119448cd98`):**
  - Range-diff shows commits 1–3, 5 and 6 as `=`.
  - Commit 4 (Queue) differs only in insertion context. Its two added notes are word for word the same. They now come after upstream's three arrangement notes.
- **Layer 2 (native-feedback, `a132c82e28`):**
  - Range-diff shows the Records commit as `=`.
  - The code commit changes in exactly four places:
    - the `QUEUE.md` context;
    - the `MenuConfirmationIOS.swift` context (upstream's `anchored` route line);
    - the `MenusIOS.sync` conflict;
    - two context lines in `NavigationBarIOS.swift` and `SegmentsIOS.swift`.
  - No added or removed line of the layer changed anywhere else.
- **Layer 3 (spelling, `61ca82d5fb`):** every commit is `=`.

## The conflict: `MenuHost.sync` (`MenusIOS.swift:129-141`)

Resolved order:
1. Reject active properties on live menu popovers.
2. `observeTouches()`.
3. `discardPendingConfirmations { !live($0.popover) || !$0.matches($0.popover) }`.
4. `followPrompt` when the confirmation has fields.
5. `if valid(owner) { owner.rejectActiveProperties() } else { resetConfirmation(preservingPending: true) }`.

**Upstream side is kept:**
- Step 3 and step 4 are unchanged, in upstream's order.
- The invalid branch calls `resetConfirmation(preservingPending: true)`, as upstream's one-line form did. At `:546-557`, this skips the full discard and schedules `resumeAfterRouteDismissal()`. The waiting queue therefore survives.
- If `followPrompt` resets the confirmation itself (`:487`), `confirmation` becomes `nil`, and the new branch is skipped. Upstream behaved the same way.
- The resolved branch adds no extra reset, so no confirmation is reset twice.

**Our side is kept:**
- A valid presented confirmation still calls `rejectActiveProperties()` on every sync. This is the R4/R5 behavior for an open alert that later gains an active property.
- `rejectActiveProperties` (`MenuConfirmationIOS.swift:106-108`) reads `actions`, `cancel` and `Presented.node`. Upstream's change to `Confirmation` removed `sourced` and added `anchored`, but it did not touch those three. The helper therefore still compiles against the same fields (source reading, not a build).
- The rejection at present time (`:1279`) still runs before the tint read.

**Removed checks:** none. Upstream's `valid(_:)` (`:436-445`) now branches on `anchored`, and the new branch calls it unchanged. Nothing rebuilds the alert or its actions.

## Automatic merges

- **Upstream extractions in `MenuConfirmationIOS`:** `preferredAction`, `choosable` and `style` are retained at `:23-57`. Our layer adds only the three-line method.
- **`PendingConfirmation` and `discardPendingConfirmations`:** retained (`:538-545`). Our layer does not touch them.
- **`MenuItemsIOS.swift`:**
  - It is byte-identical to the old layer's file.
  - I compared its `items`, `opensConfirmation` and `submenu` with the copy on new main, ignoring leading whitespace. The only differences are the layer's own: the new `rejectActiveMenuProperties` helper, one `rejectNativeActiveProperties(on: "UIAction")` call, and three comments that the old layer already dropped.
  - Upstream did not change that block between `70365218ab` and `c7662a06ec`. No upstream change is lost.
  - The block exists only once. It is gone from `MenusIOS.swift`, so there is no duplicate.
- **`HeaderShapeIOS.swift`:**
  - It is byte-identical to the old layer's file.
  - The region of `NavigationBarIOS.swift` it came from (lines 20-295) is identical on old and new main.
  - Upstream's NavigationBar hunks are all at line 774 or later, outside the moved code.
- **Navigation `contentScrollView`:**
  - Upstream moved `contentScroller(of:)` and `contentScrollView(of:)` to `ScrollsToTopIOS.swift:93,102`, made `element(named:in:)` internal, and changed `scroll = scroller?.scrollView` to `contentScrollView(of: c)`.
  - At HEAD, `NavigationBarIOS.swift:526` has upstream's form, and the layer's added block sits just before it.
  - Each helper has one definition. Upstream's `ownedScroll`, `hidesBackButton`, arrangement scroller, `projectContentScrollView` and `flowingTopContent` changes are present, with no layer edits to them.
- **Segmented control:** upstream's layout comment, its `available(_:forActivation:)` and its trait updates are kept. The layer's `rejectNativeActiveProperties(on: "UISegmentedControl")` line sits after `decide` and before `adopt`, as before.
- **New upstream native carriers:** I searched upstream's 25-commit diff for added `UIAction(`, `UIButton(`, `UIBarButtonItem(`, `UIMenu(`, `NSButton(` and `NSMenuItem(` lines. There are none, so no new native surface lacks the refusal.

## Passes

- **Correctness:** No code defect. Both sides of the conflict are kept. There is no queue loss, no lost check, no duplicate helper and no new reconstruction.
- **Simplification:** No finding. The resolution is the smallest combination: one `if` with two arms.
- **Writing:**
  - Finding 1 is the only text defect.
  - The Queue merge keeps upstream's four arrangement notes, the native-feedback notes and the active-paints notes, and nothing contradicts. A blank line between the native-feedback group and the active-paints group splits them into two Markdown lists. This is cosmetic only and was also present before the rebase.
- **Verification (source):**
  - The checkout is clean.
  - `git diff --check c7662a06ec 61ca82d5fb` reports only trailing hard-break spaces in `llp/reviews/code-2026-11-07-native-feedback-r2.astra.md`. The same report occurs on the old stack, and you say that record is unchanged.
  - The changed Swift files are within the 1,500-line cap: `MenusIOS.swift` 1,391, `NavigationBarIOS.swift` 1,244, `SegmentsIOS.swift` 696, `HeaderShapeIOS.swift` 276, `MenuConfirmationIOS.swift` 141, `MenuItemsIOS.swift` 98.
  - Pending and not claimed:
    - the six checks on the rebased top;
    - the UIKit runs: `QueuedAlertIOSTests` (including `testInvalidatingTheVisibleActionsResumesTheWaitingAlertWithItsModality`), `ConfirmationAlertIOSTests` (including `testAnOpenAlertRejectsAnActivePropertyAddedLaterWithoutReplacingItsActions`), `MenuStability` and `NativeActiveProjection`;
    - the `preservingPending` negative;
    - the tvOS compile and difftest.
  - Firefox remains excluded.
  - The runtime qualifications from the old base stay in the existing records, and I make no claim about current main's runtime limits.