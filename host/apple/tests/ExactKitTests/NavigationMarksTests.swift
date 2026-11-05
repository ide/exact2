#if os(iOS)
import XCTest
import QuartzCore
@testable import ExactKit

final class NavigationMarksTests: XCTestCase {
    func testTheRenderLinkStopsWhileTTIWaitsForWork() throws {
        let session = ExactApp.shared.makeSession(label: "navigation-marks")
        defer { session.destroy() }
        XCTAssertNil(session.boot(plan: try fixturePlan("HEADLESS"), size: CGSize(width: 400, height: 800)).error)
        let marks = NavigationMarks()
        marks.routerChanged(session, payload: ["top": 1, "pattern": "/"])
        session.tickInFlight = true
        defer { session.tickInFlight = false }
        marks.routerChanged(session, payload: ["top": 2, "pattern": "/details"])
        waitFor("the navigation's first frame") { marks.recent.contains { $0.hasPrefix("cold_ttr ") } }
        XCTAssertNil(marks.link, "only the first frame needs a display link")
        XCTAssertFalse(marks.recent.contains { $0.hasPrefix("tti ") }, "native work still holds TTI")
        session.tickInFlight = false
        marks.applied(session)
        waitFor("TTI after the work clears") { marks.recent.contains { $0.hasPrefix("tti ") } }
        XCTAssertNil(marks.link)
        marks.routerChanged(session, payload: ["top": 1, "pattern": "/"])
        waitFor("a warm navigation's first frame") { marks.recent.contains { $0.hasPrefix("warm_ttr ") } }
        XCTAssertNil(marks.link)
        XCTAssertEqual(marks.recent.filter { $0.hasPrefix("tti ") }.count, 1, "a warm navigation has no new TTI")
    }
}
#endif
