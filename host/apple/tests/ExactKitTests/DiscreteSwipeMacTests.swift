#if os(macOS)
import AppKit
import XCTest
@testable import ExactKit

/// LLP 1057.001 §8 on AppKit: a node takes `swipe(with:)` in the directions
/// it names, by AppKit's signs, and only with no `touch-count`, which AppKit
/// does not report; a tracked two-finger swipe goes to the innermost such node
/// under its start, the way the fingers went with natural scrolling on or off,
/// once, when the gesture ends on the side it set out for.
final class DiscreteSwipeMacTests: XCTestCase {
    private var window: NSWindow!

    private func host(_ ops: [[String: Any]]) -> Presenter {
        _ = NSApplication.shared
        let p = Presenter()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = p.viewport
        p.apply(wireBatch(ops))
        return p
    }

    func testANodeTakesAppKitsSwipeInTheDirectionsItNamesWithNoCount() throws {
        XCTAssertEqual(NodeView.swipeWord(deltaX: 1, deltaY: 0), "left")
        XCTAssertEqual(NodeView.swipeWord(deltaX: -1, deltaY: 0), "right")
        XCTAssertEqual(NodeView.swipeWord(deltaX: 0, deltaY: 1), "up")
        XCTAssertEqual(NodeView.swipeWord(deltaX: 0, deltaY: -1), "down")
        XCTAssertNil(NodeView.swipeWord(deltaX: 0, deltaY: 0))
        XCTAssertEqual(NodeSwipe.word(dx: 12, inverted: true), "right", "natural scrolling: the delta follows the fingers")
        XCTAssertEqual(NodeSwipe.word(dx: 12, inverted: false), "left")
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left down"]],
            ["op": "create", "id": 2, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left", "touchCount": "2"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0],
        ])
        let outer = try XCTUnwrap(p.views[1]), inner = try XCTUnwrap(p.views[2])
        XCTAssertTrue(outer.takesSwipe("left"))
        XCTAssertTrue(outer.takesSwipe("down"))
        XCTAssertFalse(outer.takesSwipe("right"))
        XCTAssertFalse(inner.takesSwipe("left"), "AppKit reports no count: a node that names one hears no swipe")
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["disabled": "true"]]]))
        XCTAssertFalse(outer.takesSwipe("left"))
    }

    func testATrackedSwipeGoesToTheInnermostNodeUnderItsStartOnceWhenItEndsOnItsSide() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left right"]],
            ["op": "create", "id": 2, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 200.0, "h": 100.0],
        ])
        let outer = try XCTUnwrap(p.views[1]), inner = try XCTUnwrap(p.views[2])
        let center = { (v: NSView) in v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        XCTAssertTrue(NodeView.swipeTarget(at: center(inner), in: p.viewport, "left") === inner, "the innermost that names it")
        XCTAssertTrue(NodeView.swipeTarget(at: center(inner), in: p.viewport, "right") === outer, "the inner one does not name right")
        XCTAssertTrue(NodeView.swipeTarget(at: center(outer), in: p.viewport, "left") === outer)
        XCTAssertNil(NodeView.swipeTarget(at: center(inner), in: p.viewport, "up"))
        p.nodeSwipe.pointer = { _ in center(inner) }
        XCTAssertTrue(p.nodeSwipe.wanted(in: p.viewport), "a sideways swipe under the pointer: the root asks for the scroll views' events")

        var sent: [(UInt32, String)] = []
        p.onSwipe = { sent.append(($0, $1)) }
        var handler: ((CGFloat, NSEvent.Phase, Bool) -> Void)?
        p.nodeSwipe.track = { _, tracked in handler = tracked }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 14, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        p.nodeSwipe.begin(inner, "left", event)
        XCTAssertTrue(p.nodeSwipe.tracking)
        let tracked = try XCTUnwrap(handler)
        tracked(-0.3, .changed, false)
        XCTAssertTrue(sent.isEmpty, "nothing until the fingers lift")
        tracked(-0.8, .ended, false)
        tracked(-1, [], true)
        XCTAssertEqual(sent.map(\.0), [inner.id])
        XCTAssertEqual(sent.map(\.1), ["left"])
        XCTAssertFalse(p.nodeSwipe.tracking)
        for end in [(CGFloat(-0.1), NSEvent.Phase.cancelled), (CGFloat(0.6), NSEvent.Phase.ended)] {
            handler = nil
            p.nodeSwipe.begin(inner, "left", event)
            let again = try XCTUnwrap(handler)
            again(-0.3, .changed, false)
            again(end.0, end.1, false)
            again(0, [], true)
        }
        XCTAssertEqual(sent.count, 1, "cancelled, or ended back past where it started: nowhere")
    }

    /// Events at the view under the pointer, as AppKit sends a trackpad's: a
    /// three-finger swipe goes up the responder chain to the node; for
    /// phased scroll events the root tracks the swipe of the node under the
    /// gesture's start only when every scroller and node between passes the
    /// gesture up, and the direction is the fingers'.
    func testASwipeGoesUpTheChainToTheNodeAndATrackedOneOnlyPastWhatScrollsOrTakesTheWheel() throws {
        _ = NSApplication.shared
        let session = ExactApp.shared.makeSession(label: "discrete-swipe-chain")
        defer { session.destroy() }
        let p = session.presenter
        let root = ExactView(session: session)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = root
        // A swipe node (1) around a sideways scroller (2) whose content (3) hears the wheel
        let scrolls: [String: Any] = ["overflow_x": "scroll", "overflow_y": "hidden"]
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left right"]],
            ["op": "create", "id": 2, "kind": "view", "style": scrolls],
            ["op": "create", "id": 3, "kind": "view", "handlers": ["wheel"]],
            ["op": "children", "id": 2, "ids": [3]], ["op": "children", "id": 1, "ids": [2]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 200.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 400.0, "h": 200.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 0.0, "w": 800.0, "h": 200.0],
            ["op": "content", "id": 2, "w": 800.0, "h": 200.0],
        ]))
        let content = try XCTUnwrap(p.views[3])
        let start = content.convert(NSPoint(x: 100, y: 100), to: nil)
        let below = NSPoint(x: 200, y: 50)
        var pointer = below
        p.nodeSwipe.pointer = { _ in pointer }
        XCTAssertFalse(p.nodeSwipe.wanted(in: root), "no swipe under the pointer: the page keeps its rubber band")
        XCTAssertFalse(root.wantsScrollEventsForSwipeTracking(on: .horizontal))
        pointer = start
        XCTAssertTrue(root.wantsScrollEventsForSwipeTracking(on: .horizontal), "the page's scroll view passes the gesture up")
        XCTAssertFalse(root.wantsScrollEventsForSwipeTracking(on: .vertical))

        var handler: ((CGFloat, NSEvent.Phase, Bool) -> Void)?
        var sent: [(UInt32, String)] = []
        var prevents = false
        p.nodeSwipe.enabled = { true }
        p.nodeSwipe.track = { _, h in handler = h }
        p.onSwipe = { sent.append(($0, $1)) }
        p.onClipboard = { _, kind, _ in if kind == 37, prevents { p.defaultPrevented = true } }
        // CGEvent's field for natural scrolling, `isDirectionInvertedFromDevice`, is not in its headers
        let invertedField = try XCTUnwrap(CGEventField(rawValue: 137))
        func send(_ phase: Int64, dx: Int32 = 0, dy: Int32 = 0, inverted: Bool = true, at point: NSPoint? = nil) throws {
            let at = point ?? start
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(invertedField, value: inverted ? 1 : 0)
            let event = try XCTUnwrap(Agent.windowEvent(cg, at: at, in: window, flags: []))
            XCTAssertEqual(event.isDirectionInvertedFromDevice, inverted)
            XCTAssertEqual(event.locationInWindow, at)
            let hit = try XCTUnwrap(root.hitTest(try XCTUnwrap(root.superview).convert(at, from: nil)))
            hit.scrollWheel(with: event)
        }
        /// One gesture: its `began`, the first of `moves`, at the start, the
        /// rest at `point`, then the lift; what the root tracked, ended on the
        /// side it set out for.
        func gesture(_ moves: [(Int32, Int32)], inverted: Bool = true, at point: NSPoint? = nil) throws -> String? {
            handler = nil
            let before = sent.count
            for (index, (dx, dy)) in moves.enumerated() { try send(index == 0 ? 1 : 2, dx: dx, dy: dy, inverted: inverted, at: index == 0 ? nil : point) }
            try send(4, inverted: inverted, at: point)
            guard let h = handler else { return nil }
            h(0.5, .changed, false); h(1, .ended, false); h(1, [], true)
            XCTAssertEqual(sent.count, before + 1)
            return sent.last.map { "\($0.0) \($0.1)" }
        }
        // A three-finger swipe goes up the responder chain from the view under
        // the pointer, which the scroll view, able to scroll either way, does not
        // stand in: CoreGraphics' gesture event, of IOHID's swipe type (16) and
        // direction mask (1 up, 2 down, 4 left, 8 right), fields not in its headers
        func swipe(_ mask: Int64) throws {
            let cg = try XCTUnwrap(CGEvent(source: nil))
            cg.type = try XCTUnwrap(CGEventType(rawValue: 29))
            cg.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 110)), value: 16)
            cg.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 115)), value: mask)
            let event = try XCTUnwrap(Agent.windowEvent(cg, at: start, in: window, flags: []))
            XCTAssertEqual(event.type, .swipe)
            window.sendEvent(event)
        }
        let scroll = try XCTUnwrap(p.views[2]?.scroll)
        func scrolled(to x: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scrolled(to: 200)
        try swipe(8)
        try swipe(4)
        try swipe(1)
        XCTAssertEqual(sent.map { "\($0.0) \($0.1)" }, ["1 right", "1 left"], "up is not named: it goes on up the chain")
        sent = []
        // Scrolled to its start, it takes the fingers going left and passes up their going right
        scrolled(to: 0)
        XCTAssertNil(try gesture([(-14, 0), (-10, 0)]), "the scroller has room: it scrolls")
        XCTAssertTrue(ChainingScrollView.latch.owner === scroll, "the gesture is the scroller's (LLP 1070 G1)")
        XCTAssertEqual(try gesture([(14, 0), (10, 0)]), "1 right", "pinned that way: the fingers went right, with natural scrolling")
        XCTAssertEqual(try gesture([(14, 0)], inverted: false), "1 left", "without it the same delta is the fingers going left")
        XCTAssertNil(try gesture([(2, 14), (14, 0)]), "a vertical gesture never, whatever it turns to: AppKit decides at its `began`")
        XCTAssertEqual(try gesture([(14, 0), (2, 14)]), "1 right", "a sideways one is the swipe's")
        XCTAssertNil(try gesture([(0, 0), (14, 0)]), "a `began` that says no direction passes nothing up")
        // Once tracked, the gesture is the node's wherever the pointer goes, as a Magic Mouse's does
        XCTAssertEqual(try gesture([(14, 0), (10, 0)], at: below), "1 right")
        // A `wheel` handler that prevents the default keeps the scroll, as on the web
        prevents = true
        XCTAssertNil(try gesture([(14, 0)]))
        prevents = false
        // Its content fitting, the scroller passes the gesture on, unless its `overscroll-behavior` is `contain`
        p.apply(wireBatch([
            ["op": "frame", "id": 3, "x": 0.0, "y": 0.0, "w": 400.0, "h": 200.0],
            ["op": "content", "id": 2, "w": 400.0, "h": 200.0],
        ]))
        XCTAssertEqual(try gesture([(14, 0)]), "1 right")
        p.apply(wireBatch([["op": "style", "id": 2, "style": scrolls.merging(["overscroll_behavior_x": "contain"]) { $1 }]]))
        XCTAssertNil(try gesture([(14, 0)]))
        XCTAssertFalse(p.nodeSwipe.tracking)
    }

    /// The agent's `tap … swipe` (§8.7): a three-finger swipe event at the
    /// target's middle or `at` in it, which the responder chain carries to the
    /// first node that takes it; refused, having sent nothing, when that is
    /// not the target.
    func testTheAgentsSwipeIsAThreeFingerSwipeUpTheResponderChain() throws {
        _ = NSApplication.shared
        let session = ExactApp.shared.makeSession(label: "discrete-swipe-agent")
        defer { session.destroy() }
        let p = session.presenter
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = ExactView(session: session)
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left right"]],
            ["op": "create", "id": 2, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "left"]],
            ["op": "create", "id": 3, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "up", "touchCount": "2"]],
            // A scroller that can scroll either way, around content that hears the wheel
            ["op": "create", "id": 4, "kind": "view", "style": ["overflow_x": "scroll", "overflow_y": "hidden"]],
            ["op": "create", "id": 5, "kind": "view", "handlers": ["wheel"]],
            ["op": "children", "id": 4, "ids": [5]], ["op": "children", "id": 1, "ids": [2, 3, 4]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 400.0, "h": 100.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 100.0, "w": 400.0, "h": 100.0],
            ["op": "frame", "id": 4, "x": 0.0, "y": 200.0, "w": 400.0, "h": 100.0],
            ["op": "frame", "id": 5, "x": 0.0, "y": 0.0, "w": 800.0, "h": 100.0],
            ["op": "content", "id": 4, "w": 800.0, "h": 100.0],
        ]))
        p.views[4]?.scroll?.contentView.scroll(to: NSPoint(x: 200, y: 0))
        var sent: [String] = []
        p.onSwipe = { sent.append("\($0) \($1)") }
        let agent = Agent(session: session)
        let inner = agent.tap(["id": 2, "swipe": "left"])
        XCTAssertEqual(inner["delivery"] as? String, "platform", "\(inner)")
        XCTAssertNil(agent.tap(["id": 1, "swipe": "right"])["error"], "its middle is past the inner node")
        XCTAssertNil(agent.tap(["id": 1, "swipe": "right", "at": [20.0, 20.0]])["error"], "the inner node names no right: it goes on up")
        XCTAssertNil(agent.tap(["id": 1, "swipe": "left", "at": [200.0, 250.0]])["error"], "inside a scroll view and past a `wheel` handler, as `swipe(with:)` goes")
        XCTAssertEqual(sent, ["2 left", "1 right", "1 right", "1 left"])
        let nearer = agent.tap(["id": 1, "swipe": "left", "at": [20.0, 20.0]])
        XCTAssertTrue((nearer["error"] as? String)?.contains("#2, nearer") == true, "\(nearer)")
        XCTAssertNotNil(agent.tap(["id": 1, "swipe": "up"])["error"])
        XCTAssertNotNil(agent.tap(["id": 3, "swipe": "up"])["error"], "AppKit reports no finger count")
        XCTAssertEqual(agent.tap(["id": 1, "swipe": "sideways"])["malformed"] as? Bool, true)
        XCTAssertEqual(sent.count, 4, "a refusal sends nothing")
    }
}
#endif
