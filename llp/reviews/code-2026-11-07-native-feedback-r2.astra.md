# Native feedback: Astra review, round 2

- **Family:** OpenAI. GPT-6 Astra (`gpt-6-astra`) via `codex-cli 0.167.0`, reasoning effort max, read-only sandbox, a throwaway worktree at `74a657b498` on `72c8cabfe8`.
- **Method:** one brief (sha256 `2d222e279f5aef97a684ccfb2bbed3a02692dd19ca95e8251c5b41d14e579eab`), one reviewer, with four passes: adversarial correctness, simplification, writing and verification. The author is not a reviewer.
- **Transcription:** the final message, unedited; its links name the review's evidence paths and its commit names that frozen source.

---

Reviewed frozen HEAD `74a657b498` against `72c8cabfe8`, including the R1 review and relevant callers. No files changed or agents launched. Three concrete defects remain.

1. **[P2] AppKit native writes displace authored overrides while the button remains held.**  
   The setters save the new native base, but also immediately install it: [NativeButtonsMac.swift:70](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/Mac/NativeButtonsMac.swift:70). With active red background and blue ink, native writes of purple bezel, orange tint and brown title therefore replace the authored colors before release. The unchanged-highlight guard does not reapply them: [NativeButtonsMac.swift:144](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/Mac/NativeButtonsMac.swift:144).

   Preserve the latest native base while continuing to apply the authored field during the hold. The new test misses this: it performs the writes, releases, then asserts restoration; it neither checks the held appearance nor clears the CSS properties while held: [NativeButtonsMacTests.swift:54](/tmp/exact-native-astra-r2-checkout/host/apple/tests/ExactKitTests/NativeButtonsMacTests.swift:54).

2. **[P2] Linux neutral tabs silently lose active background color.**  
   Generic pressed-background painting is now skipped for every native button: [presented.rs:258](/tmp/exact-native-astra-r2-checkout/host/linux/src/paint/presented.rs:258). However, the native painter’s neutral-tab branch returns an ink color without painting the active background: [button.rs:507](/tmp/exact-native-astra-r2-checkout/host/linux/src/paint/button.rs:507). It never reaches the new active-background fill at [button.rs:577](/tmp/exact-native-astra-r2-checkout/host/linux/src/paint/button.rs:577).

   This affects an enabled native `button role="tab"` with `aria-controls` inside a `tablist`, using the default or gray style under neutral metrics. Its authored active background is accepted but disappears. Keep the single native painting owner and handle the override in this branch; restoring generic painting would restore the alpha defect.

3. **[P2] Already-open native menus miss refusal diagnostics for newly added active properties.**  
   UIKit menu rows are checked when `UIAction` instances are constructed: [MenuItemsIOS.swift:26](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/IOS/MenuItemsIOS.swift:26). Batch synchronization now rechecks confirmations, but not retained menu actions: [MenusIOS.swift:128](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/IOS/MenusIOS.swift:128). An unchanged target/title takes the native-menu cache return: [NativeButtonsIOS.swift:440](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/IOS/NativeButtonsIOS.swift:440).

   Open a menu with no active overrides, then add active opacity to an existing row through a commit. The displayed `UIAction` cannot express it, yet no refusal is journaled until reconstruction. The retained AppKit chooser has the same construction-only check: [ChooserMac.swift:118](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/Mac/ChooserMac.swift:118), while [MenusMac.swift:528](/tmp/exact-native-astra-r2-checkout/host/apple/Sources/ExactKit/Mac/MenusMac.swift:528) keeps the valid menu. Revalidate the presented rows during synchronization while preserving their native components.

My assessment of each R1 settlement:

1. **Agree.** UIKit now removes only saved transformer fields, invokes the client callback, then wraps the resulting fields at the configuration callback boundary. The font callback uses the title transformer. I found no remaining configuration-equality strategy or layout reconciliation loop.
2. **Agree with the double-paint correction.** The supplied positive and negative alpha results support retaining it. Finding 2 identifies a separate native-painter branch that the focused regression does not cover.
3. **Disagree that this fully settles native writes while active.** Release restoration now preserves the newer native values, but held precedence remains wrong, as finding 1 explains.
4. **Agree for live confirmations, alerts and component-identifying diagnostics.** That correction does not cover retained native menus, as finding 3 explains.
5. **Agree with the extractions, NodeExtras placement and source-cap correction.** The recipe is 3,254 bytes and byte-identical to the specified review base. I cannot independently confirm its current upstream-main identity: this checkout’s local `origin/main` is stale, dated October 20.
6. **Agree.** The guide, RFC and schema comments distinguish custom timing from native behavior and describe field-only overrides. The custom example opts out of native appearance. Border/shadow remain unimplemented, with a straightforward extension path through existing property transport and host adapters.

The four passes found:

- **Correctness:** The three defects above. I also traced held retarget/clear, viewless face color ownership, callback composition, disabled handling, transform origin, and projection caches. Pure-title bar color and mixed-combination refusal preserve the native component as requested.
- **Simplification:** No additional finding. The ordinary source extractions are reasonable, and the remaining corrections fit existing setters, painters and synchronization paths. No new registry or API is needed.
- **Writing:** No additional defect in the revised prose. It describes the intended behavior clearly; the implementation exceptions are the findings above. Retained public spelling was excluded from review.
- **Verification:** `git diff --check` passed. All 62 changed working-tree files matched HEAD. An independent source-line scan found no counted source above 1,500 lines; this was not a full caps run. I ran no runtime suites.

Runtime results remain the supplied evidence: Chrome 12/12 equal, WebKit zero failures, the isolated iOS suites and retained-alert test passing, and the Linux alpha positive/negative checks. Earlier clippy, workspace and difftest results belong to the earlier R1 candidate. The current root gate, broad Linux rerun, macOS suites, iOS negative checks and navigation-share upstream comparison remain pending. Firefox was skipped.