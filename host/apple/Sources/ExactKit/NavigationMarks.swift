// Journals Observe's navigation metrics (cold_ttr, warm_ttr, tti) for each router change.
// A navigation starts at the input event's timestamp if one came within a second,
// otherwise at the commit. It is cold if its entry was not shown before in the session.
// Render time is the first vsync after the committing run-loop turn ends.
// TTI is when outstanding work clears, never before render. A newer change cancels it.
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
        init(session: ExactSession, start: Double, committed: Double, fields: [String: Any], cold: Bool) {
            self.session = session
            self.start = start
            self.committed = committed
            self.fields = fields
            self.cold = cold
        }
    }

    func input(at timestamp: TimeInterval) { lastInput = timestamp }

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
        ExactJournal.shared.record("navigation", f)
        note("\(f["name"] ?? "") \(f["route"] ?? "") \(String(format: "%.1f", (g - p.start) * 1000)) ms")
        evaluate()
    }

    /// Records TTI once nothing is outstanding after the change was shown.
    private func evaluate() {
        guard let p = pending, let presented = p.presented, let session = p.session,
              let ledger = ExactLaunch.ledger(session) else { return }
        guard ledger.items.isEmpty, !ledger.poisoned else { return }
        pending = nil
        deadline?.cancel()
        stop()
        var f = p.fields
        f["name"] = "tti"
        f["value"] = max(CACurrentMediaTime(), presented) - p.start
        if !ledger.failed.isEmpty { f["exact.tti.failed"] = ledger.failed.count }
        ExactJournal.shared.record("navigation", f)
        note("tti \(f["route"] ?? "") \(String(format: "%.1f", (f["value"] as? Double ?? 0) * 1000)) ms")
    }
}
