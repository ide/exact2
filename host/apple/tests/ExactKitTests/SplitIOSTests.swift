#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// LLP 1127 §1 on UIKit: collapsed, the split nests the detail's stack in
/// the list's, so a back swipe has both stacks' pop recognizers under the
/// finger. The detail's pops while it holds a route beneath its top; at its
/// root the list's pops, back to the list. The other must not begin, or it
/// takes the swipe and nothing goes back. UIKit, so a simulator runs it:
/// bun host/apple/build.mjs --test --ios
final class SplitIOSTests: XCTestCase {
    private var window: UIWindow?
    private var session: ExactSession?

    override func tearDown() {
        session?.destroy()
        window?.isHidden = true
        window = nil
        session = nil
        super.tearDown()
    }

    private func boot(_ fixture: String = "SPLIT_BACK", size: CGSize = CGSize(width: 402, height: 874)) throws -> ExactSession {
        if ExactEnv.authoredChrome { throw XCTSkip("under the agent's chrome the stack is not split") }
        let plan = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["EXACT_\(fixture)_PLAN"], "build.mjs --test --ios compiles the fixture")))
        let session = ExactApp.shared.makeSession(label: "split-\(UUID().uuidString)") // no state of another test's
        self.session = session
        let view = ExactView(session: session), host = UIViewController()
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(view)
        self.window = window
        XCTAssertNil(session.boot(plan: plan, size: window.bounds.size).error)
        view.frame = host.view.bounds
        view.layoutIfNeeded()
        return session
    }
    private func until(_ what: String, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while !done(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done(), what)
    }
    private func node(_ session: ExactSession, _ testId: String) throws -> NodeView {
        try XCTUnwrap(session.presenter.views.values.first { $0.props["testId"] == testId }, testId)
    }
    /// Whether the runner reads `testId`'s node as inactive (the agent's tree).
    private func inactive(_ session: ExactSession, _ testId: String) throws -> Bool {
        let id = try node(session, testId).id
        let tree = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(session.agent(#"{"op":"tree"}"#).utf8)) as? [String: Any])
        let rows = try XCTUnwrap(tree["nodes"] as? [[String: Any]])
        return rows.first { ($0["id"] as? NSNumber)?.uint32Value == id }?["inactive"] as? Bool == true
    }

    func testACollapsedSplitsBackSwipeIsTheStackWithARouteBeneathItsTop() throws {
        let session = try boot()
        let navigation = session.presenter.navigation, agent = Agent(session: session)
        until("a list whose rows push is a split") { navigation.split != nil && !agent.nativeInFlight() }
        let split = try XCTUnwrap(navigation.split)
        XCTAssertTrue(split.controller.isCollapsed, "an iPhone's width collapses it")
        func begins(_ nav: UINavigationController) throws -> Bool {
            var pop = nav.interactivePopGestureRecognizer
            if #available(iOS 26.0, *) { pop = nav.interactiveContentPopGestureRecognizer ?? pop }
            return navigation.popMayBegin(try XCTUnwrap(pop), from: CGPoint(x: 100, y: 400), in: nav.view, velocity: CGPoint(x: 600, y: 20))
        }
        XCTAssertNil(agent.tap(["id": Int(try node(session, "row-a").id)])["error"])
        until("the book is pushed") { split.shown.count == 2 && !agent.nativeInFlight() }
        XCTAssertTrue(try begins(split.list), "at the detail's root the list's stack pops, back to the list")
        XCTAssertFalse(try begins(split.detail), "the detail's own has nothing beneath its root")

        XCTAssertNil(agent.tap(["id": Int(try node(session, "notes-a").id)])["error"])
        until("the notes are pushed") { split.shown.count == 3 && !agent.nativeInFlight() }
        XCTAssertTrue(try begins(split.detail), "the detail's stack pops its top")
        XCTAssertFalse(try begins(split.list), "the list's would take the whole detail stack")
    }

    /// Whether a stack splits is read again with each batch, its routes
    /// kept: a list whose rows come later makes a split, and a root that
    /// says `navigationSplit="none"` later makes a stack again.
    func testAStackSplitsWhenItsRowsComeAndPushesWhenItsRootSaysNone() throws {
        let session = try boot("SPLIT_CHANGE")
        let navigation = session.presenter.navigation, agent = Agent(session: session)
        until("the stack is up") { navigation.primaryNavigation != nil && !agent.nativeInFlight() }
        XCTAssertNil(navigation.split, "no row pushes yet")
        let root = try XCTUnwrap(navigation.primaryNavigation?.viewControllers.first as? RouteController)
        XCTAssertNil(agent.tap(["id": Int(try node(session, "fill").id)])["error"])
        until("the rows came: a split") { navigation.split != nil && !agent.nativeInFlight() }
        XCTAssertTrue(navigation.split?.list.viewControllers.first === root, "the same route, in the list's column")
        XCTAssertNil(agent.tap(["id": Int(try node(session, "row-a").id)])["error"])
        until("the book is in the detail") { navigation.split?.shown.count == 2 && !agent.nativeInFlight() }
        XCTAssertNil(agent.back()["error"])
        until("back at the list") { navigation.split?.shown.count == 1 && !agent.nativeInFlight() }
        XCTAssertNil(agent.tap(["id": Int(try node(session, "stop").id)])["error"])
        until("the root says none: a stack again") { navigation.split == nil && navigation.primaryNavigation != nil && !agent.nativeInFlight() }
        XCTAssertTrue(navigation.primaryNavigation?.viewControllers.first === root, "the same route, in a stack")
        XCTAssertNil(agent.tap(["id": Int(try node(session, "row-b").id)])["error"])
        until("a row pushes") { navigation.primaryNavigation?.viewControllers.count == 2 && !agent.nativeInFlight() }
    }

    /// LLP 1127 D8: beside the detail the list is live with it; while the
    /// list overlays the detail, only the list is; with the detail alone, or
    /// collapsed, only the detail.
    func testOnlyTheListIsLiveWhileItOverlaysTheDetail() throws {
        let session = try boot(size: CGSize(width: 1100, height: 800))
        let navigation = session.presenter.navigation, agent = Agent(session: session)
        until("a split") { navigation.split != nil && !agent.nativeInFlight() }
        let split = try XCTUnwrap(navigation.split)
        // The size class expands the split or collapses it, whatever the window's width.
        split.controller.traitOverrides.horizontalSizeClass = .regular
        until("expanded") { !split.controller.isCollapsed && !agent.nativeInFlight() }
        XCTAssertNil(agent.tap(["id": Int(try node(session, "row-a").id)])["error"])
        until("the book is in the detail") { split.shown.count == 2 && !agent.nativeInFlight() }
        let cases: [(UIUserInterfaceSizeClass, UISplitViewController.DisplayMode, UISplitViewController.SplitBehavior, Bool, Bool)] = [
            (.regular, .oneBesideSecondary, .tile, false, false),
            (.regular, .oneOverSecondary, .overlay, false, true),
            (.regular, .secondaryOnly, .tile, true, false),
            (.compact, .automatic, .automatic, true, false),
        ]
        for (size, mode, behavior, list, detail) in cases {
            split.controller.traitOverrides.horizontalSizeClass = size
            split.controller.preferredSplitBehavior = behavior
            split.controller.preferredDisplayMode = mode
            let shows = "\(size == .compact ? "collapsed" : "mode \(mode.rawValue)")"
            until("the split is \(shows)") { split.controller.isCollapsed == (size == .compact) && (size == .compact || split.controller.displayMode == mode) && !agent.nativeInFlight() }
            until("\(shows): the list \(list ? "in" : "")active, the detail \(detail ? "in" : "")active") {
                (try? inactive(session, "row-a")) == list && (try? inactive(session, "notes-a")) == detail
            }
            let facts = "beside \(split.beside.map(\.node.id)) under \(split.under.map(\.node.id)) blocks \(session.presenter.owners.told.keys.sorted())"
            XCTAssertEqual(try inactive(session, "row-a"), list, "the list, \(shows): \(facts)")
            XCTAssertEqual(try inactive(session, "notes-a"), detail, "the detail, \(shows): \(facts)")
            XCTAssertEqual(navigation.isInactiveRoute(containing: try node(session, "notes-a")), detail, "the host's, \(shows)")
        }
    }
    /// LLP 1127 §1, item 2: UIKit takes the detail's controller out of the
    /// list's as the split expands (an iPhone Duo unfolded on a book), and
    /// nests it again as it collapses. Neither is a Back: the book stays
    /// shown and live, and Back from it, collapsed, returns to the list.
    func testExpandingAndCollapsingKeepTheDetail() throws {
        let session = try boot()
        let navigation = session.presenter.navigation, agent = Agent(session: session)
        let has = { (testId: String) in session.presenter.views.values.contains { $0.props["testId"] == testId } }
        until("a split") { navigation.split != nil && !agent.nativeInFlight() }
        let split = try XCTUnwrap(navigation.split)
        XCTAssertTrue(split.controller.isCollapsed, "an iPhone's width collapses it")
        XCTAssertNil(agent.tap(["id": Int(try node(session, "row-a").id)])["error"])
        until("the book is pushed") { split.shown.count == 2 && !agent.nativeInFlight() }
        let window = try XCTUnwrap(self.window)
        window.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        window.rootViewController?.view.subviews.first?.frame = window.bounds
        split.controller.traitOverrides.horizontalSizeClass = .regular
        until("expanded") { !split.controller.isCollapsed && !agent.nativeInFlight() }
        until("the book shows beside the list") { split.shown.count == 2 && has("notes-a") }
        XCTAssertFalse(try inactive(session, "notes-a"), "expanded, the book is live")
        split.controller.traitOverrides.horizontalSizeClass = .compact
        until("collapsed") { split.controller.isCollapsed && !agent.nativeInFlight() }
        until("the book is on top") { split.nested && split.shown.count == 2 && has("notes-a") }
        XCTAssertFalse(try inactive(session, "notes-a"), "collapsed, the book is live")
        XCTAssertNil(agent.back()["error"])
        until("back at the list") { split.shown.count == 1 && !has("notes-a") && !agent.nativeInFlight() }
    }
}
#endif
