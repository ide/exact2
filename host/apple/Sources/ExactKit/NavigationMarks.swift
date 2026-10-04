// Navigation marks (Exact Observe design §3.6): for each router change a
// session commits, when its cause happened, when its first frame was shown,
// and when its screen became usable — Observe's navigation cold_ttr,
// warm_ttr and tti, journaled for a module such as Observe to send.
//
// - Start: the platform event's own timestamp (UIEvent/NSEvent, the same
//   mach clock as every mark) when an input preceded the change by at most
//   a second; else the commit itself (a timer, a data answer, a deep link).
// - Cold or warm: whether this entry (visit id) was shown before in the
//   session, as Observe keys on the screen's identity.
// - TTR: the first vsync after the turn that committed the change ended.
// - TTI: the first moment after that the session's settle ledger is clear,
//   never before TTR; a later change before it supersedes it (no metric).
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class NavigationMarks: NSObject {
    static let shared = NavigationMarks()
    /// The last input the window dispatched (a touch ended, a press, a key).
    private var lastInput: Double?
    private var seen: [ObjectIdentifier: Set<UInt64>] = [:]
    private var launched: Set<ObjectIdentifier> = []
    private var pending: Pending?
    private var link: CADisplayLink?
    private var vsync: (at: Double, interval: Double)?
    private var deadline: DispatchWorkItem?
    /// What it measured, newest last (`state.observe`).
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

    /// The window dispatched an input that can cause a navigation.
    func input(at timestamp: TimeInterval) { lastInput = timestamp }

    /// A batch applied to `session` carried a router change.
    func routerChanged(_ session: ExactSession, payload: [String: Any]) {
        guard let top = (payload["top"] as? NSNumber)?.uint64Value else { return }
        let key = ObjectIdentifier(session)
        let now = CACurrentMediaTime()
        var fields: [String: Any] = ["route": payload["pattern"] as? String ?? "", "url": payload["url"] as? String ?? "",
                                     "routeParams": payload["params"] as? [String: Any] ?? [:]]
        // The session's first route is its launch route: its marks are startup's.
        guard launched.contains(key) else {
            launched.insert(key)
            seen[key, default: []].insert(top)
            fields["entry"] = Int(top)
            ExactJournal.shared.record("navigation.launch", fields)
            note("launch \(fields["route"] ?? "")")
            return
        }
        let cold = !(seen[key]?.contains(top) ?? false)
        seen[key, default: []].insert(top)
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
        // The commit is made at the end of this turn; the turn after is past it.
        DispatchQueue.main.async { [weak self, weak p] in
            guard let self, let p, pending === p else { return }
            p.turnEnded = CACurrentMediaTime()
            watch()
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

    /// A batch applied to `session`: the screen may have become usable.
    func applied(_ session: ExactSession) {
        guard let p = pending, p.session === session, p.presented != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func watch() {
        guard link == nil else { return }
        #if os(macOS)
        let l: CADisplayLink? = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        let l: CADisplayLink? = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        l?.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        vsync = (link.timestamp, interval > 0 ? interval : link.duration)
        guard let p = pending, let ended = p.turnEnded, p.presented == nil, let v = vsync else { return }
        var g = v.at + ((ended - v.at) / v.interval).rounded(.up) * v.interval
        if g <= ended { g += v.interval }
        p.presented = g
        var f = p.fields
        f["name"] = p.cold ? "cold_ttr" : "warm_ttr"
        f["value"] = g - p.start
        ExactJournal.shared.record("navigation", f)
        note("\(f["name"] ?? "") \(f["route"] ?? "") \(String(format: "%.1f", (g - p.start) * 1000)) ms")
        evaluate()
    }

    /// Navigation TTI: the ledger clear at a barrier after the change was shown.
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
