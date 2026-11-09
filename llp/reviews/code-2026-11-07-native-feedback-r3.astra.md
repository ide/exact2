# Native feedback: Astra review, round 3

- **Family:** OpenAI. GPT-6 Astra (`gpt-6-astra`) via `codex-cli 0.167.0`, reasoning effort max, read-only sandbox, a throwaway worktree at `191c6a7751` on `72c8cabfe8`.
- **Method:** one reviewer, with four passes: adversarial correctness, simplification, writing and verification. The initial brief (sha256 `c0085fd5f2d0f866c10765b585dc784c149d787b972d5aceec78b92134688a63`) was resumed after the menu test correction (sha256 `89d744ec2a898088242e565f7d2139f5fd46be93ac0545d321c931bb4793a658`). The author is not a reviewer.
- **Transcription:** the final message, unedited; its links name the review's evidence paths and its commit names that frozen source.

---

Reviewed `191c6a7751702fff674d0cb7cd9afd942bfb2b9a` against `72c8cabfe8ce1ee03eb16b9da6ac5e2ab5e155e0`, including both recorded reviews and relevant callers. **Two concrete defects remain.** These are source findings, not runtime reproductions.

1. **[P2] UIKit bar menus without an explicit menu role still bypass live refusal.**

   The added validation runs inside [`project` at NavigationBarIOS.swift:614](/tmp/exact-native-astra-r3-checkout/host/apple/Sources/ExactKit/IOS/NavigationBarIOS.swift:614), but [`prepareRoutes` at line 531](/tmp/exact-native-astra-r3-checkout/host/apple/Sources/ExactKit/IOS/NavigationBarIOS.swift:531) calls `project` only when `BarSource` changes. Changing an existing menu row’s active opacity does not change that source: the item signature contains the invoker’s properties, not its menu rows.

   Open a menu-shaped popover without `role="menu"` from a native header button, then add active opacity to one row while leaving the header unchanged. The route cache skips the new validation. The general menu synchronization also misses it: its initial scan requires the menu role, and [native invokers continue before the custom-invoker validator](/tmp/exact-native-astra-r3-checkout/host/apple/Sources/ExactKit/IOS/MenusIOS.swift:173). The retained `UIAction` silently ignores the override.

   Validation must run before the outer route cache, while retaining the native item and menu.

2. **[P2] AppKit toolbar menus without an explicit menu role remain outside retained-menu validation.**

   [`MenuHost.sync` at MenusMac.swift:536](/tmp/exact-native-astra-r3-checkout/host/apple/Sources/ExactKit/Mac/MenusMac.swift:536) checks semantic menu popovers and menus in `entries`. Toolbar menus belong to neither category when their popover has no menu role: [`toolbarPopover` accepts their shape without requiring that role, and AppKit tracks their `InvokerMenu` itself](/tmp/exact-native-astra-r3-checkout/host/apple/Sources/ExactKit/Mac/MenusMac.swift:768).

   Open such a toolbar menu, then add active opacity to an existing action row with no independent shortcut or menu placement. The retained menu remains in place through [ToolbarMac.swift:618](/tmp/exact-native-astra-r3-checkout/host/apple/Sources/ExactKit/Mac/ToolbarMac.swift:618), but neither synchronization scan checks its rows. No refusal is journaled until reconstruction or reopening.

   Revalidate these existing projected menus during synchronization without replacing their native objects.

My assessment of every R1 settlement:

1. **Agree on UIKit callback composition in this candidate.** The nesting guard lets a client call the previous handler and finishes composing active fields after the outer callback returns. Unrelated configuration fields remain intact.
2. **Agree on Linux’s single background painter.** Generic pressed-background painting is excluded for native buttons; the native painter owns the override.
3. **Agree on preserving intervening AppKit writes.** The final setters retain authored colors during the hold and save newer native values for restoration.
4. **Agree for live confirmations and alerts.** Their synchronization paths now revalidate retained actions. This does not settle the menu paths identified above.
5. **Agree on the source-cap correction and extractions.** `HeaderShape`, menu-item extraction, and `NodeExtras` placement are coherent. No changed counted source exceeds 1,500 lines.
6. **Agree on the prose corrections.** The guide, grammar, RFC, and schema distinguish native field overrides from custom press timing. Border/shadow support and spelling retirement remain outside this layer.

My assessment of every R2 settlement:

1. **Agree.** The AppKit regression now asserts authored colors during the hold, clears CSS while still held, and checks restoration of the newer native colors and font.
2. **Agree.** The neutral-tab branch now fills its native shape before returning ink. The supplied positive/negative results directly exercise the missing fill.
3. **Disagree that retained-menu refusal is fully settled.** The in-page UIKit correction, retained context-menu check, AppKit entry traversal, and semantic-menu scans address their paths. Findings 1–2 identify remaining paths outside those checks.

I also **agree with the final test-only delta**. [MenuStabilityIOSTests.swift:46](/tmp/exact-native-astra-r3-checkout/host/apple/tests/ExactKitTests/MenuStabilityIOSTests.swift:46) now records the menu and action from `UIButton` after assignment, correctly respecting the SDK’s public `copy` property. Its supplied negative/positive result validates that in-page path; it does not cover either finding above.

The four passes found:

- **Correctness:** Findings 1–2. No additional concrete finding from held retarget/clear, viewless color ownership, callback composition, disabled gating, or geometry/origin. Pure-title bar color and mixed-combination refusal preserve the native component.
- **Simplification:** No separate finding. The remaining defects concern where existing validation runs. They require no new registry, API, renderer, or tooling.
- **Writing:** No additional substantive defect. The revised prose states the intended semantics clearly; the implementation exceptions are the findings above.
- **Verification:** All 69 changed working files match HEAD. All 60 changed counted source files satisfy the line cap. The foldables recipe is 3,254 bytes and identical to the review base. `git diff --check` reports only three Markdown hard-break trailing spaces in the verbatim R2 review. I modified no files, launched no agents, and ran no runtime suites.

Runtime results remain supplied evidence: corrected UIKit menu negative/positive, callback and viewless-color tests; AppKit’s five classes; neutral Linux negative/positive and integration suites; the full Linux lib rerun; build, tests, clippy, fmt, workspace and boot; local difftest; tvOS; Chrome 12/12 and WebKit zero failures. Earlier native/grouped/fidelity results precede the final menu hooks. Caps retains the unchanged recipe failure, navigation retains the main-reproduced share failure, and the complete-main Linux timeout comparison remains pending. Remote difftest is not claimed; Firefox was skipped.