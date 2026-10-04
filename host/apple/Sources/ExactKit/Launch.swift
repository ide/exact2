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
        case process, constructor, delegateInit, didFinishLaunching, scene, boot, commit, present, activated
    }

    let facts = exact_launch_constructor_facts()
    /// Monotonic seconds per mark, for the launch session only.
    private(set) var marks: [Mark: Double] = [:]
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
        guard suppressed == nil, !ExactEnv.agentMode else { return }
        watchVsync()
        watchInterruption()
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
        if ok { marks[.activated] = CACurrentMediaTime() }
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
    }

    /// F0: the first vsync strictly after the commit, on the grid of the
    /// nearest sample. A sample delivered late still names its own vsync, so a
    /// busy main turn after the commit does not move F0.
    private func resolvePresent() {
        guard let c0 = marks[.commit], marks[.present] == nil, let v = vsync, v.interval > 0 else { return }
        var g = v.at + ((c0 - v.at) / v.interval).rounded(.up) * v.interval
        if g <= c0 { g += v.interval }
        marks[.present] = g
        stopWatching()
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
            guard let self, marks[.present] == nil, suppressed == nil else { return }
            suppressed = "interrupted"
            stopWatching()
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
        return "\(r["launchType"] ?? "?") \(r["bootPath"] ?? "?") \(r["suppressed"].map { "suppressed: \($0) " } ?? "")activation \(r["activation"] ?? "?"); \(metrics.isEmpty ? "no metrics" : metrics); marks \(marks)"
    }
}
