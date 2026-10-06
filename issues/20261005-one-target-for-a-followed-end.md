# A followed end should get one target, not an estimate and then a correction

**Status:** proposal, no code. Written 2026-10-05, against upstream `main`
plus `feat/display-link-scrolling`. It is about LLP 1010 §6.8 ("A smooth
correction is one retargetable motion").

## 1. The question

Take a chat whose list follows its end with `scroll-behavior: smooth`. When
someone sends a message, the transcript should rise once, by the new
bubble's height, in one 0.3 s ease.

§6.8 does get there, but it gets there by *recovering*. The motion starts
toward a target worked out from an **estimated** row height. Then the
measured height arrives and the motion is **retargeted** in flight.

- **Before §6.8:** that second target was a visible 12 pt jump on Signal
  Clone (the bubble rose for 0.15 s, then jumped 0.2 s later).
- **After §6.8:** the retarget hides the jump. Measured deviation from one
  ease-in-out is 0.014.

The retarget is the right tool for changes no one could know in advance. It
should not be the mechanism for the common case, where the size *is* known
before the motion starts.

## 2. Where the second target comes from

This is one round trip between the runner and the host.

**1. The runner gives the new row an estimated height.** The rows change.
The new key's height is the list's `estimatedItemHeight` (32 pt by default,
`runner/src/instance/collection/mod.rs` `ESTIMATED_HEIGHT`). That height is
an estimate in the size index until a host measures it.

**2. The runner turns the followed end into a smooth correction.** The
list's anchor follows the end (`index.rs` `capture_anchor`). Restoring it
against the new total height moves the offset. `restore` in
`collection/mod.rs` makes that an `AnchorCorrection` with `smooth: true`
("a followed end that moved, once the list has opened, is the reader's own
content arriving"). The extent and the offset both include the estimate.

**3. The host fits and starts the motion.** It sets `contentSize` from the
runner's extent (`CollectionIOS.swift` `fit`) and calls `animateOffset`
toward the runner's offset. The start is deferred one main-queue turn, and
it takes the last target that turn gave.

**4. The host lays out the row.** The kernel's frames give the row its
real size. The host now knows it, but nothing uses it yet.

**5. The host reports the real height back.** The next collection report
carries `measurements`: each mounted row's laid-out size
(`Collection.swift`, `facts.measurements = … size(row.view …)`). The report
is scheduled, not sent inline, and may go off main.

**6. The runner moves the target.** It stores the measurement
(`set_measured_height_at`), restores the anchor against the corrected
total, and emits a second correction. The host retargets the running
motion (`OffsetDriver.retarget`).

The second target exists because the target is computed before the one
party that knows the row's size has reported it. The deferred start in §6.8
only absorbs the case where both targets land in the same turn. Here the
measurement arrives a report later.

## 3. Proposal

### Recommended: the host resolves a followed end from its own layout

A followed end is an intent ("stay at the end"), not an offset. Send it as
the intent, and let the host turn it into an offset after it has laid out
the batch.

- **The correction says what it is.** `AnchorCorrection` gains a kind:
  `end` versus `offset`. A smooth followed end is `end`. Everything else
  stays an offset.
- **The host corrects the extent with its own rows.** For mounted rows the
  host has just laid out, it uses their laid-out size in place of the
  runner's estimate when it fits `contentSize`:
  `extent − Σ estimate + Σ laid-out` over the rows it measured.
  The report still goes to the runner as now. The runner's index catches up,
  and its next extent agrees with what the host already showed.
- **The driver eases toward the reachable end.** Instead of a fixed point,
  each frame targets `reachable(end)`. A late change at the end (an image
  that finishes loading, text laid out later) then folds into the same
  motion without a retarget message.
- **Same on the web.** On the web host, `scrollIntoView({block: "end"})` and
  a browser's own scroll anchoring are already resolved against layout. The
  web host should do the same thing so the two hosts stay in parity.

**Result:** in the common case (send a message, the row is in the window),
the first target is the true one, and nothing is retargeted.

### Alternative: wait for the measurement before starting

Hold a followed end's smooth start until the report that measures the new
row has been answered, rather than for one main-queue turn.

- **Pro:** a much smaller change.
- **Con:** adds a report round trip of latency before the bubble starts to
  move. That round trip hasn't been measured. (Signal Clone's 0.2 s was
  when UIKit's held second target landed, not the report's latency.)
- Use it only if the round trip turns out to be reliably within a frame.

### Not proposed: the runner measures the row itself

The runner has no laid-out size for a row until a host reports one. Text
metrics are the platform's. Making the runner measure would move layout
facts the wrong way across the boundary.

## 4. What stays as it is

Retargeting (§6.8) stays for things that genuinely change mid-flight:

- a row above or at the end that changes size after it was shown (an image
  loads, a link preview expands)
- another message arriving during the motion
- the reader interrupting: a drag or a wheel still stops it where it is

Rows outside the window keep their estimates. They don't affect a followed
end.

## 5. How to tell it worked

- **Signal Clone's send, measured with `scripts/motion-trace.mjs`:** one
  motion, *zero* retargets, and still ≤ 0.02 deviation from a 0.3 s
  ease-in-out.
- **A test in `SmoothCollectionIOSTests`:** a batch that inserts a row whose
  laid-out height differs from the estimate starts a single motion whose
  first target is the laid-out end, with no `retarget` call.
- **A test for the late case:** a row that grows after the motion starts
  still produces one continuous motion. This is the existing retarget test,
  driven through the reachable-end target instead.

## 6. Risks

- **Host and runner briefly disagree on the extent** until the report lands.
  Today they also disagree: the host shows the laid-out row inside a
  `contentSize` that assumed the estimate. The change makes the host's
  version the one shown.
- **Horizontal lists and `scroll-start: end` openings** take the same
  path. An opening (§6.5) is not smooth and is out of scope, but the extent
  correction would apply to it too. Check that it doesn't change when an
  opening settles (`settle_start`).
