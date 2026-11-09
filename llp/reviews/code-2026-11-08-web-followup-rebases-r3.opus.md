# Web follow-up rebases: Opus review, round 3

- **Family:** Anthropic. Opus 5.5 (`claude-opus-5-5`), through Claude Code's Agent tool on account `ide@expo.dev`, effort max, in frozen worktrees at response `c4861f461f`, motion `81d8d0f8e7` and locks `ce357f8a43`, each on `ead04512f1`.
- **Method:** one brief (sha256 `e5e2bb7a9dfb21d9714e03fc63a8cbfad08f918c585e9f32fcf86beeb988db49`), one reviewer, with correctness, simplification, writing, and verification and test passes over what changed since round 2, and a check of every round-2 settlement. The reviewer read source and logs only and changed no files. The author is not a reviewer.
- **Transcription:** the final message, unedited, recorded in all three branches; its paths name the review worktrees and the author's logs, and its shas are of the reviewed history.

---

# Review record: three exact2 web branches, round 3

- **Heads:** response `c4861f461f`, motion `81d8d0f8e7` and locks `ce357f8a43`. Each is on `ead04512f1`. The source commits are `3b54f31c47`, `70b65ebec6` and `84f107b6b7`.
- **What I read:**
  - `git range-diff` from the round-2 heads, and the three frozen worktrees;
  - every records commit message;
  - the round-3 logs and the bench directory;
  - the main worktree's `HEAD` reflog, which I used to date each log;
  - `AGENTS.md`, `rules/RULES.md`, `docs/testing.md` and `/Users/admin/AGENTS.md`.
- **What I ran:**
  - read-only `git`, `shasum` and `cmp`;
  - `rustfmt +1.97.0 --edition 2021 --check` on standard input, for the eight Rust files that the motion source commit changes.
  - I built nothing, ran no test and opened no browser.
  - I wrote only to the scratch directory: empty `rustfmt` outputs, and a `git show` copy of the lock test at `4425485510`.
- **"By reading"** means that I read that code but did not run it.
- **Result:** no finding is blocking. There are five nonblocking findings: two for response, two for motion and one for locks.

## Response: `ide/web-response-followups` at `c4861f461f`

### Findings

1. **Nonblocking, test reliability.** `host/web-js/document-agent.test.mjs:133` keeps a 1 s deadline for the rollback case that starts pending.
   - **The render returns early.** It returns when nothing is in flight (`host/web-js/build.mjs:579-580`), so it does not wait out the deadline in this case.
   - **Evidence:** in `r3-response-document-agent.xml`, the two rollback cases take 0.264 s and 0.260 s, builds included. With 1 s for both cases, they took 0.291 s and 0.293 s (`response-time-document-agent.xml`).
   - **What the case needs:** the trigger's answer and its refused settlement must land before the render returns. Until then, `trigger` is also pending, and the `"pending":["later"]` check (`:136`) fails.
   - **Why it matters:** the 1 s is a deadline that an event must beat. `docs/testing.md` ("Waiting") says that a fixed wait "is too short on a slow one", and it keeps fixed bounds of tens of seconds only to stop hanging tests.
   - **Cost:** a 10 s deadline costs nothing when the case passes.
   - **Proposed edit:** at `:133`:
     ```js
     // Give the render a long deadline: it returns once the refused settlement has rolled back and nothing is in flight
     const reply = await render('/', 10000);
     ```
   - **Commit message:** in commit `3b54f31c47`, Test Plan, paragraph 1, replace the last sentence with "Every render except the silent and heartbeat pages has a 10 s deadline; the renderer returns as soon as nothing is in flight."
   - **Negatives:** run the save and restore negatives again.
   - **Optional wording:** a renderer does not "leave" a deadline. At `:66`, "Give a page that must settle a long deadline: the renderer returns as soon as nothing is in flight" is plainer.

2. **Nonblocking, test names.** `host/web-js/document-agent.test.mjs:96` and `host/web-js/resource-inspection.test.mjs:79` use `test.each([false, true])` with `%s` in the name.
   - **The problem:** Bun 1.4.2 does not put a boolean into `%s`, so each pair reports the same name twice. These files show it:
     - `r3-response-document-agent.xml`;
     - `r3-response-resource-inspection.xml`;
     - both `(fail)` lines in `r3-response-negative-pend-document-restore.log`.
   - **Effect:** the async lane names a Bun failure by its `(fail)` line, and it keeps the names in a set (`scripts/async.mjs:383`, `:408`). So it cannot say which case failed. `scripts/known.mjs` (`:35`, `:97-98`) then sorts both cases as one test.
   - **On main:** main has the same pattern twice, at `host/web-js/build.test.mjs:45` and `scripts/app-bake.test.mjs:533`.
   - **Proposed edit:** give each row a string, as the table at `document-agent.test.mjs:140-198` does:
     ```js
     test.each([['not pending', false], ['pending', true]])('a refused settlement restores renderer pending state (initially %s)', async (_, initiallyPending) => {
     ```
     Make the same change at `resource-inspection.test.mjs:79`.

### Round-2 settlements

- **Finding 1 (each suite alone):** I agree. Each suite has its own unfiltered run:
  - build: 13 pass;
  - document-agent: 31 pass;
  - resource-inspection: 3 pass;
  - held: 1 pass, and held-count: 1 pass;
  - answer-timers: 3 pass;
  - store-readers: 8 pass;
  - long-poll: 1 pass;
  - document-render: 38 pass, and 3 fail at the Firefox launch, as the Test Plan says.
- **Finding 2 (deadlines):** I agree with the 10 s deadlines and the 60 s bound. Response finding 1 applies the same reasoning to the case that starts pending.
- **Declined HEAD removal:** I agree with the decline.
  - By reading, the HEAD request for `/feed` reaches no code that GET `/feed` and HEAD `/` do not reach.
  - `pageServer` keeps no 503 page (`host/web-js/render.mjs:319`), and one header set serves both methods (`host/web/serve.mjs:918`).
  - But the item was optional, and the cost is one 3 s render in a lane test with a 60 s bound.
  - The full set of policies and methods also guards a later change that treats one combination differently.
- **Finding 3 (removed entries in the How):** I agree. Both names match the removed lines.
- **Finding 4 (indicative mood):** I agree. No records commit on this branch uses the imperative mood.

### Evidence checked

- **Negatives:**
  - Without the restore, both rollback cases fail at `:134`, in 0.26 s and 0.27 s.
  - Without the pending selector, `/` answers 503 at `:68`, in 0.25 s.
  - So the long deadlines do not slow these failures.
- **Dating:** the main worktree had this branch checked out from 16:55:09 to 16:59:17.
  - The logs are from 16:55:45 to 16:58:22, and the fixup commit is at 16:58:37.
  - The negative logs quote the new comment at `:66`.
- **Transcription:** the round-2 record is the same file on all three branches. After its 8-line header, it is byte-identical to the saved final (sha256 `181adad0b3fe3765a2e5f7637d3b6d4d4231da991b78f9a5cbb8ea4a600f6b3d`).

## Motion: `ide/web-computed-exit-motion` at `81d8d0f8e7`

### Findings

1. **Nonblocking, writing.** Commit `70b65ebec6`, How, paragraph 2, says that "the dynamic-exit entry keeps only its `contract build` part". Records commit `8fec5bf90e`, paragraph 3, says the same.
   - **Extra notes:** the entry (`QUEUE.md:1332-1342`) also keeps two notes from the second attempt.
   - **First note:** it says that main's holds restore a node's whole saved style on release. Main's #1209 (`227b00122f`, 2026-10-31) changed this. `restore` now puts back only the properties that motion writes over (`host/web/motion-glue.js:293-297`).
   - **Second note:** it is about a scale hold's `--exact-scale` mapping. That is a `motion-glue.js` item, not part of `contract build`.
   - **Dangling phrase:** the removed snapshot sentence leaves "carries the six commits onto main and fixes the rest" (`:1334`) with no stated "rest".
   - **Proposed edit:**
     - End that sentence at "carries the six commits onto main."
     - Delete "Its third round found … on the held properties only.", because #1209 delivered it.
     - Move "Open where it stopped (Astra): …" to a line of its own.
     - If the entry stays as it is, write this in the How instead: "the dynamic-exit entry keeps its `contract build` request and the second attempt's notes on holds".

2. **Nonblocking, accuracy.** `QUEUE.md:45` ends with "Snapshot per commit, or run each queued commit's effects in its own flush." Neither fix works as written.
   - **Snapshot per commit:** it cannot read the element, as `px` does (`host/web-js/rt.js:949`). Until the first queued update runs, the element shows the value from before the first queued commit. Records commit `81d8d0f8e7` gives this same reason for a queue entry.
   - **One flush per commit:** it does not match the runner when the later commit also writes the exit.
     - `stale` queues an effect only when it is clean (`rt.js:58`), so an effect that two queued commits change is queued once.
     - That effect runs with the latest signal values, which are the later commit's.
     - The runner plays the earlier commit's value, because it ends the arm without updating its bindings.
   - **Proposed edit:** "A fix reads each bound exit from its binding, not from its element, at the start of each queued commit. Until the first queued update runs, the element still shows the value from before the first queued commit. One flush per commit is not enough: an effect that two queued commits change is queued once and runs with the later commit's values."

### Round-2 settlements

- **Finding 1 (Test Plan):** I agree. The new wording matches the logs:
  - list-accessibility's WebKit time-out;
  - the 11 list-structures skips;
  - main's WebKit press-scale time-outs (`main-press-scale-webkit.log`).
  - The recipe compiles at the head (`r3-motion-recipe-js.log`).
- **Finding 2 (comments):** I agree. The four comments now agree with the code:
  - `px` and `lt` each call `pr` (`rt.js:950`, `:954`);
  - `declares` comes from `rows::presence_decls` (`emit.rs:997`, `:1116`);
  - the fixture's values match its new comment.
- **Finding 3 (How):** I agree with the paint-flag and press-scale sentence (`paint.rs`, and `presence.rs` `exit_animations`). The dynamic-exit clause is still wrong (motion finding 1).
- **Finding 4 (literal names in `rows.rs`):** I agree.
  - The literals are the strings that `format!` made, so the output does not change.
  - `rustfmt --check` passes on `rows.rs` and on the other seven changed Rust files.
- **Finding 5 (queue entry in place of a fix):** I agree with a queue entry in place of a fix.
  - The case needs a pending shared-element transition and a second commit before the transition's update callback. It was found by reading.
  - A correct fix must read exits from bindings for each queued commit, which is new work in `px` and in the commit path.
  - By reading, the entry describes the defect correctly (`shared.js:99`, `:125`; `rt.js:205`, `:207`, `:949`). Its proposed fixes are not correct (motion finding 2).
- **Finding 6 (indicative mood):** I agree.

### Evidence checked

- **Dating:** this branch was checked out from 16:11:41 to 16:52:07.
  - The fmt, build, cargo-test, clippy, layout and recipe-js logs are from 16:50:58 to 16:51:22. The fixup commit is at 16:51:32.
  - The 180 crate tests and clippy pass. The format log is empty, which is a pass.
- **Runtime:** after `d3ca790957`, only comments changed in `rt.js`, and no other runtime file changed. By reading, the registration move into `motion.rs` keeps the same conditions.
- **Caps:** `rows.rs` has 1,492 lines. Caps reports only main's `PresenterIOS.swift`.

## Locks: `ide/web-build-locks` at `ce357f8a43`

### Findings

1. **Nonblocking, writing.** `host/web-js/gpu-cache.test.mjs:126-127` says that owned children would cost one process-table read each, "eighty of them here".
   - **Old count:** the count describes main's test, which started 8 waiters in each of 10 rounds.
   - **New count:** this branch starts 17 waiters: 8 contenders once (`:265`), 1 holder (`:275`) and 8 blocked waiters (`:278`). Its own Test Plan says that it "replaces 80 process starts with 8".
   - **Proposed edit:** "seventeen of them here".

### Round-2 settlements

- **Finding 1 (constant names):** I agree.
  - `FILE_SHARE_READ = 1` and `FILE_SHARE_WRITE = 2` (`host/web/build-lock.mjs:11`) add up to the earlier 3 at `:33`.
  - The comments at `gpu-cache.test.mjs:212` and `:218` name each raw argument in order.
- **Finding 2 (message):** I agree.
  - `build-lock.mjs:87` says how long the caller waited and which process the file names.
  - With the original message, which names no process, the regression fails at `:171` (`r3-locks-negative-holder.log`).
- **Finding 3 (contention script):** I agree.
  - `${ROUNDS}` fills in the count, and only contention waiters do the handshake.
  - The check before each `go-<round>` stays deterministic: a waiter writes `ready-<round>` only after its previous `withLock` returns.
- **Finding 4 (QoS and main's failure):** I agree.
  - The launchd job sets `ProcessType` to `Interactive`.
  - The junit times match the Test Plan: 6.72–6.83 s before the change and 3.38–3.44 s after it.
  - The `reuse` copy equals the head's test, and the `respawn` copy equals the test at `4425485510`.
  - Main's failure is the `EEXIST` race in `main-gpu-cache-waiters.log`.
- **Finding 5 (indicative mood):** I agree.

### Evidence checked

- **Suites:** gpu-cache 10 pass, generations 9 pass, replace-build 4 pass and dev-bin-run 1 pass.
  - They ran from 16:54:10 to 16:54:46, with this branch checked out.
  - The fixup commit is at 16:55:00.
- **Callers:** no tracked file matches the old timeout wording. `dev-bin-run.test.mjs:41` matches the `ELOCKED` code.

`ide/web-response-followups` (`c4861f461f`): READY
`ide/web-computed-exit-motion` (`81d8d0f8e7`): READY
`ide/web-build-locks` (`ce357f8a43`): READY