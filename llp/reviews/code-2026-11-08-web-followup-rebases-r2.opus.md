# Web follow-up rebases: Opus review, round 2

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Claude Code's Agent tool on account `ide@expo.dev`, effort max, in frozen worktrees at response `3d29de332e`, motion `242da55e25` and locks `603b8f318b`, each on `ead04512f1`.
- **Method:** one brief (sha256 `b0f3818493b00b17d32753eac963143d889d8a7c5e6132f77c1510a92d7d4029`), one reviewer, with four passes for each branch: correctness, simplification, writing, and verification and tests, and a check of every round-1 settlement. The reviewer read source and logs, fetched Microsoft's Win32 documentation, and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited, recorded in all three branches; its paths name the review worktrees and the author's logs, and its shas are of the reviewed history.

---

# Review record: three exact2 web branches, round 2

- **Heads:** response `3d29de332e`, motion `242da55e25` and locks `603b8f318b`. Each is on `ead04512f1`. The source commits are `8bb756efce`, `0b707fc952` and `140e7a8049`.
- **What I read:**
  - the three frozen worktrees and `git range-diff` from the round-1 heads;
  - the branch reflogs, to date each fixup against the logs;
  - the logs and probes;
  - `AGENTS.md`, `rules/RULES.md`, `docs/testing.md` and `/Users/admin/AGENTS.md`.
- **What I ran:**
  - read-only `git` and two `bun -e` probes;
  - `rustfmt --edition 2021 --check` on standard input, which writes nothing;
  - fetches of Microsoft's pages for `LockFileEx`, `UnlockFileEx`, `CreateFileW`, generic access rights and system error codes.
  - I built nothing, ran no test and opened no browser.
- **Dating:** most logs name no commit. I dated each log against the reflog times.
- **"By reading":** I read that code but did not run it.
- **Result:** there is no blocking finding. All findings are nonblocking.

## Response: `ide/web-response-followups` at `3d29de332e`

### Findings

1. **Nonblocking, verification.** Commit `8bb756efce`, Test Plan, paragraph 2, says the suites "pass, each in its own process".
   - Four suites have a run of their own:
     - `response-document-agent.log`: 31 pass.
     - `response-document-render.log`: 38 pass, and 3 fail at the Firefox loops.
     - `response-time-resource-inspection.log`: 3 pass.
     - `response-longpoll.log`: 1 pass.
   - `response-time-build.log` runs `build.test.mjs` alone, but it filters out 5 of the 13 cases (`response-time-build.xml`).
   - No log runs the held-answer, timer or store-reader suites alone. `response-suites.log` runs eleven files in one process, and it names only the files that fail.
   - The How of records commit `3d29de332e` repeats the claim.
   - **Proposed edit:** "The build, document, resource, held-answer, timer, store-reader and long-poll suites pass. In one `bun test` process, `store-readers.test.mjs` leaves `EXACT_APP_DIR` set for the files after it (`QUEUE.md`), so the document and long-poll suites also ran alone, where they pass. The exception is …"
   - **Alternative:** run the three suites alone, and run `build.test.mjs` without a filter.

2. **Nonblocking, test reliability.** Fixed render deadlines.
   - **Item 1:** `host/web-js/document-agent.test.mjs:66` renders each path with a 500 ms deadline. Line `:132` uses 1,000 ms.
     - Some pages must settle: `/`, `/status`, and the rollback case that starts with nothing pending. On a slow machine they can need more time, and then they answer 503.
     - The renderer returns as soon as nothing is in flight (`host/web-js/render.mjs:4-5`). A long deadline therefore costs nothing when a page settles.
     - `docs/testing.md` says: "A fixed sleep is too long on a fast machine and too short on a slow one." This applies the same way to a deadline that a page must beat.
     - **Proposed edit:** `render(path, expected === 503 ? 500 : 10000)` at `:66`, and `render('/', initiallyPending ? 1000 : 10000)` at `:132`.
   - **Item 2:** in `host/web-js/build.test.mjs:334-354`, the retry test builds a site. Then it waits for the 3 s render deadline (`render.mjs:22`) to pass four times.
     - Its bound is 30 s (`:354`). It took 12.6 s alone (`response-time-build.xml`).
     - A variant that sent the four requests at the same time took 27.0 s (`response-r2-retry.xml`). That is 3 s less than the bound.
     - The other render test in the file has a 60 s bound (`:332`).
     - **Proposed edit:** `}, 60000);` at `:354`.
     - **Optional:** remove the HEAD request for `/feed`. Both HEAD requests use the same header code (`host/web/serve.mjs:918`), and each one costs one more 3 s render.

3. **Nonblocking, writing.** Commit `8bb756efce`, How, paragraph 2.
   - It names the three entries that `QUEUE.md` gets. It does not name the two entries that it removes: "`serve` drops a rendered page's `Retry-After`" and "A JS render treats an answered open stream as pending".
   - It calls all three entries "related". The `EXACT_APP_DIR` entry is a test-harness problem that the testing found.
   - **Proposed edit:** "`QUEUE.md` drops the two entries that this change delivers. It records two related problems and one found while testing: the Rust render host holds a page for an answered stream in the same way, an open stream hides other loading from time-to-interactive, and a test that names its app by path leaves `EXACT_APP_DIR` set for later test files."

4. **Nonblocking, writing.** Records commits `3d29de332e` and `4201001ce3` use the imperative mood. `/Users/admin/AGENTS.md` requires the indicative mood.
   - `3d29de332e`, How, sentence 1: "Record Opus's round 1 final without editing its transcription; …"
   - `4201001ce3`, How, sentence 1: "Record Astra's joint round 3 final …"
   - `4201001ce3`, Test Plan, sentence 1: "Verify the transcription byte-for-byte …"
   - **Proposed edit:** "This commit records Opus's round 1 final without editing its transcription; …", "This commit records Astra's joint round 3 final …" and "The transcription matches the saved reviewer final byte for byte in both branches."

### Round-1 settlements

- **Finding 1 (negatives):** I agree. Six negatives ran on this base, and each one makes its regression fail.
- **Finding 2 (suite claims):** I agree with the document-render wording. The "own process" wording claims more than the logs show (finding 1). The text that round 1 proposed had the same fault.
- **Finding 3 (How):** I agree.
- **Finding 4 (records bases):** I agree. The imperative mood remains (finding 4).
- **QUEUE entries:** `QUEUE.md:12-14` holds the two items outside the branches and the `EXACT_APP_DIR` problem. By reading, each entry agrees with the code (next section).

### Checked, no finding

- The source is the same as in round 1. `git diff 7bbea091f7 8bb756efce` changes only `QUEUE.md`.
- **`QUEUE.md:12`:** `host/render/src/lib.rs:807-814` waits on every ticket in `runner.pending()`.
  - `pending()` (`runner/src/runner/in_flight.rs:36-50`) keeps an answered stream.
  - `in_flight()` (`:117-123`) removes it through `waited()` (`runner/src/runner.rs:300-308`).
- **`QUEUE.md:13`:** `marks.js:28-31` subtracts every resource ticket from `inflight.n`. At its first message, `send`'s `done` (`rt.js:406-409`) stops counting a stream, but the stream keeps its ticket.
- **`QUEUE.md:14`:** `scripts/app.mjs:494-495` sets `process.env.EXACT_APP_DIR` for a path. `store-readers.test.mjs:211` gives a path to `runTests`.
- **Negatives** (`response-r3-negative-*.log`):
  - Without the save, the rollback case that starts pending fails.
  - Without the restore, both rollback cases fail.
  - Without the pending selector, `/` answers 503.
  - Without the continuing report, the page has no `data-activate="eager"`.
  - Without either `Retry-After` step, the header is `null`.
- **Transcription:** after its header, the records file is the same as `r1.final.md`, byte for byte. Its sha256, `6a2e168e…`, is the value that the three records commits give.

## Motion: `ide/web-computed-exit-motion` at `242da55e25`

### Findings

1. **Nonblocking, verification.** Commit `0b707fc952`, Test Plan, paragraphs 2 and 3.
   - **"the list … suites … pass":**
     - In `motion-r3-host-web-js-list-accessibility.log`, the case "list items keep links, layout and identity on webkit" times out at 60 s.
     - `motion-r3-host-web-js-list-structures.log` skips 11 cases. Its skip message names a missing `EXACT_WEB_DIST` build.
   - **"the motion recipe compiles to the JS target":** the last compile is `motion-r2-recipe-js.log`, at 15:20. That was before the `px` registration that the recipe's row now gets.
   - **"in main's own WebKit tests":** `main-press-scale-webkit.log` shows that main's WebKit cases time out. It does not show the step where they stop.
   - **Formatting:** `final-motion-fmt.log` is older than fixup `5d62fa0a91`, which moved the registration into `motion.rs`, and the `final2-*` runs have no format check. My `rustfmt --check` of the six changed `src` files at the head shows no difference. The claim is therefore correct.
   - **Proposed edit:** "The layout and registry cases, the list-accessibility, list-structures, sheet-leave, dataset and presence suites, and the guide-compilation test pass. List-accessibility's WebKit case times out on this Mac, and list-structures skips its 11 cases that need `EXACT_WEB_DIST`."
   - Compile the recipe again at the head, or say that it compiled before the `px` registration.
   - In paragraph 3, write: "and main's own WebKit press-scale cases also time out there."

2. **Nonblocking, writing.** Comments that are now out of date or imprecise.
   - **`host/web-js/rt.js:942-943`:** the `exitView` comment says "the exit animation `css` names". `css` is no longer a parameter: the function now takes the row's `root` and reads its exit through `exitOf`.
     - **Proposed edit:** "A virtualized list's row wrapper `el` leaves with the exit its row's `root` declares (list.js): whether it stays, leaving, for presence-glue.js to remove."
   - **`host/web-js/rt.js:934`:** the presence header names `pr` and `lt`, but not `px`.
     - **Proposed edit:** "(its node calls `pr`; a bound layout transition's, `lt`; a bound exit's, `px`)".
   - **`host/web-js/src/motion.rs:14-15`:** the comment says "another node that `declares` presence motion takes `pr`". But `declares` is true for every declaration that `rows::presence_decls` moves inline, which includes press feedback and `--exact-fit` (`emit.rs:997`, `:1116`).
     - **Proposed edit:** "a node with any declaration that `rows::presence_decls` moves inline (`declares`) gets `pr`."
   - **`host/web-js/conformance/presence-bound.contract:2`:** the comment says "follow reduced motion". The fixture reads a `calm` state, not the viewport preference.
     - **Proposed edit:** "Computed exit and layout declarations in the shape that reduced motion takes: `none` while calm, a curve or a spring otherwise."

3. **Nonblocking, writing.** Commit `0b707fc952`, How.
   - **Paragraph 1:** "the kernel's paint policy and press-scale keyframes stay" does not say what the JS target does.
     - **Proposed edit:** "the paint flag follows the kernel's mask, and an exit on a node with a fixed press scale plays the kernel's `-exact-press` keyframes".
   - **Paragraph 2:** it does not say that the entry "Reduced motion on the web" becomes "Reduce Motion for web-host motion". It also does not say that the entry loses part (1), which this change delivers.
     - **Proposed edit:** add "The reduced-motion entry keeps only the motion that the web host starts."

4. **Nonblocking, simplification.** `host/web-js/src/rows.rs:484-491`.
   - The merged arm makes the property name with `format!("--exact-{name}")`. A search for `"--exact-exit-animation"` no longer finds the place where the JS target writes it.
   - **Proposed edit:** keep the literal property name in the tuple, for example `let (property, name, values) = if id == StyleId::LayoutTransition { ("--exact-layout-transition", "layout-transition", …) } else { ("--exact-exit-animation", "exit-animation", …) };`. Then call `one(property, …)`.

5. **Nonblocking, correctness (narrow).** The snapshot and a tree update that waits for a view transition.
   - **How it happens:**
     - While a shared-element view transition is pending, `host/web-js/shared.js:99` puts the tree update of each later commit in a queue.
     - The transition then runs the queued updates together (`shared.js:121-125`).
     - The first queued update takes the snapshot in its `Before` hook (`rt.js:205`).
     - Its `flush()` (`rt.js:207`) then runs the effects of all queued commits, because they share `Queue`.
   - **Result:** the first queued commit can change a bound exit, and a later queued commit can remove the node. Then the JS target plays the value from before the first commit, but the runner plays the value that the first commit left.
   - **Comparison:** without the snapshot, the queue would run the first commit's exit write before the removal. The removal would then read the runner's value.
   - **Conditions:** the case needs a shared-element hand-off and a second action before the transition's update callback. No test covers it.
   - **Proposed edit:** add a `QUEUE.md` line: "A bound exit removed in a commit queued behind a view transition plays its value from before the first queued commit (`rt.js` `px`, `shared.js` `pending`); the runner plays the value the earlier commit left."

6. **Nonblocking, writing.** Records commits `242da55e25`, `affa78d09a` and `e9683ef6ee` use the imperative mood.
   - `242da55e25`, How, sentence 1: "Record Opus's round 1 final …"
   - `affa78d09a`, How, sentence 1: "Record Astra's joint round 3 final …"
   - `affa78d09a`, Test Plan, sentence 1: "Verify the transcription …"
   - `e9683ef6ee`, Why: "Keep Astra's … review with the change."
   - `e9683ef6ee`, How, sentence 1: "Record both final messages verbatim."
   - `e9683ef6ee`, Test Plan, sentence 1: "Compare each transcription …"
   - **Proposed edit:** use the same pattern as response finding 4. Examples: "This commit keeps Astra's … review with the change." and "Each transcription matches its raw final message byte for byte."

### Round-1 settlements

- **Finding 1 (blocking, order of writes):** I agree with the fix.
  - The `Before` hook reads each bound exit before any effect of the commit runs.
  - `Leave` and `exitView` read that value first.
  - Before the fix, the browser case received `[1, 0, 0, 1]` (`motion-r3-order-before-fix.log`).
  - Finding 5 is the only path where the snapshot and the runner disagree.
- **Declined part of finding 1 (the `presence-bound` steps):** I agree. With the two steps and without the snapshot, the fixture still reports 18 of 18 steps equal (`motion-r3-conform-negative.log`). The fixture compares the state after settling, so it cannot see which exit played.
- **Finding 2 (`QUEUE.md`):** I agree.
  - The delivered request, its "done when" clause and the snapshot lesson are removed.
  - The press-scale lessons no longer apply. Next to a fixed press scale, an exit plays the kernel's `-exact-press` keyframes. Next to a computed press scale, it plays the plain keyframes, which override the inline `scale`.
  - The new wording "first decide how the page loads that parser" is clear.
- **Finding 3 (WebKit paragraph):** I agree. The probes ran with both page forms, and `newPage` stopped in both.
- **Finding 4 (Test Plan claims):** I agree, except for the list, recipe and main-WebKit wording (finding 1).
- **Findings 5, 6 and 7:** I agree.

### Checked, no finding

- **Snapshot order:** `Before` runs at `rt.js:205`, before `flush()` at `:207`. Every `S` and `Sm` effect of the commit runs in that flush.
- **Removal paths:** all of them read `exitOf` (`rt.js:952`):
  - arms: `when` and `match`, then `clear`, `leave` and `Leave` (`:972-976`);
  - keyed rows (`:1270`);
  - list-item shells (`leave` through `listRow`);
  - virtualized rows (`list.js:526-530`). `retire(m, true)` comes only from the `realize` of a data update (`list.js:328`), inside the commit's flush.
- **Scope end:** `onEnd` removes a node from `Exits` when its arm or row scope ends. `$exit` stays on the element for the `Leave` call that follows.
- **Held nodes:**
  - On a held node, an `Sm` write goes through `hooks.style` (`motion.js:168-177`) to `api.style`.
  - `api.style` sets `el.style.cssText` (`motion-glue.js:607-611`).
  - A release puts back only the hold's own properties (`motion-glue.js:296`, `:317-320`).
  - So the snapshot also reads the committed value on held nodes.
- **Literal exits stay static:**
  - `emit.rs:1239-1245` skips literal bindings.
  - `presence_registration` (`motion.rs:16-37`) gives `px` only to a non-literal exit that can declare an animation.
  - The lowering pass refuses custom properties (`lower.rs:434-439`), so the exit row stays inline.
- **Runner:**
  - When an arm switches, the runner destroys the old arm and does not update it (`runner/src/instance/region.rs:352-356`).
  - Keyed rows that leave are destroyed after the kept rows update, also without an update (`:225-296`).
  - The kernel reads the exit from the current arena style (`kernel/src/txn.rs`, `leaving_with`).
  - I did not trace the runner's virtualized-list path.
- **Test coverage:** the ordering case covers an `if` arm only. Keyed rows and virtualized rows read the same `exitOf`. The list suites cover `exitView` with literal exits.
- **Other evidence:**
  - With main's compiler sources, the first browser case fails at compile time (`final-motion-negative-exit.log`).
  - The merged arms give the same recipe and fixture output (`motion-refactor-output-identity.log`).
  - At the head, the 180 crate tests and clippy pass (`final2-motion-*`).
- **Dating:**
  - The r3 runs (15:29–15:48) are older than the snapshot's commit (`28d8750287` at 15:47, amended as `d3ca790957` at 15:49).
  - The ordering case passes in `motion-r3-layout.log`, so the snapshot was present.
  - No runtime file changed after `d3ca790957`.
- **WebKit probes:**
  - Every run whose `newPage` returned passed: `probe-webkit-combined-suite-8.log`, runs 2, 4 and 5 of `probe-webkit-suite-form.log`, and `probe-order-webkit-2.log`.
  - Every other run stopped at `newPage`, with both page forms.

## Locks: `ide/web-build-locks` at `603b8f318b`

### Findings

1. **Nonblocking, writing.** Constant names.
   - **`host/web/build-lock.mjs:11`:** `FILE_SHARE_READ_WRITE` is not a Win32 name, but the Test Plan calls these constants "the named Win32 … constants". Microsoft's `CreateFileW` page defines `FILE_SHARE_READ` as `0x1` and `FILE_SHARE_WRITE` as `0x2`.
     - **Proposed edit:** `FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2`, and pass `FILE_SHARE_READ + FILE_SHARE_WRITE` at `:33`.
   - **`host/web-js/gpu-cache.test.mjs:212` and `:217`:** the shared-reader fixture still gives `0x80000000, 3, null, 3, 0x80` and the flag `1` to the same calls.
     - **Proposed edit:** name these constants as the module does, or add a comment as `:222` does for its `flock` flags.

2. **Nonblocking, error message.** `host/web/build-lock.mjs:87`.
   - "process N has held this build lock for 30 s" states how long process N held the lock. The code knows only that this caller waited 30 s.
   - When several builds wait, process N can take the lock just before the timeout.
   - For a short time, the file can also still name the previous holder (`:96-97`).
   - **Proposed edit:** `` `${lock}: waited 30 s for this build lock, which ${holder(lock)} holds; wait for its build to finish, or stop it if it is stuck` ``. Change `gpu-cache.test.mjs:171` to expect "which process <pid> holds".

3. **Nonblocking, simplification.** `host/web-js/gpu-cache.test.mjs:229-274`.
   - The waiter source has a `ROUNDS` placeholder, and `.replace('ROUNDS', String(ROUNDS))` fills it in (`:250`). The template already inserts values, so `${ROUNDS}` at `:237` does the same thing directly.
   - A `waiting` waiter (`:274`) also does the round-0 handshake (`:238-239`). It passes only because `go-0` remains from the contention rounds (`:266`).
   - **Proposed edit:** write `${ROUNDS}` at `:237` and remove the `.replace`. Do the `ready`/`go` handshake only for `quick` waiters. Then the hold phase does not depend on files that an earlier phase left.

4. **Nonblocking, verification and writing.** Commit `140e7a8049`, Test Plan.
   - **Paragraph 2, QoS:** the measurements ran at background QoS.
     - `docs/testing.md` ("Measuring to optimize tests") says to measure with interactive QoS, because background QoS makes every wait longer.
     - This test runs 80 lock holds of `nap(20)` one after another, and it retries every 10 ms. The change removes process starts, so the background-QoS times do not isolate its effect.
   - **Paragraph 2, main's failure:** "Main's version of that test took 21 s there and failed" does not say how it failed.
     - In `main-gpu-cache-waiters.log`, a waiter that uses the old checkout's lock gets `EEXIST` on `inside`. That failure is the mixed-protocol race of the removed `QUEUE.md` entry.
     - Main's test also has other phases: two 1.5 s sleeps and a mixed round. Its 21 s therefore cannot be compared with 15–16 s.
   - **Paragraph 1:** "the last fails with a message that names none" reads as a current failure.
   - **Proposed edit:**
     - Run the three alternating pairs again from an interactive launchd job, and report those times. Or write "Starting the contenders once replaces 80 process starts with 8."
     - Then write "Main's version of the test fails there on the mixed-protocol race that the removed `QUEUE.md` entry describes."
     - In paragraph 1, write "… and that a timeout names the holding process. A timeout message that names no process fails the last one."

5. **Nonblocking, writing.** Records commits `603b8f318b` and `18c832ff16` use the imperative mood.
   - `603b8f318b`, How, sentence 1: "Record Opus's round 1 final …"
   - `18c832ff16`, How, sentence 1: "Record each Astra final message …"
   - `18c832ff16`, Test Plan, sentence 1: "Verify every transcription …"
   - **Proposed edit:** use the same pattern as response finding 4.

### Round-1 settlements

- **Finding 1 (Test Plan negatives):** I agree. The negative ran on this base (`locks-r3-negative-main-impl.log`). That is stronger evidence than the note that round 1 proposed.
- **Finding 2 (holder in the timeout message):** I agree that the message should name the holder from the lock file. One wording change is necessary (finding 2).
- **Finding 3 (header and constants):** I agree, except for `FILE_SHARE_READ_WRITE` (finding 1).
- **Findings 4 and 5:** I agree.

### Checked, no finding

- **Constants:** each named constant equals the number that it replaces.
  - **flock:** the macOS SDK's `sys/fcntl.h` gives `LOCK_SH` 1, `LOCK_EX` 2 and `LOCK_NB` 4. I did not check a Linux header.
  - **Microsoft's pages:**
    - `GENERIC_READ` is `0x80000000` and `GENERIC_WRITE` is `0x40000000`.
    - `OPEN_EXISTING` is 3, `OPEN_ALWAYS` is 4 and `FILE_ATTRIBUTE_NORMAL` is `0x80`.
    - `LOCKFILE_FAIL_IMMEDIATELY` is 1 and `LOCKFILE_EXCLUSIVE_LOCK` is 2.
    - `ERROR_FILE_NOT_FOUND` is 2, `ERROR_PATH_NOT_FOUND` is 3 and `ERROR_LOCK_VIOLATION` is 33.
  - **Access mask:** the code adds the flags with `+`. With `|`, JavaScript gives a negative number (`bun -e`: `-1073741824`).
- **Holder message on each platform:**
  - On macOS and Linux, the holder truncates the file and then writes its PID at offset 0 (`:69`). With `a+`, a write goes to the end of the file, which is offset 0 after the truncate.
  - On Windows, the holder writes the PID at offset 0 of the new handle and truncates the file after it (`:47-52`). The lock is at byte 64, after the PID (`:38-41`).
  - If the read fails, the message names "another process" (`:100-101`).
  - The test ran the PID assertion (`gpu-cache.test.mjs:171`) on macOS only.
- **Windows release:**
  - Microsoft's `UnlockFileEx` page says: "Locks are released before the CloseHandle function is finished processing." So closing a handle releases its lock.
  - The `LockFileEx` page says that, after a process ends, the time to unlock "depends upon available system resources". Waiters try again for 30 s.
- **Negatives:**
  - With the earlier timeout message, the timeout regression fails (`locks-r3-negative-holder.log`).
  - With main's implementation, the inode test fails at `existsSync(lock)` after the release, and the read-only and shared-reader tests pass (`locks-r3-negative-main-impl.log`).
- **Contention test:** each `go` is deterministic. A waiter writes `ready-<round>` only after its previous `withLock` returns, so `lockHeld(lock)` is false before each `go` file.
- **Timings:** the times agree with the junit files: 18.48–18.67 s before the change, 15.30–16.11 s after it, and 21.21 s for main.
- **Suites:** `locks-r3-gpu-cache.log` (10 pass), `locks-r3-generations.log` (9 pass), `locks-r3-replace-build.log` (4 pass) and `locks-r3-dev-bin-run.log` (1 pass). These runs were between 1 and 37 s before the fixup commit `c8f0428c2a` (16:01:46).

`ide/web-response-followups` (`3d29de332e`): READY
`ide/web-computed-exit-motion` (`242da55e25`): READY
`ide/web-build-locks` (`603b8f318b`): READY