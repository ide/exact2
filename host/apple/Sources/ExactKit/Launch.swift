// Startup metrics with Observe's definitions (expo-app-metrics `AppStartupMarkers`).
// All marks are seconds on `CACurrentMediaTime` (mach_absolute_time).
//   launch time = (constructor − process start) + (didFinishLaunching − delegate init)
//   time to first render = first vsync after the first tree's commit − didFinishLaunching
// Time to first render assumes the render server shows a commit at the next vsync.
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
        case process, constructor, main, delegateInit, didFinishLaunching, scene, boot, commit, present, activated, interactive
    }

    let facts = exact_launch_constructor_facts()
    /// Each mark's time in seconds, for the launch session only.
    private(set) var marks: [Mark: Double] = [:] {
        didSet {
            for (m, t) in marks where oldValue[m] == nil { ExactJournal.shared.record("mark", ["mark": m.rawValue], at: t) }
        }
    }
    /// Services the launch parts asked for, waiting for their moment.
    private var services: [(module: String, when: ExactServiceLoad, config: [String: Any], handoff: () -> Data)] = []
    /// Services due to load in a later turn, and those loaded.
    private var scheduled: Set<String> = []
    private var loaded: Set<String> = []
    /// "cold", "warm", or nil before didFinishLaunching.
    private(set) var launchType: String?
    /// Why this launch reports no startup metrics, when it doesn't.
    private(set) var suppressed: String?
    private(set) var activation = "pending"
    private(set) var bootPath: String?
    private(set) weak var launchSession: ExactSession?
    private var commitPending = false
    private var link: CADisplayLink?
    private var vsync: Vsync?
    /// How time to interactive ended: settled or failed (reached), or
    /// interrupted, activation_failed or logic_failed (never reached).
    private(set) var ttiOutcome: String?
    /// The app went to the background (on macOS, was hidden) before time to
    /// interactive. As in Observe, what was measured before it still reports.
    private(set) var interruptedAt: Double?
    /// `ttiTimeout` passed without TTI: the display link is off until the screen settles, and
    /// TTI has no frame parameters, its window not having been timed throughout.
    private var late = false
    /// When work last cleared while late, for the vsync the next tick picks.
    private var clearedAt: Double?
    private var frames = FrameStats()
    /// `present` is the commit plus one refresh, not a sampled vsync.
    private var presentEstimated = false
    private(set) var lastOutstanding: [String] = []
    /// Each outstanding item's span, seconds on the `CACurrentMediaTime`
    /// clock: first seen at an evaluation, cleared at a later one (what held
    /// TTI, by item, not only the set at each change the trace keeps).
    private var spans: [String: (from: Double, to: Double?)] = [:]
    private var spanOrder: [String] = []
    /// Each batch that changed the screen after nothing was outstanding: ms
    /// from process start and what it changed.
    private var changes: [String] = []
    /// Each distinct set of outstanding work, with ms from process start, for
    /// debugging how time to interactive was reached.
    private(set) var trace: [String] = []
    private(set) var failedResources: [String] = []
    /// The screen changed since its last presented frame.
    private var contentDirty = false
    /// The vsync at which a settled screen becomes interactive, unless work reappears.
    private var candidate: Double?
    private var evaluateScheduled = false
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

    /// Called first thing in the adapter's `main`: what ran between the
    /// constructor and here is every other image's initializers.
    public func main() {
        if marks[.main] == nil { marks[.main] = CACurrentMediaTime() }
    }

    /// Called from the app delegate's init, inside `UIApplicationMain` and after
    /// any prewarm pause. Observe calls this mark "main".
    public func delegateInit() {
        if marks[.delegateInit] == nil { marks[.delegateInit] = CACurrentMediaTime() }
    }

    /// Called as `didFinishLaunching` returns, after the session is made.
    /// `hidden` means macOS launched the app hidden, as a login item does.
    /// A scene-based iOS app reports `.background` here even for a tap on its
    /// icon, so `sceneConnected` detects background launches instead.
    public func didFinishLaunching(hidden: Bool = false) {
        guard marks[.didFinishLaunching] == nil else { return }
        marks[.didFinishLaunching] = CACurrentMediaTime()
        if hidden, suppressed == nil { suppressed = "hidden" }
        if marks[.delegateInit] == nil, suppressed == nil { suppressed = "no delegate mark" }
        launchType = classify()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            firstTurn = true
            #if os(iOS)
            // No scene by the first turn: a background launch, whose scene connects only when the user opens the app.
            if marks[.scene] == nil { backgroundLaunch() }
            #endif
        }
        ExactJournal.shared.record("launch", ["type": launchType ?? "", "suppressed": suppressed ?? ""])
        watchInterruption()
        guard suppressed == nil, !ExactEnv.agentMode else { loadServices(.afterStartup); return }
        link = mainDisplayLink(self, #selector(tick(_:)))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ttiTimeout) { [weak self] in
            // Not interactive yet: the display link stops, as it costs power; host work still drawing
            // keeps being read without it (`evaluate`), and a later TTI still reports.
            guard let self, ttiOutcome == nil, suppressed == nil else { return }
            if let o = outstandingNow() { lastOutstanding = o }
            late = true
            stopWatching()
            loadServices(.afterStartup)
            scheduleEvaluate()
        }
    }

    /// UIKit connects a foreground launch's scene inside the launch itself, before
    /// the main thread's first turn after `didFinishLaunching`. A background launch
    /// (a push, a background task) runs turns first and gets its scene only when
    /// the user opens the app, so a scene after a turn suppresses startup metrics.
    public func sceneConnected() {
        guard marks[.scene] == nil else { return }
        marks[.scene] = CACurrentMediaTime()
        if firstTurn { backgroundLaunch() }
    }
    /// The main thread has run a turn since `didFinishLaunching`.
    private var firstTurn = false

    /// A background launch (a push, a background task) has no startup metrics.
    private func backgroundLaunch() {
        guard suppressed == nil else { return }
        suppressed = "background launch"
        stopWatching()
        loadServices(.afterStartup)
    }

    // MARK: Session hooks

    /// The first session to boot after `didFinishLaunching` is the launch session.
    func bootEntered(_ session: ExactSession) {
        guard marks[.didFinishLaunching] != nil, launchSession == nil, marks[.boot] == nil else { return }
        launchSession = session
        marks[.boot] = CACurrentMediaTime()
    }

    /// The launch session's first tree is applied. Core Animation draws and
    /// commits it next, which `drawn` records.
    func treeApplied(_ session: ExactSession, path: String) {
        guard session === launchSession, marks[.commit] == nil, bootPath == nil else { return }
        bootPath = path
        commitPending = true
    }

    func activated(_ session: ExactSession, ok: Bool) {
        guard session === launchSession, activation == "pending" else { return }
        activation = ok ? "ready" : "failed"
        if ok { marks[.activated] = CACurrentMediaTime() } else { finish("activation_failed") }
        scheduleEvaluate()
    }

    /// What activation spent, seconds: the app's Swift module load, each
    /// `dataReady` call (the last one runs the data module's start), how
    /// long and how often it said pending, and applying its first batch.
    private var data: (module: Double, waited: Double, polls: Int, ready: Double, apply: Double, first: Double?) = (0, 0, 0, 0, 0, nil)

    func dataStep(_ session: ExactSession, appModule: Double, ready: Double, pending: Bool) {
        guard session === launchSession, ttiOutcome == nil else { return }
        let now = CACurrentMediaTime()
        if data.first == nil { data.first = now - appModule - ready }
        data.module += appModule
        if pending {
            data.polls += 1
        } else {
            data.ready = ready
            data.waited = now - ready - appModule - (data.first ?? now)
        }
    }

    func dataApplied(_ session: ExactSession, _ seconds: Double) {
        guard session === launchSession, ttiOutcome == nil else { return }
        data.apply = seconds
    }

    /// The data module is still starting (activation pending): sample what
    /// is outstanding, so its span starts when it does, not at the next apply.
    func waitingForData(_ session: ExactSession) {
        guard session === launchSession, ttiOutcome == nil else { return }
        scheduleEvaluate()
    }

    /// Re-reads outstanding work after this run-loop turn and its commit finish.
    func applied(_ session: ExactSession, changed: Bool, what: () -> String = { "" }) {
        guard session === launchSession, ttiOutcome == nil else { return }
        // Nothing outstanding, but the screen still changing: TTI waits for
        // a frame with no change, so this is what holds it then (a fresh
        // answer replacing a kept one, a fade). Its span: first to last.
        if changed, lastOutstanding.isEmpty, marks[.present] != nil {
            let now = CACurrentMediaTime(), item = "screen:changing"
            if spans[item] == nil { spanOrder.append(item) }
            spans[item] = (spans[item]?.from ?? now, now)
            if changes.count < 12, let p = marks[.process] {
                changes.append("\(String(format: "%.0f", (now - p) * 1000)) \(what())")
            }
        }
        if changed { contentDirty = true; candidate = nil }
        scheduleEvaluate()
    }

    // MARK: Commit and vsync

    /// The first tree's layers draw inside the Core Animation commit that
    /// carries them, so this marks the commit. A run-loop observer would miss
    /// commits that macOS makes from HIToolbox's own run-loop mode.
    func drawn(_ session: ExactSession) {
        guard session === launchSession, commitPending else { return }
        commitPending = false
        marks[.commit] = CACurrentMediaTime()
        // The update this first tree is of: startup's metrics are its, whatever a live activation does later.
        launchUpdate = Self.runningUpdate.map { String(cString: $0) } ?? ""
        resolvePresent()
        // Late, the link is off: restart it, and its first tick finds the frame.
        if marks[.present] == nil, link == nil, suppressed == nil { link = mainDisplayLink(self, #selector(tick(_:))) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let v = Vsync(link)
        vsync = v
        if !late { frames.add(at: v.at, target: v.interval) }
        if let c = clearedAt {
            clearedAt = nil
            candidate = v.next(after: c)
        }
        resolvePresent()
        confirmCandidate()
        // Host work (a canvas, a picture) can end with no batch after it: re-check each frame.
        if lastOutstanding.contains(where: { $0.hasPrefix("host:") }) { scheduleEvaluate() }
    }

    /// Marks `present` as the first vsync after the commit, on the last sample's
    /// grid. A late display-link callback still carries its own vsync time, so
    /// a busy main thread does not move the mark.
    private func resolvePresent(estimate: Bool = false) {
        guard let commit = marks[.commit], marks[.present] == nil else { return }
        let present: Double
        if let next = vsync?.next(after: commit) {
            present = next
        } else if estimate {
            // No display-link sample (a busy main thread from launch until now): the
            // commit plus one refresh, the latest the next vsync can be.
            present = commit + 1 / Double(max(1, maximumFramesPerSecond(launchSession)))
            presentEstimated = true
        } else {
            return
        }
        marks[.present] = present
        loadServices(.afterFirstPixel)
        scheduleEvaluate()
        // The report goes with TTR (and launch time, now that the first tree's update is known) once its
        // vsync is past (it can be the next one): also when startup ended before then, as TTI can be decided
        // before that vsync, and the report then left the frame out; one after an interruption is not in it.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, present - CACurrentMediaTime())) { [weak self] in self?.journalReport() }
    }

    // MARK: Time to interactive

    private func scheduleEvaluate() {
        guard !evaluateScheduled, ttiOutcome == nil, suppressed == nil, !ExactEnv.agentMode else { return }
        evaluateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.evaluateScheduled = false
            self?.evaluate()
        }
    }

    /// The launch session's outstanding work, from the runner and the host.
    /// Empty when the screen can be used.
    private func outstandingNow() -> [String]? {
        guard let session = launchSession, let ledger = Self.ledger(session) else { return nil }
        if ledger.poisoned { finish("logic_failed"); return nil }
        failedResources = ledger.failed
        return ledger.items + (activation != "ready" ? ["activation"] : [])
    }

    /// A session's outstanding work from the runner and the host, as
    /// `kind:name` items, plus failed resources and whether the runner is poisoned.
    static func ledger(_ session: ExactSession) -> (items: [String], failed: [String], poisoned: Bool)? {
        guard let data = session.agent("{\"op\":\"outstanding\"}").data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String] = []
        for key in ["requests", "streams", "awaiting"] {
            out += (o[key] as? [String] ?? []).map { "\(key):\($0)" }
        }
        out += session.hostOutstanding.map { "host:\($0)" }
        return (out, o["failed"] as? [String] ?? [], o["poisoned"] as? Bool == true)
    }

    /// Runs the turn after an apply or activation. With nothing outstanding,
    /// the interactive mark is the next vsync if the screen changed, else now.
    /// It is never earlier than the first render.
    private func evaluate() {
        guard ttiOutcome == nil, suppressed == nil, let outstanding = outstandingNow() else { return }
        if outstanding != lastOutstanding || trace.isEmpty, trace.count < 32, let p = marks[.process] {
            trace.append("\(String(format: "%.1f", (CACurrentMediaTime() - p) * 1000)) [\(outstanding.joined(separator: ", "))]")
        }
        let seen = CACurrentMediaTime()
        for item in outstanding where spans[item]?.to != nil || spans[item] == nil {
            if spans[item] == nil { spanOrder.append(item) }
            spans[item] = (spans[item]?.from ?? seen, nil)
        }
        for item in lastOutstanding where !outstanding.contains(item) {
            spans[item]?.to = seen
            // Host work that ended drew something (an image, a canvas) with no batch after it.
            if item.hasPrefix("host:") { contentDirty = true; candidate = nil }
        }
        lastOutstanding = outstanding
        // Late, the link is off; host work can end with no batch after it, so it re-reads each frame.
        if late, link == nil, outstanding.contains(where: { $0.hasPrefix("host:") }) { link = mainDisplayLink(self, #selector(tick(_:))) }
        guard outstanding.isEmpty, marks[.present] != nil else { candidate = nil; return }
        let now = CACurrentMediaTime()
        if contentDirty {
            // Late, the link is off: restart it, and its first tick picks the vsync.
            if link == nil {
                link = mainDisplayLink(self, #selector(tick(_:)))
                clearedAt = now
                return
            }
            candidate = vsync?.next(after: now)
        } else {
            interactive(at: now)
        }
    }

    /// Confirms the candidate vsync if no work became outstanding before it.
    private func confirmCandidate() {
        guard let target = candidate, let v = vsync, v.at >= target, ttiOutcome == nil else { return }
        candidate = nil
        guard let outstanding = outstandingNow(), outstanding.isEmpty else { scheduleEvaluate(); return }
        contentDirty = false
        interactive(at: target)
    }

    private func interactive(at t: Double) {
        marks[.interactive] = max(t, marks[.present] ?? t)
        if let s = launchSession { NavigationMarks.shared.interactive(for: s) }
        finish(!failedResources.isEmpty ? "failed" : "settled")
    }

    private func finish(_ outcome: String) {
        guard ttiOutcome == nil else { return }
        ttiOutcome = outcome
        stopWatching()
        // A frame drawn before an interruption or a failure shows at the vsync after its commit.
        resolvePresent(estimate: true)
        journalReport()
        if ExactEnv.environment["EXACT_OBSERVE_LOG"] == "1", launchSession != nil || interruptedAt != nil { fputs("observe: startup \(smokeLine())\n", stderr) }
        loadServices(.afterStartup)
    }

    /// Journals the startup report with the metrics measured so far, at TTR and when startup
    /// ends, as Observe records each metric at its own mark: the services store each once.
    private func journalReport() {
        #if os(iOS)
        // Only once the scene connected in time is this a foreground launch, which has metrics.
        guard marks[.scene] != nil else { return }
        #endif
        guard !metricMarks().isEmpty else { return }
        ExactJournal.shared.record("startup", report())
    }

    func requestService(module: String, when: ExactServiceLoad, config: [String: Any], handoff: @escaping () -> Data) {
        services.append((module, when, config, handoff))
        if when == .afterFirstPixel, marks[.present] != nil || suppressed != nil { loadServices(.afterFirstPixel) }
        if when == .afterStartup, ttiOutcome != nil || late || suppressed != nil { loadServices(.afterStartup) }
    }

    /// Loads due services in a later turn, never inside the work that triggered them.
    private func loadServices(_ moment: ExactServiceLoad) {
        let due = services.filter { ($0.when == moment || moment == .afterStartup) && !scheduled.contains($0.module) }
        for s in due {
            scheduled.insert(s.module)
            DispatchQueue.main.async { [weak self] in self?.load(s) }
        }
    }

    /// Loads every requested service now, on this thread: at termination no later turn comes.
    private func loadServicesNow() {
        for s in services { load(s) }
    }

    private func load(_ s: (module: String, when: ExactServiceLoad, config: [String: Any], handoff: () -> Data)) {
        guard loaded.insert(s.module).inserted else { return }
        let config = (try? JSONSerialization.data(withJSONObject: s.config)) ?? Data("{}".utf8)
        guard let service = ExactService.load(module: s.module, config: config, handoff: s.handoff()) else { return }
        ExactJournal.shared.attach(service)
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
            // The interrupted startup report goes first, so a service's send on background carries it.
            if let self, ttiOutcome == nil, suppressed == nil {
                interruptedAt = CACurrentMediaTime()
                finish("interrupted")
            }
            ExactJournal.shared.record("background")
            NavigationMarks.shared.background()
            ExactJournal.shared.background()
        }
        #if os(macOS)
        let shown = NSApplication.didUnhideNotification
        #else
        let shown = UIApplication.willEnterForegroundNotification
        #endif
        NotificationCenter.default.addObserver(forName: shown, object: nil, queue: .main) { _ in NavigationMarks.shared.foreground() }
        #if os(macOS)
        let terminate = NSApplication.willTerminateNotification
        #else
        let terminate = UIApplication.willTerminateNotification
        #endif
        NotificationCenter.default.addObserver(forName: terminate, object: nil, queue: .main) { [weak self] _ in
            // Quitting before TTI reports what was measured, as an interruption does, and the
            // services store it before the process ends; they send it at the next launch.
            guard let self else { return }
            if ttiOutcome == nil, suppressed == nil {
                interruptedAt = CACurrentMediaTime()
                finish("terminated")
            }
            loadServicesNow()
            ExactJournal.shared.flush()
        }
    }

    // MARK: Cold or warm, by Observe's heuristic (`AppStartupMonitoring.getAppLaunchType`)

    private static let defaults = UserDefaults(suiteName: "dev.exact.observe")
    private func classify() -> String {
        let boot = Self.bootTime()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        // Per app: on the Mac, apps outside a sandbox share this suite.
        let key = "launch.\(Bundle.main.bundleIdentifier ?? "app")"
        let previous = Self.defaults?.dictionary(forKey: key)
        Self.defaults?.set(["boot": boot, "build": build], forKey: key)
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

    // MARK: Report for `state.observe` and the smoke test

    /// Observe's metric names with values in seconds, plus Exact's marks in ms from process start.
    public func report(for session: ExactSession? = nil) -> [String: Any] {
        var out: [String: Any] = ["activation": activation]
        if let launchType { out["launchType"] = launchType }
        // The update startup's marks are of: the first tree's, else the one running now; none
        // before the first generation started, when it is not known yet.
        if let update = launchUpdate ?? Self.runningUpdate.map({ String(cString: $0) }) { out["update"] = update }
        if let suppressed { out["suppressed"] = suppressed }
        if let bootPath { out["bootPath"] = bootPath }
        if let ttiOutcome { out["tti"] = ttiOutcome }
        if !lastOutstanding.isEmpty { out["outstanding"] = lastOutstanding }
        if !failedResources.isEmpty { out["failed"] = failedResources }
        if !trace.isEmpty { out["trace"] = trace }
        if !changes.isEmpty { out["changes"] = changes }
        // Boot's two parts (ms): the runner's boot with the first layout, and
        // applying its batch to the views.
        if let s = launchSession, s.rustMs > 0 {
            var boot: [String: Any] = ["runner": (s.rustMs * 10).rounded() / 10, "apply": (s.applyMs * 10).rounded() / 10]
            // The apply's largest parts, so a slow first batch says which part.
            let parts = s.applyParts.filter { $0.value >= 0.5 }.sorted { $0.value > $1.value }
            if !parts.isEmpty { boot["parts"] = parts.filter { $0.key != "runner" }.prefix(16).map { $0.key.hasPrefix("#") ? "\($0.key.dropFirst()) ×\(Int($0.value))" : "\($0.key) \(Int($0.value.rounded()))" }.joined(separator: ", ") }
            out["boot"] = boot
        }
        if data.first != nil {
            let ms = { (s: Double) in (s * 1000 * 10).rounded() / 10 }
            // From the first commit to the first node's draw receipt, which
            // starts activation (the render server's first draw).
            let receipt = marks[.commit].flatMap { c in data.first.map { ms(max(0, $0 - c)) } }
            out["data"] = ["appModule": ms(data.module), "waited": ms(max(0, data.waited)), "polls": data.polls,
                           "ready": ms(data.ready), "apply": ms(data.apply), "receipt": receipt as Any]
        }
        if let p = marks[.process], !spans.isEmpty {
            let ms = { (t: Double) in ((t - p) * 1000 * 10).rounded() / 10 }
            out["items"] = spanOrder.compactMap { item -> [String: Any]? in
                guard let span = spans[item] else { return nil }
                var o: [String: Any] = ["item": item, "from": ms(span.from)]
                if let to = span.to { o["to"] = ms(to) }
                return o
            }
        }
        if !NavigationMarks.shared.recent.isEmpty { out["navigation"] = NavigationMarks.shared.recent }
        if let session { out["launchSession"] = session === launchSession }
        if facts.traced != 0 { out["debugger"] = true }
        if let p = marks[.process] {
            out["marks"] = Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, (($0.value - p) * 1000 * 10).rounded() / 10) })
        }
        out["metrics"] = metrics()
        out["walls"] = metricWalls()
        out["presentMethod"] = presentEstimated ? "estimated" : "next_vsync"
        if let i = interruptedAt {
            out["interrupted"] = true
            if let p = marks[.process] { out["interruptedAt"] = ((i - p) * 1000 * 10).rounded() / 10 }
        }
        if marks[.interactive] != nil {
            // The screen that became interactive, as Observe names the screen whose marker fired.
            if let route = launchSession.flatMap({ NavigationMarks.shared.current(for: $0) }) { out["route"] = route }
            // Its TTI is the launch screen's too (`navigation` `tti`, `isAppLaunch`) when that screen stayed on top.
            if let s = launchSession, NavigationMarks.shared.onLaunchScreen(s) { out["launchScreen"] = true }
            // The frames from didFinishLaunching to TTI, unless its window was not timed throughout.
            if !late, !frames.params.isEmpty { out["frames"] = frames.params }
        }
        return out
    }

    func metrics() -> [String: Double] {
        metricMarks().mapValues { $0.value }
    }

    /// The update the launch's first tree is of (`""` for the embedded app), which its startup metrics carry.
    private var launchUpdate: String?

    /// Also a frame whose vsync is not past yet (the next one, predicted from the last sample) is not in a report.
    private func metricMarks() -> [String: (value: Double, end: Double)] {
        suppressed == nil ? Self.metricMarks(marks, launchType: launchType, interruptedAt: min(interruptedAt ?? .infinity, CACurrentMediaTime())) : [:]
    }

    /// Each metric's value in seconds and the mark that ends it, by Observe's
    /// definitions. A frame presented after an interruption was not seen during the launch.
    static func metricMarks(_ marks: [Mark: Double], launchType: String?, interruptedAt: Double?) -> [String: (value: Double, end: Double)] {
        guard let dfl = marks[.didFinishLaunching] else { return [:] }
        var m: [String: (value: Double, end: Double)] = [:]
        if let p = marks[.process], let l = marks[.constructor], let md = marks[.delegateInit], let type = launchType {
            m["\(type)LaunchTime"] = ((l - p) + (dfl - md), dfl)
        }
        if let f0 = marks[.present], f0 <= interruptedAt ?? .infinity { m["timeToFirstRender"] = (f0 - dfl, f0) }
        if let i = marks[.interactive] { m["timeToInteractive"] = (i - dfl, i) }
        return m
    }

    /// Each metric's time, seconds since 1970: when its end mark happened, as
    /// Observe stamps a metric when it records it.
    func metricWalls() -> [String: Double] {
        let offset = Date().timeIntervalSince1970 - CACurrentMediaTime()
        return metricMarks().mapValues { $0.end + offset }
    }
}

/// Frame pacing from the display link, with Observe's thresholds: a frame is
/// slow at 17 ms or more and frozen at 700 ms or more, from one vsync to the
/// next; delay is the time past each frame's target interval.
struct FrameStats {
    private var previous: Double?
    /// Frames timed, from one vsync to the next.
    private(set) var timed = 0
    private(set) var slow = 0
    private(set) var frozen = 0
    private(set) var delay = 0.0

    mutating func add(at timestamp: Double, target: Double) {
        defer { previous = timestamp }
        guard let previous, target > 0, timestamp > previous else { return }
        let d = timestamp - previous
        timed += 1
        if d >= 0.017 { slow += 1 }
        if d >= 0.7 { frozen += 1 }
        delay += max(0, d - target)
    }

    /// Observe's TTI parameters, or none when no frame was timed.
    var params: [String: Any] {
        guard timed > 0 else { return [:] }
        return ["expo.frameRate.slowFrames": slow, "expo.frameRate.frozenFrames": frozen, "expo.frameRate.totalDelay": delay]
    }
}

extension ExactLaunch {
    /// One line for `EXACT_SMOKE`: the metrics in ms and the marks from process start.
    public func smokeLine() -> String {
        let metrics = metrics().sorted { $0.key < $1.key }
            .map { "\($0.key) \(String(format: "%.1f", $0.value * 1000)) ms" }.joined(separator: "; ")
        let marks = self.marks[.process].map { p in
            Mark.allCases.compactMap { m in self.marks[m].map { "\(m.rawValue) \(String(format: "%.1f", ($0 - p) * 1000))" } }.joined(separator: " · ")
        } ?? ""
        let interrupted = interruptedAt.flatMap { i in self.marks[.process].map { " (at \(String(format: "%.1f", (i - $0) * 1000)))" } } ?? ""
        return "\(launchType ?? "?") \(bootPath ?? "?") tti \(ttiOutcome ?? "pending")\(interrupted)\(lastOutstanding.isEmpty ? "" : " outstanding \(lastOutstanding)") \(suppressed.map { "suppressed: \($0) " } ?? "")activation \(activation); \(metrics.isEmpty ? "no metrics" : metrics); marks \(marks); ledger \(trace.joined(separator: " → "))"
    }
}

/// The highest refresh rate of the screen `session` shows on.
func maximumFramesPerSecond(_ session: ExactSession?) -> Int {
    #if os(macOS)
    (session?.presenter.viewport.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
    #else
    session?.presenter.viewport.window?.screen.maximumFramesPerSecond ?? 60
    #endif
}

/// A display link on the main run loop's common modes, so it fires during tracking.
func mainDisplayLink(_ target: Any, _ selector: Selector) -> CADisplayLink? {
    #if os(macOS)
    let link = NSScreen.main?.displayLink(target: target, selector: selector)
    #else
    let link: CADisplayLink? = CADisplayLink(target: target, selector: selector)
    #endif
    link?.add(to: .main, forMode: .common)
    return link
}

/// Runs each waiter at the first vsync after the turn it asked in: Core Animation commits that
/// turn's changes at its end, so that vsync is the first frame that can show them. One display
/// link serves every waiter and runs only while one waits.
final class NextFrame: NSObject {
    static let shared = NextFrame()
    private var waiting: [(ended: Double, run: (Double) -> Void)] = []
    private var link: CADisplayLink?

    /// Calls `run` with that vsync's time, once it has passed.
    func after(_ run: @escaping (Double) -> Void) {
        DispatchQueue.main.async { [self] in
            waiting.append((CACurrentMediaTime(), run))
            if link == nil { link = mainDisplayLink(self, #selector(tick(_:))) }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let v = Vsync(link)
        var due: [(Double, (Double) -> Void)] = []
        waiting.removeAll { w in
            guard let g = v.next(after: w.ended), v.at + 1e-6 >= g else { return false }
            due.append((g, w.run))
            return true
        }
        if waiting.isEmpty {
            self.link?.invalidate()
            self.link = nil
        }
        for (g, run) in due { run(g) }
    }
}

/// A display-link sample: its vsync time and observed interval, in seconds.
struct Vsync {
    let at: Double
    let interval: Double

    init(_ link: CADisplayLink) {
        // On ProMotion, `duration` can stay nominal while the real cadence changes.
        let interval = link.targetTimestamp - link.timestamp
        at = link.timestamp
        self.interval = interval > 0 ? interval : link.duration
    }

    /// The first vsync strictly after `t`, on this sample's grid.
    func next(after t: Double) -> Double? {
        guard interval > 0 else { return nil }
        let g = at + ((t - at) / interval).rounded(.up) * interval
        return g <= t ? g + interval : g
    }
}
