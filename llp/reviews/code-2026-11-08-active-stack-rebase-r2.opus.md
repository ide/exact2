# Active-state stack rebase: Opus review, round 2

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Ocho account `claude:ide@expo.dev`, in a frozen worktree at `01c6f0282b` on `c7662a06ec`.
- **Method:** one follow-up brief (sha256 `6af63a92dad1ba24a39a3e60f913dc89686639b0524660ab3798b8afefa3a29c`), one reviewer, with four passes: correctness, simplification, writing and verification. The reviewer read source only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited.

---

# Three-PR stack rebase: Opus review, round 2

I reviewed HEAD `01c6f0282b421473807f650d4be88d7dbd800a23` on upstream main `c7662a06ec`. I compared it with my R1 source, `61ca82d5fb`. This is a source review only. I ran no builds, tests or apps, I changed no files and I started no agents. I used `git`, `grep`, `sed` and `wc` only. All runtime results are your supplied evidence, not mine.

**Result: no defect remains. The R1 finding is settled.**

## Stack shape

- The new commit `e6db33c1ce` ("Queue: remove the resolved foldables cap note") has parent `a132c82e28`. It changes only `QUEUE.md`, with one deletion.
- `git range-diff a132c82e28..61ca82d5fb e6db33c1ce..HEAD` shows both spelling-layer commits as `=` (`b25f492b8d` = `9aacbe2881`, `61ca82d5fb` = `01c6f0282b`).
- `git diff 61ca82d5fb HEAD` changes only `QUEUE.md`, with one deletion. No file under `llp/reviews` changed, so the records stay as they were.
- The first layer, the native-feedback code commit, the `MenuHost.sync` resolution and all the automatic merges are byte-for-byte the same as in R1. My R1 source conclusions on them still hold:
  - both sides of the conflict are kept;
  - there is no queue loss, lost check, duplicate helper or new reconstruction;
  - the line counts are unchanged and within the cap.

## R1 finding 1 (stale foldables cap note): settled, agree

- The removed line is exactly the stale note. No other `QUEUE.md` line changed.
- At HEAD, `docs/recipes/foldables.md` is 3063 bytes, and the cap is 3072 (`scripts/caps.mjs:41`). The queued action is therefore complete, and deletion is the correct fix.
- `foldables` still occurs in `QUEUE.md`, at lines 787 and 790. Both are older Duo notes that refer to the recipe's content, not its size, so neither conflicts with this change.
- The notes that remain near the top are the upstream arrangement notes, the iOS share-test note, the two active-paints notes and the JS-fixture notes. None of them contradicts another.
- `git diff --check c7662a06ec HEAD -- QUEUE.md` is clean.

## Passes

- **Correctness:** No defect. The delta changes no code.
- **Simplification:** No finding. A one-line deletion is the smallest fix.
- **Writing:** No defect. One cosmetic point from R1 remains: a blank line separates the share-test note from the two active-paints notes, so they render as two Markdown lists. It was there before the rebase, and it is not a defect.
- **Verification:**
  - The checkout is clean at HEAD.
  - Supplied, not run by me: difftest quick passed on the rebased top (13.7 s), and `cargo build --all-targets --keep-going` passed on M6.
  - Still running, and I do not claim them:
    - tests, clippy, fmt, workspace, boot and caps;
    - the UIKit negative, which removes only `preservingPending: true` from the invalid-confirmation arm and runs `QueuedAlertIOSTests`;
    - the UIKit positive (QueuedAlert, ConfirmationAlert, MenuStability and NativeActiveProjection);
    - the tvOS compile.
  - The source shows the planned negative is the right one. That arm is the only place where the resolved code differs from what upstream needs to keep waiting confirmations.
  - Firefox remains excluded.