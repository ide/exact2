// Module launch parts (Exact Observe design §4.3, §4.6): the small, static part
// of a module that runs during initialization, and the lifecycle journal it
// reads. A launch part is linked into the app's executable (no dlopen on the
// boot path), runs once at the app delegate's init, and from then on hears
// every journal event — the history first, then live ones — at the end of a
// main-thread turn, never inside a draw, a commit or an apply. Its heavier
// half (storage, network) is a separate artifact, `lib<module>_service.dylib`,
// loaded later, on the policy the launch part asks for.
//
// Budgets are validation gates: all launch parts together 500 µs at launch,
// each delivery turn 1 ms across every subscriber. An overrun is journaled
// (`launchBudget`) and printed in development; it never aborts.
import Foundation
import QuartzCore

/// A module's launch part. `launch` runs on the main thread, inside
/// `UIApplicationMain`, before `didFinishLaunching`: no I/O, no UI, no runner.
public protocol ExactLaunchPart {
    static var module: String { get }
    static func launch(_ context: ExactLaunchContext)
}

/// One journal event: what happened, when (monotonic seconds, the
/// `CACurrentMediaTime` clock, and wall seconds since 1970), and its fields.
public struct ExactJournalEvent {
    public let kind: String
    public let at: Double
    public let wall: Double
    public let fields: [String: Any]

    /// The event as one JSON object (what a service receives).
    public var json: String {
        var o = fields
        o["kind"] = kind
        o["at"] = at
        o["wall"] = wall
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// The process's journal: append-only, bounded. The startup events are few
/// and always kept; the rest is a ring that drops its oldest and counts it.
public final class ExactJournal {
    public static let shared = ExactJournal()
    public static let capacity = 4096
    private(set) var events: [ExactJournalEvent] = []
    private(set) var dropped = 0
    private var subscribers: [(name: String, fn: (ExactJournalEvent) -> Void, next: Int)] = []
    private var delivering = false
    private var services: [(name: String, handle: ExactService)] = []

    /// Every subscriber's events this turn, together, may take this long.
    static let turnBudget = 0.001

    func record(_ kind: String, _ fields: [String: Any] = [:], at: Double = CACurrentMediaTime()) {
        let wall = Date().timeIntervalSince1970 - (CACurrentMediaTime() - at)
        events.append(ExactJournalEvent(kind: kind, at: at, wall: wall, fields: fields))
        if events.count > Self.capacity {
            // Startup marks are re-derivable from ExactLaunch; keep the ring bounded.
            events.removeFirst()
            dropped += 1
            for i in subscribers.indices { subscribers[i].next = max(0, subscribers[i].next - 1) }
        }
        for s in services { s.handle.event(events[events.count - 1]) }
        scheduleDelivery()
    }

    func subscribe(_ name: String, _ fn: @escaping (ExactJournalEvent) -> Void) {
        subscribers.append((name, fn, 0))
        scheduleDelivery()
    }

    func attach(_ name: String, _ service: ExactService) {
        services.append((name, service))
        for e in events { service.event(e) }
    }

    func background() { for s in services { s.handle.background() } }

    private func scheduleDelivery() {
        guard !delivering, !subscribers.isEmpty else { return }
        delivering = true
        DispatchQueue.main.async { [weak self] in self?.deliver() }
    }

    /// One turn's delivery, within the budget; the rest waits for the next turn.
    private func deliver() {
        delivering = false
        let start = CACurrentMediaTime()
        var more = false
        outer: for i in subscribers.indices {
            while subscribers[i].next < events.count {
                if CACurrentMediaTime() - start > Self.turnBudget { more = true; break outer }
                let e = events[subscribers[i].next]
                subscribers[i].next += 1
                subscribers[i].fn(e)
            }
        }
        if more { scheduleDelivery() }
    }
}

/// When a module's service artifact loads.
public enum ExactServiceLoad: String {
    /// After the launch session is interactive, or startup ended without it.
    case afterStartup
    /// After the first presented frame.
    case afterFirstPixel
}

/// What a launch part sees.
public final class ExactLaunchContext {
    public let module: String
    /// Provisional facts at launch: `prewarmed` and `debugger` are final;
    /// eligibility and cold/warm come with the `didFinishLaunching` event.
    public let facts: [String: Any]
    /// A directory that exists at launch, for a crash record written from a
    /// signal handler (no directory is created on the boot path).
    public let crashDirectory: String
    /// This module's settings from `app.json` `moduleConfig.<module>`.
    public let config: [String: Any]
    /// The app's baked metadata (its Info.plist, or a bare build's sidecar):
    /// identity, version and build, for a module to describe the app with.
    public let app: [String: Any]

    init(module: String, facts: [String: Any]) {
        self.module = module
        self.facts = facts
        app = ExactEnv.appMetadata
        config = (app["ExactModuleConfig"] as? [String: Any])?[module] as? [String: Any] ?? [:]
        crashDirectory = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    }

    /// The journal: every event so far, then each new one, at the end of a turn.
    public func subscribe(_ fn: @escaping (ExactJournalEvent) -> Void) {
        ExactJournal.shared.subscribe(module, fn)
    }

    /// Load `lib<module>_service.dylib` at `when`, starting it with `config`
    /// and `handoff` (the launch part's bytes, e.g. its ring).
    public func requestService(_ when: ExactServiceLoad, config: [String: Any], handoff: @escaping () -> Data) {
        ExactLaunch.shared.requestService(module: module, when: when, config: config, handoff: handoff)
    }
}

/// A fixed RAM ring of length-prefixed records: what a launch part keeps
/// before its service exists. Drops its oldest when full, and counts them.
public final class ExactRing {
    public let capacity: Int
    private var records: [Data] = []
    private var bytes = 0
    public private(set) var dropped = 0

    public init(capacity: Int) { self.capacity = capacity }

    public func append(_ record: Data) {
        records.append(record)
        bytes += record.count
        while bytes > capacity, !records.isEmpty {
            bytes -= records.removeFirst().count
            dropped += 1
        }
    }

    /// Length-prefixed (UInt32, little-endian) records, oldest first.
    public func encoded() -> Data {
        var out = Data()
        for r in records {
            var n = UInt32(r.count).littleEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(r)
        }
        return out
    }
}

/// A loaded service artifact: the C entry points of `lib<module>_service.dylib`.
final class ExactService {
    typealias Start = @convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafePointer<UInt8>?, UInt32) -> UnsafeMutableRawPointer?
    typealias Event = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt32) -> Void
    typealias Background = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private let state: UnsafeMutableRawPointer?
    private let eventFn: Event
    private let backgroundFn: Background

    /// The artifact beside the executable (macOS) or in Frameworks (iOS).
    static func load(module: String, config: Data, handoff: Data) -> ExactService? {
        let name = "lib\(module)_service.dylib"
        #if os(macOS)
        let path = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(name).path
        #else
        let path = (Bundle.main.privateFrameworksPath ?? Bundle.main.bundlePath) + "/" + name
        #endif
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            fputs("exact: \(name): \(String(cString: dlerror()))\n", stderr)
            return nil
        }
        guard let s = dlsym(h, "exact_service_start"), let e = dlsym(h, "exact_service_event"), let b = dlsym(h, "exact_service_background") else {
            fputs("exact: \(name) lacks the service entry points\n", stderr)
            return nil
        }
        let start = unsafeBitCast(s, to: Start.self)
        let state = config.withUnsafeBytes { c in
            handoff.withUnsafeBytes { r in
                start(c.bindMemory(to: UInt8.self).baseAddress, UInt32(config.count), r.bindMemory(to: UInt8.self).baseAddress, UInt32(handoff.count))
            }
        }
        return ExactService(state: state, event: unsafeBitCast(e, to: Event.self), background: unsafeBitCast(b, to: Background.self))
    }

    private init(state: UnsafeMutableRawPointer?, event: Event, background: Background) {
        self.state = state
        eventFn = event
        backgroundFn = background
    }

    func event(_ e: ExactJournalEvent) {
        let bytes = Array(e.json.utf8)
        bytes.withUnsafeBufferPointer { eventFn(state, $0.baseAddress, UInt32($0.count)) }
    }

    func background() { backgroundFn(state) }
}

extension ExactLaunch {
    /// Run the app's launch parts, in `app.json` order, timing each (§4.6).
    public func runLaunchParts(_ parts: [ExactLaunchPart.Type]) {
        let facts: [String: Any] = ["prewarmed": facts.prewarm != 0, "debugger": facts.traced != 0, "development": !ExactEnv.productionBake, "agent": ExactEnv.agentMode]
        var total = 0.0
        for part in parts {
            let t = CACurrentMediaTime()
            part.launch(ExactLaunchContext(module: part.module, facts: facts))
            let took = CACurrentMediaTime() - t
            total += took
            ExactJournal.shared.record("launchPart", ["module": part.module, "ms": took * 1000])
        }
        if total > Self.launchBudget {
            ExactJournal.shared.record("launchBudget", ["ms": total * 1000])
            fputs("exact: launch parts took \(String(format: "%.2f", total * 1000)) ms, over the \(Self.launchBudget * 1000) ms budget\n", stderr)
        }
    }

    static let launchBudget = 0.0005

    /// The window dispatched an input (touch ended, press, mouse up, key):
    /// its platform timestamp, a navigation's cause (§3.6).
    public func input(at timestamp: TimeInterval) { NavigationMarks.shared.input(at: timestamp) }
}

/// What an app (its native modules, its host adapter) reports for a module
/// such as Observe to send: custom events, errors and the attributes merged
/// into everything. Journal events; the module's service decides what they mean.
public enum ExactEvents {
    /// Contract's `observe`, `observeAttributes` and `observeError` (Exact
    /// Observe design §5.2), journal events stamped now. The compiler sends
    /// a record's fields as name, value pairs.
    static func hostCommand(_ name: String, _ args: [Any]) {
        let pairs = { (from: Int) -> [String: Any] in
            var out: [String: Any] = [:]
            var i = from
            while i + 1 < args.count { if let k = args[i] as? String { out[k] = args[i + 1] }; i += 2 }
            return out
        }
        let text = { (i: Int, or: String) in args.count > i ? args[i] as? String ?? or : or }
        switch name {
        case "observe": log(text(0, ""), attributes: pairs(2), severity: text(1, "info"))
        case "observeAttributes": setGlobalAttributes(pairs(0))
        default: reportError(type: text(1, "ContractError"), message: text(0, ""))
        }
    }

    /// A custom event (Observe's `logEvent`): `severity` is trace, debug,
    /// info (the default), warn, error or fatal.
    public static func log(_ name: String, attributes: [String: Any] = [:], severity: String = "info", body: String? = nil, displayName: String? = nil) {
        var f: [String: Any] = ["name": name, "attributes": attributes, "severity": severity]
        if let body { f["body"] = body }
        if let displayName { f["displayName"] = displayName }
        ExactJournal.shared.record("app.event", f)
    }

    /// Attributes merged into every later metric and event; per-record keys win.
    public static func setGlobalAttributes(_ attributes: [String: Any]) {
        ExactJournal.shared.record("app.attributes", ["attributes": attributes])
    }

    /// A caught error (Observe's `reportError`).
    public static func reportError(type: String, message: String, stack: String? = nil) {
        var f: [String: Any] = ["type": type, "message": message]
        if let stack { f["stack"] = stack }
        ExactJournal.shared.record("app.error", f)
    }
}
