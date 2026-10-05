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

    static func attr(_ key: String, _ value: Any) -> [String: Any]? {
        guard let v = anyValue(value) else { return nil }
        return ["key": key, "value": v]
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
        var a: [[String: Any]] = []
        let s = { (k: String, m: String) in if let v = meta[m] as? String { a.append(["key": k, "value": ["stringValue": v]]) } }
        a.append(["key": "os.type", "value": ["stringValue": "darwin"]])
        s("os.name", "osName"); s("os.version", "osVersion")
        s("device.model.name", "deviceName"); s("device.model.identifier", "deviceModel")
        s("browser.language", "language")
        a.append(["key": "telemetry.sdk.name", "value": ["stringValue": "exact-observe"]])
        s("telemetry.sdk.version", "clientVersion")
        a.append(["key": "telemetry.sdk.language", "value": ["stringValue": "swift"]])
        a.append(["key": "expo.eas_client.id", "value": ["stringValue": clientId]])
        s("service.name", "appIdentifier"); s("service.version", "appVersion")
        s("expo.app.name", "appName"); s("expo.app.build_number", "appBuildNumber")
        s("expo.app.update_id", "updateId"); s("expo.app.updates.id", "updateId")
        s("expo.app.updates.channel", "channel"); s("expo.app.updates.runtime_version", "runtimeVersion")
        s("expo.environment", "environment")
        s("exact.version", "exactVersion")
        return ["attributes": a]
    }

    static func scope(_ meta: [String: Any]) -> [String: Any] {
        ["name": "expo-observe", "version": meta["clientVersion"] as? String ?? "0"]
    }

    /// `{"resourceMetrics":[…]}`, one resource per session in the chunk.
    static func metricsBody(_ rows: [[Any?]], sessions: [String: [String: Any]], clientId: String) -> [String: Any] {
        var bySession: [String: [[String: Any]]] = [:]
        for r in rows {
            guard let session = r[1] as? String, let time = r[2] as? Double, let category = r[3] as? String,
                  let name = r[4] as? String, let value = r[5] as? Double else { continue }
            var attrs: [[String: Any]] = [["key": "session.id", "value": ["stringValue": session]]]
            if let route = r[6] as? String { attrs.append(["key": "expo.route_name", "value": ["stringValue": route]]) }
            if let update = r[7] as? String { attrs.append(["key": "expo.update_id", "value": ["stringValue": update]]) }
            if let params = r[8] as? String { attrs.append(["key": "expo.custom_params", "value": ["stringValue": params]]) }
            bySession[session, default: []].append([
                "unit": "s",
                "name": names["\(category)/\(name)"] ?? "expo.unknown.\(name)",
                "gauge": ["dataPoints": [["timeUnixNano": nanos(time), "asDouble": value, "attributes": attrs]]],
            ])
        }
        return ["resourceMetrics": bySession.keys.sorted().compactMap { s -> [String: Any]? in
            guard let meta = sessions[s] else { return nil }
            return ["resource": resource(meta, clientId: clientId), "scopeMetrics": [["scope": scope(meta), "metrics": bySession[s]!]], "schemaUrl": schemaUrl]
        }]
    }

    /// `{"resourceLogs":[…]}`, one resource per session in the chunk.
    static func logsBody(_ rows: [[Any?]], sessions: [String: [String: Any]], clientId: String) -> [String: Any] {
        var bySession: [String: [[String: Any]]] = [:]
        for r in rows {
            guard let session = r[1] as? String, let time = r[2] as? Double, let severity = r[3] as? String, let name = r[4] as? String else { continue }
            var attrs: [[String: Any]] = [["key": "session.id", "value": ["stringValue": session]], ["key": "event.name", "value": ["stringValue": name]]]
            var dropped = (r[7] as? Int64).map(Int.init) ?? 0
            if let text = r[6] as? String, let user = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                for (k, v) in user.sorted(by: { $0.key < $1.key }) { if let a = attr(k, v) { attrs.append(a) } else { dropped += 1 } }
            }
            var record: [String: Any] = [
                "timeUnixNano": nanos(time), "observedTimeUnixNano": nanos(time),
                "severityNumber": severities[severity] ?? 9, "severityText": severity.uppercased(),
                "body": ["stringValue": r[5] as? String ?? ""], "attributes": attrs,
            ]
            if dropped > 0 { record["droppedAttributesCount"] = dropped }
            bySession[session, default: []].append(record)
        }
        return ["resourceLogs": bySession.keys.sorted().compactMap { s -> [String: Any]? in
            guard let meta = sessions[s] else { return nil }
            return ["resource": resource(meta, clientId: clientId), "scopeLogs": [["scope": scope(meta), "logRecords": bySession[s]!]], "schemaUrl": schemaUrl]
        }]
    }

    enum Result {
        case success, payloadTooLarge, nonRetryable(String), retryable(TimeInterval?)
    }

    static func classify(status: Int, retryAfter: String?) -> Result {
        if (200...299).contains(status) { return .success }
        if status == 413 { return .payloadTooLarge }
        if [429, 502, 503, 504].contains(status) { return .retryable(parseRetryAfter(retryAfter)) }
        return .nonRetryable("HTTP \(status)")
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
        guard attempt >= 1 else { return 0 }
        return min(backoffBase * pow(2, Double(attempt - 1)), backoffCap) * Double.random(in: 0..<1)
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
