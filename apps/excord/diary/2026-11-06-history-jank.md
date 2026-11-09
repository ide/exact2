surfaces: web
agent: Codex
task: keep message paging responsive and preserve the reader's position

### Rough

Paging discarded unchanged rows' measurements and built offscreen rows synchronously. Moving a frozen message to another array position also lost its converted identity. Symbol fitting read layout in modes that did not need box dimensions.

At scroll offset zero, refreshing history and restoring the saved message ran in separate commits. They now share a commit. The regression checks the saved message's position after animation callbacks: older content can fill the top padding and change the first visible key without moving that message.

New rows were measured before paint only at rest. The same bounded pass now runs during scrolling. Its regression checks a height change at nonzero velocity.

Measurements depend on row values, position reads and parent inputs. Position dependencies survive unmounting, and the compiler reads parent dependencies from the native engine's table. Parent changes can therefore revive an unmounted row measured at zero height, even when the list data stays the same.

The converter reuses frozen data across positions and validates every answer. Frozen proxies can change serialization or be revoked. Array validation follows JSON's element indices. Deleting the saved message during paging leaves prefetch free because a refused restoration produces no scroll event to release it.

### Lean in

Browser fixtures expose row identity, geometry and measurement epochs. A local transcript backend makes paging and arrivals reproducible without a tunnel.

### Needed

History tests must assert successful page admission as well as stable geometry. They must also wait for the paging callback to finish before checking that prefetch is free.

### Checkpoints

List, data, upload, reorder, document and accessibility tests pass. Chrome and WebKit symbol checks pass. Firefox cannot launch because its profile folder is unavailable. Current main brings the foldables recipe within its byte limit.

The root build, Rust tests, Clippy, formatting, boot, compiler tests and quick differential checks passed. The workspace check stopped at a 4 GiB free-space reserve and remains unverified. Disposable build caches were cleared.

Incoming bursts follow the live tail and preserve the saved message and offset while reading history. Regressions at scroll offset zero cover both restoration and deletion of the saved message during paging.

Astra reproduced the dependency and validation bugs and checked their fixes with compiled nested lists and Excord's deletion/history overlap. Native refresh and restoration ordering was checked in source. The slow-scroll test without `scrollend` also failed on the original main revision `70365218ab`.

The paging benchmark recorded 224 measurement invalidations for retained mounted rows across 15 baseline pages and none across 15 patched pages. Chrome and WebKit scrolling traces showed no visible spacer gaps. Wall-clock timings vary with machine load; this comparison measures invalidation work.

### Mobile scroll ownership

Excord keeps the fetched candidate window separate from the complete window it presents. Fetching can continue during motion; passive publication waits for the host's scroll admission. The web scheduler also waits for the collection's accepted final motion report and an event for an accepted position change. A rejected report is retried under the normal frame budget. An ignored write does not invent a position-event obligation.

Publication reads the actual visible row and signed offset immediately before replacing the presented window. Layout can move rows without a scroll event, so the last event alone is insufficient. If the candidate slid beyond that row, Excord queries around it before publishing. A deleted row falls back to a physically visible survivor. Window replacement and placement share one commit. Sends and explicit destinations retain their placement intent.

A nonempty opening remains pending until its final geometry report is acknowledged. The JavaScript and Rust engines expose that obligation through their existing pending flag; an empty opening requests no repeated reports. Their existing measurement and end-settlement guards remain.

The active-coast regression rejects writes while a page arrives and checks that the presented rows stay unchanged. It then moves another 16 pixels, releases motion and verifies the final physical position. Further cases cover deletion and reversal beyond a capped candidate. The reversal also exercises old-window measurement corrections: those remain the virtualizer's existing behavior, and publication captures the viewport after them. The new coast test fails against the restored main bundle because it publishes 99 rows while motion still owns the 49-row view.

Astra reviewed the presentation and admission policies and independently verified one rejected final report followed by a successful retry, without an unrelated app commit. The review and browser fixtures do not establish physical Duo Safari momentum behavior. The complete Chrome routing suite, WebKit history regressions, focused JavaScript suites and Rust collection tests pass. The repository build, tests, Clippy, formatting, caps, boot, workspace and quick differential checks also pass.
