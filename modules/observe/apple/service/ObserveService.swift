// Observe's service: a separate dylib ExactKit loads after startup. It stores journal
// events as Observe's metric and log rows, records crashes from earlier launches, and
// sends the rows the way expo-observe does. All work runs on one serial background queue.
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
    /// The route shown at launch. It gets startup's `tti` when the startup report says it stayed on top (`launchScreen`).
    var launchRoute: [String: Any]?
    var globals: [String: Any] = [:]
    /// Each signal's retry gate, as expo-observe keeps one per endpoint.
    var gates: [String: (after: Date?, failures: Int)] = [:]
    /// The earliest dispatch a closed gate scheduled, and its token: a newer, earlier one replaces it.
    var retryAt: Date?
    var retryToken = 0
    var sending = false
    var scheduled = false

    static let logEnabled = ProcessInfo.processInfo.environment["EXACT_OBSERVE_LOG"] == "1"

    /// Sends new rows within 5 seconds. Only one timer is pending at a time.
    func scheduleDispatch() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.scheduled = false
            self?.dispatch()
        }
    }

    /// Crash records are read from here: the user's Caches directory, where ObserveCrash writes them.
    let crashDirectory: String?

    /// `root` and `clientId` are for tests: `root` holds the store and the crash records.
    init(config: [String: Any], handoff: Data, root: URL? = nil, clientId fixedId: UUID? = nil) {
        self.config = config
        session = config["session"] as? String ?? UUID().uuidString
        if let fixedId {
            clientId = fixedId
        } else {
            let defaults = UserDefaults.standard
            let id = defaults.string(forKey: "expo.eas-client-id") ?? UUID().uuidString
            defaults.set(id, forKey: "expo.eas-client-id")
            clientId = UUID(uuidString: id) ?? UUID()
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = ObserveStore(directory: root ?? base.appendingPathComponent("exact/\(config["app.CFBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier ?? "app")/observe", isDirectory: true))
        crashDirectory = root?.path ?? NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
        metadata = Self.metadata(config)
        for record in Self.records(handoff) {
            if record["kind"] as? String == "device" { device = record["params"] as? [String: Any] ?? [:] }
        }
        // Remove a disconnected path's cost flags, which the launch part kept from the connection
        // before it, as Observe omits them without one (`MetricParamsBuilder.swift`).
        if device["expo.network.connected"] as? Bool == false {
            device["expo.network.isExpensive"] = nil
            device["expo.network.isConstrained"] = nil
        }
        if Self.logEnabled { fputs("observe: service started, session \(session)\n", stderr) }
        queue.async { [self] in
            store?.saveSession(session, start: config["sessionStart"] as? Double ?? Date().timeIntervalSince1970, metadata: metadata)
            ingestCrashes()
            scheduleDispatch()
        }
    }

    // MARK: Journal events

    func event(_ json: Data) {
        queue.async { [self] in
            guard let e = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], let kind = e["kind"] as? String else { return }
            let wall = e["wall"] as? Double ?? Date().timeIntervalSince1970
            switch kind {
            case "startup": startup(e, wall: wall)
            case "startup.tti": startup(e, wall: wall)
            case "memory.warning": memoryWarning(e, wall: wall)
            case "navigation.launch": launchRoute = e
            case "navigation": navigation(e, wall: wall)
            case "update.download": updateDownload(e, wall: wall)
            // The update that runs from now (empty: the embedded app): Observe's `expo.app.update_id` on the rows after it.
            case "update.launched":
                store?.running = (e["entry"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                store?.setSessionRunning(session, store?.running)
            case "app.attributes": globals = ObserveRules.attributes(e["attributes"] as? [String: Any] ?? [:]).kept
            case "app.event": log(e, wall: wall, error: false)
            case "app.error": log(e, wall: wall, error: true)
            case "background": DispatchQueue.main.async { [self] in dispatchInBackground() }
            default: return
            }
            if kind != "background" { scheduleDispatch() }
        }
    }

    /// The startup metrics stored, by name (`launch.` for the launch route's): a report after
    /// the timeout's (`startup.tti`) stores only what that one lacked, such as a first frame
    /// that came after it.
    var stored: Set<String> = []

    /// Stores the launch metrics from ExactLaunch's startup report under Observe's names,
    /// each at the time of its own mark, and each once.
    func startup(_ e: [String: Any], wall: Double) {
        // The rows carry the update startup's marks are of, not one a live activation started since.
        let current = store?.running
        if let u = e["update"] as? String { store?.running = u.isEmpty ? nil : u }
        defer { store?.running = current }
        launchNavigation(e, wall: wall)
        guard let store, let metrics = e["metrics"] as? [String: Double], !metrics.isEmpty else { return }
        let marks = e["marks"] as? [String: Double] ?? [:]
        let walls = e["walls"] as? [String: Double] ?? [:]
        let ms = { (a: String, b: String) -> NSDecimalNumber? in
            guard let x = marks[a], let y = marks[b] else { return nil }
            return Self.seconds(x - y)
        }
        var phases: [String: Any] = [:]
        // Before the app has control: dyld and this image's constructor, the
        // other images' initializers up to `main`, UIKit up to the app
        // delegate's init, and the delegate's launch up to didFinishLaunching.
        phases["exact.phase.exec"] = ms("constructor", "process")
        phases["exact.phase.initializers"] = ms("main", "constructor")
        phases["exact.phase.uikit"] = ms("delegateInit", "main")
        phases["exact.phase.launching"] = ms("didFinishLaunching", "delegateInit")
        phases["exact.phase.scene"] = ms("scene", "didFinishLaunching")
        phases["exact.phase.boot_wait"] = ms("boot", "scene")
        phases["exact.phase.boot"] = ms("commit", "boot")
        phases["exact.phase.present"] = ms("present", "commit")
        phases["exact.phase.activate"] = ms("activated", "commit")
        phases["exact.since_process_start.ttr"] = marks["present"].map { Self.seconds($0) }
        phases["exact.since_process_start.tti"] = marks["interactive"].map { Self.seconds($0) }
        phases["exact.present.method"] = e["presentMethod"] as? String ?? "next_vsync"
        // Activation's parts (ms): the app module's load, the wait for the
        // data module (and how many polls), its ready call, its first batch.
        if let b = e["boot"] as? [String: Any] {
            for key in ["runner", "apply"] { if let v = b[key] as? Double { phases["exact.boot.\(key)"] = Self.seconds(v) } }
            if let parts = b["parts"] as? String { phases["exact.boot.apply_parts"] = parts }
        }
        if let d = e["data"] as? [String: Any] {
            for (key, name) in [("receipt", "draw_receipt"), ("appModule", "app_module"), ("waited", "wait"), ("ready", "ready"), ("apply", "apply")] {
                if let v = d[key] as? Double { phases["exact.data.\(name)"] = Self.seconds(v) }
            }
            if let polls = d["polls"] as? Int { phases["exact.data.polls"] = polls }
        }
        if let path = e["bootPath"] { phases["exact.boot.path"] = path }
        // Cold or warm, by Observe's heuristic (a reboot since the last launch).
        if let type = e["launchType"] { phases["exact.launch.type"] = type }
        if e["debugger"] as? Bool == true { phases["exact.launch.debugger"] = true }
        if e["interrupted"] as? Bool == true { phases["exact.launch.interrupted"] = true }
        for (name, value) in metrics where stored.insert(name).inserted {
            var params = globals
            for (k, v) in phases { params[k] = v }
            var route: String?
            if name == "timeToInteractive" {
                for (k, v) in device { params[k] = v }
                // The screen shown at TTI, with Observe's navigation params.
                if let r = e["route"] as? [String: Any] {
                    route = r["route"] as? String
                    params["routeParams"] = r["routeParams"] ?? [:]
                    if let url = r["url"] { params["url"] = url }
                }
                if let frames = e["frames"] as? [String: Any] { for (k, v) in frames { params[k] = v } }
                if e["late"] as? Bool == true { params["exact.tti.late"] = true }
                params["exact.tti.reason"] = e["tti"] ?? "settled"
                // What was outstanding over time, ms from process start: shows what held TTI.
                if let trace = e["trace"] as? [String], !trace.isEmpty { params["exact.tti.trace"] = trace.joined(separator: " → ") }
                // Batches that still changed the screen once nothing was outstanding.
                if let changes = e["changes"] as? [String], !changes.isEmpty { params["exact.tti.changes"] = changes.joined(separator: "; ") }
                // Each item that held it, ms from process start, the latest to clear first.
                if let items = e["items"] as? [[String: Any]], !items.isEmpty {
                    let ordered = items.sorted { ($0["to"] as? Double ?? .infinity) > ($1["to"] as? Double ?? .infinity) }
                    params["exact.tti.items"] = ordered.map { item -> String in
                        let from = String(format: "%.0f", item["from"] as? Double ?? 0)
                        let to = (item["to"] as? Double).map { String(format: "%.0f", $0) } ?? "…"
                        return "\(item["item"] as? String ?? "?") \(from)–\(to)"
                    }.joined(separator: "; ")
                }
                if let failed = e["failed"] as? [String] { params["exact.tti.failed"] = failed.count }
            }
            store.addMetric(session: session, time: walls[name] ?? wall, category: "appStartup", name: name, value: value, route: route, params: params)
        }
    }

    /// Observe's `expo.navigation.*` metrics. The route is the pattern, not the concrete path.
    func navigation(_ e: [String: Any], wall: Double) {
        guard let store, let name = e["name"] as? String, let value = e["value"] as? Double else { return }
        var params = navigationParams(e, launch: false)
        for (k, v) in e where k.hasPrefix("exact.") { params[k] = v }
        store.addMetric(session: session, time: wall, category: "navigation", name: name, value: value, route: e["route"] as? String, params: params)
    }

    /// The launch route's `cold_ttr` and `tti`, measured from boot. Observe measures from
    /// its integration start, which Exact has no equivalent of; boot is the closest mark.
    /// They exist when the startup metrics they end with do.
    func launchNavigation(_ e: [String: Any], wall: Double) {
        guard let store, let route = launchRoute, let marks = e["marks"] as? [String: Double], let boot = marks["boot"] else { return }
        let metrics = e["metrics"] as? [String: Any] ?? [:]
        let walls = e["walls"] as? [String: Double] ?? [:]
        var params = navigationParams(route, launch: true)
        params["exact.nav.anchor"] = "boot"
        if metrics["timeToFirstRender"] != nil, let present = marks["present"], stored.insert("launch.cold_ttr").inserted {
            store.addMetric(session: session, time: walls["timeToFirstRender"] ?? wall, category: "navigation", name: "cold_ttr", value: (present - boot) / 1000, route: route["route"] as? String, params: params)
        }
        // Startup's TTI is the launch screen's when that screen stayed on top until it (the host says so in the session).
        if metrics["timeToInteractive"] != nil, let interactive = marks["interactive"], e["launchScreen"] as? Bool == true, stored.insert("launch.tti").inserted {
            store.addMetric(session: session, time: walls["timeToInteractive"] ?? wall, category: "navigation", name: "tti", value: (interactive - boot) / 1000, route: route["route"] as? String, params: params)
        }
    }

    /// Observe's `expo.memory.warning` log, with the memory in use when the system warned.
    func memoryWarning(_ e: [String: Any], wall: Double) {
        guard let store else { return }
        var attrs = globals
        for key in ["expo.memory.allocated", "expo.memory.physical", "expo.memory.available", "expo.memory.warningsCount"] {
            if let v = e[key] { attrs[key] = v }
        }
        store.addLog(session: session, time: wall, severity: "warn", name: "expo.memory.warning", body: nil, attributes: attrs, dropped: 0)
    }

    /// Observe's navigation params, on top of the global attributes.
    func navigationParams(_ e: [String: Any], launch: Bool) -> [String: Any] {
        var params = globals.merging(["isAppLaunch": launch, "routeParams": e["routeParams"] ?? [:]]) { $1 }
        if let url = e["url"] { params["url"] = url }
        return params
    }

    /// Observe's `updates/updateDownloadTime`: from the first request to the update being staged.
    /// The update id is Exact's envelope digest, not an EAS update id.
    func updateDownload(_ e: [String: Any], wall: Double) {
        guard let store, let seconds = e["seconds"] as? Double else { return }
        let params = globals.merging(["exact.update.files_fetched": e["files"] ?? 0, "exact.update.seq": e["seq"] ?? 0, "exact.update.id_kind": "digest"]) { $1 }
        store.run("INSERT INTO metrics (session, time, category, name, value, updateId, running, params) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                  [session, wall, "updates", "updateDownloadTime", seconds, e["entry"] as? String, store.running,
                   String(decoding: (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])) ?? Data(), as: UTF8.self)])
    }

    func log(_ e: [String: Any], wall: Double, error: Bool) {
        guard let store else { return }
        if error {
            var attrs = globals
            for (k, v) in ["expo.error.source": e["source"] as? String ?? "reportedByUser", "expo.error.is_fatal": false,
                           "exception.type": e["type"] as? String ?? "Error", "exception.message": e["message"] as? String ?? ""] as [String: Any] { attrs[k] = v }
            if let stack = e["stack"] as? String { attrs["exception.stacktrace"] = stack }
            store.addLog(session: session, time: wall, severity: "error", name: "js.exception", body: nil, attributes: attrs, dropped: 0)
            return
        }
        guard let name = ObserveRules.name(e["name"] as? String ?? "") else { return }
        let user = ObserveRules.attributes(e["attributes"] as? [String: Any] ?? [:])
        var attrs = globals
        for (k, v) in user.kept { attrs[k] = v }
        if let display = ObserveRules.displayName(e["displayName"] as? String) { attrs["expo.log.display_name"] = display }
        let severity = (e["severity"] as? String).flatMap { ObserveWire.severities[$0] != nil ? $0 : nil } ?? "info"
        store.addLog(session: session, time: wall, severity: severity, name: name, body: ObserveRules.body(e["body"] as? String),
                     attributes: attrs, dropped: user.dropped)
    }

    /// Turns each pending ObserveCrash record into a `native.exception` log for the crashed session.
    func ingestCrashes() {
        guard let store, let dir = crashDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let app = config["app.CFBundleIdentifier"] as? String ?? "app"
        // `exact-observe-pending-<session>-<app>.json` (ObserveCrash.swift): this app's, from another session.
        let ours = { (f: String) -> Bool in
            let head = "exact-observe-pending-", tail = ".json"
            guard f.hasPrefix(head), f.hasSuffix(tail) else { return false }
            let middle = f.dropFirst(head.count).dropLast(tail.count), id = String(middle.prefix(36))
            return UUID(uuidString: id) != nil && id != self.session && middle.dropFirst(36).first == "-" && middle.dropFirst(37) == app
        }
        for f in files where ours(f) {
            let path = "\(dir)/\(f)"
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let data = FileManager.default.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let crashed = o["session"] as? String, let signal = o["signal"] as? Int, o["app"] as? String ?? app == app else { continue }
            let start = o["sessionStart"] as? Double ?? 0
            // The crashed build's version and OS, which can differ from this launch's.
            store.saveSession(crashed, start: start, metadata: metadata.merging(o["metadata"] as? [String: Any] ?? [:]) { $1 })
            let names = [6: "SIGABRT", 11: "SIGSEGV", 10: "SIGBUS", 4: "SIGILL", 8: "SIGFPE", 5: "SIGTRAP"]
            let attrs: [String: Any] = ["exception.type": names[signal] ?? "SIG\(signal)", "exception.message": "fatal signal \(signal)",
                                        "expo.error.source": "nativeCrash", "expo.error.is_fatal": true, "expo.crash.signal_number": signal]
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? start
            // The update the crashed process ran: its record's, else the one its service stored last, not this launch's.
            let current = store.running
            store.running = o["updateId"] as? String ?? store.sessionRunning(crashed)
            store.addLog(session: crashed, time: modified, severity: "fatal", name: "native.exception", body: nil, attributes: attrs, dropped: 0)
            // The startup metrics the crashed process measured, each its service did not store (a timeout's
            // report can have stored launch time, not the first frame after it).
            if let s = o["startup"] as? [String: Any], let metrics = s["metrics"] as? [String: Double] {
                let stored = Set(store.rows("SELECT name FROM metrics WHERE session = ? AND category = 'appStartup'", [crashed]).compactMap { $0.first as? String })
                let walls = s["walls"] as? [String: Double] ?? [:]
                // The update those marks are of, if the snapshot names it; else the crash's.
                if s["update"] != nil { store.running = (s["update"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                for (name, value) in metrics where !stored.contains(name) {
                    store.addMetric(session: crashed, time: walls[name] ?? modified, category: "appStartup", name: name, value: value,
                                    params: ["exact.launch.interrupted": true, "exact.launch.crashed": true])
                }
            }
            store.running = current
        }
    }

    // MARK: Dispatch

    /// Observe's gate: dispatching enabled, this install in the sample, and not a development
    /// build unless `dispatchInDebug`. When it fails, rows are dropped, not kept for later.
    var shouldDispatch: Bool {
        let enabled = config["dispatchingEnabled"] as? Bool ?? true
        let rate = min(max(config["sampleRate"] as? Double ?? 1, 0), 1)
        let development = config["fact.development"] as? Bool == true || config["fact.agent"] as? Bool == true
        return enabled && ObserveWire.uniform(clientId) < rate && (!development || config["dispatchInDebug"] as? Bool == true)
    }

    /// Called when a send in progress finishes.
    var waiting: [() -> Void] = []
    /// A dispatch was asked for during a send (a retry that came due): it runs after it.
    var again = false

    /// Sends what is stored. `done` runs on the service queue once nothing is being sent.
    func dispatch(done: (() -> Void)? = nil) {
        guard let store else { done?(); return }
        if sending {
            if let done { waiting.append(done) }
            again = true
            return
        }
        guard shouldDispatch, let project = config["projectId"] as? String else {
            store.setCursor("metrics", store.maxId("metrics"))
            store.setCursor("logs", store.maxId("logs"))
            done?()
            return
        }
        let base = (config["endpoint"] as? String ?? "https://o.expo.dev").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        sending = true
        sendSignal("metrics", url: "\(base)/\(project)/v1/metrics") { [self] in
            sendSignal("logs", url: "\(base)/\(project)/v1/logs") { [self] in
                sending = false
                if again {
                    again = false
                    return dispatch { [self] in
                        let finished = waiting
                        waiting = []
                        for f in finished { f() }
                        done?()
                    }
                }
                let finished = waiting
                waiting = []
                for f in finished { f() }
                done?()
            }
        }
    }

    /// Sends when the app goes to the background, as Observe does when it resigns
    /// active. On iOS a background task keeps the app running until the send ends.
    func dispatchInBackground() {
        #if os(iOS)
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            DispatchQueue.main.async {
                guard task != .invalid else { return }
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "exact.observe", expirationHandler: end)
        queue.async { [self] in dispatch(done: end) }
        #else
        queue.async { [self] in dispatch() }
        #endif
    }

    /// Sends one signal unless its gate is closed, in which case the attempt waits for the gate's deadline.
    func sendSignal(_ signal: String, url: String, done: @escaping () -> Void) {
        if let after = gates[signal]?.after, after > Date() {
            retry(at: after)
            return done()
        }
        send(signal, url: url, limit: ObserveWire.chunk, done: done)
    }

    /// Dispatches again at `date`, so rows a closed gate kept wait for no new event.
    func retry(at date: Date) {
        if let at = retryAt, at <= date { return }
        retryAt = date
        retryToken += 1
        let token = retryToken
        queue.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow)) { [weak self] in
            guard let self, token == retryToken else { return }
            retryAt = nil
            dispatch()
        }
    }

    /// Sends one signal's rows chunk by chunk until none are left or a send must wait.
    /// Follows expo-observe's `DispatchLoop.swift`.
    func send(_ signal: String, url: String, limit: Int, done: @escaping () -> Void) {
        guard let store, let next = chunk(signal, limit: limit), let highest = next.rows.last?.first as? Int64,
              let data = try? JSONSerialization.data(withJSONObject: next.body), let endpoint = URL(string: url) else { return done() }
        let rows = next.rows
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
                if Self.logEnabled { fputs("observe: \(signal) \(rows.count) rows → \(status.map(String.init) ?? "transport error")\n", stderr) }
                switch result {
                case .payloadTooLarge where rows.count > 1:
                    gates[signal]?.failures = 0
                    send(signal, url: url, limit: rows.count / 2, done: done)
                // Success, a lone 413 row, or a status Observe does not retry: skip the chunk.
                case .success, .nonRetryable, .payloadTooLarge:
                    gates[signal]?.failures = 0
                    store.setCursor(signal, highest)
                    send(signal, url: url, limit: ObserveWire.chunk, done: done)
                case .retryable(let after):
                    let failures = (gates[signal]?.failures ?? 0) + 1
                    let deadline = Date().addingTimeInterval(after ?? ObserveWire.backoff(attempt: failures))
                    gates[signal] = (deadline, failures)
                    retry(at: deadline)
                    done()
                }
            }
        }.resume()
    }

    /// The next unsent rows of a signal, up to `limit`, and their OTLP body.
    func chunk(_ signal: String, limit: Int) -> (rows: [[Any?]], body: [String: Any])? {
        guard let store else { return nil }
        let cursor = store.cursor(signal)
        let rows = signal == "metrics"
            ? store.rows("SELECT id, session, time, category, name, value, route, updateId, params, running FROM metrics WHERE id > ? ORDER BY id LIMIT ?", [cursor, limit])
            : store.rows("SELECT id, session, time, severity, name, body, attributes, dropped, running FROM logs WHERE id > ? ORDER BY id LIMIT ?", [cursor, limit])
        guard !rows.isEmpty else { return nil }
        var sessions: [String: [String: Any]] = [:]
        for r in rows { if let s = r[1] as? String, sessions[s] == nil { sessions[s] = store.metadata(s) } }
        let id = clientId.uuidString.lowercased()
        return (rows, signal == "metrics"
            ? ObserveWire.metricsBody(rows, sessions: sessions, clientId: id)
            : ObserveWire.logsBody(rows, sessions: sessions, clientId: id))
    }

    /// Milliseconds to seconds, rounded to 0.1 ms, as a decimal so JSON prints it exactly.
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
            // On a simulator, `uname` reports the Mac's architecture, so use the simulated model.
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

// MARK: Queries from the app's own module

extension ObserveService {
    /// What this device recorded, newest first, for an app's own screens
    /// (`ExactServices.query("observe", …)`). `{"op": "recent", "limit": n}`
    /// (1–500, default 50) answers `{"session", "metrics": [{session, time,
    /// category, name, value, route, sent, params}]}`: `time` in seconds since
    /// 1970, `value` in seconds as sent, `sent` whether it has gone to Observe.
    func query(_ request: [String: Any]) -> [String: Any] {
        guard request["op"] as? String == "recent" else { return ["error": "observe answers {\"op\": \"recent\"}"] }
        guard let store else { return ["session": session, "metrics": []] }
        let limit = max(1, min(500, (request["limit"] as? Int) ?? 50))
        let sent = store.cursor("metrics")
        let rows = store.rows("SELECT id, session, time, category, name, value, route, params FROM metrics ORDER BY id DESC LIMIT ?", [limit])
        let metrics = rows.map { r -> [String: Any] in
            var m: [String: Any] = ["session": r[1] ?? "", "time": r[2] ?? 0.0, "category": r[3] ?? "", "name": r[4] ?? "",
                                    "value": r[5] ?? 0.0, "route": r[6] ?? "", "sent": ((r[0] as? Int64) ?? .max) <= sent]
            if let p = r[7] as? String, let o = try? JSONSerialization.jsonObject(with: Data(p.utf8)) { m["params"] = o }
            return m
        }
        return ["session": session, "metrics": metrics]
    }
}

// MARK: C entry points bound by ExactKit's service loader

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
    Unmanaged<ObserveService>.fromOpaque(state).takeUnretainedValue().dispatchInBackground()
}

@_cdecl("exact_service_flush")
public func exactServiceFlush(_ state: UnsafeMutableRawPointer?) {
    guard let state else { return }
    Unmanaged<ObserveService>.fromOpaque(state).takeUnretainedValue().queue.sync {}
}

@_cdecl("exact_service_query")
public func exactServiceQuery(_ state: UnsafeMutableRawPointer?, _ json: UnsafePointer<UInt8>?, _ length: UInt32, _ context: UnsafeMutableRawPointer?,
                              _ reply: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt32) -> Void) {
    guard let state else { return reply(context, nil, 0) }
    let service = Unmanaged<ObserveService>.fromOpaque(state).takeUnretainedValue()
    let request = json.flatMap { (try? JSONSerialization.jsonObject(with: Data(bytes: $0, count: Int(length)))) as? [String: Any] } ?? [:]
    service.queue.async {
        let data = (try? JSONSerialization.data(withJSONObject: service.query(request))) ?? Data("{}".utf8)
        data.withUnsafeBytes { reply(context, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count)) }
    }
}
