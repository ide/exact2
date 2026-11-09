# Web follow-up rebases: Opus review, round 1

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Claude Code's Agent tool on account `ide@expo.dev`, effort max, in frozen worktrees at response `fe70065cd9`, motion `a46db2065f` and locks `4425485510`, each on `ead04512f1`.
- **Method:** one brief (sha256 `959448e6512a92c9a0a992648159946f5e2d877db96f0dce7d4e6346f8de9f7d`), one reviewer, with four passes for each branch: correctness, simplification, writing and verification. The reviewer read source and logs only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited, recorded in all three branches; its paths name the review worktrees and the author's logs, and its shas are of the reviewed history.

---

# Review record: three rebased exact2 web branches, round 1

- **Scope:** new base `ead04512f1`, old base `70365218ab`.
- **What I read:** the three frozen worktrees, the range-diffs, main's changes since the old base, and the author's logs.
- **What I ran:** only read-only `git` commands and file reads. I did not build, run tests or open a browser.
- **"By reading":** I read that source code but did not run it.

## Response: `ide/web-response-followups` at `fe70065cd9`

**Checked, no finding:**
- **Conflict resolution** (`host/web-js/rt.js:534-535`):
  - `save` keeps main's `r.placeholder` at index 18 and adds `pend.n.v` at index 19.
  - `restore` puts index 18 back into `r.placeholder` and writes index 19 to `pend.n`.
  - Only `commit()` (`rt.js:170`, `:193`) calls `save` and `restore`.
- **The `pend` signal** (`rt.js:463`, read at `host/web-js/build.mjs:588`) matches the runner's `pending(x)` (`runner/src/runner/in_flight.rs:10-31`). No other code reads `pending` on a resource.
- **Main's `placeholder` and `marks.js`:**
  - `marks.js` reads `r.ticket`, `r.placeholder` and `inflight.n`. It does not read `pend`.
  - `answers()` (`checkpoint.js:19-27`) keeps an answered stream's value, and `revalidate` makes the client subscribe again.
  - The branch does not change time-to-interactive.
- **`continuing`:** `Resources.some(r => r.ticket)` is necessary. `unfinishedAnswers()` and `unfinishedIO()` do not count streams (`held.js:14-21`, `ts-fetch.js:37-38`).
- **Rust checks:** the Rust tests that import `host/web/serve.mjs` run only in the async lane. So "touches no Rust" is a valid reason to skip the Cargo checks.

**Findings:**

1. **Nonblocking, verification.** Commit `7bbea091f7`, Test Plan, paragraph 1: "Removing each fix makes its regressions fail."
   - **Problem:** this base has only one negative. With `pend.n.v` removed from `save` and `restore`, the two browser rollback cases fail (`response-negative-resource-inspection.log`).
     - `response-negative-build.log` runs `build.test.mjs`, which does not test rollback.
     - No log on this base runs the rollback cases in `document-agent.test.mjs` under the negative.
     - No log on this base removes the render selector (`build.mjs:588`), the `continuing` change, or the `Retry-After` forwarding (`host/web/serve.mjs:918`, `:982`).
     - This rebase changed exactly these `rt.js` lines.
   - **Proposed edit:** run `document-agent.test.mjs` under the same negative, and remove each of the other fixes once. Otherwise, write: "Removing the pending-state restore makes the browser rollback regressions fail. The other negatives ran on `70365218ab`."

2. **Nonblocking, verification.** Same paragraph: "The build, document, resource, held-answer, timer, store-reader and long-poll suites pass."
   - **Problem:** the combined run (`response-suites.log`) reports 71 pass, 3 fail and 1 error.
     - `store-readers.test.mjs` calls `runTests`. `runTests` calls `resolveApp(dir)`, which sets `EXACT_APP_DIR` for the process (`scripts/app.mjs:495`). That makes the later long-poll and document-render builds fail.
     - One document-agent case times out in that run.
     - Run alone, the long-poll and document-agent suites pass.
     - `document-render.test.mjs` run alone reports 38 pass and 3 fail. The three failures are its engine loops (`:747`, `:804`, `:838`), which run `chromium`, `firefox`, `webkit` in that order. They stop at the Firefox launch, so WebKit never runs.
   - **Proposed edit:** "Each suite passes in its own process. The exception is the three document-render engine loops: they pass in Chromium, then stop at the Firefox launch (QUEUE.md) before WebKit. In one process, `store-readers.test.mjs` leaves `EXACT_APP_DIR` set for the suites after it."

3. **Nonblocking, writing.** Commit `7bbea091f7`, How: "Open streams remain recorded so an inferred client activates and subscribes again."
   - **Problem:** "recorded" does not say where.
   - **Proposed edit:** "The render still reports an open stream as continuing work. So an inferred page activates eagerly, and its client subscribes again."

4. **Nonblocking, writing.** Records commits `4850fbc8df` and `fe70065cd9` state results from earlier bases as current facts.
   - **Problem:**
     - `fe70065cd9` says "The feature patches are unchanged by rebase", but this rebase changed `rt.js`.
     - It says the suites pass "on the new base", and that the Cargo checks pass.
     - It says caps reports "the existing foldables recipe limit". `4850fbc8df` says "navigation source and foldables recipe violations".
     - On `ead04512f1`, caps reports only `PresenterIOS.swift` (`web-response-followups-caps.log`), and the Cargo checks did not run.
   - **Proposed edit:** give each result its base ("On `70365218ab`, …"), or remove the check results from these messages.

## Motion: `ide/web-computed-exit-motion` at `a46db2065f`

**Checked, no finding:**
- **Main's `emit.rs` and `rows.rs` changes:** they are Markdown work. `rows.rs` is now 1,493 lines; the shortened comments read well and need no change.
- **Main's press work (#1605 to #1607):** an `:active` scale lowers to `PressScale` (`contract/lower/src/states.rs:42-50`).
  - A static scale sets `press` (`rows.rs:166`). The exit then plays the `-exact-press` copy, which the JS target emits for every scale keyframes rule (`emit.rs:816-839`).
  - A computed scale writes a normal inline `scale` (`rows.rs:424-440`), and the plain keyframes override it.
  - The branch's browser cases test both. Main's `showScale` changes only how the press factor eases.
- **`__proto__`:** `declaration_map` writes computed keys (`presence.rs:77-94`), so `__proto__` is an own property.
- **Endless exits:** the kernel's setter (`kernel/build.rs:1300`) and lowering (`contract/lower/src/svg.rs:950-967`) refuse `infinite` and `paused`.

**Findings:**

1. **Blocking, correctness.** A computed exit now plays a value that depends on the order of assignments inside one action. The runner and the wasm host do not depend on that order.
   - **JS target:**
     - `when` ends the arm's scope and then calls `leave()` (`host/web-js/rt.js:1166`, `:1147`).
     - `Leave` reads the inline `--exact-exit-animation` at that moment (`rt.js:964-965`). The exit row is a plain `S` effect (`rt.js:791`, `:803`).
     - Effects run in the order that their sources were written (`rt.js:58`, `:82`, `:175`).
     - With `calm = false` then `shown = false`, the style effect runs first, so `leave 200ms …` plays. With the reverse order, the arm ends first, so nothing plays.
     - Virtualized rows read the same inline value (`list.js:528`).
   - **Runner:**
     - A region that switches arms destroys the old arm and does not evaluate its bindings (`runner/src/instance/region.rs:352-356`).
     - The kernel takes the exit from the current arena style (`kernel/src/txn.rs:1122`, `:1140`).
     - So iOS, macOS and the wasm web host play the value from before the action, in both orders.
   - **Why this is new and untested:**
     - Main refused computed exits, so this difference is new. The branch accepts any bound exit whose values are literals.
     - `QUEUE.md:1311-1352` on main records this requirement for the same feature: "snapshots the committed exit in rt.js `S` so a removal in the same action plays it in either assignment order, as the wasm host does".
     - No test covers it. In the compared conformance steps (`motion-conform/report.json`), `tap both` runs only while `First` is hidden. The browser cases change the preference and remove the node in separate commits.
   - **Proposed edit:**
     - For a bound exit, emit `px(e)` in place of `pr(e)` (`emit.rs:1116`). `px` adds `e` to a set and removes it at `onEnd`.
     - Add a `Before` hook. It runs before `flush()` (`rt.js:205`) and copies each element's inline `--exact-exit-animation` into `e.$exit`.
     - Make `Leave` and the call at `list.js:528` read `$exit` first.
     - Add a case to `layout-transition.test.mjs`: one action changes the exit input and removes the node, in both orders, and expects no ghost.
     - Add `tap both` with `First` shown to `presence-bound.steps`.
     - If the owner accepts the order dependence instead, record it in LLP 1063 "Known gaps" (beside `llp/1063-presence-and-layout-motion.rfc.md:231`), in `docs/agent-pitfalls.md`, and in the recipe's "JS target" item.

2. **Nonblocking, writing.** `QUEUE.md:1311-1352` ("A dynamic exit animation fails the web build only") still asks for computed exits on the JS target.
   - **Problem:** the branch delivers that part. Only the `contract build` part is still open.
   - **Proposed edit:** remove the delivered request and its "Done when the dynamic exit runs on the JS target" clause. Keep the `contract build` request. Keep the snapshot lesson while finding 1 is open.
   - **Also:** in `QUEUE.md:45`, "define how it loads" has no clear subject. Write "decide how the page loads that parser".

3. **Nonblocking, verification.** Commit `5cdb210e4b`, Test Plan, paragraph 2. The logs do not support its stated cause.
   - **Problem:**
     - The suite opens its page with `newPage({ reducedMotion: 'reduce' })` (`layout-transition.test.mjs:169`). In `webkit-newpage-samples.log`, that call returns in 0.5 to 0.6 s in 3 of 3 runs. A plain `newPage()` hangs in 3 of 3 runs.
     - The suite's WebKit cases still time out in all three runs. That includes `motion-exit-rerun-2.log`, written after the samples. The logs do not show which step stops.
     - The probe does not repeat the cases' steps. It opens a plain page and then emulates reduced motion (`probes/exit-webkit-probe.mjs:52-53`).
     - In the four `probe-webkit-emulate-*` runs, the probe's page opened twice. Both of those runs passed.
     - The WebKit conformance run was killed (exit 137) and wrote no report.
   - **Proposed edit:** time each step of the suite's WebKit cases, or run the probe with the suite's `newPage` form. Otherwise, write: "The suite's WebKit cases time out at a step these logs do not show. A probe that opens a plain WebKit page, emulates reduced motion and repeats the remaining steps passes both press variants in the two runs where its page opened."

4. **Nonblocking, verification.** Same Test Plan, paragraph 1.
   - **Problem:**
     - "press-scale checks pass": main's `host/web/tests/press-scale.test.mjs` loads `input-glue.js` directly and compiles nothing (`:10-21`). It runs no file that this branch changes. Its Chromium cases pass alone (`motion-press-scale-chromium.log`). In `main-press-scale-webkit.log`, one Chromium case fails to create a browser context, and the WebKit cases time out.
     - "Removing the exit-binding implementation makes those browser regressions fail": the negative swaps in all of main's `host/web-js/src`. It runs the Chromium cases only, and they fail at compile time (`motion-negative-exit.log`).
     - The recipe change reaches `contract`'s guide-compilation test. That test passes (`motion-docs-test.log`), but the Test Plan does not name it.
   - **Proposed edit:** "The existing layout and registry cases pass in Chromium. With main's compiler sources, the Chromium exit cases fail at compile time with the old refusal. The guide-compilation test passes." Remove the press-scale claim.

5. **Nonblocking, writing.** Commit `5cdb210e4b`, How, sentences 1 and 2, use the imperative mood. The owner's rules require the indicative mood.
   - **Proposed edit:** "The compiler parses the binding's string literals with the kernel and writes the selected exit declaration. Presence loads even when the first value is `none`. The kernel's paint policy and press-scale keyframes stay, and the layout row shares the mapping."

6. **Nonblocking, writing.** `docs/recipes/motion.md` loses facts that the old text gave.
   - **Lines 57-58:** they lose "when it ends" and "not motion". **Proposed edit:** "To change state when a motion ends, use a gated task's `after(ms, action)`. A `sequence` is sound and haptics, not motion."
   - **Line 49:** "finite keyframes" is wrong, because the animation must end, not the keyframes. **Proposed edit:** "`-exact-exit-animation` names keyframes that play when an `if` arm or `for` row leaves. It must end: `infinite` and `paused` are refused."
   - **Line 53:** restore "children jump to their place, unscaled".

7. **Nonblocking, writing.** Records commits `8708eda998` and `a46db2065f` state old-base results as current.
   - **Problem:** they report the old caps violations, suites that pass "on the new base", and Cargo checks. On this base, caps reports only `PresenterIOS.swift` (`motion-caps.log`), and the WebKit cases time out.
   - **Proposed edit:** as in response finding 4.

## Locks: `ide/web-build-locks` at `4425485510`

No correctness finding.

**Checked, no finding:**
- **Main's changes:** among this branch's files, main changed only `QUEUE.md`. Main's `build-lock.mjs` is the same at both bases.
- **Callers:** main added no callers and no match on the old error text.
- **Persistent lock file:** `dist.lock` stays beside `dist`. Generations live in `${dist}.gen` (`generations.mjs:23`).
- **Probes:** they open read-only and take a shared lock (`build-lock.mjs:55`, `:33`). Release runs only once.

**Findings:**

1. **Nonblocking, writing and verification.** Commit `34e943b5f7`, Test Plan, paragraph 1.
   - **Problem:**
     - "The read-only probe regression fails before its access-mode correction" and the shared-reader sentence describe earlier versions of this branch, not main. Main's probe already opens read-only and takes a shared lock.
     - These negatives, and the persistent-inode negative, have no log on this base. The message does not say where they ran.
   - **Proposed edit:** "Regressions check that a read-only lock file and a shared reader report no owner. With main's implementation, the persistent-inode regression fails (run on `70365218ab`; main's `build-lock.mjs` has not changed since)."

2. **Nonblocking, error message.** `host/web/build-lock.mjs:78`.
   - **Problem:** the file keeps the holder's PID for diagnosis, and the Windows lock is at byte 64 so that reads of the PID still work (`:29`). But nothing reads the PID, and the timeout message does not name the holder. Main's message did.
   - **Proposed edit:** read the file in the timeout branch: "`<lock>`: process 1234 (from the lock file) has held it for 30 s; wait for that build to finish."

3. **Nonblocking, writing.** `build-lock.mjs:1` says "Build swaps and GPU-cache copies share a persistent lock file".
   - **Problem:** each tree has its own lock file. Also, lines 24, 33, 35 and 55 use bare numbers where main had named constants.
   - **Proposed edit:** "Each tree's builders take one persistent lock file beside it." Name `LOCK_EX`, `LOCK_SH`, `LOCK_NB`, `LOCKFILE_EXCLUSIVE_LOCK`, `LOCKFILE_FAIL_IMMEDIATELY`, `ERROR_LOCK_VIOLATION`, `GENERIC_READ`, `GENERIC_WRITE` and `OPEN_ALWAYS`. Then remove the "fail immediately" comment.

4. **Nonblocking, writing.** Commit `34e943b5f7`, How.
   - **Problem:** sentence 1 uses the imperative mood. "The queue entry is removed" does not say which entry.
   - **Proposed edit:** "One persistent lock file stays, and the OS owns exclusion: …" and "The `QUEUE.md` entry about the GPU-cache lock test's mixed-protocol race is removed."

5. **Nonblocking, writing.** Records commit `4425485510`.
   - **Problem:** its Test Plan reports old-base Cargo and caps results as current.
   - **Proposed edit:** as in response finding 4.

## Outside the branches (by reading)

- **`marks.js` on main:** `host/web-js/marks.js:28-31` subtracts every resource ticket from `inflight.n`. An open stream keeps `r.ticket` after its first message (`rt.js:479`) but leaves `inflight` (`rt.js:408`). So time-to-interactive can miss one other loading piece. Proposed `QUEUE.md` line: count only tickets where `t.counted` is true.
- **Rust render host:** its `settle` (`host/render/src/lib.rs:807-822`) waits for every ticket in `runner.pending()`. `pending()` keeps answered streams (`runner/src/runner/in_flight.rs:36`), but `in_flight()` (`:117`) removes them. So the Rust renderer can still return 503 in the case that the response branch fixes in the JS renderer. Proposed `QUEUE.md` line for this.

`ide/web-response-followups` (`fe70065cd9`): READY
`ide/web-computed-exit-motion` (`a46db2065f`): NOT READY
`ide/web-build-locks` (`4425485510`): READY