// Journals Observe's navigation metrics (cold_ttr, warm_ttr, tti) for each router change.
// A screen is a router visit at its URL, so a replace that keeps the visit but shows
// another URL is a new screen, as a new route key is in Observe. A navigation is cold
// if its screen was never shown in the session, else warm; it has a TTI until its
// screen has once been interactive (Observe records one per screen). A screen counts
// as shown when its first frame is presented, so one superseded before it stays cold.
// A navigation starts at the input being dispatched when the router changed (the tap
// whose action navigated, also when its dispatch queued the press for a later turn),
// otherwise at the commit; one UIKit made itself starts at the last touch or press
// before UIKit began it (a Back tap, a swipe's touch that moved).
// Render time is the first vsync after the committing run-loop turn, journaled once the
// display link reaches it. TTI is when outstanding work clears, never before render, and
// at the next vsync if the screen changed after it was shown. While the app is in the
// background nothing is measured, and going there cancels what waits: no one is waiting.
// A change UIKit made itself (its Back button, a back swipe, LLP 1035.001.000)
// reaches the app once its transition has ended, but the screen it shows was
// drawn from the transition's first frame: render is that frame, the first vsync
// after the turn in which UIKit began to show it (`willShow` comes before it), and TTI
// the first frame after the ledger is found clear once the transition has ended.
import Foundation
import QuartzCore

final class NavigationMarks: NSObject {
    static let shared = NavigationMarks()
    /// The timestamp of the input being dispatched, in seconds on the
    /// `CACurrentMediaTime` clock: set just before its dispatch, cleared after.
    private var dispatching: Double?
    /// The latest touch (in any phase: a swipe's moving touch begins one) or press, for a
    /// transition UIKit begins after it.
    private var lastTouch: Double?
    /// Per session, the screens shown so far.
    private var screens: [ObjectIdentifier: ScreenHistory] = [:]
    /// Per session, the route on top: `route`, `url` and `routeParams`.
    private var top: [ObjectIdentifier: [String: Any]] = [:]
    /// The sessions that navigated since their launch route was shown.
    private var navigated: Set<ObjectIdentifier> = []
    private var launched: Set<ObjectIdentifier> = []
    private var pending: Pending?
    private var link: CADisplayLink?
    private var inBackground = false
    /// Recent measurements for `state.observe`, newest last.
    private(set) var recent: [String] = []

    private func note(_ line: String) {
        if ExactEnv.environment["EXACT_OBSERVE_LOG"] == "1" { fputs("observe: navigation \(line)\n", stderr) }
        recent.append(line)
        if recent.count > 16 { recent.removeFirst() }
    }

    private final class Pending {
        weak var session: ExactSession?
        let key: ObjectIdentifier
        let visit: UInt64
        let url: String
        let start: Double
        let fields: [String: Any]
        let cold: Bool
        /// Its screen has not been interactive before.
        let measuresTTI: Bool
        var turnEnded: Double?
        /// Its screen is not shown yet (a sheet still to present, a cover on it, a transition that
        /// defers it): render is the first frame after UIKit begins to show it (`appearing`).
        var awaitingAppearance = false
        var presented: Double?
        /// The screen changed after the navigation's turn (a batch, or host work that ended).
        var dirty = false
        /// When the ledger was last found clear with the screen changed: TTI is the
        /// first vsync after it, if nothing became outstanding by then.
        var settledAt: Double?
        init(session: ExactSession, visit: UInt64, url: String, start: Double, fields: [String: Any], cold: Bool, measuresTTI: Bool) {
            self.session = session
            key = ObjectIdentifier(session)
            self.visit = visit
            self.url = url
            self.start = start
            self.fields = fields
            self.cold = cold
            self.measuresTTI = measuresTTI
        }
    }

    /// An input is about to be dispatched at `timestamp`; `inputEnded` follows its dispatch.
    func input(at timestamp: TimeInterval) {
        dispatching = timestamp
        lastTouch = timestamp
    }
    func inputEnded() { dispatching = nil }
    /// The input being dispatched, which work its dispatch queues for a later turn carries (`carrying`).
    var currentInput: Double? { dispatching }

    /// Runs `work`, which the dispatch of `input` queued (the tab bar's press of its
    /// authored tab), as part of that dispatch.
    func carrying(_ input: Double?, _ work: () -> Void) {
        guard let input, dispatching == nil else { return work() }
        dispatching = input
        defer { dispatching = nil }
        work()
    }

    /// The route `session` shows now.
    func current(for session: ExactSession) -> [String: Any]? { top[ObjectIdentifier(session)] }

    /// Whether the session's launch screen has stayed on top since launch, with nothing navigated to.
    func onLaunchScreen(_ session: ExactSession) -> Bool { !navigated.contains(ObjectIdentifier(session)) }

    /// Startup reached TTI: the screen on top has been interactive.
    func interactive(for session: ExactSession) {
        screens[ObjectIdentifier(session)]?.markInteractive()
    }

    /// The app went to the background: a navigation still waiting is cancelled,
    /// and none is measured until it is back.
    func background() {
        inBackground = true
        if pending != nil { note("cancelled by background") }
        pending = nil
        stop()
        platformCancelled()
    }

    /// A session ended: its screens go with it, as a later session can have its identity.
    func ended(_ session: ExactSession) {
        let key = ObjectIdentifier(session)
        screens[key] = nil
        top[key] = nil
        launched.remove(key)
        navigated.remove(key)
        launching[key] = nil
        foregroundTops[key] = nil
        if pending?.key == key {
            pending = nil
            stop()
        }
    }

    /// Back from the background: each session's screen on top, which a change
    /// there may have put on top, is presented again.
    func foreground() {
        inBackground = false
        // Each session's screen on top at the first frame after the return is shown (one a change
        // replaced before that frame is not).
        foregroundEnded = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !inBackground else { return }
            foregroundEnded = CACurrentMediaTime()
            foregroundTops = screens.compactMapValues { $0.current }
            if foregroundLink == nil { foregroundLink = mainDisplayLink(self, #selector(foregroundTick(_:))) }
        }
    }
    private var foregroundEnded: Double?
    /// Each session's screen on top when the return's turn ended.
    private var foregroundTops: [ObjectIdentifier: (visit: UInt64, url: String)] = [:]
    private var foregroundLink: CADisplayLink?

    @objc private func foregroundTick(_ link: CADisplayLink) {
        let v = Vsync(link)
        guard let ended = foregroundEnded, let g = v.next(after: ended), v.at + 1e-6 >= g else { return }
        foregroundEnded = nil
        foregroundLink?.invalidate()
        foregroundLink = nil
        // A screen a router change replaced since is not marked: that change's own render marks its screen.
        for (key, top) in foregroundTops where screens[key]?.current.map({ $0 == top }) == true { screens[key]?.markShown() }
        foregroundTops = [:]
    }

    /// The first frame of UIKit's last transition of its own (its Back
    /// button, a back swipe), in seconds on the `CACurrentMediaTime` clock,
    /// and the input being dispatched when UIKit began it.
    private var platformShowing: Double?
    private var platformTurnEnded: Double?
    private var platformInput: Double?
    private var platformLink: CADisplayLink?
    /// UIKit's own transition is being dispatched to the app (`platformDispatch`).
    private var platformDispatching = false

    /// UIKit begins showing a screen itself (`willShow` outside Exact's
    /// projection): its first frame is the next vsync after this turn, as
    /// Core Animation commits the transition at the turn's end.
    func platformBeganShowing() {
        platformShowing = nil
        // Only a touch or press begins UIKit's own transitions: the latest before it. UIKit reaches
        // `willShow` after it, in the layout pass of a Back tap's turn or a turn or two after a
        // swipe's touch moved. One over a second before is not its (code that popped).
        platformInput = dispatching ?? lastTouch.flatMap { CACurrentMediaTime() - $0 <= 1.0 ? $0 : nil }
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
        platformInput = nil
        platformLink?.invalidate()
        platformLink = nil
    }

    /// Runs the dispatch of UIKit's completed transition to the app (its Back, a dismissal):
    /// only a router change it makes takes the transition's marks, which go after it, used or
    /// not (an authored Back that only asked to confirm leaves them to no other navigation).
    func platformDispatch(_ dispatch: () -> Void) {
        platformDispatching = true
        defer {
            platformDispatching = false
            platformShowing = nil
            platformInput = nil
        }
        dispatch()
    }

    @objc private func platformTick(_ link: CADisplayLink) {
        defer { platformLink?.invalidate(); platformLink = nil }
        guard let ended = platformTurnEnded, let g = Vsync(link).next(after: ended) else { return }
        platformShowing = g
        platformTurnEnded = nil
    }

    /// Per session, the launch screen's frame not yet shown: when the turn that last
    /// changed it ended (nil until that turn ends).
    private var launching: [ObjectIdentifier: Double?] = [:]
    private var launchLink: CADisplayLink?

    /// The first vsync after the launch screen's last turn shows it.
    @objc private func launchTick(_ link: CADisplayLink) {
        let v = Vsync(link)
        for (key, ended) in launching {
            guard let ended, let g = v.next(after: ended), v.at + 1e-6 >= g else { continue }
            screens[key]?.markShown()
            launching[key] = nil
        }
        if launching.isEmpty {
            launchLink?.invalidate()
            launchLink = nil
        }
    }

    func routerChanged(_ session: ExactSession, payload: [String: Any]) {
        guard let visit = (payload["top"] as? NSNumber)?.uint64Value else { return }
        let key = ObjectIdentifier(session)
        let now = CACurrentMediaTime()
        let url = payload["url"] as? String ?? ""
        var fields: [String: Any] = ["route": payload["pattern"] as? String ?? "", "url": url,
                                     "routeParams": payload["params"] as? [String: Any] ?? [:]]
        let removed = (payload["removed"] as? [NSNumber] ?? []).map(\.uint64Value)
        // nil: the same screen is still on top (a change in another tab), so nothing was navigated to.
        guard let screen = screens[key, default: ScreenHistory()].change(visit: visit, url: url, removed: removed) else { return }
        top[key] = fields
        // The first route is the launch route, which startup metrics cover. Until a frame shows
        // it, a change replaces it (a redirect at launch) and is no navigation; the screen on top
        // at that frame is the one shown.
        if launched.insert(key).inserted || launching[key] != nil {
            fields["entry"] = Int(visit)
            // Startup's route is its session's: another window's first route is not the launch's.
            if session === ExactLaunch.shared.launchSession { ExactJournal.shared.record("navigation.launch", fields) }
            note("launch \(fields["route"] ?? "")")
            // Waiting for this turn's end (a value of nil, not a removal).
            launching[key] = .some(nil)
            // Core Animation commits at the end of this turn, so the next turn is after it.
            DispatchQueue.main.async { [weak self] in
                guard let self, launching[key] != nil else { return }
                launching[key] = CACurrentMediaTime()
                if launchLink == nil { launchLink = mainDisplayLink(self, #selector(launchTick(_:))) }
            }
            return
        }
        navigated.insert(key)
        if pending != nil { ExactJournal.shared.record("navigation.superseded", ["route": fields["route"] ?? ""]) }
        pending = nil
        guard !inBackground else {
            stop()
            note("change \(fields["route"] ?? "") in the background: not measured")
            return
        }
        // The platform's own change: its screen showed when UIKit began to
        // show it, not now, after the transition (a Back tap's pop is ~0.5 s).
        // UIKit's transition, however long it ran (a held swipe), unless it ended over a second ago
        // with no router change: then this change is not its. Nor is a change no event made (a
        // timer's or an answer's redirect during a swipe), which waits for its own frame.
        let fromEvent = payload["event"] as? Bool != false
        // UIKit's change reaches the app in the dispatch of its completed transition: only a change
        // from that dispatch takes its marks, not one while it runs (a tab pressed during a held
        // swipe) or another after.
        let platform = fromEvent && platformDispatching ? platformShowing : nil
        // A change a timer made, which the runner fired before the event's own commit, is not the input's.
        let input = platform != nil ? platformInput : fromEvent ? dispatching : nil
        let start = min(input ?? now, platform ?? now)
        fields["exact.nav.cause"] = input != nil ? "input" : "program"
        if platform != nil {
            platformShowing = nil
            platformInput = nil
        }
        note("change \(fields["route"] ?? "") visit \(visit) \(screen.shown ? "warm" : "cold") \(fields["exact.nav.cause"] ?? "")")
        if let shown = platform {
            fields["exact.nav.platform"] = true
            let p = Pending(session: session, visit: visit, url: url, start: start, fields: fields, cold: !screen.shown, measuresTTI: !screen.interactive)
            pending = p
            rendered(p, at: shown, by: "UIKit's")
            // The ledger now says nothing of the frames UIKit showed while it animated (a
            // request can have ended during them): TTI is the first frame after it is clear now.
            p.dirty = true
            if pending === p { evaluate() }
            return
        }
        let p = Pending(session: session, visit: visit, url: url, start: start, fields: fields, cold: !screen.shown, measuresTTI: !screen.interactive)
        pending = p
        renderAfterThisTurn(p)
    }

    /// Core Animation commits at the end of this turn, so the next turn is after it, once UIKit
    /// shows the screen: one it does not show yet waits for it to begin to (`appearing`).
    private func renderAfterThisTurn(_ p: Pending) {
        DispatchQueue.main.async { [weak self, weak p] in
            guard let self, let p, pending === p else { return }
            #if os(iOS) || os(tvOS)
            // The route keyed by the visit, as the router keys its views (`navigationKey`). None with
            // that key yet waits too (a sheet presented after another), unless this host keys none so.
            if let host = p.session?.presenter.navigation {
                let appeared = host.routeAppeared(String(p.visit))
                if appeared == false || (appeared == nil && host.keysByVisit) {
                    p.awaitingAppearance = true
                    return
                }
            }
            #endif
            p.turnEnded = CACurrentMediaTime()
            if link == nil { link = mainDisplayLink(self, #selector(tick(_:))) }
        }
    }

    /// UIKit begins to show the route keyed `key` in `session` (`viewIsAppearing`): a navigation
    /// waiting for it renders at the first frame after this turn.
    func appearing(_ session: ExactSession, key: String) {
        guard let p = pending, p.session === session, p.awaitingAppearance, key == String(p.visit) else { return }
        p.awaitingAppearance = false
        renderAfterThisTurn(p)
    }

    /// Re-checks outstanding work after a batch, once the change is shown.
    func applied(_ session: ExactSession, changed: Bool) {
        guard let p = pending, p.session === session, p.turnEnded != nil || p.presented != nil else { return }
        // A change after the navigation's own turn shows in a later frame than the one it is timed by.
        if changed {
            p.dirty = true
            p.settledAt = nil
        }
        guard p.presented != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let p = pending else { return stop() }
        let v = Vsync(link)
        if p.presented != nil {
            // The frame that shows the settled screen, unless work came back before it.
            if let since = p.settledAt, let target = v.next(after: since) {
                guard v.at + 1e-6 >= target else { return }
                p.settledAt = nil
                guard let session = p.session, let ledger = ExactLaunch.ledger(session), ledger.items.isEmpty, !ledger.poisoned else { return evaluate() }
                return interactive(p, at: target, failed: ledger.failed.count)
            }
            // Shown and still waiting on host work, which can end with no batch after it.
            return evaluate()
        }
        // The first vsync after the navigation's turn, once the display link has reached it.
        guard let ended = p.turnEnded, let g = v.next(after: ended), v.at + 1e-6 >= g else { return }
        rendered(p, at: g, by: nil)
        if pending === p { evaluate() }
    }

    /// The navigation's screen is on screen at `t`: its TTR, and the screen is shown.
    private func rendered(_ p: Pending, at t: Double, by: String?) {
        p.presented = t
        screens[p.key]?.markShown(visit: p.visit, url: p.url)
        var f = p.fields
        f["name"] = p.cold ? "cold_ttr" : "warm_ttr"
        f["value"] = t - p.start
        ExactJournal.shared.record("navigation", f, at: t)
        note("\(f["name"] ?? "") \(f["route"] ?? "") \(String(format: "%.1f", (t - p.start) * 1000)) ms\(by.map { " (\($0))" } ?? "")")
        guard p.measuresTTI else {
            pending = nil
            stop()
            return
        }
    }

    /// Records TTI once nothing is outstanding after the change was shown: at once
    /// if the screen has not changed since, else at the frame that shows the change.
    private func evaluate() {
        guard let p = pending, let presented = p.presented, let session = p.session,
              let ledger = ExactLaunch.ledger(session) else { return }
        // A poisoned runtime handles no action again: the navigation ends without TTI, as on the web.
        if ledger.poisoned {
            note("cancelled: the runtime is poisoned")
            pending = nil
            stop()
            return
        }
        guard ledger.items.isEmpty else {
            p.settledAt = nil
            // Runner work ends in a batch (`applied`); host work may not, so only it keeps
            // the link, and its end changes the screen.
            if ledger.items.contains(where: { $0.hasPrefix("host:") }) {
                p.dirty = true
                if link == nil { link = mainDisplayLink(self, #selector(tick(_:))) }
            } else {
                stop()
            }
            return
        }
        guard !p.dirty else {
            if p.settledAt == nil { p.settledAt = CACurrentMediaTime() }
            if link == nil { link = mainDisplayLink(self, #selector(tick(_:))) }
            return
        }
        interactive(p, at: max(CACurrentMediaTime(), presented), failed: ledger.failed.count)
    }

    private func interactive(_ p: Pending, at t: Double, failed: Int) {
        pending = nil
        stop()
        screens[p.key]?.markInteractive(visit: p.visit, url: p.url)
        var f = p.fields
        f["name"] = "tti"
        f["value"] = t - p.start
        if failed > 0 { f["exact.tti.failed"] = failed }
        ExactJournal.shared.record("navigation", f, at: t)
        note("tti \(f["route"] ?? "") \(String(format: "%.1f", (t - p.start) * 1000)) ms")
    }
}

/// The screens a session has shown, and those that have been interactive. A screen
/// is a router visit at its URL: a replace keeps the visit and shows another screen;
/// visit ids are never reused.
struct ScreenHistory {
    private var shown: [UInt64: Set<String>] = [:]
    private var interactive: [UInt64: Set<String>] = [:]
    private var top: (visit: UInt64, url: String)?
    /// The screen on top.
    var current: (visit: UInt64, url: String)? { top }

    /// Records the router's top after a change that removed `removed`. Returns
    /// whether that screen was shown and whether it was interactive before, or
    /// nil when it is already the one on top.
    mutating func change(visit: UInt64, url: String, removed: [UInt64]) -> (shown: Bool, interactive: Bool)? {
        for id in removed {
            shown[id] = nil
            interactive[id] = nil
        }
        if let t = top, t.visit == visit, t.url == url { return nil }
        top = (visit, url)
        return (shown[visit]?.contains(url) == true, interactive[visit]?.contains(url) == true)
    }

    /// The screen at `visit` and `url` (by default the one on top) was presented.
    mutating func markShown(visit: UInt64? = nil, url: String? = nil) {
        guard let visit = visit ?? top?.visit, let url = url ?? top?.url else { return }
        shown[visit, default: []].insert(url)
    }

    /// The screen at `visit` and `url` (by default the one on top) was interactive.
    mutating func markInteractive(visit: UInt64? = nil, url: String? = nil) {
        guard let visit = visit ?? top?.visit, let url = url ?? top?.url else { return }
        interactive[visit, default: []].insert(url)
    }
}
