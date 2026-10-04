// Observe's event rules (expo-app-metrics `LogEvents/*Validation.swift`,
// `AttributeValidation.swift` on main), copied so a custom event means the
// same thing from Exact: a name of 1–256 characters, trimmed, never `expo.`;
// a body truncated to 4096 characters with "…"; a display name truncated to
// 128; at most 128 attributes (alphabetical, the rest dropped and counted);
// reserved keys (`expo.*`, `session.id`, `event.name`) and blank keys dropped.
import Foundation

enum ObserveRules {
    static let maxName = 256, maxBody = 4096, maxDisplayName = 128, maxAttributes = 128

    static func name(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("expo."), name.count <= maxName else {
            fputs("observe: dropped an event with an invalid name\n", stderr)
            return nil
        }
        return name
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    static func body(_ raw: String?) -> String? { raw.map { truncate($0, maxBody) } }

    static func displayName(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return truncate(s, maxDisplayName)
    }

    static func reserved(_ key: String) -> Bool {
        (key.hasPrefix("expo.") && key.count > 5) || key == "session.id" || key == "event.name"
    }

    static func attributes(_ raw: [String: Any]) -> (kept: [String: Any], dropped: Int) {
        var kept: [String: Any] = [:]
        var dropped = 0
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if k.isEmpty || reserved(k) || kept.count >= maxAttributes { dropped += 1; continue }
            kept[k] = value
        }
        return (kept, dropped)
    }
}
