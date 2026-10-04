// Observe's service (Exact Observe design §4.5): the heavy half, a dylib of its
// own that ExactKit loads after startup. It turns journal events into
// Observe's metric and log rows (SQLite), ingests crashes a previous launch
// recorded, and sends them as expo-observe does. Everything runs on one serial
// queue, off the main thread.
import Foundation
#if os(iOS)
import UIKit
#endif

final class ObserveService {
    let queue = DispatchQueue(label: "exact.observe.service")
    let config: [String: Any]
    let session: String
    let store: ObserveStore?
    let clientId: UUID
    let metadata: [String: Any]
    var device: [String: Any] = [:]
    /// The launch route (its first router change) and whether the user had
    /// navigated away before startup ended (then it gets no `tti`).
    var launchRoute: [String: Any]?
    var navigatedBeforeStartup = false
    var globals: [String: Any] = [:]
    var gate: (after: Date?, failures: Int) = (nil, 0)
    var sending = false
    var scheduled = false

    /// New rows go out within `delay` (one timer at a time), besides the
    /// background and terminal-outcome sends.
    func scheduleDispatch(_ delay: Double = 5) {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.scheduled = false
            self?.dispatch()
        }
    }

    init(config: [String: Any], handoff: Data) {
        self.config = config
        session = config["session"] as? String ?? UUID().uuidString
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "expo.eas-client-id") ?? UUID().uuidString
        defaults.set(id, forKey: "expo.eas-client-id")
        clientId = UUID(uuidString: id) ?? UUID()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = ObserveStore(directory: base.appendingPathComponent("exact/\(config["app.CFBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier ?? "app")/observe", isDirectory: true))
        metadata = Self.metadata(config)
        for record in Self.records(handoff) {
            if record["kind"] as? String == "device" { device = record["params"] as? [String: Any] ?? [:] }
        }
        if ProcessInfo.processInfo.environment["EXACT_OBSERVE_LOG"] == "1" { fputs("observe: service started, session \(session)\n", stderr) }
        queue.async { [self] in
            store?.saveSession(session, start: config["sessionStart"] as? Double ?? Date().timeIntervalSince1970, metadata: metadata)
            ingestCrashes()
        }
        queue.async { [weak self] in self?.scheduleDispatch() }
    }

    // MARK: Journal events

    func event(_ json: Data) {
        queue.async { [self] in
            guard let e = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], let kind = e["kind"] as? String else { return }
            let wall = e["wall"] as? Double ?? Date().timeIntervalSince1970
            switch kind {
            case "startup": startup(e, wall: wall)
            case "navigation.launch": launchRoute = e
            case "navigation": navigation(e, wall: wall)
            case "update.download": updateDownload(e, wall: wall)
            case "app.attributes": globals = ObserveRules.attributes(e["attributes"] as? [String: Any] ?? [:]).kept
            case "app.event": log(e, wall: wall, error: false)
            case "app.error": log(e, wall: wall, error: true)
            case "background": dispatch()
            default: return
            }
            if kind != "background" { scheduleDispatch() }
        }
    }

    /// The launch's metrics, Observe's names, from ExactLaunch's report.
    func startup(_ e: [String: Any], wall: Double) {
        launchNavigation(e, wall: wall)
        guard let store, let metrics = e["metrics"] as? [String: Double], !metrics.isEmpty else { return }
        let marks = e["marks"] as? [String: Double] ?? [:]
        let ms = { (a: String, b: String) -> NSDecimalNumber? in
            guard let x = marks[a], let y = marks[b] else { return nil }
            return Self.seconds(x - y)
        }
        var phases: [String: Any] = [:]
        phases["exact.phase.scene"] = ms("scene", "didFinishLaunching")
        phases["exact.phase.boot_wait"] = ms("boot", "scene")
        phases["exact.phase.boot"] = ms("commit", "boot")
        phases["exact.phase.present"] = ms("present", "commit")
        phases["exact.phase.activate"] = ms("activated", "commit")
        phases["exact.since_process_start.ttr"] = marks["present"].map { Self.seconds($0) }
        phases["exact.since_process_start.tti"] = marks["interactive"].map { Self.seconds($0) }
        phases["exact.present.method"] = "next_vsync"
        if let path = e["bootPath"] { phases["exact.boot.path"] = path }
        if e["debugger"] as? Bool == true { phases["exact.launch.debugger"] = true }
        for (name, value) in metrics {
            var params = globals
            for (k, v) in phases { params[k] = v }
            if name == "timeToInteractive" {
                for (k, v) in device { params[k] = v }
                params["exact.tti.reason"] = e["tti"] ?? "settled"
                if let failed = e["failed"] as? [String] { params["exact.tti.failed"] = failed.count }
            }
            store.addMetric(session: session, time: wall, category: "appStartup", name: name, value: value, params: params)
        }
    }

    /// Observe's navigation metrics (`expo.navigation.*`): routeName is the
    /// route pattern; params are routeParams, url and isAppLaunch.
    func navigation(_ e: [String: Any], wall: Double) {
        guard let store, let name = e["name"] as? String, let value = e["value"] as? Double else { return }
        navigatedBeforeStartup = true
        var params = globals
        params["isAppLaunch"] = false
        params["routeParams"] = e["routeParams"] ?? [:]
        params["url"] = e["url"] ?? ""
        for (k, v) in e where k.hasPrefix("exact.") { params[k] = v }
        store.addMetric(session: session, time: wall, category: "navigation", name: name, value: value, route: e["route"] as? String, params: params)
    }

    /// The launch route's own pair, from startup's marks: from boot (Exact's
    /// nearest to Observe's integration start; a declared deviation) to the
    /// first frame, and to TTI unless the user had navigated away by then.
    func launchNavigation(_ e: [String: Any], wall: Double) {
        guard let store, let route = launchRoute, let marks = e["marks"] as? [String: Double], let boot = marks["boot"] else { return }
        var params = globals
        params["isAppLaunch"] = true
        params["routeParams"] = route["routeParams"] ?? [:]
        params["url"] = route["url"] ?? ""
        params["exact.nav.anchor"] = "boot"
        if let present = marks["present"] {
            store.addMetric(session: session, time: wall, category: "navigation", name: "cold_ttr", value: (present - boot) / 1000, route: route["route"] as? String, params: params)
        }
        if let interactive = marks["interactive"], !navigatedBeforeStartup, ["settled", "failed", "declared"].contains(e["tti"] as? String ?? "") {
            store.addMetric(session: session, time: wall, category: "navigation", name: "tti", value: (interactive - boot) / 1000, route: route["route"] as? String, params: params)
        }
    }

    /// Observe's `updates/updateDownloadTime`: a staged update's blobs, from
    /// the first request to staged. The id is Exact's envelope digest.
    func updateDownload(_ e: [String: Any], wall: Double) {
        guard let store, let seconds = e["seconds"] as? Double else { return }
        store.run("INSERT INTO metrics (session, time, category, name, value, updateId, params) VALUES (?, ?, ?, ?, ?, ?, ?)",
                  [session, wall, "updates", "updateDownloadTime", seconds, e["entry"] as? String,
                   String(decoding: (try? JSONSerialization.data(withJSONObject: ["exact.update.files_fetched": e["files"] ?? 0, "exact.update.seq": e["seq"] ?? 0, "exact.update.id_kind": "digest"], options: [.sortedKeys])) ?? Data(), as: UTF8.self)])
    }

    func log(_ e: [String: Any], wall: Double, error: Bool) {
        guard let store else { return }
        if error {
            var attrs: [String: Any] = ["expo.error.source": "reportedByUser", "expo.error.is_fatal": false,
                                        "exception.type": e["type"] as? String ?? "Error", "exception.message": e["message"] as? String ?? ""]
            if let stack = e["stack"] as? String { attrs["exception.stacktrace"] = stack }
            store.addLog(session: session, time: wall, severity: "error", name: "js.exception", body: nil, attributes: attrs, dropped: 0)
            return
        }
        guard let name = ObserveRules.name(e["name"] as? String ?? "") else { return }
        let user = ObserveRules.attributes(e["attributes"] as? [String: Any] ?? [:])
        var attrs = globals
        for (k, v) in user.kept { attrs[k] = v }
        if let display = ObserveRules.displayName(e["displayName"] as? String) { attrs["expo.log.display_name"] = display }
        let severity = ObserveWire.severities[e["severity"] as? String ?? ""] != nil ? e["severity"] as! String : "info"
        store.addLog(session: session, time: wall, severity: severity, name: name, body: ObserveRules.body(e["body"] as? String),
                     attributes: attrs, dropped: user.dropped)
    }

    /// Pending records ObserveCrash wrote as earlier processes died: one
    /// `native.exception` each, against the session that crashed.
    func ingestCrashes() {
        guard let store, let dir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for f in files where f.hasPrefix("exact-observe-pending-") && !f.contains(session) {
            let path = "\(dir)/\(f)"
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let data = FileManager.default.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let crashed = o["session"] as? String, let signal = o["signal"] as? Int else { continue }
            let start = o["sessionStart"] as? Double ?? 0
            store.saveSession(crashed, start: start, metadata: metadata)
            let names = [6: "SIGABRT", 11: "SIGSEGV", 10: "SIGBUS", 4: "SIGILL", 8: "SIGFPE", 5: "SIGTRAP"]
            let attrs: [String: Any] = ["exception.type": names[signal] ?? "SIG\(signal)", "exception.message": "fatal signal \(signal)",
                                        "expo.error.source": "nativeCrash", "expo.error.is_fatal": true, "expo.crash.signal_number": signal]
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? start
            store.addLog(session: crashed, time: modified, severity: "fatal", name: "native.exception", body: nil, attributes: attrs, dropped: 0)
        }
    }

    // MARK: Dispatch

    var development: Bool { config["fact.development"] as? Bool == true || config["fact.agent"] as? Bool == true }

    /// Observe's gate: enabled, in sample (per install), and not a development
    /// build unless `dispatchInDebug`. Out of the gate, rows are dropped.
    var shouldDispatch: Bool {
        let enabled = config["dispatchingEnabled"] as? Bool ?? true
        let rate = min(max(config["sampleRate"] as? Double ?? 1, 0), 1)
        return enabled && ObserveWire.uniform(clientId) < rate && (!development || config["dispatchInDebug"] as? Bool == true)
    }

    func dispatch() {
        guard let store, !sending else { return }
        if let after = gate.after, after > Date() { return }
        guard shouldDispatch, let project = config["projectId"] as? String else {
            store.setCursor("metrics", store.maxId("metrics"))
            store.setCursor("logs", store.maxId("logs"))
            return
        }
        let base = (config["endpoint"] as? String ?? "https://o.expo.dev").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        sending = true
        send("metrics", url: "\(base)/\(project)/v1/metrics", limit: ObserveWire.chunk) { [self] in
            send("logs", url: "\(base)/\(project)/v1/logs", limit: ObserveWire.chunk) { [self] in sending = false }
        }
    }

    /// One signal, chunk by chunk, until drained or stopped (Observe's DispatchLoop).
    func send(_ signal: String, url: String, limit: Int, done: @escaping () -> Void) {
        guard let store else { return done() }
        let cursor = store.cursor(signal)
        let rows = signal == "metrics"
            ? store.rows("SELECT id, session, time, category, name, value, route, updateId, params FROM metrics WHERE id > ? ORDER BY id LIMIT ?", [cursor, limit])
            : store.rows("SELECT id, session, time, severity, name, body, attributes, dropped FROM logs WHERE id > ? ORDER BY id LIMIT ?", [cursor, limit])
        guard !rows.isEmpty, let highest = rows.last?.first as? Int64 else { return done() }
        var sessions: [String: [String: Any]] = [:]
        for r in rows { if let s = r[1] as? String, sessions[s] == nil { sessions[s] = store.session(s)?.metadata } }
        let body = signal == "metrics"
            ? ObserveWire.metricsBody(rows, sessions: sessions, clientId: clientId.uuidString.lowercased())
            : ObserveWire.logsBody(rows, sessions: sessions, clientId: clientId.uuidString.lowercased())
        guard let data = try? JSONSerialization.data(withJSONObject: body), let endpoint = URL(string: url) else { return done() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Expo-AppMetrics-Skip")
        URLSession.shared.dataTask(with: request) { [self] _, response, error in
            queue.async { [self] in
                let status = (response as? HTTPURLResponse)?.statusCode
                let result: ObserveWire.Result = error != nil || status == nil
                    ? .retryable(nil)
                    : ObserveWire.classify(status: status!, retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
                if ProcessInfo.processInfo.environment["EXACT_OBSERVE_LOG"] == "1" { fputs("observe: \(signal) \(rows.count) rows → \(status.map(String.init) ?? "transport error")\n", stderr) }
                switch result {
                case .success, .nonRetryable:
                    gate.failures = 0
                    store.setCursor(signal, highest)
                    send(signal, url: url, limit: ObserveWire.chunk, done: done)
                case .payloadTooLarge:
                    gate.failures = 0
                    if rows.count > 1 { send(signal, url: url, limit: max(1, rows.count / 2), done: done) }
                    else { store.setCursor(signal, highest); send(signal, url: url, limit: ObserveWire.chunk, done: done) }
                case .retryable(let after):
                    gate.failures += 1
                    gate.after = Date().addingTimeInterval(after ?? ObserveWire.backoff(attempt: gate.failures))
                    done()
                }
            }
        }.resume()
    }

    /// Milliseconds as seconds, to 0.1 ms, printed without binary noise.
    static func seconds(_ ms: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.4f", ms / 1000))
    }

    // MARK: Snapshot

    static func metadata(_ config: [String: Any]) -> [String: Any] {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var m: [String: Any] = [
            "osVersion": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            // The simulator's own model, not the Mac's architecture.
            "deviceModel": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine,
            "language": Locale.preferredLanguages.first ?? "en",
            "clientVersion": "0.1.0",
            "environment": config["environment"] as? String ?? ((config["fact.development"] as? Bool ?? false) ? "development" : "production"),
        ]
        #if os(iOS)
        m["osName"] = "iOS"
        m["deviceName"] = UIDevice.current.model
        #else
        m["osName"] = "macOS"
        m["deviceName"] = "Mac"
        #endif
        let app = { (k: String) in config["app." + k] ?? info[k] }
        m["appIdentifier"] = app("CFBundleIdentifier")
        m["appVersion"] = app("CFBundleShortVersionString")
        m["appBuildNumber"] = app("CFBundleVersion")
        m["appName"] = app("CFBundleDisplayName") ?? app("CFBundleName")
        return m
    }

    static func records(_ data: Data) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        let bytes = [UInt8](data)
        while i + 4 <= bytes.count {
            let n = Int(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
            i += 4
            guard i + n <= bytes.count else { break }
            if let o = (try? JSONSerialization.jsonObject(with: Data(bytes[i..<i + n]))) as? [String: Any] { out.append(o) }
            i += n
        }
        return out
    }
}

// MARK: The C entry points ExactKit's service loader binds.

@_cdecl("exact_service_start")
public func exactServiceStart(_ config: UnsafePointer<UInt8>?, _ configLength: UInt32, _ handoff: UnsafePointer<UInt8>?, _ handoffLength: UInt32) -> UnsafeMutableRawPointer? {
    let c = config.map { Data(bytes: $0, count: Int(configLength)) } ?? Data()
    let h = handoff.map { Data(bytes: $0, count: Int(handoffLength)) } ?? Data()
    let o = (try? JSONSerialization.jsonObject(with: c)) as? [String: Any] ?? [:]
    return Unmanaged.passRetained(ObserveService(config: o, handoff: h)).toOpaque()
}

@_cdecl("exact_service_event")
public func exactServiceEvent(_ state: UnsafeMutableRawPointer?, _ json: UnsafePointer<UInt8>?, _ length: UInt32) {
    guard let state, let json else { return }
    Unmanaged<ObserveService>.fromOpaque(state).takeUnretainedValue().event(Data(bytes: json, count: Int(length)))
}

@_cdecl("exact_service_background")
public func exactServiceBackground(_ state: UnsafeMutableRawPointer?) {
    guard let state else { return }
    let service = Unmanaged<ObserveService>.fromOpaque(state).takeUnretainedValue()
    service.queue.async { service.dispatch() }
}
