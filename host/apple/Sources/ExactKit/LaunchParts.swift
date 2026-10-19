// Module launch parts and the journal of lifecycle events they subscribe to.
// A launch part is linked into the executable, so nothing is dlopened during
// launch. It runs once at the app delegate's init and receives journal events
// in their own main-thread turn, never inside a draw, commit or apply. Its
// heavier service, `lib<module>_service.dylib`, loads later when it asks.
import Foundation
import QuartzCore

/// `launch` runs on the main thread inside `UIApplicationMain`, before
/// `didFinishLaunching`. It must do no I/O and no UI, and has no runner.
/// All launch parts together have a 500 µs budget, which is logged when exceeded.
public protocol ExactLaunchPart {
    static var module: String { get }
    static func launch(_ context: ExactLaunchContext)
}

/// `at` is seconds on `CACurrentMediaTime`; `wall` is seconds since 1970.
public struct ExactJournalEvent {
    public let kind: String
    public let at: Double
    public let wall: Double
    public let fields: [String: Any]

    /// The JSON object a service receives.
    public var json: String {
        var o = fields
        o["kind"] = kind
        o["at"] = at
        o["wall"] = wall
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// The process's append-only event journal. Past `capacity` it drops and
/// counts its oldest events.
public final class ExactJournal {
    public static let shared = ExactJournal()
    public static let capacity = 4096
    private(set) var events: [ExactJournalEvent] = []
    private(set) var dropped = 0
    private var subscribers: [(fn: (ExactJournalEvent) -> Void, next: Int)] = []
    private var delivering = false
    private var services: [ExactService] = []

    /// Seconds all subscribers may spend in one turn; the rest is delivered next turn.
    static let turnBudget = 0.001

    func record(_ kind: String, _ fields: [String: Any] = [:], at: Double = CACurrentMediaTime()) {
        let wall = Date().timeIntervalSince1970 - (CACurrentMediaTime() - at)
        events.append(ExactJournalEvent(kind: kind, at: at, wall: wall, fields: fields))
        if events.count > Self.capacity {
            // Dropping startup marks is safe: ExactLaunch keeps them.
            events.removeFirst()
            dropped += 1
            for i in subscribers.indices { subscribers[i].next = max(0, subscribers[i].next - 1) }
        }
        for s in services { s.event(events[events.count - 1]) }
        scheduleDelivery()
    }

    func subscribe(_ fn: @escaping (ExactJournalEvent) -> Void) {
        subscribers.append((fn, 0))
        scheduleDelivery()
    }

    func attach(_ service: ExactService) {
        services.append(service)
        for e in events { service.event(e) }
    }

    func background() { for s in services { s.background() } }
    /// Waits for each service to finish handling the events it was given.
    func flush() { for s in services { s.flush() } }

    /// The loaded service of `module`, if it is loaded (main thread).
    func service(_ module: String) -> ExactService? { services.first { $0.module == module } }

    private func scheduleDelivery() {
        guard !delivering, !subscribers.isEmpty else { return }
        delivering = true
        DispatchQueue.main.async { [weak self] in self?.deliver() }
    }

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
    /// `prewarmed`, `debugger`, `development` and `agent`. Cold or warm and
    /// whether metrics are suppressed arrive later, in the `launch` journal event.
    public let facts: [String: Any]
    /// An existing directory a signal handler can write a crash record to.
    public let crashDirectory: String
    /// This module's settings from `app.json` `moduleConfig.<module>`.
    public let config: [String: Any]
    /// The app's Info.plist, or a bare build's sidecar: identity, version and build.
    public let app: [String: Any]

    init(module: String, facts: [String: Any]) {
        self.module = module
        self.facts = facts
        app = ExactEnv.appMetadata
        config = (app["ExactModuleConfig"] as? [String: Any])?[module] as? [String: Any] ?? [:]
        crashDirectory = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    }

    /// Delivers every event so far, then each new one, in later main-thread turns.
    public func subscribe(_ fn: @escaping (ExactJournalEvent) -> Void) {
        ExactJournal.shared.subscribe(fn)
    }

    /// Loads `lib<module>_service.dylib` at `when` and starts it with `config` and
    /// `handoff`, the bytes the launch part kept for its service.
    public func requestService(_ when: ExactServiceLoad, config: [String: Any], handoff: @escaping () -> Data) {
        ExactLaunch.shared.requestService(module: module, when: when, config: config, handoff: handoff)
    }
}

/// The C entry points of a loaded `lib<module>_service.dylib`.
final class ExactService {
    typealias Start = @convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafePointer<UInt8>?, UInt32) -> UnsafeMutableRawPointer?
    typealias Event = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt32) -> Void
    typealias Background = @convention(c) (UnsafeMutableRawPointer?) -> Void
    /// Optional: `exact_service_query(state, json, length, context, reply)`;
    /// the service calls `reply(context, json, length)` once, on any thread.
    typealias Reply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt32) -> Void
    typealias Query = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?, Reply) -> Void
    /// Optional: `exact_service_flush(state)` returns once the events given so far are handled.
    typealias Flush = @convention(c) (UnsafeMutableRawPointer?) -> Void
    let module: String
    private let state: UnsafeMutableRawPointer?
    private let eventFn: Event
    private let backgroundFn: Background
    private let queryFn: Query?
    private let flushFn: Flush?

    /// Loads from beside the executable on macOS, or from Frameworks on iOS
    /// (wrapped as a framework in an archive: `serviceFramework` in launch-parts.mjs).
    static func load(module: String, config: Data, handoff: Data) -> ExactService? {
        let name = "lib\(module)_service.dylib"
        #if os(macOS)
        let path = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(name).path
        #else
        let path = embeddedModule(framework: serviceFramework(module), dylib: name)
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
        return ExactService(module: module, state: state, event: unsafeBitCast(e, to: Event.self), background: unsafeBitCast(b, to: Background.self),
                            query: dlsym(h, "exact_service_query").map { unsafeBitCast($0, to: Query.self) },
                            flush: dlsym(h, "exact_service_flush").map { unsafeBitCast($0, to: Flush.self) })
    }

    private init(module: String, state: UnsafeMutableRawPointer?, event: Event, background: Background, query: Query?, flush: Flush?) {
        self.module = module
        self.state = state
        eventFn = event
        backgroundFn = background
        queryFn = query
        flushFn = flush
    }

    func flush() { flushFn?(state) }

    /// Asks the service; `reply` gets its JSON object, or nil when it answers
    /// no queries or its answer is not one.
    func query(_ request: [String: Any], reply: @escaping ([String: Any]?) -> Void) {
        guard let queryFn, let bytes = try? JSONSerialization.data(withJSONObject: request) else { return reply(nil) }
        let box = Unmanaged.passRetained(ReplyBox(reply)).toOpaque()
        bytes.withUnsafeBytes { b in
            queryFn(state, b.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count), box) { context, json, length in
                guard let context else { return }
                let box = Unmanaged<ReplyBox>.fromOpaque(context).takeRetainedValue()
                let data = json.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                box.reply((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            }
        }
    }

    private final class ReplyBox {
        let reply: ([String: Any]?) -> Void
        init(_ reply: @escaping ([String: Any]?) -> Void) { self.reply = reply }
    }

    func event(_ e: ExactJournalEvent) {
        let bytes = Array(e.json.utf8)
        bytes.withUnsafeBufferPointer { eventFn(state, $0.baseAddress, UInt32($0.count)) }
    }

    func background() { backgroundFn(state) }
}

/// A module's service, asked by the app's own module (LLP 1067.000 keeps
/// one module per app; a service such as Observe's is the framework's).
/// `reply` runs once, on any thread, with the service's JSON answer, or nil
/// when that service is not loaded (yet) or answers no queries.
public enum ExactServices {
    public static func query(_ module: String, _ request: [String: Any], reply: @escaping ([String: Any]?) -> Void) {
        DispatchQueue.main.async {
            guard let service = ExactJournal.shared.service(module) else { return reply(nil) }
            service.query(request, reply: reply)
        }
    }
}

extension ExactLaunch {
    /// Runs the launch parts in `app.json` order and journals each one's time.
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

    /// An input's event timestamp, just before its dispatch: a navigation its
    /// dispatch commits is timed from it. `inputEnded` follows the dispatch.
    public func input(at timestamp: TimeInterval) { NavigationMarks.shared.input(at: timestamp) }

    /// The update entry the app runs (Exact's envelope digest), nil for the embedded app.
    /// The updating composition sets it as each generation starts; a crash handler may read
    /// it at any time, so a replaced string is never freed.
    nonisolated(unsafe) public static var runningUpdate: UnsafeMutablePointer<CChar>?
    public func inputEnded() { NavigationMarks.shared.inputEnded() }
}

/// Framework events journaled for a module such as Observe. The module's
/// service decides what to send.
public enum ExactEvents {
    /// A framework event for modules, such as an update's download. `uptime`
    /// (`ProcessInfo.systemUptime`) is when it happened, if not now.
    public static func journal(_ kind: String, _ fields: [String: Any], uptime: Double? = nil) {
        ExactJournal.shared.record(kind, fields, at: CACurrentMediaTime() - (uptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0))
    }
}

/// A launch service's framework name in an archive (`serviceFramework` in launch-parts.mjs): `observe` is `ExactObserveService`.
func serviceFramework(_ module: String) -> String {
    let words = module.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    return "Exact" + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Service"
}
