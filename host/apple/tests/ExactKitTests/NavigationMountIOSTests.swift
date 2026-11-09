#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

extension NavigationBasicsIOSTests {
    func testTheDocumentLeavesItsMountWithTheNativeContainerUnderCover() throws {
        guard hostedWindowScene() != nil else {
            throw missing("scene", "the native container needs the hosted window")
        }
        let session = try fixture("mount-under-cover", plan: "EXACT_NAVIGATION_BARS_PLAN"), p = session.presenter
        let app = try node(session, "app"), route = try node(session, "route-start")
        p.apply(wireBatch([["op": "props", "id": Int(app.id), "set": ["viewportFit": "cover"]]]))
        let view = try XCTUnwrap(session.view)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let hearsTouches = { (host: UIView) in host.gestureRecognizers?.contains { $0 is PopoverTouch } == true }
        XCTAssertTrue(p.documentFixed)
        XCTAssertTrue(p.viewport.accessibilityElementsHidden, "the empty backing viewport is excluded")
        XCTAssertFalse(p.documentMount.accessibilityElementsHidden, "the document mount does not exclude its content")
        XCTAssertTrue(hearsTouches(p.documentMount))
        let frame = p.viewport.frame
        for turn in 0..<3 {
            let previous = try XCTUnwrap(p.navigation.primaryOwner)
            // Every route leaves the root, which retires the container.
            p.apply(wireBatch([["op": "children", "id": Int(app.id), "ids": []]]))
            view.layoutIfNeeded()
            XCTAssertNil(p.navigation.primaryOwner)
            XCTAssertEqual(p.viewport.frame, frame, "under cover the session's area is the same without the container")
            XCTAssertFalse(p.documentFixed, "the document leaves its mount with the container")
            XCTAssertTrue(p.root.superview === p.viewport)
            XCTAssertTrue(p.viewport.isScrollEnabled)
            XCTAssertFalse(p.viewport.accessibilityElementsHidden, "the page is exposed again")
            XCTAssertTrue(hearsTouches(p.viewport) && !hearsTouches(p.documentMount), "light dismissal hears the document where it is")
            if turn < 2 {
                p.apply(wireBatch([["op": "children", "id": Int(app.id), "ids": [Int(route.id)]]]))
                view.layoutIfNeeded()
                let installed = try XCTUnwrap(p.navigation.primaryOwner)
                XCTAssertFalse(installed === previous)
                XCTAssertTrue(route.isDescendant(of: p.documentMount))
                XCTAssertTrue(p.viewport.accessibilityElementsHidden)
                XCTAssertFalse(p.documentMount.accessibilityElementsHidden)
                XCTAssertTrue(hearsTouches(p.documentMount) && !hearsTouches(p.viewport))
            }
        }
    }

    func testReplacingANativeRootWithPageContentAndAnEmptyRootRestoresAccessibility() throws {
        guard hostedWindowScene() != nil else {
            throw missing("scene", "replacing a native root needs the hosted window")
        }
        let session = try fixture("mount-root-replacement", plan: "EXACT_NAVIGATION_BARS_PLAN"), p = session.presenter
        let app = try node(session, "app"), route = try node(session, "route-start"), content = try node(session, "content-start")
        let children = route.container.subviews.compactMap { ($0 as? NodeView).map { Int($0.id) } }
        let previous = try XCTUnwrap(p.navigation.primaryOwner)
        XCTAssertTrue(p.viewport.accessibilityElementsHidden)
        p.apply(wireBatch([["op": "roots", "ids": [Int(content.id)]]]))
        XCTAssertNil(p.navigation.primaryOwner)
        XCTAssertNil(previous.parent)
        XCTAssertTrue(content.superview === p.root)
        XCTAssertTrue(p.root.superview === p.viewport)
        XCTAssertFalse(p.viewport.accessibilityElementsHidden)
        p.apply(wireBatch([["op": "roots", "ids": []]]))
        XCTAssertTrue(p.root.subviews.isEmpty)
        XCTAssertNil(p.navigation.primaryOwner)
        XCTAssertFalse(p.viewport.accessibilityElementsHidden)
        p.apply(wireBatch([
            ["op": "children", "id": Int(route.id), "ids": children],
            ["op": "roots", "ids": [Int(app.id)]],
        ]))
        let installed = try XCTUnwrap(p.navigation.primaryOwner)
        XCTAssertFalse(installed === previous)
        XCTAssertTrue(content.isDescendant(of: installed.view))
        XCTAssertTrue(p.root.superview === p.documentMount)
        XCTAssertTrue(p.viewport.accessibilityElementsHidden)
        XCTAssertFalse(p.documentMount.accessibilityElementsHidden)
    }

    func testViewportAccessibilityFollowsDocumentReplacementAndPlainPageBoot() throws {
        guard hostedWindowScene() != nil else {
            throw missing("scene", "native containment needs the hosted window")
        }
        let session = try fixture("mount-replacement", plan: "EXACT_HEADLESS_PLAN"), p = session.presenter
        let view = try XCTUnwrap(session.view)
        XCTAssertNil(p.navigation.primaryOwner)
        XCTAssertTrue(p.root.superview === p.viewport)
        XCTAssertFalse(p.viewport.accessibilityElementsHidden, "a page booted without a native container is exposed")
        for key in ["EXACT_NAVIGATION_BARS_PLAN", "EXACT_FIXTURE_PLAN", "EXACT_HEADLESS_PLAN", "EXACT_NAVIGATION_BARS_PLAN", "EXACT_HEADLESS_PLAN"] {
            let previous = p.navigation.primaryOwner
            let path = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
            let plan = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertNil(session.boot(plan: plan, size: view.bounds.size).error)
            view.layoutIfNeeded()
            if key == "EXACT_HEADLESS_PLAN" {
                XCTAssertNil(p.navigation.primaryOwner)
                XCTAssertTrue(p.root.superview === p.viewport)
                XCTAssertTrue(p.viewport.isScrollEnabled)
                XCTAssertFalse(p.viewport.accessibilityElementsHidden)
            } else {
                waitFor("the replacement document has its native owner") {
                    p.navigation.primaryOwner != nil && p.navigation.primaryOwner !== previous && !p.navigation.inTransition
                }
                let owner = try XCTUnwrap(p.navigation.primaryOwner)
                if key == "EXACT_FIXTURE_PLAN" { XCTAssertTrue(owner is UITabBarController) }
                else { XCTAssertTrue(owner is UINavigationController) }
                XCTAssertTrue(p.root.superview === p.documentMount)
                XCTAssertFalse(p.viewport.isScrollEnabled)
                XCTAssertTrue(p.viewport.accessibilityElementsHidden)
                XCTAssertFalse(p.documentMount.accessibilityElementsHidden)
                XCTAssertTrue(owner.view.isDescendant(of: p.documentMount))
            }
            if let previous {
                XCTAssertNil(previous.parent)
                XCTAssertNil(previous.viewIfLoaded?.window)
                XCTAssertFalse(p.navigation.primaryOwner === previous)
            }
            XCTAssertFalse(p.root.accessibilityElementsHidden, "replacing the document never hides its content")
            XCTAssertFalse(p.root.subviews.isEmpty)
        }
    }

    func testViewportAccessibilityFollowsUnmountingAndANewEnclosingTabHost() throws {
        guard hostedWindowScene() != nil else {
            throw missing("scene", "remounting needs the hosted window")
        }
        let session = try fixture("mount-new-host", plan: "EXACT_NAVIGATION_BARS_PLAN"), p = session.presenter
        let view = try XCTUnwrap(session.view), window = try XCTUnwrap(view.window)
        for _ in 0..<2 {
            let previous = try XCTUnwrap(p.navigation.primaryOwner)
            XCTAssertTrue(p.viewport.accessibilityElementsHidden)
            view.removeFromSuperview()
            XCTAssertNil(p.navigation.primaryOwner)
            XCTAssertNil(previous.parent)
            XCTAssertTrue(p.root.superview === p.viewport)
            XCTAssertTrue(p.viewport.isScrollEnabled)
            XCTAssertFalse(p.viewport.accessibilityElementsHidden)

            let host = UIViewController(), tabs = UITabBarController()
            tabs.setViewControllers([host], animated: false)
            window.rootViewController = tabs
            host.view.addSubview(view)
            view.frame = host.view.bounds
            view.layoutIfNeeded()
            waitFor("the native owner returns under the new host") {
                p.navigation.primaryOwner?.parent === host && !p.navigation.inTransition
            }
            let installed = try XCTUnwrap(p.navigation.primaryOwner)
            XCTAssertFalse(installed === previous)
            XCTAssertTrue(installed is UINavigationController)
            XCTAssertTrue(p.root.superview === p.documentMount)
            XCTAssertTrue(p.viewport.accessibilityElementsHidden)
            XCTAssertFalse(p.documentMount.accessibilityElementsHidden)
            XCTAssertTrue(installed.view.isDescendant(of: p.documentMount))
        }
    }
}
#endif
