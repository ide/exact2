import Foundation
import CoreFoundation

extension Agent {
    /// Reject malformed direct carrier requests before another tap form can take them.
    func swipeMalformed(_ req: [String: Any], checking: Bool) -> [String: Any]? {
        func malformed(_ why: String) -> [String: Any] { ["malformed": true, "error": why] }
        let fields: Set<String> = ["op", "id", "session", "swipe", "at"]
        if req.keys.contains(where: { !fields.contains($0) && !(checking && $0 == "check") }) {
            return malformed("swipe takes only a direction and optional at <x> <y>")
        }
        guard let word = req["swipe"] as? String, ["left", "right", "up", "down"].contains(word) else {
            return malformed("swipe: expected left, right, up or down")
        }
        func number(_ value: Any) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        guard let raw = req["id"], let id = number(raw), id >= 0, id <= Double(UInt32.max), id.rounded() == id else {
            return malformed("swipe needs a view id")
        }
        if let raw = req["at"] {
            guard let at = raw as? [Any], at.count == 2, at.allSatisfy({ number($0) != nil }) else {
                return malformed("at needs two finite numbers")
            }
        }
        if let raw = req["check"], CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID() {
            return malformed("swipe check must be a boolean")
        }
        return nil
    }
}
