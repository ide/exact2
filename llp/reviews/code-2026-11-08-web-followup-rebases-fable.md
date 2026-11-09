# Web follow-up rebases: Fable review

- **Family:** Anthropic. Fable 5.1 (`claude-fable-5-1`), through Claude Code (`claude -p`) on account `ide@expo.io`, effort max, in `dontAsk` mode with a read-only allow-list, in frozen worktrees at response `dcaa669354`, motion `cb50a7cb1d` and locks `9ef215ab18`, each on `ead04512f1`. The session stopped once at the account's usage limit and continued in the same session after the reset.
- **Method:** one brief (sha256 `249f771b6c0f82d0725444f7bc5ca087fdc061325e926ded9176b6bc3c736b97`), one reviewer, with correctness, simplicity, test-optimization, writing and verification passes for each branch. The reviewer read source and logs only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited, recorded in all three branches; its paths name the review worktrees and the author's logs, and its shas are of the reviewed history.

---

I could not write `final.md`: the harness denied the Write tool and a shell write to the scratch directory. The record below is complete and is my final message; please save it to `fable-scratch/final.md` if the file is still wanted.

# Review record: three exact2 web branches, Fable review

- **Heads:** response `dcaa669354` (source commit `59961af2c0`), motion `cb50a7cb1d` (source `4202343943`) and locks `9ef215ab18` (source `690b28d466`). Each is on `ead04512f1`. Main has since gained `bd4338026b`.
- **What I read:** the three frozen worktrees and each source commit's diff against `ead04512f1`; every commit message on each branch; the three Opus records and the settlements the records commits describe; the round briefs; the logs, probes and bench; `AGENTS.md`, `rules/RULES.md`, `docs/testing.md` and `/Users/admin/AGENTS.md`; main's `bd4338026b`.
- **What I ran:** read-only `git` (`log`, `show`, `diff`, `reflog`, `status`), `shasum` and `ls`. I built nothing, ran no test and opened no browser. I wrote nothing: the harness denied the write of this record to `fable-scratch/final.md`.
- **"By reading"** means I read that code and did not run it.
- **Result:** no blocking finding. Nonblocking findings: three for response, nine for motion, five for locks. All three branches are READY.

## Response: `ide/web-response-followups` at `dcaa669354`

**Correctness.** No findings. Checked by reading:
- `host/web-js/rt.js:463` puts the `pend` signal on the record; `:534-535` save it at index 19 and restore it. `commit()` saves before any write (`:170`) and restores after the undo list (`:191-193`), so both put back the same pre-commit value.
- Every write to `pend`: `flag(pend, true)` at `:523` and `:529`; `flag(pend, false)` in `release` at `:465` and at `:511`; `W(pend, …)` at `:480`; `write(pend.n, false)` at `:481`. Only the `W` write enters the undo list. The restore covers the rest. That is the fix.
- `host/web-js/build.mjs:588`: the status comes from `r.pending()`, and `continuing` adds every open ticket. `host/web-js/render.mjs:54` turns `continuing` into eager activation, `:208` into `revalidate`, and `:226-227` compute the status. An answered stream gives 200 with `pending: []`; a silent stream or a heartbeat gives 503.
- `host/web/serve.mjs:982` carries `retry-after` out of `pageServer`, and `:918` puts it in the header set. `sendStaticBody` at `:1233` drops only the body for HEAD, so GET and HEAD share the header set. `render.mjs:304` sets the header for every 503. `serve.mjs:936` and `host/web-js/dev.mjs:1037` set their own for a bodyless 503. No other page path builds headers from a render.
- The client reads a checkpoint's `answers` and `revalidate` only (`rt.js:1417-1418`). It never reads the checkpoint's `pending` list. So `revalidate` is the one existing way to make the client subscribe again. Its cost: the client asks every kept answer again at launch (`:463`, `:494`), not only the stream. Finding 3 asks the How to say so.

**Simplicity.** No findings. `runtimeServer` at `host/web-js/resource-inspection.test.mjs:5-15` removes a server that two tests built alike.

**Test optimization.**

1. **Nonblocking, test optimization.** `host/web-js/build.test.mjs:344-349`. The retry test waits out four renders of 3 s each (`render.mjs:22`): GET and HEAD for `/`, then for `/feed`. It took 12.7 s of the file's 20.0 s (`r3-response-build.xml`). The policy and the method do not change the code under test. The header set is built once at `serve.mjs:918`. HEAD differs only at `sendStaticBody` (`:1233`). `pageServer` keeps no 503 page (`render.mjs:319`), so a `cached` route renders again as a `request` route does. Proposed edit: one request per axis value, GET `/` without compression and HEAD `/feed` with gzip:
   ```js
   const page = await serve.get('/');
   expect([page.status, page.cache, page.retryAfter]).toEqual([503, 'no-store', '1']);
   const head = await fetch(`http://127.0.0.1:${serve.port}/feed`, { method: 'HEAD', headers: { accept: 'text/html', 'accept-encoding': 'gzip' } });
   expect([head.status, head.headers.get('retry-after'), head.headers.get('content-encoding'), await head.text()]).toEqual([503, '1', 'gzip', '']);
   ```
   This saves two renders, about 6 s per run, and keeps both policies, both methods and the compressed path. Round 2 proposed dropping one HEAD, and the author kept every policy and method. This edit keeps every policy and every method. It drops only the repeated combinations. Rename the test to say so, for example "serve preserves the retry delay for unfinished pages, request and cached, GET and HEAD".

2. **Nonblocking, test optimization, optional.** `host/web-js/document-agent.test.mjs:96-139` and `host/web-js/resource-inspection.test.mjs:79-111` check the same rollback: the same three sources, the same refusal, the same restore. The renderer rows add the status and the checkpoint's `pending` list. The renderer row that starts not pending passes without the save (`r4-response-negative-pend-document.log`), so it guards nothing the rt.js rows do not. By reading, both rt.js rows fail without the save and without the restore; the round-1 negative removed both at once, and both rows failed (`response-negative-resource-inspection.log`). Proposed edit: keep one renderer row, the one that starts pending, which checks 503 and `"pending":["later"]`, and keep both rt.js rows. This saves one build and one render per run, 0.3 s to 0.8 s in `r3-response-document-agent.xml` and `r4-response-document-agent.xml`. Coverage does not change.

**Writing.**

3. **Nonblocking, writing.** Commit `59961af2c0`, How, paragraph 1, sentence 2: "so an inferred page activates eagerly and its client subscribes again". The client subscribes again because `revalidate` makes it ask every kept answer again (`rt.js:463`, `:494`; `render.mjs:208`). The sentence reads as if the stream alone were asked again. Proposed: "The render still reports an open stream as continuing work, so an inferred page activates eagerly and its checkpoint asks for revalidation: the client asks every kept answer again, the stream among them, and so subscribes again."

   The comments at `document-agent.test.mjs:66` and `:133`, the one at `resource-inspection.test.mjs:100`, the three new `QUEUE.md` entries and the records commits read well on first reading. No other finding.

**Verification.** Every Test Plan claim has a log:

| Claim | Evidence |
|---|---|
| Renderer fixtures and browser rollback tests | `r4-response-document-agent.xml`: 31 pass; `r4-response-resource-inspection.xml`: 3 pass, rows labeled |
| Public-server regressions | `r3-response-build.xml`: 13 pass |
| Each fix has a failing negative | `r4-response-negative-pend-document.log` (save), `r4-response-negative-pend-document-restore.log` (restore), `r3-response-negative-pending-selector.log`, `response-r3-negative-continuing.log`, `response-r3-negative-retry-page.log`, `response-r3-negative-retry-header.log` |
| Suites pass, each alone | `r3-response-held.log` 1, `-held-count.log` 1, `-answer-timers.log` 3, `-store-readers.log` 8, `-longpoll.log` 1, `-document-render.log` 38 pass and 3 fail at the Firefox launch |
| Boot | `response-boot.log` from round 1; `git diff 7bbea091f7 59961af2c0` on `rt.js`, `build.mjs` and `serve.mjs` is empty, so it still applies |
| Caps | `r4-response-caps.log`: only `PresenterIOS.swift` |

The round-4 document-agent run took 134 s against 27 s in round 3, so it ran under load. It passed. The pending-selector and continuing negatives ran before the rows were labeled; the labels did not touch the test they fail. No claim lacks evidence.

## Motion: `ide/web-computed-exit-motion` at `cb50a7cb1d`

**Correctness.** No findings. Checked by reading:
- Every removal path reads the snapshot. `leave` (`host/web-js/rt.js:1155`) calls `Leave`, which reads `exitOf` (`:973`); `clear` (`:1156`) and keyed rows (`:1270`) call `leave`; a virtualized row calls `exitView` (`host/web-js/list.js:528`), which reads `exitOf` of the row's root. `px` (`rt.js:948-951`) registers the node and refreshes `$exit` in a `Before` hook, which `commit`'s `tail` runs before `flush` (`:205`, `:207`). So a removal reads the value the commit began with, whichever effect runs first. `onEnd` removes the node from `Exits` and leaves `$exit` on the element for the `Leave` that follows.
- A server render runs the hook too. `host/web-js/dom.js:60` implements `getPropertyValue`, so a render of a bound exit is safe.
- `presence_registration` (`host/web-js/src/motion.rs:16-37`) gives `px` only to a non-literal exit binding that can declare an animation. A literal exit keeps `pr`, and `emit.rs` keeps it inline.
- `host/web-js/src/paint.rs:199-208` and `host/web-js/src/rows.rs:483-492` share `presence.rs`. The paint flag is set where the kernel's mask is. `declaration_map` writes computed keys, so `__proto__` is an own property.
- **Main's `bd4338026b`.** It does not change what this branch should do. It changes how the Apple and Linux hosts lay out for a host's fact: a box takes its place, and a move under way continues. It amends LLP 1063 D6, which says the web already does so for a resize and measures only around a batch. It touches no exit path and no web file. The exit snapshot is per commit, whatever caused the commit, as the runner's arm destruction is. One point of contact: D6 now says the web plays a layout move the app commits in answer to a fact, such as an `exactViewport` re-answer, where native takes its place. The first browser case flips `prefersReducedMotion`, and the app's commit changes text and declarations and moves no box, so the case does not meet that difference. The recipe's gated `-exact-layout-transition` would meet it when a viewport re-answer also moves boxes. Main's D6 documents that difference. It is not this branch's to fix.
- The entry at `QUEUE.md:45`: I agree with a queue entry in place of a fix. By reading `host/web-js/shared.js`, a pending view transition queues later commits' tree updates, and the first queued `tail`'s `flush` runs every queued commit's effects. A node a later queued commit removes plays the value from before the first. The entry's description of a fix is right.

**Simplicity.** No findings. I asked whether `px` could avoid the per-commit read of every registered node by reading the binding instead. That needs an emitted reader as `lt` has (`rt.js:954`), which the queued view-transition fix needs anyway. The hook is the simplest form that matches the runner today.

**Test optimization.**

4. **Nonblocking, test optimization, optional.** `host/web-js/layout-transition.test.mjs:134` and `:172` each compile an app and open a page per engine. One app can hold both: the `Media` resource, the two press-scale boxes, and the `calm` card with its three buttons. One `exitApp` per engine then serves both checks: the press-scale sequence first, then the four removals. This saves one compile and one browser context per engine. On this Mac, where WebKit's `newPage` hangs, it also halves the WebKit loss per suite run, from 120 s to 60 s (`motion-r3-layout-webkit.log`). Risk: one longer case with two concerns, and a failure names the case, not the concern. The `drop` helper counts every ghost in the document, so keep the two sections from leaving in the same commit.

**Writing.**

5. **Nonblocking, writing.** Commit `4202343943`, How, paragraph 2, sentence 1: "gates its entrance, layout and exit declarations". The recipe also gates the `transition` on `still` (`docs/recipes/motion.md:31`). Proposed: "The motion recipe gates its transition, entrance, layout and exit declarations on the viewport preference."

6. **Nonblocking, writing.** Commit `4202343943`, Test Plan, paragraph 1: "In Chrome and WebKit". The suite opens Playwright's Chromium through `suiteBrowser('chromium')` (`docs/testing.md`, "Browsers"). The conformance oracle is Chrome, so paragraph 2's "in Chrome" is right. Proposed: "In Chromium and WebKit". The same at `host/web-js/conformance/presence-bound.contract:5`: "the motion in Chromium and WebKit".

7. **Nonblocking, writing.** `host/web-js/src/presence.rs:51`: "// Resolve the press rule's scale frames; CSS handles names without a rule." does not say what is resolved or why. `keyframes.resolve` attaches the plan's keyframes to each animation (`runner/src/bridge.rs:929-931`), and `keyframes_name` (`host/web/src/css.rs:475-485`) reads them to decide whether a pressable node's `-exact-press` rule applies. Proposed: "// Attach the plan's keyframes: a pressable node's `-exact-press` rule depends on whether they animate `scale` (css.rs `keyframes_name`). A name with no rule plays nothing, as in CSS".

8. **Nonblocking, writing.** `docs/recipes/motion.md:55-56`: "write exit and layout values as literals in the binding; other computed strings clear with a diagnostic." The literals also sit inside a computed expression, so "other computed strings" is unclear on first reading. Proposed: "**JS target:** a bound exit or layout value must be one of the binding's string literals; a string built at runtime clears the row with a diagnostic." The recipe stays under its cap (`r4-motion-caps.log`: no recipe over).

9. **Nonblocking, writing.** `QUEUE.md:1332-1334`: "a second attempt … carries the commits onto main." does not say which commits. Proposed: "carries the first attempt's commits onto main."

10. **Nonblocking, writing, optional.** Commit `4202343943`, title: "Web exit animations accept computed motion preferences" names the motivating case. The change accepts any computed exit value. Proposed: "The JS target accepts a computed exit animation".

    The comments at `rt.js:942-946`, `motion.rs:12-15`, `paint.rs:199`, `rows.rs:483` and `:639`, the two test comments, and the records commits read well. No other finding.

**Verification.**

11. **Nonblocking, verification.** Commit `4202343943`, Test Plan, paragraph 2: "the list-accessibility, list-structures, sheet-leave, dataset and presence suites … pass". Their logs (`motion-r3-host-web-js-*.log`, `motion-r3-host-web-tests-*.log`) are from 15:29:53 to 15:32:26. The snapshot fixup `28d8750287`, which changed `rt.js`, `list.js` and `emit.rs`, was committed at 15:47:34 (the branch reflog). The ordering case fails in `motion-r3-order-before-fix.log` at 15:28:07 and passes in `motion-r3-layout.log` at 15:29:44, so the snapshot code was in the working tree when the suites ran. After that commit, `rt.js` changed only in comments and `list.js` not at all (`git diff 28d8750287 4202343943`), and the compiler's later refactors gave byte-identical output for two plans (`motion-refactor-output-identity.log`). No log names the tree, though. Proposed: run the five suites once more at the head, or say in the Test Plan that they ran on the working tree before the snapshot's commit. Their earlier times: dataset 0.6 s, sheet-leave 2.2 s, presence 1.7 s, presence-loader 0.03 s, list-accessibility 61 s, list-structures 88 s. Risk: low.

12. **Nonblocking, verification.** No boot run for this branch. The branch changes `rt.js` and `list.js`, which `bun scripts/boot.mjs` counts. By reading, `px` adds no import, and `presence-glue.js` was already a dynamic import, so the count does not change. Proposed: run boot once, or say in the Test Plan that the module graph is unchanged.

Supported claims:

| Claim | Evidence |
|---|---|
| Compiler tests, clippy, fmt | `r3-motion-cargo-test.log`: 180 pass; `r3-motion-clippy.log` clean; `r3-motion-fmt.log` empty. Since that run only `QUEUE.md` and one test comment changed (`git diff --stat 70b65ebec6 4202343943`) |
| Browser cases in Chromium | `r3-motion-layout.log`: 4 pass |
| Without the snapshot the first order plays the new exit | `motion-r3-order-before-fix.log`: `[1, 0, 0, 1]` |
| With main's compiler sources the first case fails at compile time | `final-motion-negative-exit.log` |
| Recipe compiles | `r3-motion-recipe-js.log` |
| Fixture matches wasm in Chrome | `motion-r3-conform.log`: 18 of 18 steps equal, run with two extra steps later dropped; the fixture's later change was its header comment |
| WebKit timeouts | `motion-r3-layout-webkit.log`, `motion-r3-host-web-js-list-accessibility.log`; the list-structures skips in `motion-r3-host-web-js-list-structures.log` |
| Caps | `r4-motion-caps.log`: only `PresenterIOS.swift` |

## Locks: `ide/web-build-locks` at `9ef215ab18`

**Correctness.**

13. **Nonblocking, correctness risk, by reading.** `host/web/build-lock.mjs:64-65` and `:42-43`. After a failed `flock`, the code reads `errno` in a second foreign function interface (FFI) call, `read.i32(symbols[errno]())`. On Windows it reads `GetLastError()` the same way. JavaScript runs between the two calls. If the runtime touches the thread's `errno` or last error there, a plain `EWOULDBLOCK` surfaces as "cannot lock build output: errno N", and the build fails at once instead of waiting. Main treated every nonzero `flock` result as "wait". The probability is low: JSC's allocator does not set `errno` on success. I did not measure it, and Windows is unverified. Two options. Accept it, and say in the comment at `:63` that the code reads `errno` in a second call. Or treat an unexpected code as "not taken", so the 30 s timeout reports it with the holder; that loses the immediate report of a genuine error such as `EBADF` or `ENOLCK`, which the How promises. The owner's call.

    Checked, no other finding:
    - The persistent file is safe for every reader. `foreignBeside` accepts lines of digits, an empty file too (`host/web/generations.mjs:32`, `:38`). `swapping` uses `lockHeld` (`:180`). `host/web-js/gpu-cache.mjs:21-25` sweeps `stage-` names only. `replaceBuild` (`host/web/serve.mjs:745-762`) touches `.previous` and `.gen` only. `scripts/deploy.mjs:102` skips `dist.lock` by name. `host/web/generations.test.mjs:164` and `:222` still mean what they say: a PID in the file holds nothing.
    - Release closes the handle once (`build-lock.mjs:92-93`). `mark` runs under the lock (`:90`), and a failed `mark` closes the handle (`:91`). On POSIX the write after `ftruncate` lands at offset 0 under `a+`. On Windows the write lands at the new handle's position 0 and the truncate follows; the byte lock at 64 is beyond the PID.
    - `lockHeld` opens read-only and takes a shared lock (`:108-110`). `ENOENT` is "not held"; other errors propagate.
    - A checkout still on main that shares a GPU cache with this one (two checkouts on one `CARGO_TARGET_DIR`, `gpu-cache.mjs:1-3`) reads the PID a released lock leaves, and main's `takeLock` waits while that process lives, then fails after 30 s. The rules forbid a shim for this. Finding 16 asks the How to state the limit.

**Simplicity and test optimization.**

14. **Nonblocking, test optimization, optional.** `host/web-js/gpu-cache.test.mjs:275-284`. The hold phase starts eight new `waiting` processes after the eight contenders have exited (`:272`). The contenders can do the hold phase themselves after their rounds: wait for the `holding` file, check `lockHeld`, write `blocked-<pid>`, call `work()`, exit. The test then starts the holder after round 9's `go` file and checks the exit codes once at the end. This removes eight process starts, the `waiting` mode and its handshake, the same kind of saving the source commit measured for the rounds. I did not measure it. The exclusion check does not change: `inside` still makes it.

    `build-lock.mjs` itself has no simplification left that I can see.

**Writing.**

15. **Nonblocking, writing.** `host/web/build-lock.mjs:39`: "OVERLAPPED.Offset is 16 bytes into the 64-bit structure". A structure is not 64-bit; its layout on 64-bit Windows is. Proposed: "// `OVERLAPPED.Offset` is 16 bytes into the structure on 64-bit Windows; the event and high offset stay zero".

16. **Nonblocking, writing.** Commit `690b28d466`, How, paragraph 1. It does not state the limit a shared cache meets during the change-over. Proposed sentence at the paragraph's end: "A checkout still on main that shares a GPU cache with this one reads the PID a released lock leaves as a live holder and waits out its 30 s, until it updates."

    The header comment, the comments at `:31`, `:38`, `:63` and `:96-97`, the error message at `:87`, the test comments and the records commits read well. No other finding.

**Verification.**

17. **Nonblocking, verification.** `host/web-js/build.test.mjs` is not in the Test Plan or the logs, though `web-build --out` reaches `build-lock.mjs` through `serve.mjs`'s `replaceBuild`, and `bun scripts/affected.mjs` selects by imports. By reading, its `--out` refusals (`:142-180`) stop at `foreignBeside` before any lock, and its site build goes through `replaceBuild`, which `replace-build.test.mjs` covers. Proposed: run it once, or say in the Test Plan which suites `affected.mjs` named and why the rest were not run.

Supported claims:

| Claim | Evidence |
|---|---|
| Suites pass | `r3-locks-gpu-cache.log`: 10 pass; `r3-locks-generations.log`: 9; `r3-locks-replace-build.log`: 4; `r3-locks-dev-bin-run.log`: 1; `r4-locks-waiters.log`: 1 pass in 29 s at background QoS (quality of service), the round-4 run |
| A timeout message that names no process fails the test | `r3-locks-negative-holder.log` |
| With main's implementation the inode test fails, the read-only and shared-reader tests pass | `locks-r3-negative-main-impl.log`; from round 2, before edits to those tests that changed only comments and the message expectation |
| Contention test halved at interactive QoS | `bench.plist`: `ProcessType` `Interactive`; `locks-interactive-bench.log`: load about 15; `respawn-*.xml`: 6.72 s to 6.83 s; `reuse-*.xml`: 3.38 s to 3.44 s |
| Constants equal the numbers they replace | By my knowledge of the BSD and Win32 headers, each value is right; I did not open the headers here |
| Caps | `r4-locks-caps.log`: only `PresenterIOS.swift` |

Windows and Linux are unverified, as the Test Plan says. The three records commits' hash claims hold: the saved finals hash to `6a2e168e…`, `181adad0…` and `521c99ed…`.

`ide/web-response-followups` (`dcaa669354`): READY
`ide/web-computed-exit-motion` (`cb50a7cb1d`): READY
`ide/web-build-locks` (`9ef215ab18`): READY