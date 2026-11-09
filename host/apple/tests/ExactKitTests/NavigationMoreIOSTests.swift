#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// LLP 1075.003 §3.7 over more root tabs than an iPhone's tab bar shows
/// (`more-tabs.contract`), so UIKit lists the last ones under its More item.
/// UIKit's selection is the state and the router follows it; the bar is
/// driven as a tap drives it (`tapTab`).
final class NavigationMoreIOSTests: XCTestCase {
    private var window: UIWindow?
    private var sessions: [ExactSession] = []
    private var animationsWereEnabled = true

    override func setUp() {
        super.setUp()
        // Hostless UIKit does not finish an animated tab selection.
        animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        for session in sessions { session.destroy() }
        sessions = []
        window?.isHidden = true
        window = nil
        UIView.setAnimationsEnabled(animationsWereEnabled)
        super.tearDown()
    }

    /// A tab's press that moves the router to a third tab, neither the one
    /// tapped nor the one shown, is the app's answer to the tap: UIKit shows
    /// the router's tab, and the tapped one is not selected.
    func testAPressThatMovesTheRouterToAnotherTabShowsThatTab() throws {
        let session = try fixture("more-redirect")
        let navigation = session.presenter.navigation
        let tabs = try XCTUnwrap(navigation.tabController)
        try tapNode(session, "redirect")
        let redirect = try node(session, "redirect")
        waitFor("Redirect is on") { redirect.accessibleText.contains("Redirecting") }
        tapTab(tabs, 3)
        XCTAssertEqual(navigation.routerTab, 2, "Four's press selected Three")
        let three = try XCTUnwrap(tabs.viewControllers?[2])
        XCTAssertTrue(tabs.selectedViewController === three, "UIKit shows the router's tab")
        XCTAssertTrue(navigation.primaryNavigation === three)
        XCTAssertEqual(three.stackRoutes.count, 1, "Three is built")
    }

    /// A tab not built yet whose root shows no bar is its navigation
    /// controller, empty, its bar hidden; the tap's press fills it before
    /// the call returns.
    func testATapOnATabNotBuiltThatShowsNoBarFillsItsController() throws {
        let session = try fixture("more-barless")
        let navigation = session.presenter.navigation
        let tabs = try XCTUnwrap(navigation.tabController)
        let barless = try XCTUnwrap(tabs.viewControllers?[1] as? UINavigationController, "Barless's panel draws its stack")
        XCTAssertTrue(barless.viewControllers.isEmpty)
        tapTab(tabs, 1)
        XCTAssertTrue(tabs.selectedViewController === barless)
        XCTAssertEqual(navigation.routerTab, 1)
        XCTAssertTrue(navigation.primaryNavigation === barless)
        XCTAssertEqual((barless.viewControllers.first as? RouteController)?.node.props["testId"], "route-barless")
        XCTAssertTrue(barless.isNavigationBarHidden)
        XCTAssertNotNil(barless.viewControllers.first?.view.window)
    }

    /// A tab not built yet gets its routes within the tap, though another
    /// tab's push still runs: its navigation controller is the same one, so
    /// nothing in the tab controller is replaced under that transition.
    func testATabNotBuiltIsBuiltWithinATapDuringAnotherTabsPush() throws {
        let session = try fixture("more-mid-push")
        let navigation = session.presenter.navigation
        let tabs = try XCTUnwrap(navigation.tabController)
        let home = try XCTUnwrap(tabs.viewControllers?[0] as? UINavigationController)
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(false) }
        try tapNode(session, "open-detail")
        waitFor("Home's push runs") { home.transitionCoordinator != nil }
        let unbuilt = try XCTUnwrap(tabs.viewControllers?[2] as? UINavigationController)
        tapTab(tabs, 2)
        let three = try XCTUnwrap(tabs.selectedViewController as? UINavigationController, "Three's navigation controller, built within the tap")
        XCTAssertTrue(three === unbuilt)
        XCTAssertEqual(three.viewControllers.count, 1)
        XCTAssertTrue(navigation.primaryNavigation === three)
    }

    /// More tapped: before its list shows, the runner builds each tab whose
    /// row it lists and whose navigation controller is empty, selecting
    /// none, since a row for an empty navigation controller does nothing
    /// (iOS 27, measured). A plain tab is pushed empty, so it waits.
    func testMoreTappedBuildsTheTabsItListsWithoutSelectingThem() throws {
        let (session, tabs, more) = try moreFixture("more-builds")
        let navigation = session.presenter.navigation
        let five = try XCTUnwrap(tabs.viewControllers?[4] as? UINavigationController)
        let six = try XCTUnwrap(tabs.viewControllers?[5] as? PlainTab, "Six's panel shows one fixed route")
        XCTAssertTrue(five.viewControllers.isEmpty && six.route == nil, "neither is built")
        tapTab(tabs, of: tabs.moreNavigationController)
        XCTAssertEqual((five.viewControllers.first as? RouteController)?.node.props["testId"], "route-five", "Five is built")
        XCTAssertNil(six.route, "Six waits for its row")
        XCTAssertEqual(navigation.routerTab, 0, "the router stays on Home")
        XCTAssertTrue(tabs.selectedViewController === more)
        XCTAssertTrue(more.stackRoutes.isEmpty, "More shows its list")
    }

    /// A row of More's list: UIKit sends no tab delegate call, More's
    /// `willShow` presses the tab, and UIKit moves its routes into More's
    /// stack above its list (iOS 27, measured). The root shows UIKit's Back
    /// to the list.
    func testARowOfMoresListSelectsItsTabAndItsRoutesShowInMore() throws {
        let (session, tabs, more) = try moreFixture("more-row")
        let navigation = session.presenter.navigation
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 4)
        waitFor("the router follows Five") { navigation.routerTab == 4 }
        waitFor("More holds Five's root above its list") { more.stackRoutes.count == 1 && more.transitionCoordinator == nil }
        let root = try XCTUnwrap(more.stackRoutes.first as? RouteController)
        XCTAssertEqual(root.node.props["testId"], "route-five")
        XCTAssertEqual(more.stackFront.count, 1, "UIKit's list stays before them")
        XCTAssertEqual((tabs.viewControllers?[4] as? UINavigationController)?.viewControllers.count, 0, "UIKit moved its routes into More")
        XCTAssertTrue(navigation.primaryNavigation === more)
        XCTAssertTrue(root.pushed, "pushed over the list")
        XCTAssertFalse(more.isNavigationBarHidden)
        XCTAssertTrue(more.navigationBar.topItem === root.navigationItem, "More's bar shows the route's item")
        XCTAssertFalse(root.navigationItem.hidesBackButton, "with UIKit's Back to the list")
        XCTAssertTrue(navigation.primaryRoutes.contains { $0 === root }, "a route of the root's stacks (owner blocks, the status bar's tap)")
    }

    /// A push in a tab under More goes onto More's stack, and UIKit's Back
    /// there is the router's Back. More's own Back on the root goes to its
    /// list, which is no route: the router keeps its tab.
    func testATabUnderMorePushesThereAndItsBackGoesToTheList() throws {
        let (session, tabs, more) = try moreFixture("more-push")
        let navigation = session.presenter.navigation
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 4)
        waitFor("the router follows Five, whose root More holds") { session.presenter.navigation.routerTab == 4 && more.stackRoutes.count == 1 && more.transitionCoordinator == nil }
        try tapNode(session, "open-deeper")
        waitFor("Deeper pushed onto More") { more.stackRoutes.count == 2 && more.transitionCoordinator == nil && !navigation.changing }
        XCTAssertEqual((more.topViewController as? RouteController)?.node.props["testId"], "route-deeper")
        XCTAssertEqual(more.stackFront.count, 1)
        more.popViewController(animated: false)
        waitFor("the router popped Deeper") { (navigation.observation()["stack"] as? [String])?.count == 1 && !navigation.changing }
        XCTAssertEqual(navigation.observation()["route"] as? String, (more.stackRoutes.first as? RouteController)?.key)
        let five = navigation.observation()["route"] as? String
        let swipe = try XCTUnwrap(more.interactivePopGestureRecognizer)
        XCTAssertTrue(navigation.popMayBegin(swipe, from: nil, in: nil, velocity: .zero), "the root's swipe to the list is UIKit's")
        more.popViewController(animated: false)
        waitFor("More shows its list") { more.stackRoutes.isEmpty && !navigation.changing }
        waitForMainQueue()
        XCTAssertEqual(navigation.routerTab, 4, "the list is no tab: the router keeps Five")
        XCTAssertEqual(navigation.observation()["route"] as? String, five, "and its root")
        // Five picked again: UIKit moves its routes back into More, which navigation follows at once
        pickRow(tabs, 4)
        waitFor("More shows Five's root again") { more.topViewController is RouteController && more.transitionCoordinator == nil }
        waitForMainQueue()
        XCTAssertTrue(navigation.primaryNavigation === more, "navigation follows More within its willShow")
        XCTAssertEqual(navigation.observation()["stack"] as? [String], five.map { [$0] })
    }

    /// A width that puts every tab on the bar moves a tab's routes out of
    /// More into its own stack (measured): UIKit's Back there is the
    /// router's Back, as in any stack.
    func testATabLeavingMoreKeepsItsBack() throws {
        let (session, tabs, more) = try moreFixture("more-leave")
        let navigation = session.presenter.navigation
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 4)
        waitFor("the router follows Five, whose root More holds") { session.presenter.navigation.routerTab == 4 && more.stackRoutes.count == 1 && more.transitionCoordinator == nil }
        try tapNode(session, "open-deeper")
        waitFor("Deeper pushed onto More") { more.stackRoutes.count == 2 && more.transitionCoordinator == nil && !navigation.changing }
        tabs.traitOverrides.horizontalSizeClass = .regular
        tabs.view.setNeedsLayout()
        tabs.view.layoutIfNeeded()
        let five = try XCTUnwrap(tabs.viewControllers?[4] as? UINavigationController)
        waitFor("Five's routes are in its own stack, which navigation follows") { five.viewControllers.count == 2 && navigation.primaryNavigation === five }
        five.popViewController(animated: false)
        waitFor("the router popped Deeper") { (navigation.observation()["stack"] as? [String])?.count == 1 && !navigation.changing }
        waitForMainQueue()
        XCTAssertEqual(five.viewControllers.count, 1, "no batch pushes Deeper back")
    }

    /// A row whose tab's press leaves the router where it was is the app
    /// declining: UIKit shows the router's tab again, as for a tap on the bar.
    func testARowWhosePressIsDeclinedShowsTheRoutersTabAgain() throws {
        let (session, tabs, _) = try moreFixture("more-declined")
        let navigation = session.presenter.navigation
        try node(session, "tab-six").handlers.remove("press")
        let home = try XCTUnwrap(tabs.viewControllers?[0])
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 5)
        waitFor("UIKit shows Home again") { tabs.selectedViewController === home }
        XCTAssertEqual(navigation.routerTab, 0)
    }

    /// A plain tab's row: More pushes the tab's own controller, empty, and
    /// its press builds the route into it. More's bar shows the tab's title
    /// with UIKit's Back to the list, and More's swipe back is UIKit's.
    func testAPlainTabUnderMoreShowsUnderMoresBar() throws {
        let (session, tabs, more) = try moreFixture("more-plain")
        let navigation = session.presenter.navigation
        let six = try XCTUnwrap(tabs.viewControllers?[5] as? PlainTab)
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 5)
        waitFor("the router follows Six") { navigation.routerTab == 5 }
        waitFor("More shows Six") { more.topViewController === six && more.transitionCoordinator == nil }
        XCTAssertEqual(six.route?.node.props["testId"], "route-six")
        XCTAssertNotNil(six.route?.view.window)
        XCTAssertTrue(navigation.primaryPlain === six)
        XCTAssertTrue(navigation.activeRoute === six.route)
        XCTAssertFalse(more.isNavigationBarHidden, "More's bar")
        XCTAssertEqual(more.navigationBar.topItem?.title, "Six")
        XCTAssertNotNil(more.navigationBar.backItem, "with UIKit's Back to the list")
        let swipe = try XCTUnwrap(more.interactivePopGestureRecognizer)
        XCTAssertTrue(navigation.popMayBegin(swipe, from: nil, in: nil, velocity: .zero), "More's swipe to its list is UIKit's")
    }

    /// A plain tab on the bar has no navigation bar: its route's header is
    /// content, and the route's cover is its own safe area past the
    /// document's insets, as a route under a hidden bar has (`routeEdges`).
    func testAPlainTabOnTheBarIsCoveredForItsSafeArea() throws {
        let session = try fixture("more-plain-bar")
        let navigation = session.presenter.navigation
        let tabs = try XCTUnwrap(navigation.tabController)
        tabs.traitOverrides.horizontalSizeClass = .regular
        tabs.view.setNeedsLayout()
        tabs.view.layoutIfNeeded()
        let six = try XCTUnwrap(tabs.viewControllers?[5] as? PlainTab)
        waitFor("the bar shows Six") { navigation.barItem(ofTab: 5) != nil }
        tapTab(tabs, 5)
        waitFor("the router follows Six") { navigation.routerTab == 5 && six.route?.view.window != nil }
        let route = try XCTUnwrap(six.route)
        let document = session.presenter.insets
        waitFor("Six's route is covered for its safe area", facts: { "cover \(String(describing: navigation.covers[route.node.id])), safe area \(route.view.safeAreaInsets), document \(document)" }) {
            guard case .edges(let edges)? = navigation.covers[route.node.id] else { return false }
            return abs(edges.top - max(0, route.view.safeAreaInsets.top - document.top)) < 0.5 && edges.top > 0
        }
    }

    /// More tapped while it shows a tab above its root is UIKit's pop to its
    /// list (measured): refused where Back does not go (LLP 1035.001 D1).
    func testMoreTappedAgainAboveARootWhereBackIsRefusedPopsNothing() throws {
        let (session, tabs, more) = try moreFixture("more-reselect")
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 4)
        waitFor("the router follows Five, whose root More holds") { session.presenter.navigation.routerTab == 4 && more.stackRoutes.count == 1 && more.transitionCoordinator == nil }
        try tapNode(session, "open-deeper")
        waitFor("Deeper pushed onto More") { more.stackRoutes.count == 2 && more.transitionCoordinator == nil }
        try node(session, "back-deeper").handlers.remove("press")
        XCTAssertEqual(tabs.delegate?.tabBarController?(tabs, shouldSelect: more), false, "More's pop is refused")
    }

    /// More tapped again while it shows a tab above its root, where Back
    /// goes: UIKit pops More to its list (measured). The routes above the
    /// root that go with it count as a Back to that root; the list is no
    /// route, so the router keeps the tab.
    func testMoreTappedAgainAboveARootTakesTheRouterBackToIt() throws {
        let (session, tabs, more) = try moreFixture("more-retap")
        let navigation = session.presenter.navigation
        tapTab(tabs, of: tabs.moreNavigationController)
        pickRow(tabs, 4)
        waitFor("the router follows Five, whose root More holds") { session.presenter.navigation.routerTab == 4 && more.stackRoutes.count == 1 && more.transitionCoordinator == nil }
        let five = try XCTUnwrap(navigation.observation()["route"] as? String)
        try tapNode(session, "open-deeper")
        waitFor("Deeper pushed onto More") { more.stackRoutes.count == 2 && more.transitionCoordinator == nil && !navigation.changing }
        // More's tap as UIKit performs it (measured): `shouldSelect(more)`, `didSelect` of the tab it shows, then the pop to the list
        XCTAssertEqual(tabs.delegate?.tabBarController?(tabs, shouldSelect: more), true)
        tabs.delegate?.tabBarController?(tabs, didSelect: try XCTUnwrap(tabs.selectedViewController))
        more.popToRootViewController(animated: false)
        waitFor("the router is back on Five's root") { navigation.observation()["route"] as? String == five && !navigation.changing }
        XCTAssertEqual(navigation.routerTab, 4)
        XCTAssertTrue(more.stackRoutes.isEmpty, "More shows its list")
    }

    /// The agent's tap on an authored tab the bar has no item for is the
    /// router's selection, which UIKit shows under More, as selecting the
    /// tab in code does (measured); the reply names More's list.
    func testTheAgentsTapOnATabUnderMoreShowsItThere() throws {
        let (session, tabs, more) = try moreFixture("more-agent")
        let navigation = session.presenter.navigation
        let reply = Agent(session: session).tap(["id": Int(try node(session, "tab-five").id)])
        XCTAssertNil(reply["error"], "\(reply)")
        XCTAssertEqual(reply["native"] as? String, "more-list-row")
        XCTAssertEqual(navigation.routerTab, 4)
        XCTAssertTrue(tabs.selectedViewController === tabs.viewControllers?[4])
        waitFor("the router follows Five, whose root More holds") { session.presenter.navigation.routerTab == 4 && more.stackRoutes.count == 1 && more.transitionCoordinator == nil }
        XCTAssertEqual((more.stackRoutes.first as? RouteController)?.node.props["testId"], "route-five")
        XCTAssertTrue(navigation.primaryNavigation === more)
    }

    /// The more-tabs fixture, skipped where UIKit's bar shows every tab.
    private func moreFixture(_ label: String) throws -> (ExactSession, UITabBarController, UINavigationController) {
        let session = try fixture(label)
        let tabs = try XCTUnwrap(session.presenter.navigation.tabController)
        guard tabs.tabBar.items?.count == 5 else { throw XCTSkip("UIKit's bar shows every tab at this width: there is no More") }
        return (session, tabs, tabs.moreNavigationController)
    }

    /// A row of More's list picked: UIKit selects the tab's controller as
    /// `selectedViewController` set in code does, with no tab delegate call;
    /// More's `willShow` and `didShow` follow in a later turn (measured).
    private func pickRow(_ tabs: UITabBarController, _ index: Int) {
        tabs.selectedViewController = tabs.viewControllers![index]
    }

    private func fixture(_ label: String) throws -> ExactSession {
        let env = ProcessInfo.processInfo.environment
        let plan = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["EXACT_MORE_TABS_PLAN"], "build.mjs --test --ios compiles the more-tabs fixture")))
        let session = ExactApp.shared.makeSession(label: label)
        sessions.append(session)
        let view = ExactView(session: session)
        let host = UIViewController()
        // In the test host's scene when it has one: UIKit presents only from a window a scene holds.
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(view)
        self.window = window
        XCTAssertNil(session.boot(plan: plan, size: frame.size).error)
        view.frame = host.view.bounds
        view.layoutIfNeeded()
        waitFor("the tab container and the selected stack are in the window") {
            let navigation = session.presenter.navigation
            return navigation.tabController?.viewIfLoaded?.window != nil
                && navigation.tabController?.selectedViewController?.viewIfLoaded?.window != nil
                && !Agent(session: session).nativeInFlight()
        }
        return session
    }

    private func node(_ session: ExactSession, _ testId: String) throws -> NodeView {
        try XCTUnwrap(session.presenter.views.values.first { $0.props["testId"] == testId }, "no \(testId)")
    }

    private func tapNode(_ session: ExactSession, _ testId: String) throws {
        _ = Agent(session: session).tap(["id": Int(try node(session, testId).id)])
    }
}
#endif
