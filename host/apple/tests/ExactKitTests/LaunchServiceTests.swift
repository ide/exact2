import XCTest
#if os(iOS)
import UIKit
#endif
@testable import ExactKit

final class LaunchServiceTests: XCTestCase {
    #if os(iOS)
    func testAnInterruptedCommitKeepsWatchingUntilItsPresentation() {
        let launch = ExactLaunch()
        let session = ExactApp.shared.makeSession(label: "interrupted-launch")
        defer { session.destroy() }
        launch.delegateInit()
        launch.didFinishLaunching()
        launch.bootEntered(session)
        launch.treeApplied(session, path: "/")
        launch.drawn(session)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertNotNil(launch.link, "the committed frame still needs its first vsync")
        waitFor("the interrupted launch's first presentation") { launch.marks[.present] != nil }
        XCTAssertNil(launch.link, "the interrupted launch stops watching after first pixel")
    }
    #endif

    func testSuppressedLaunchesStillWaitForFirstPixelBeforeLoadingServices() {
        for when in [ExactServiceLoad.afterFirstPixel, .afterStartup] {
            XCTAssertFalse(ExactLaunch.serviceIsReady(when, presented: false, settled: false, suppressed: true), "prewarming and agent launches have not shown a frame")
            XCTAssertTrue(ExactLaunch.serviceIsReady(when, presented: true, settled: false, suppressed: true), "a suppressed launch can load once it has shown a frame")
        }
        XCTAssertFalse(ExactLaunch.serviceIsReady(.afterStartup, presented: false, settled: true, suppressed: false), "failed activation does not load a service before first pixel")
        XCTAssertTrue(ExactLaunch.serviceIsReady(.afterFirstPixel, presented: true, settled: false, suppressed: false))
        XCTAssertFalse(ExactLaunch.serviceIsReady(.afterStartup, presented: true, settled: false, suppressed: false), "normal startup still waits for interactivity")
        XCTAssertTrue(ExactLaunch.serviceIsReady(.afterStartup, presented: true, settled: true, suppressed: false))
    }
}
