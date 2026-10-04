// The launch marks (Exact Observe design §3.2–3.4): when the process started,
// when the platform finished launching it, when the first tree was committed
// and shown. Marks are host timestamps on one clock (`CACurrentMediaTime`,
// mach_absolute_time); nothing here does I/O beyond one preferences write.
//
// Anchors are Observe's own (expo-app-metrics `AppStartupMarkers`):
//   launch = (L − P) + (DFL − Md)      Md: the app delegate's init (after any prewarm)
//   TTR    = F0 − DFL                  DFL: didFinishLaunching *returns*
// F0 is the first vsync after the commit that carried the first tree: views
// handed to Core Animation are taken to be displayed by the next frame. The
// render server can show them a frame or more later; that gap is not measured.
import CExactLaunch
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public final class ExactLaunch: NSObject {
    public static let shared = ExactLaunch()

    public enum Mark: String, CaseIterable {
        case process, constructor, delegateInit, didFinishLaunching, scene, boot, commit, present, activated, interactive
    }

    let facts = exact_launch_constructor_facts()
    /// Monotonic seconds per mark, for the launch session only.
    private(set) var marks: [Mark: Double] = [:] {
        didSet {
            for (m, t) in marks where oldValue[m] == nil { ExactJournal.shared.record("mark", ["mark": m.rawValue], at: t) }
        }
    }
    /// Services the launch parts asked for, waiting for their moment.
    private var services: [(module: String, when: ExactServiceLoad, config: [String: Any], handoff: () -> Data)] = []
    private var loaded: Set<String> = []
    /// cold, warm, or nil before DFL.
    private(set) var launchType: String?
    /// Why this launch reports no startup metrics, when it doesn't.
    private(set) var suppressed: String?
    private(set) var activation = "pending"
    private(set) var bootPath: String?
    private weak var launchSession: ExactSession?
    private var commitPending = false
    private var link: CADisplayLink?
    /// The last display-link sample: its vsync time and its observed interval.
    private var vsync: (at: Double, interval: Double)?
    /// TTI (§3.5): how startup ended, what was still outstanding, whether the
    /// screen changed since its last presented frame, and the vsync a ready
    /// candidate waits for.
    private(set) var ttiOutcome: String?
    private(set) var lastOutstanding: [String] = []
    /// Each distinct outstanding set the ledger passed through, with its time
    /// from process start: how TTI was reached (`state.observe`, the smoke).
    private(set) var trace: [String] = []
    private(set) var failedResources: [String] = []
    private var contentDirty = false
    private var candidate: Double?
    private var evaluateScheduled = false
    /// The app's own `aria-busy` was the last thing outstanding.
    private var declaredLast = false
    static let ttiTimeout = 30.0

    private override init() {
        super.init()
        if facts.valid != 0 {
            marks[.constructor] = facts.constructorMono
            marks[.process] = facts.constructorMono - facts.processAge
        }
        if facts.prewarm != 0 { suppressed = "prewarmed" }
    }

    // MARK: Host hooks (the adapter's app delegate)

    /// The app delegate is being made: inside `UIApplicationMain`, after any
    /// prewarm pause. Observe's "main".
    public func delegateInit() {
        if marks[.delegateInit] == nil { marks[.delegateInit] = CACurrentMediaTime() }
    }

    /// `didFinishLaunching` is about to return, its own setup (the session)
    /// done. `hidden`: macOS launched the app hidden (a login item).
    ///
    /// A scene-based iOS app is `.background` here even when the user tapped
    /// its icon (measured on the iOS 27 simulator), so the application state
    /// can't tell a background launch. The scene does (`sceneConnected`).
    public func didFinishLaunching(hidden: Bool = false) {
        guard marks[.didFinishLaunching] == nil else { return }
        marks[.didFinishLaunching] = CACurrentMediaTime()
        if hidden, suppressed == nil { suppressed = "hidden" }
        if marks[.delegateInit] == nil, suppressed == nil { suppressed = "no delegate mark" }
        launchType = classify()
        ExactJournal.shared.record("launch", ["type": launchType ?? "", "suppressed": suppressed ?? ""])
        watchInterruption()
        guard suppressed == nil, !ExactEnv.agentMode else { loadServices(.afterStartup); return }
        watchVsync()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ttiTimeout) { [weak self] in
            guard let self, ttiOutcome == nil, suppressed == nil else { return }
            if let o = outstandingNow() { lastOutstanding = o }
            finish("timeout")
        }
    }

    /// The first scene connected. UIKit connects a foreground launch's scene
    /// straight after `didFinishLaunching` (tens of ms); a process launched
    /// in the background (a push, a background task) gets its scene only when
    /// the user later opens it, after its launch work is long done. So a
    /// scene that connects more than `backgroundGap` after DFL means this
    /// process was launched in the background: no startup metrics.
    public func sceneConnected() {
        guard marks[.scene] == nil else { return }
        let now = CACurrentMediaTime()
        marks[.scene] = now
        if let dfl = marks[.didFinishLaunching], now - dfl > Self.backgroundGap, suppressed == nil {
            suppressed = "background launch"
            stopWatching()
        }
    }
    static let backgroundGap = 5.0

    // MARK: Session hooks

    /// A session begins a boot, on any path. The first one after DFL is the
    /// launch session.
    func bootEntered(_ session: ExactSession) {
        guard marks[.didFinishLaunching] != nil, launchSession == nil, marks[.boot] == nil else { return }
        launchSession = session
        marks[.boot] = CACurrentMediaTime()
    }

    /// The launch session's first tree is applied; Core Animation draws and
    /// commits it next (`drawn`).
    func treeApplied(_ session: ExactSession, path: String) {
        guard session === launchSession, marks[.commit] == nil, bootPath == nil else { return }
        bootPath = path
        commitPending = true
    }

    /// Data activation settled for the launch session's first generation.
    func activated(_ session: ExactSession, ok: Bool) {
        guard session === launchSession, activation == "pending" else { return }
        activation = ok ? "ready" : "failed"
        if ok { marks[.activated] = CACurrentMediaTime() } else { finish("activation_failed") }
        scheduleEvaluate()
    }

    /// A batch applied to the launch session: re-read the ledger once this
    /// turn (and the commit that ends it) is done.
    func applied(_ session: ExactSession, changed: Bool) {
        guard session === launchSession, ttiOutcome == nil else { return }
        if changed { contentDirty = true; candidate = nil }
        scheduleEvaluate()
    }

    // MARK: Commit and vsync

    /// The launch session's first tree drew. Its layers are drawn inside the
    /// Core Animation commit that carries it (`CA::Transaction::commit` →
    /// `display_if_needed`, whether the commit runs at the run loop's
    /// before-waiting or from AppKit's and UIKit's update cycle), so this is
    /// the commit, less only what Core Animation does after drawing. A run-loop
    /// observer can't see every commit: on current macOS the update cycle commits
    /// from an observer in HIToolbox's own mode.
    func drawn(_ session: ExactSession) {
        guard session === launchSession, commitPending else { return }
        commitPending = false
        marks[.commit] = CACurrentMediaTime()
        resolvePresent()
    }

    private func watchVsync() {
        #if os(macOS)
        let l: CADisplayLink? = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        let l: CADisplayLink? = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        l?.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The observed interval: on ProMotion `duration` can stay nominal while
        // the cadence changes (as `Session`'s frame code notes).
        let interval = link.targetTimestamp - link.timestamp
        vsync = (link.timestamp, interval > 0 ? interval : link.duration)
        resolvePresent()
        confirmCandidate()
    }

    /// F0: the first vsync strictly after the commit, on the grid of the
    /// nearest sample. A sample delivered late still names its own vsync, so a
    /// busy main turn after the commit does not move F0.
    private func resolvePresent() {
        guard let c0 = marks[.commit], marks[.present] == nil, let v = vsync, v.interval > 0 else { return }
        var g = v.at + ((c0 - v.at) / v.interval).rounded(.up) * v.interval
        if g <= c0 { g += v.interval }
        marks[.present] = g
        loadServices(.afterFirstPixel)
        scheduleEvaluate()
    }

    /// The first vsync strictly after `t`, on the last sample's grid.
    private func nextVsync(after t: Double) -> Double? {
        guard let v = vsync, v.interval > 0 else { return nil }
        var g = v.at + ((t - v.at) / v.interval).rounded(.up) * v.interval
        if g <= t { g += v.interval }
        return g
    }

    // MARK: TTI (§3.5)

    private func scheduleEvaluate() {
        guard !evaluateScheduled, ttiOutcome == nil, suppressed == nil, !ExactEnv.agentMode else { return }
        evaluateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.evaluateScheduled = false
            self?.evaluate()
        }
    }

    /// What is still outstanding for the launch session: the runner's ledger
    /// and the host's. Empty when the screen can be used.
    private func outstandingNow() -> [String]? {
        guard let session = launchSession, let ledger = Self.ledger(session) else { return nil }
        if ledger.poisoned { finish("logic_failed"); return nil }
        failedResources = ledger.failed
        return ledger.items + (activation != "ready" ? ["activation"] : [])
    }

    /// A session's settle ledger (§3.5): the runner's outstanding work and the
    /// host's, as names; what failed; whether the runner is poisoned.
    static func ledger(_ session: ExactSession) -> (items: [String], failed: [String], poisoned: Bool)? {
        guard let data = session.agent("{\"op\":\"outstanding\"}").data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String] = []
        for key in ["requests", "streams", "awaiting", "deferred", "oneShots", "thens", "busy"] {
            out += (o[key] as? [String] ?? []).map { "\(key):\($0)" }
        }
        out += session.hostOutstanding.map { "host:\($0)" }
        return (out, o["failed"] as? [String] ?? [], o["poisoned"] as? Bool == true)
    }

    /// At a completion barrier (the turn after an apply or an activation):
    /// when nothing is outstanding, I is the screen's next presentation if it
    /// changed since its last one, else now; never before the first frame.
    private func evaluate() {
        guard ttiOutcome == nil, suppressed == nil, let outstanding = outstandingNow() else { return }
        if outstanding.isEmpty, !lastOutstanding.isEmpty, lastOutstanding.allSatisfy({ $0.hasPrefix("busy:") }) { declaredLast = true }
        if outstanding != lastOutstanding || trace.isEmpty, trace.count < 32, let p = marks[.process] {
            trace.append("\(String(format: "%.1f", (CACurrentMediaTime() - p) * 1000)) [\(outstanding.joined(separator: ", "))]")
        }
        lastOutstanding = outstanding
        guard outstanding.isEmpty, let f0 = marks[.present] else { candidate = nil; return }
        let now = CACurrentMediaTime()
        if contentDirty {
            candidate = nextVsync(after: now)
            return
        }
        marks[.interactive] = max(now, f0)
        finish(!failedResources.isEmpty ? "failed" : declaredLast ? "declared" : "settled")
    }

    /// A ready candidate holds if nothing came outstanding before its vsync.
    private func confirmCandidate() {
        guard let target = candidate, let v = vsync, v.at >= target, ttiOutcome == nil else { return }
        candidate = nil
        guard let outstanding = outstandingNow(), outstanding.isEmpty else { scheduleEvaluate(); return }
        contentDirty = false
        marks[.interactive] = max(target, marks[.present] ?? target)
        finish(!failedResources.isEmpty ? "failed" : declaredLast ? "declared" : "settled")
    }

    private func finish(_ outcome: String) {
        guard ttiOutcome == nil else { return }
        ttiOutcome = outcome
        stopWatching()
        ExactJournal.shared.record("startup", report())
        if ExactEnv.environment["EXACT_OBSERVE_LOG"] == "1", let session = launchSession { fputs("observe: startup \(smokeLine(for: session))\n", stderr) }
        loadServices(.afterStartup)
    }

    func requestService(module: String, when: ExactServiceLoad, config: [String: Any], handoff: @escaping () -> Data) {
        services.append((module, when, config, handoff))
        if when == .afterFirstPixel, marks[.present] != nil || suppressed != nil { loadServices(.afterFirstPixel) }
        if when == .afterStartup, ttiOutcome != nil || suppressed != nil { loadServices(.afterStartup) }
    }

    /// Load each service whose moment came, in the turn after this one: never
    /// inside the work that triggered it.
    private func loadServices(_ moment: ExactServiceLoad) {
        let due = services.filter { ($0.when == moment || moment == .afterStartup) && !loaded.contains($0.module) }
        for s in due {
            loaded.insert(s.module)
            DispatchQueue.main.async {
                let config = (try? JSONSerialization.data(withJSONObject: s.config)) ?? Data("{}".utf8)
                guard let service = ExactService.load(module: s.module, config: config, handoff: s.handoff()) else { return }
                ExactJournal.shared.attach(s.module, service)
            }
        }
    }

    private func stopWatching() {
        link?.invalidate()
        link = nil
    }

    private func watchInterruption() {
        #if os(macOS)
        let name = NSApplication.didHideNotification
        #else
        let name = UIApplication.didEnterBackgroundNotification
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            ExactJournal.shared.record("background")
            ExactJournal.shared.background()
            guard let self, ttiOutcome == nil, suppressed == nil else { return }
            suppressed = "interrupted"
            stopWatching()
            loadServices(.afterStartup)
        }
    }

    // MARK: Classification (Observe's heuristic, `AppStartupMonitoring.getAppLaunchType`)

    private static let defaults = UserDefaults(suiteName: "dev.exact.observe")
    private func classify() -> String {
        let boot = Self.bootTime()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let previous = Self.defaults?.dictionary(forKey: "launch")
        Self.defaults?.set(["boot": boot, "build": build, "os": os], forKey: "launch")
        guard let previous, previous["build"] as? String == build else { return "cold" }
        if facts.tty != 0 { return "cold" }
        guard let was = previous["boot"] as? Double, abs(was - boot) < 1 else { return "cold" }
        return "warm"
    }

    private static func bootTime() -> Double {
        var t = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &t, &size, nil, 0) == 0 else { return 0 }
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }

    // MARK: The report (`state.observe`, smoke)

    /// Observe's metric names and values (seconds), plus Exact's phases.
    public func report(for session: ExactSession? = nil) -> [String: Any] {
        var out: [String: Any] = ["activation": activation]
        if let launchType { out["launchType"] = launchType }
        if let suppressed { out["suppressed"] = suppressed }
        if let bootPath { out["bootPath"] = bootPath }
        if let ttiOutcome { out["tti"] = ttiOutcome }
        if !lastOutstanding.isEmpty { out["outstanding"] = lastOutstanding }
        if !failedResources.isEmpty { out["failed"] = failedResources }
        if !trace.isEmpty { out["trace"] = trace }
        if !NavigationMarks.shared.recent.isEmpty { out["navigation"] = NavigationMarks.shared.recent }
        if let session { out["launchSession"] = session === launchSession }
        if facts.traced != 0 { out["debugger"] = true }
        if let p = marks[.process] {
            out["marks"] = Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, (($0.value - p) * 1000 * 10).rounded() / 10) })
        }
        out["metrics"] = metrics()
        return out
    }

    func metrics() -> [String: Double] {
        guard suppressed == nil, let dfl = marks[.didFinishLaunching] else { return [:] }
        var m: [String: Double] = [:]
        if let p = marks[.process], let l = marks[.constructor], let md = marks[.delegateInit], let type = launchType {
            m["\(type)LaunchTime"] = (l - p) + (dfl - md)
        }
        if let f0 = marks[.present] { m["timeToFirstRender"] = f0 - dfl }
        if let i = marks[.interactive], ["settled", "failed", "declared"].contains(ttiOutcome ?? "") { m["timeToInteractive"] = i - dfl }
        return m
    }
}

extension ExactLaunch {
    /// One line for `EXACT_SMOKE`: the metrics in ms and the marks from process start.
    public func smokeLine(for session: ExactSession) -> String {
        let r = report(for: session)
        let metrics = (r["metrics"] as? [String: Double] ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key) \(String(format: "%.1f", $0.value * 1000)) ms" }.joined(separator: "; ")
        let order = Mark.allCases.map(\.rawValue)
        let marks = (r["marks"] as? [String: Double] ?? [:]).sorted { order.firstIndex(of: $0.key)! < order.firstIndex(of: $1.key)! }
            .map { "\($0.key) \(String(format: "%.1f", $0.value))" }.joined(separator: " · ")
        let trace = (r["trace"] as? [String] ?? []).joined(separator: " → ")
        return "\(r["launchType"] ?? "?") \(r["bootPath"] ?? "?") tti \(r["tti"] ?? "pending")\((r["outstanding"] as? [String]).map { " outstanding \($0)" } ?? "") \(r["suppressed"].map { "suppressed: \($0) " } ?? "")activation \(r["activation"] ?? "?"); \(metrics.isEmpty ? "no metrics" : metrics); marks \(marks); ledger \(trace)"
    }
}
