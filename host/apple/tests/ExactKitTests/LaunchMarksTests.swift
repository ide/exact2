import XCTest
@testable import ExactKit

/// Observe's startup and navigation rules as the Apple host applies them.
final class LaunchMarksTests: XCTestCase {
    private let marks: [ExactLaunch.Mark: Double] = [
        .process: 10, .constructor: 10.4, .delegateInit: 10.5, .didFinishLaunching: 10.7,
        .commit: 11.0, .present: 11.01, .interactive: 11.5,
    ]

    func testLaunchTimeTTRAndTTIEndAtTheirOwnMarks() {
        let m = ExactLaunch.metricMarks(marks, launchType: "warm", interruptedAt: nil)
        XCTAssertEqual(m["warmLaunchTime"]!.value, 0.4 + 0.2, accuracy: 1e-9, "constructor − process, plus didFinishLaunching − delegate init")
        XCTAssertEqual(m["warmLaunchTime"]!.end, 10.7)
        XCTAssertEqual(m["timeToFirstRender"]!.value, 0.31, accuracy: 1e-9)
        XCTAssertEqual(m["timeToFirstRender"]!.end, 11.01)
        XCTAssertEqual(m["timeToInteractive"]!.value, 0.8, accuracy: 1e-9)
        XCTAssertNil(m["coldLaunchTime"])
    }

    func testAnInterruptionKeepsWhatWasShownBeforeIt() {
        var interrupted = marks
        interrupted[.interactive] = nil
        let after = ExactLaunch.metricMarks(interrupted, launchType: "cold", interruptedAt: 11.2)
        XCTAssertEqual(Set(after.keys), ["coldLaunchTime", "timeToFirstRender"], "the first frame came before the background")
        let before = ExactLaunch.metricMarks(interrupted, launchType: "cold", interruptedAt: 11.005)
        XCTAssertEqual(Set(before.keys), ["coldLaunchTime"], "a frame presented after the background was not seen")
        XCTAssertEqual(ExactLaunch.metricMarks([.process: 1], launchType: "cold", interruptedAt: nil).count, 0, "nothing before didFinishLaunching")
    }

    func testFrameStatsUseObservesThresholds() {
        var f = FrameStats()
        XCTAssertTrue(f.params.isEmpty, "no frame timed")
        let target = 1.0 / 60
        var t = 0.0
        f.add(at: t, target: target)
        for _ in 0..<10 { t += target; f.add(at: t, target: target) }
        t += 3 * target; f.add(at: t, target: target)
        t += 0.75; f.add(at: t, target: target)
        XCTAssertEqual(f.timed, 12)
        XCTAssertEqual(f.slow, 2, "at 17 ms or more")
        XCTAssertEqual(f.frozen, 1, "at 700 ms or more")
        XCTAssertEqual(f.delay, 2 * target + (0.75 - target), accuracy: 1e-9)
        XCTAssertEqual(f.params["expo.frameRate.slowFrames"] as? Int, 2)
        XCTAssertEqual(f.params["expo.frameRate.frozenFrames"] as? Int, 1)
        f.add(at: t, target: target)
        XCTAssertEqual(f.timed, 12, "a repeated timestamp is no frame")
    }

    func testAScreenIsAVisitAtItsURLShownWhenPresented() {
        var h = ScreenHistory()
        // "shown interactive" before the change, or "same" when it leaves the screen on top.
        func change(_ visit: UInt64, _ url: String, removed: [UInt64] = []) -> String {
            guard let c = h.change(visit: visit, url: url, removed: removed) else { return "same" }
            return "\(c.shown ? "shown" : "new") \(c.interactive ? "used" : "unused")"
        }
        XCTAssertEqual(change(1, "/"), "new unused", "the launch screen")
        h.markShown()
        h.markInteractive()
        XCTAssertEqual(change(2, "/settings"), "new unused")
        XCTAssertEqual(change(2, "/settings"), "same", "still on top: no navigation")
        XCTAssertEqual(change(1, "/"), "shown used", "back to a screen shown and used before")
        XCTAssertEqual(change(2, "/settings"), "new unused", "superseded before its frame: still cold")
        h.markShown(visit: 2, url: "/settings")
        XCTAssertEqual(change(1, "/"), "shown used")
        XCTAssertEqual(change(2, "/settings"), "shown unused", "shown but never interactive: a warm return still measures TTI")
        XCTAssertEqual(change(1, "/developer"), "new unused", "a replace that shows another URL")
        h.markShown()
        XCTAssertEqual(change(3, "/photo/p1"), "new unused")
        h.markShown()
        h.markInteractive()
        XCTAssertEqual(change(1, "/developer", removed: [3]), "shown unused")
        XCTAssertEqual(change(3, "/photo/p1"), "new unused", "a removed visit's screens are forgotten")
    }
}
