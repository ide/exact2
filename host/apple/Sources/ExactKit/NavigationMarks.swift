// Journals Observe's navigation metrics (cold_ttr, warm_ttr, tti) for each router change.
// A navigation starts at the input event's timestamp if one came within a second,
// otherwise at the commit. It is cold if its entry was not shown before in the session.
// Render time is the first vsync after the committing run-loop turn ends.
// TTI is when outstanding work clears, never before render. A newer change cancels it.
// Only a cold navigation has a TTI: a screen already shown (back, a tab seen
// before) was interactive before, as Observe's markInteractive on mount is
// never called again for it. A warm one ends at its warm_ttr.
// A change UIKit made itself (its Back button, a back swipe, LLP 1035.001.000)
// reaches the app once its transition has ended, but the screen it shows was
// drawn from the transition's first frame: render is that frame, the first vsync
// after the turn in which UIKit began to show it (`willShow` comes before it).
import Foundation
import QuartzCore

final class NavigationMarks: NSObject {
    static let shared = NavigationMarks()
    /// The last input's timestamp, in seconds on the `CACurrentMediaTime` clock.
    private var lastInput: Double?
    private var seen: [ObjectIdentifier: Set<UInt64>] = [:]
    private var launched: Set<ObjectIdentifier> = []
    private var pending: Pending?
    private var link: CADisplayLink?
    private var deadline: DispatchWorkItem?
    /// Recent measurements for `state.observe`, newest last.
    private(set) var recent: [String] = []

    private func note(_ line: String) {
        recent.append(line)
        if recent.count > 16 { recent.removeFirst() }
    }

    private final class Pending {
        weak var session: ExactSession?
        let start: Double
        let committed: Double
        let fields: [String: Any]
        let cold: Bool
        var turnEnded: Double?
        var presented: Double?
        /// The route change's batch, by part (`batchParts`), and when its apply ended.
        var parts: String?
        var applied: Double?
        init(session: ExactSession, start: Double, committed: Double, fields: [String: Any], cold: Bool) {
            self.session = session
            self.start = start
            self.committed = committed
            self.fields = fields
            self.cold = cold
        }
    }

    func input(at timestamp: TimeInterval) { lastInput = timestamp }

    /// The first frame of UIKit's last transition of its own (its Back
    /// button, a back swipe), in seconds on the `CACurrentMediaTime` clock.
    private var platformShowing: Double?
    private var platformTurnEnded: Double?
    private var platformLink: CADisplayLink?

    /// UIKit begins showing a screen itself (`willShow` outside Exact's
    /// projection): its first frame is the next vsync after this turn, as
    /// Core Animation commits the transition at the turn's end.
    func platformBeganShowing() {
        platformShowing = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            platformTurnEnded = CACurrentMediaTime()
            if platformLink == nil { platformLink = mainDisplayLink(self, #selector(platformTick(_:))) }
        }
    }

    /// That transition was cancelled (a swipe let go): it showed nothing.
    func platformCancelled() {
        platformShowing = nil
        platformTurnEnded = nil
        platformLink?.invalidate()
        platformLink = nil
    }

    @objc private func platformTick(_ link: CADisplayLink) {
        defer { platformLink?.invalidate(); platformLink = nil }
        guard let ended = platformTurnEnded, let g = Vsync(link).next(after: ended) else { return }
        platformShowing = g
        platformTurnEnded = nil
    }

    func routerChanged(_ session: ExactSession, payload: [String: Any]) {
        guard let top = (payload["top"] as? NSNumber)?.uint64Value else { return }
        let key = ObjectIdentifier(session)
        let now = CACurrentMediaTime()
        var fields: [String: Any] = ["route": payload["pattern"] as? String ?? "", "url": payload["url"] as? String ?? "",
                                     "routeParams": payload["params"] as? [String: Any] ?? [:]]
        let cold = seen[key, default: []].insert(top).inserted
        // The first route is the launch route, which startup metrics cover.
        if launched.insert(key).inserted {
            fields["entry"] = Int(top)
            ExactJournal.shared.record("navigation.launch", fields)
            note("launch \(fields["route"] ?? "")")
            return
        }
        for removed in payload["removed"] as? [NSNumber] ?? [] { seen[key]?.remove(removed.uint64Value) }
        let start: Double
        if let input = lastInput, input <= now, now - input <= 1.0 {
            start = input
            fields["exact.nav.cause"] = "input"
        } else {
            start = now
            fields["exact.nav.cause"] = "program"
        }
        lastInput = nil
        if pending != nil { ExactJournal.shared.record("navigation.superseded", ["route": fields["route"] ?? ""]) }
        note("change \(fields["route"] ?? "") \(cold ? "cold" : "warm") \(fields["exact.nav.cause"] ?? "")")
        // The platform's own change: its screen showed when UIKit began to
        // show it, not now, after the transition (a Back tap's pop is ~0.5 s).
        if let shown = platformShowing, now - shown <= 2.0 {
            platformShowing = nil
            fields["exact.nav.platform"] = true
            let p = Pending(session: session, start: min(start, shown), committed: now, fields: fields, cold: cold)
            pending = p
            p.presented = shown
            var f = fields
            f["name"] = cold ? "cold_ttr" : "warm_ttr"
            f["value"] = shown - p.start
            ExactJournal.shared.record("navigation", f)
            note("\(f["name"] ?? "") \(f["route"] ?? "") \(String(format: "%.1f", (shown - p.start) * 1000)) ms (UIKit's)")
            guard cold else {
                pending = nil
                deadline?.cancel()
                return
            }
            deadline?.cancel()
            let item = DispatchWorkItem { [weak self, weak p] in
                guard let self, let p, pending === p else { return }
                pending = nil
                stop()
            }
            deadline = item
            DispatchQueue.main.asyncAfter(deadline: .now() + ExactLaunch.ttiTimeout, execute: item)
            // Nothing outstanding now: nothing was while UIKit animated
            // either (the screen was there), so it was interactive as shown.
            evaluate(at: shown)
            return
        }
        platformShowing = nil
        let p = Pending(session: session, start: start, committed: now, fields: fields, cold: cold)
        pending = p
        // Core Animation commits at the end of this turn, so the next turn is after it.
        DispatchQueue.main.async { [weak self, weak p] in
            guard let self, let p, pending === p else { return }
            p.turnEnded = CACurrentMediaTime()
            if link == nil { link = mainDisplayLink(self, #selector(tick(_:))) }
        }
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, pending === p else { return }
            pending = nil
            stop()
        }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ExactLaunch.ttiTimeout, execute: item)
    }

    /// What applying the route change's batch cost, by part (ms): its
    /// largest, on the screen's render metric.
    func batchParts(_ session: ExactSession, _ parts: [String: Double]) {
        guard let p = pending, p.session === session, p.presented == nil else { return }
        p.applied = CACurrentMediaTime()
        let top = parts.filter { $0.value >= 0.5 }.sorted { $0.value > $1.value }.prefix(6)
        if !top.isEmpty { p.parts = top.map { "\($0.key) \(Int($0.value.rounded()))" }.joined(separator: ", ") }
    }

    /// Re-checks outstanding work after a batch, once the change is shown.
    func applied(_ session: ExactSession) {
        guard let p = pending, p.session === session, p.presented != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let p = pending, let ended = p.turnEnded, p.presented == nil, let g = Vsync(link).next(after: ended) else { return }
        p.presented = g
        var f = p.fields
        f["name"] = p.cold ? "cold_ttr" : "warm_ttr"
        f["value"] = g - p.start
        // Where the time went, in seconds from the start: the router's
        // change reached the host, then its batch was committed.
        f["exact.nav.route_change"] = p.committed - p.start
        f["exact.nav.commit"] = ended - p.start
        if let parts = p.parts { f["exact.nav.parts"] = parts }
        // Applying ended here; the rest of the commit is UIKit's layout and render.
        if let applied = p.applied { f["exact.nav.applied"] = applied - p.start }
        ExactJournal.shared.record("navigation", f)
        note("\(f["name"] ?? "") \(f["route"] ?? "") \(String(format: "%.1f", (g - p.start) * 1000)) ms")
        guard p.cold else {
            pending = nil
            deadline?.cancel()
            stop()
            return
        }
        evaluate()
    }

    /// Records TTI once nothing is outstanding after the change was shown.
    private func evaluate(at clear: Double? = nil) {
        guard let p = pending, let presented = p.presented, let session = p.session,
              let ledger = ExactLaunch.ledger(session) else { return }
        guard ledger.items.isEmpty, !ledger.poisoned else { return }
        pending = nil
        deadline?.cancel()
        stop()
        var f = p.fields
        f["name"] = "tti"
        f["value"] = max(clear ?? CACurrentMediaTime(), presented) - p.start
        if !ledger.failed.isEmpty { f["exact.tti.failed"] = ledger.failed.count }
        ExactJournal.shared.record("navigation", f)
        note("tti \(f["route"] ?? "") \(String(format: "%.1f", (f["value"] as? Double ?? 0) * 1000)) ms")
    }
}
