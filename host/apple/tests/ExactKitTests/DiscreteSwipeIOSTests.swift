#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest
@testable import ExactKit

/// LLP 1057.001 §8 on UIKit: `swipe` is a `UISwipeGestureRecognizer` per
/// direction the node names, taking its `touch-count`; it waits for a scroll
/// view's pan only where that pan would begin, and an outer swipe for an
/// inner one; a finger's flick passes a text editor, a pointer's does not,
/// and a selection moved during the contact refuses it. UIKit synthesizes no
/// touches for a unit test, so the tests hand the recognizers theirs.
final class DiscreteSwipeIOSTests: XCTestCase {
    private var window: UIWindow!

    private func host(_ ops: [[String: Any]]) -> Presenter {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        p.apply(wireBatch(ops))
        window.makeKeyAndVisible()
        return p
    }
    private func swipes(_ node: NodeView) -> [DiscreteSwipe] { node.gestureRecognizers?.compactMap { $0 as? DiscreteSwipe } ?? [] }

    /// A touch of the kind and on the view the test names.
    private final class Touch: UITouch {
        let on: UIView, kind: UITouch.TouchType, at: TimeInterval
        init(on: UIView, kind: UITouch.TouchType = .direct, at: TimeInterval = 10) { self.on = on; self.kind = kind; self.at = at; super.init() }
        override var view: UIView? { on }
        override var type: UITouch.TouchType { kind }
        override var timestamp: TimeInterval { at }
    }

    func testASwipeIsOneRecognizerPerDirectionAndTakesItsCount() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down up", "touchCount": "2"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
        ])
        let node = try XCTUnwrap(p.views[1])
        XCTAssertEqual(swipes(node).map(\.direction), [.down, .up])
        XCTAssertEqual(swipes(node).map(\.numberOfTouchesRequired), [2, 2])
        let before = swipes(node)
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["swipeDirection": "left"], "clear": ["touchCount"]]]))
        XCTAssertEqual(swipes(node).map(\.direction), [.left])
        XCTAssertEqual(swipes(node).map(\.numberOfTouchesRequired), [1], "omitted: UIKit's own, one finger")
        XCTAssertTrue(before.allSatisfy { $0.view == nil }, "a new configuration makes new recognizers")

        // Only the node's current recognizers speak for it (`swiped`)
        XCTAssertTrue(node.discreteSwipes.contains { $0 === swipes(node)[0] })
        XCTAssertFalse(node.discreteSwipes.contains { $0 === before[0] })
    }

    func testASwipeWaitsForAScrollViewsPanOnlyWhereItWouldScroll() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down right"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
        ])
        let node = try XCTUnwrap(p.views[1])
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        node.addSubview(scroll)
        let down = try XCTUnwrap(swipes(node).first { $0.word == "down" }), right = try XCTUnwrap(swipes(node).first { $0.word == "right" })
        XCTAssertTrue(node.admitsSwipe(down, Touch(on: scroll)))
        XCTAssertTrue(node.admitsSwipe(right, Touch(on: scroll)))
        scroll.contentSize = CGSize(width: 300, height: 400)
        XCTAssertTrue(node.swipeRequiresFailure(down, of: scroll.panGestureRecognizer), "it scrolls down: scroll wins")
        XCTAssertFalse(node.swipeRequiresFailure(right, of: scroll.panGestureRecognizer), "it does not scroll sideways")
        scroll.contentSize = CGSize(width: 300, height: 100)
        XCTAssertFalse(node.swipeRequiresFailure(down, of: scroll.panGestureRecognizer), "its content fits")
        scroll.alwaysBounceVertical = true
        XCTAssertTrue(node.swipeRequiresFailure(down, of: scroll.panGestureRecognizer), "it bounces")
    }

    func testAnOuterSwipeWaitsForAnInnerOneInTheSameDirectionAndCount() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down left"]],
            ["op": "create", "id": 2, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 300.0, "h": 100.0],
        ])
        let outer = try XCTUnwrap(p.views[1]), inner = try XCTUnwrap(p.views[2])
        let innerDown = try XCTUnwrap(swipes(inner).first)
        XCTAssertTrue(outer.swipeRequiresFailure(try XCTUnwrap(swipes(outer).first { $0.word == "down" }), of: innerDown))
        XCTAssertFalse(outer.swipeRequiresFailure(try XCTUnwrap(swipes(outer).first { $0.word == "left" }), of: innerDown))
        XCTAssertFalse(inner.swipeRequiresFailure(innerDown, of: try XCTUnwrap(swipes(outer).first)), "the inner one waits for no ancestor")
    }

    func testAFingerPassesAnEditorAndASelectionMovedSinceItWentDownRefusesTheSwipe() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down"]],
            ["op": "create", "id": 2, "kind": "textarea", "props": ["value": "Hello"]],
            ["op": "create", "id": 3, "kind": "button", "handlers": ["press"]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 300.0, "h": 100.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 120.0, "w": 60.0, "h": 40.0],
        ])
        let bar = try XCTUnwrap(p.views[1]), field = try XCTUnwrap(p.views[2]), button = try XCTUnwrap(p.views[3])
        let text = try XCTUnwrap(field.textArea)
        let down = try XCTUnwrap(swipes(bar).first)
        XCTAssertTrue(bar.admitsSwipe(down, Touch(on: text)), "a finger's flick on the field is the bar's")
        XCTAssertFalse(bar.admitsSwipe(down, Touch(on: text, kind: .indirectPointer)), "a pointer's drag selects")
        XCTAssertFalse(bar.admitsSwipe(down, Touch(on: text, kind: .pencil)))
        XCTAssertFalse(bar.admitsSwipe(down, Touch(on: button)), "a press between keeps the contact")
        down.reset()
        XCTAssertTrue(bar.admitsSwipe(down, Touch(on: text, at: 10)))
        XCTAssertTrue(down.editor === field)
        field.selectionMovedAt = 9
        XCTAssertTrue(bar.swipeMayBegin(down), "moved before the contact")
        field.selectionMovedAt = 11
        XCTAssertFalse(bar.swipeMayBegin(down), "moved during the contact: the editor's")
    }

    /// The agent's `tap … swipe` (§8.7): UIKit synthesizes no touch, so the
    /// swipe is recognized at its start once a finger there would reach the
    /// node's recognizer, and refused, naming why and sending nothing, when
    /// it would not; `check` asks only, for the touch runner's real swipe.
    func testTheAgentsSwipeIsRecognizedWhereAFingersWouldReachTheNode() throws {
        let session = ExactApp.shared.makeSession(label: "discrete-swipe-agent")
        defer { session.destroy() }
        let p = session.presenter
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let win = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        win.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        win.rootViewController = UIViewController()
        win.makeKeyAndVisible()
        defer { win.isHidden = true }
        p.viewport.frame = win.bounds
        win.rootViewController?.view.addSubview(p.viewport)
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left right"]],
            ["op": "create", "id": 2, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left"]],
            ["op": "create", "id": 3, "kind": "button", "handlers": ["press"]],
            ["op": "create", "id": 4, "kind": "view", "style": ["overflow_x": "scroll", "overflow_y": "hidden"]],
            ["op": "create", "id": 5, "kind": "view"],
            ["op": "create", "id": 6, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "up", "touchCount": "2"]],
            ["op": "children", "id": 4, "ids": [5]], ["op": "children", "id": 1, "ids": [2, 3, 4, 6]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 500.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 400.0, "h": 100.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 120.0, "w": 60.0, "h": 40.0],
            ["op": "frame", "id": 4, "x": 0.0, "y": 200.0, "w": 400.0, "h": 100.0],
            ["op": "frame", "id": 5, "x": 0.0, "y": 0.0, "w": 800.0, "h": 100.0],
            ["op": "content", "id": 4, "w": 800.0, "h": 100.0],
            ["op": "frame", "id": 6, "x": 0.0, "y": 400.0, "w": 400.0, "h": 100.0],
        ]))
        p.viewport.layoutIfNeeded()
        var sent: [String] = []
        p.onSwipe = { sent.append("\($0) \($1)") }
        let agent = Agent(session: session)
        let error = { (req: [String: Any]) in agent.tap(req)["error"] as? String ?? "" }
        XCTAssertEqual(agent.tap(["id": 2, "swipe": "left"])["delivery"] as? String, "recognized")
        XCTAssertNil(agent.tap(["id": 1, "swipe": "right", "at": [200.0, 180.0]])["error"])
        XCTAssertNil(agent.tap(["id": 6, "swipe": "up"])["error"], "recognized at its count")
        XCTAssertEqual(sent, ["2 left", "1 right", "6 up"])
        XCTAssertTrue(error(["id": 1, "swipe": "left", "at": [200.0, 50.0]]).contains("#2, nearer"))
        XCTAssertTrue(error(["id": 1, "swipe": "right", "at": [30.0, 140.0]]).contains("keeps the contact"), "the button")
        XCTAssertTrue(error(["id": 1, "swipe": "left", "at": [200.0, 250.0]]).contains("scrolls that way"))
        XCTAssertTrue(error(["id": 1, "swipe": "right", "at": [5.0, 180.0]]).contains("leading edge"))
        XCTAssertTrue(error(["id": 1, "swipe": "up"]).contains("takes no swipe to the up"))
        XCTAssertEqual(agent.tap(["id": 1, "swipe": "right", "at": [200.0, 180.0], "check": true])["checked"] as? Bool, true)
        XCTAssertTrue(error(["id": 6, "swipe": "up", "check": true]).contains("one finger"))
        XCTAssertEqual(sent.count, 3, "a refusal or a check sends nothing")
    }
}
#endif
