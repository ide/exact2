#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// A tab's containers (LLP 1038): each shows the screens it is given, root
/// first, and holds nothing it was not given.
///   bun host/apple/build.mjs --test --ios
final class TabContainersIOSTests: XCTestCase {
    func testStackShowsTheScreensInOrder() {
        let container = StackContainer(UINavigationController())
        let a = UIViewController(), b = UIViewController()
        container.show([a, b])
        XCTAssertEqual(container.navigation.viewControllers, [a, b])
        XCTAssertTrue(container.stack === container.navigation)
        container.show([a])
        XCTAssertEqual(container.navigation.viewControllers, [a])
    }

    func testScreenEmbedsOnlyTheRoot() {
        let container = ScreenContainer()
        let a = UIViewController(), b = UIViewController(), c = UIViewController()
        container.show([a, b])
        XCTAssertEqual(container.children, [a])
        XCTAssertTrue(a.view.superview === container.view)
        XCTAssertNil(container.stack)
        container.show([c])
        XCTAssertEqual(container.children, [c])
        XCTAssertNil(a.parent)
        XCTAssertNil(a.view.superview)
    }

    /// A screen moves from another container without being left in both.
    func testScreenTakesTheRootFromElsewhere() {
        let stack = StackContainer(UINavigationController())
        let a = UIViewController()
        stack.show([a])
        let container = ScreenContainer()
        container.show([a])
        XCTAssertTrue(a.parent === container)
        XCTAssertTrue(stack.navigation.viewControllers.isEmpty)
    }
}
#endif
