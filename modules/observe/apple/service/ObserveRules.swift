// Observe's custom-event validation, copied from expo-app-metrics
// (`LogEvents/*Validation.swift`, `AttributeValidation.swift`) so events match upstream.
// Attributes are kept in key order up to the limit. The rest, plus blank and
// reserved keys, are dropped and counted.
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
