// What the launch's first batch cost UIKit, part by part (`exact.boot.apply.*`
// in the launch report): each op kind and each pass after the ops, timed only
// while the boot applies that batch, so no later batch pays for it.
import Foundation
import QuartzCore

enum ApplyProfile {
    /// On only while the boot applies its first batch (`Session.finishBoot`).
    nonisolated(unsafe) static var on = false
    /// Milliseconds by part: `op.create`, `op.style`, …, `pass.navigation`, ….
    nonisolated(unsafe) private(set) static var parts: [String: Double] = [:]

    static func begin() { parts = [:]; on = true }
    static func end() -> [String: Double] { on = false; defer { parts = [:] }; return parts }

    /// Adds the time since `since` (a `CACurrentMediaTime`) to `part`.
    @inline(__always) static func add(_ part: String, since: Double) {
        parts[part, default: 0] += (CACurrentMediaTime() - since) * 1000
    }

    /// `body`, timed as `part` while on.
    @inline(__always) static func time<T>(_ part: String, _ body: () -> T) -> T {
        guard on else { return body() }
        let t = CACurrentMediaTime()
        defer { add(part, since: t) }
        return body()
    }
}
