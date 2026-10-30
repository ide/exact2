#if os(macOS)
import AppKit

// LLP 1057.001 §8 on AppKit: `swipe` is AppKit's swipe, as the person's
// "Swipe between pages" settings make it. A trackpad's three-finger swipe is
// `swipe(with:)`, up the responder chain from the view under the pointer: a
// node takes it in the directions it names and passes the others up, to the
// window's Back last. A trackpad's two-finger or a Magic Mouse's one-finger
// swipe is tracked from phased scroll events: a gesture every scroller under
// the pointer passes up reaches the page's scroll view, which, an
// `NSScrollView`, hands the root view (`ExactViewMac.scrollWheel(with:)`) a
// gesture whose `began` moves sideways while the root asks for one
// (`wantsScrollEventsForSwipeTracking`), and only that `began`. The root gives
// it to the innermost node under it whose swipe names the way the fingers
// went, before Back. AppKit reports no finger count, so a node that names a
// `touch-count` hears neither.
extension NodeView {
    /// Whether this node takes AppKit's swipe in `word`.
    func takesSwipe(_ word: String) -> Bool {
        handlers.contains("swipe") && props["touchCount"] == nil && !disabled
            && (props["swipeDirection"] ?? "").split(separator: " ").contains { $0 == word }
    }
    package override func swipe(with event: NSEvent) {
        if let word = Self.swipeWord(deltaX: event.deltaX, deltaY: event.deltaY), takesSwipe(word) { presenter?.swipe(id, word); return }
        super.swipe(with: event)
    }
    /// A `swipe(with:)` event's direction, by AppKit's signs: `deltaX` > 0
    /// left, < 0 right; `deltaY` > 0 up, < 0 down.
    static func swipeWord(deltaX: CGFloat, deltaY: CGFloat) -> String? {
        deltaX > 0 ? "left" : deltaX < 0 ? "right" : deltaY > 0 ? "up" : deltaY < 0 ? "down" : nil
    }
    /// The innermost node at `point`, in the window, whose swipe takes `word`.
    static func swipeTarget(at point: NSPoint, in root: NSView, _ word: String) -> NodeView? {
        var view = root.superview.map { root.hitTest($0.convert(point, from: nil)) } ?? nil
        while let v = view, v !== root {
            if let node = v as? NodeView, node.takesSwipe(word) { return node }
            view = v.superview
        }
        return nil
    }
}

/// A node's swipe tracked from scroll events, as `BackSwipe` tracks Back:
/// AppKit's `trackSwipeEvent` follows the gesture to its end, and the swipe
/// goes when it ends on the side it set out for.
final class NodeSwipe {
    unowned let presenter: Presenter
    private(set) var tracking = false
    init(_ presenter: Presenter) { self.presenter = presenter }

    /// AppKit's tracking of the rest of the gesture, whether the person's
    /// settings make a swipe from scroll events, and where the pointer is in
    /// a window; a test's stand in for them.
    var track: (NSEvent, @escaping (CGFloat, NSEvent.Phase, Bool) -> Void) -> Void = { event, handler in
        event.trackSwipeEvent(options: .lockDirection, dampenAmountThresholdMin: -1, max: 1) { amount, phase, complete, _ in
            handler(amount, phase, complete)
        }
    }
    var enabled: () -> Bool = { NSEvent.isSwipeTrackingFromScrollEventsEnabled && !ExactEnv.agentMode }
    var pointer: (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }

    /// The way the fingers went: `scrollingDeltaX` is reported as the person
    /// scrolls, so with natural scrolling a positive one is the fingers
    /// moving right, and without it, left.
    static func word(dx: CGFloat, inverted: Bool) -> String { (inverted ? dx > 0 : dx < 0) ? "right" : "left" }

    /// A scroll event the page passed up: true when it began a node's swipe,
    /// which AppKit then tracks wherever the pointer goes. A sideways
    /// gesture's `began` starts it, at the node under it.
    func scroll(_ event: NSEvent, in root: NSView) -> Bool {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard !tracking, enabled(), !event.phase.isEmpty, event.momentumPhase.isEmpty, dx != 0, abs(dx) > abs(dy) else { return false }
        let word = Self.word(dx: dx, inverted: event.isDirectionInvertedFromDevice)
        guard let node = NodeView.swipeTarget(at: event.locationInWindow, in: root, word) else { return false }
        begin(node, word, event)
        return true
    }
    /// Tracks the gesture for `node`: its swipe goes once, when AppKit says the
    /// gesture ended on the side it set out for; cancelled, or ended back past
    /// where it started, nowhere.
    func begin(_ node: NodeView, _ word: String, _ event: NSEvent) {
        tracking = true
        var side: CGFloat = 0
        track(event) { [weak self, weak node] amount, phase, complete in
            if side == 0, amount != 0 { side = amount < 0 ? -1 : 1 }
            if phase == .ended, amount * side > 0, let node, let presenter = self?.presenter { presenter.swipe(node.id, word) }
            if complete { self?.tracking = false }
        }
    }

    /// Whether a node under the pointer takes a sideways swipe, so the root
    /// asks AppKit for the scroll events its scroll views pass up there.
    func wanted(in root: NSView) -> Bool {
        guard let window = root.window else { return false }
        let at = pointer(window)
        return ["left", "right"].contains { NodeView.swipeTarget(at: at, in: root, $0) != nil }
    }
}
#endif
