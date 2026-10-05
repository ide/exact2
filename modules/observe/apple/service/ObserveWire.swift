// The OTLP/JSON body and retry rules expo-observe uses, copied from its
// `OpenTelemetry.swift`, `DispatchLoop.swift` and `DispatchUtils.swift`.
// A 413 halves the chunk, and a single row that still fails is dropped. 429, 502-504 and
// transport errors back off. Other errors drop the chunk. There is no auth: the project id is in the URL.
import Foundation

enum ObserveWire {
    static let schemaUrl = "https://opentelemetry.io/schemas/1.27.0"
    static let chunk = 200
    static let backoffBase = 60.0, backoffCap = 900.0

    /// Observe's `metricNameMap`. Exact emits only these names.
    static let names = [
        "appStartup/timeToInteractive": "expo.app_startup.tti",
        "appStartup/timeToFirstRender": "expo.app_startup.ttr",
        "appStartup/coldLaunchTime": "expo.app_startup.cold_launch_time",
        "appStartup/warmLaunchTime": "expo.app_startup.warm_launch_time",
        "appStartup/bundleLoadTime": "expo.app_startup.bundle_load_time",
        "updates/updateDownloadTime": "expo.updates.download_time",
        "navigation/cold_ttr": "expo.navigation.cold_ttr",
        "navigation/warm_ttr": "expo.navigation.warm_ttr",
        "navigation/tti": "expo.navigation.tti",
    ]

    static let severities = ["trace": 1, "debug": 5, "info": 9, "warn": 13, "error": 17, "fatal": 21]

    static func nanos(_ seconds: Double) -> UInt64 { UInt64((seconds * 1000).rounded()) * 1_000_000 }

    static func stringAttr(_ key: String, _ value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }

    /// Observe's `otAnyValue`: a value it can't represent is dropped and counted.
    static func anyValue(_ value: Any) -> [String: Any]? {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let b = value as? Bool { return ["boolValue": b] }
        if let n = value as? NSNumber, CFNumberIsFloatType(n) { return n.doubleValue.isFinite ? ["doubleValue": n.doubleValue] : nil }
        if let i = value as? Int64 { return ["intValue": i] }
        if let i = value as? Int { return ["intValue": i] }
        if let d = value as? Double { return d.isFinite ? ["doubleValue": d] : nil }
        if let s = value as? String { return ["stringValue": s] }
        if let a = value as? [Any] {
            let m = a.compactMap(anyValue)
            return m.count == a.count ? ["arrayValue": ["values": m]] : nil
        }
        if let d = value as? [String: Any] {
            var pairs: [[String: Any]] = []
            for (k, v) in d { guard let m = anyValue(v) else { return nil }; pairs.append(["key": k, "value": m]) }
            return ["kvlistValue": ["values": pairs]]
        }
        return nil
    }

    /// Observe's resource attributes, from the session's stored metadata.
    static func resource(_ meta: [String: Any], clientId: String) -> [String: Any] {
        var a = [stringAttr("os.type", "darwin")]
        let s = { (k: String, m: String) in if let v = meta[m] as? String { a.append(stringAttr(k, v)) } }
        s("os.name", "osName"); s("os.version", "osVersion")
        s("device.model.name", "deviceName"); s("device.model.identifier", "deviceModel")
        s("browser.language", "language")
        a.append(stringAttr("telemetry.sdk.name", "exact-observe"))
        s("telemetry.sdk.version", "clientVersion")
        a.append(stringAttr("telemetry.sdk.language", "swift"))
        a.append(stringAttr("expo.eas_client.id", clientId))
        s("service.name", "appIdentifier"); s("service.version", "appVersion")
        s("expo.app.name", "appName"); s("expo.app.build_number", "appBuildNumber")
        s("expo.app.update_id", "updateId"); s("expo.app.updates.id", "updateId")
        s("expo.app.updates.channel", "channel"); s("expo.app.updates.runtime_version", "runtimeVersion")
        s("expo.environment", "environment")
        s("exact.version", "exactVersion")
        return ["attributes": a]
    }

    /// `{outer: [{resource, inner: [{scope, list: items}], schemaUrl}]}`, one resource per session.
    static func envelope(_ bySession: [String: [[String: Any]]], _ outer: String, _ inner: String, _ list: String,
                         sessions: [String: [String: Any]], clientId: String) -> [String: Any] {
        [outer: bySession.keys.sorted().compactMap { s -> [String: Any]? in
            guard let meta = sessions[s] else { return nil }
            let scope = ["name": "expo-observe", "version": meta["clientVersion"] as? String ?? "0"]
            return ["resource": resource(meta, clientId: clientId), inner: [["scope": scope, list: bySession[s]!]], "schemaUrl": schemaUrl]
        }]
    }

    /// `{"resourceMetrics":[…]}`, one resource per session in the chunk.
    static func metricsBody(_ rows: [[Any?]], sessions: [String: [String: Any]], clientId: String) -> [String: Any] {
        var bySession: [String: [[String: Any]]] = [:]
        for r in rows {
            guard let session = r[1] as? String, let time = r[2] as? Double, let category = r[3] as? String,
                  let name = r[4] as? String, let value = r[5] as? Double else { continue }
            var attrs = [stringAttr("session.id", session)]
            for (i, key) in [(6, "expo.route_name"), (7, "expo.update_id"), (8, "expo.custom_params")] {
                if let v = r[i] as? String { attrs.append(stringAttr(key, v)) }
            }
            bySession[session, default: []].append([
                "unit": "s",
                "name": names["\(category)/\(name)"] ?? "expo.unknown.\(name)",
                "gauge": ["dataPoints": [["timeUnixNano": nanos(time), "asDouble": value, "attributes": attrs]]],
            ])
        }
        return envelope(bySession, "resourceMetrics", "scopeMetrics", "metrics", sessions: sessions, clientId: clientId)
    }

    /// `{"resourceLogs":[…]}`, one resource per session in the chunk.
    static func logsBody(_ rows: [[Any?]], sessions: [String: [String: Any]], clientId: String) -> [String: Any] {
        var bySession: [String: [[String: Any]]] = [:]
        for r in rows {
            guard let session = r[1] as? String, let time = r[2] as? Double, let severity = r[3] as? String, let name = r[4] as? String else { continue }
            var attrs = [stringAttr("session.id", session), stringAttr("event.name", name)]
            var dropped = (r[7] as? Int64).map(Int.init) ?? 0
            if let text = r[6] as? String, let user = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                for (k, v) in user.sorted(by: { $0.key < $1.key }) {
                    if let m = anyValue(v) { attrs.append(["key": k, "value": m]) } else { dropped += 1 }
                }
            }
            var record: [String: Any] = [
                "timeUnixNano": nanos(time), "observedTimeUnixNano": nanos(time),
                "severityNumber": severities[severity] ?? 9, "severityText": severity.uppercased(),
                "body": ["stringValue": r[5] as? String ?? ""], "attributes": attrs,
            ]
            if dropped > 0 { record["droppedAttributesCount"] = dropped }
            bySession[session, default: []].append(record)
        }
        return envelope(bySession, "resourceLogs", "scopeLogs", "logRecords", sessions: sessions, clientId: clientId)
    }

    enum Result {
        case success, payloadTooLarge, nonRetryable, retryable(TimeInterval?)
    }

    static func classify(status: Int, retryAfter: String?) -> Result {
        if (200...299).contains(status) { return .success }
        if status == 413 { return .payloadTooLarge }
        if [429, 502, 503, 504].contains(status) { return .retryable(parseRetryAfter(retryAfter)) }
        return .nonRetryable
    }

    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let clamp = { (s: TimeInterval) in min(max(s, backoffBase), backoffCap) }
        if let s = TimeInterval(raw) { return s.isFinite ? clamp(s) : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: raw).map { clamp($0.timeIntervalSinceNow) }
    }

    static func backoff(attempt: Int) -> TimeInterval {
        min(backoffBase * pow(2, Double(attempt - 1)), backoffCap) * Double.random(in: 0..<1)
    }

    /// Same as expo's `EASClientID.deterministicUniformValue`: a stable value in [0, 1) per install.
    static func uniform(_ uuid: UUID) -> Double {
        let (high, low) = withUnsafeBytes(of: uuid.uuid) {
            ($0.load(fromByteOffset: 0, as: UInt64.self).bigEndian, $0.load(fromByteOffset: 8, as: UInt64.self).bigEndian)
        }
        var z = high ^ low
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}
