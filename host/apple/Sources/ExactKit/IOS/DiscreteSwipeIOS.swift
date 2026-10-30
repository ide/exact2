#if os(iOS) || os(tvOS)
import UIKit

// LLP 1057.001 §8 on UIKit: `swipe` is UIKit's own discrete swipe, one
// `UISwipeGestureRecognizer` per direction the node names (one given several
// directions does not say which it saw), taking the node's `touch-count` of
// touches. On tvOS the same recognizers hear the remote's touch surface,
// one touch. A new direction or count makes new recognizers, which fails a
// pending contact's swipe; the old ones dispatch nothing after they go.
final class DiscreteSwipe: UISwipeGestureRecognizer {
    /// The direction, as `SwipeEvent` names it.
    let word: String
    /// The `touch-count` it was made for; nil, the platform's own.
    let touches: Int?
    /// What the contact landed on, recorded as it went down (`admitsSwipe`).
    weak var hit: UIView?
    /// The editor the contact went down in, and when: a change of its
    /// selection since then refuses the swipe (§8.4, rule 3).
    weak var editor: NodeView?
    var began: TimeInterval = 0

    init(_ node: NodeView, word: String, touches: Int?) {
        self.word = word
        self.touches = touches
        super.init(target: node, action: #selector(NodeView.swiped(_:)))
        direction = Self.direction(word)
        #if os(iOS)
        if let touches { numberOfTouchesRequired = touches }
        #endif
    }
    static func direction(_ word: String) -> Direction {
        switch word {
        case "left": return .left
        case "up": return .up
        case "down": return .down
        default: return .right
        }
    }
    /// The finger's travel in its direction, as a pan's velocity reads it.
    var travel: CGPoint { Self.travel(word) }
    static func travel(_ word: String) -> CGPoint {
        switch word {
        case "left": return CGPoint(x: -1, y: 0)
        case "up": return CGPoint(x: 0, y: -1)
        case "down": return CGPoint(x: 0, y: 1)
        default: return CGPoint(x: 1, y: 0)
        }
    }
    override func reset() {
        super.reset()
        hit = nil
        editor = nil
    }
}

extension NodeView {
    /// The recognizers this node's `swipe`, `swipe-direction` and
    /// `touch-count` ask for, made again when any of them changes.
    func updateDiscreteSwipes() {
        let words = handlers.contains("swipe")
            ? (props["swipeDirection"] ?? "").split(separator: " ").map(String.init).filter { ["left", "right", "up", "down"].contains($0) }
            : []
        let touches = props["touchCount"].flatMap(Int.init).flatMap { $0 >= 1 ? $0 : nil }
        #if os(tvOS)
        // The remote's surface is one touch
        let made = touches.map { $0 == 1 } ?? true ? words : []
        #else
        let made = words
        #endif
        let current = discreteSwipes
        if current.map(\.word) == made, current.allSatisfy({ $0.touches == touches }) { return }
        for gesture in current { removeGestureRecognizer(gesture) }
        discreteSwipes = made.map { word in
            let gesture = DiscreteSwipe(self, word: word, touches: touches)
            gesture.delegate = self
            addGestureRecognizer(gesture)
            return gesture
        }
    }
    @objc func swiped(_ gesture: DiscreteSwipe) {
        // Only this node's current recognizers speak for it
        guard gesture.state == .recognized, discreteSwipes.contains(where: { $0 === gesture }) else { return }
        presenter?.swipe(id, gesture.word)
    }
    /// Whether a contact is this swipe's: a direct touch passes a text
    /// editor, as a finger's flick on the composer's field does, and a
    /// pointer's or pencil's stays the editor's, whose drag selects; a press
    /// or control between the hit and the node keeps it (rule 3).
    func admitsSwipe(_ gesture: DiscreteSwipe, _ touch: UITouch) -> Bool {
        if CanvasInputs.owns(touch.view) { return false }
        #if os(iOS)
        let finger = touch.type == .direct
        #else
        let finger = true
        #endif
        if pressBoundary(touch, editors: !finger) { return false }
        if hitsNativeEditor(touch.view), !finger { return false }
        if gesture.numberOfTouches == 0 {
            gesture.hit = touch.view
            gesture.began = touch.timestamp
            gesture.editor = Self.editingNode(touch.view, below: self)
        }
        return true
    }
    /// A swipe may recognize: the node is enabled, and the editor the
    /// contact went down in has not moved its selection since (a handle or
    /// the caret dragged, a double tap's word, the loupe's long press).
    func swipeMayBegin(_ gesture: DiscreteSwipe) -> Bool {
        !disabled && (gesture.editor.map { $0.selectionMovedAt < gesture.began } ?? true)
    }
    /// The swipe waits for each pan that would begin for travel in its
    /// direction: a scroll view's on the contact's hit path, by that view's
    /// own admission (UIKit's, that it scrolls on that axis; Exact's, its
    /// `admitsPan`, or for a textarea that its text overflows), so scroll wins
    /// by construction; and an inner node's swipe in the same direction and
    /// count, so the innermost wins (rule 3).
    func swipeRequiresFailure(_ gesture: DiscreteSwipe, of other: UIGestureRecognizer) -> Bool {
        if let inner = other as? DiscreteSwipe, let owner = inner.view as? NodeView, owner !== self, owner.isDescendant(of: self) {
            return inner.word == gesture.word && inner.touches == gesture.touches
        }
        guard let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer,
              let hit = gesture.hit, hit === scroll || hit.isDescendant(of: scroll) else { return false }
        return Self.scrolls(scroll, travel: gesture.travel, from: gesture.location(in: scroll))
    }
    /// Whether `scroll`'s pan admits `travel` from `start`, in its own space.
    static func scrolls(_ scroll: UIScrollView, travel: CGPoint, from start: CGPoint) -> Bool {
        let vertical = travel.y != 0
        let size = scroll.bounds.inset(by: scroll.adjustedContentInset).size
        let overflows = vertical ? scroll.contentSize.height > size.height + 0.5 : scroll.contentSize.width > size.width + 0.5
        let bounces = vertical ? scroll.alwaysBounceVertical : scroll.alwaysBounceHorizontal
        guard overflows || bounces else { return false }
        if let area = scroll as? TextArea { return !area.fits }
        if let own = scroll as? ScrollView { return own.admitsPan(velocity: travel, translation: travel, start: start) }
        return true
    }
    /// Whether a touch that lands here begins in a one-touch swipe in the
    /// leading-to-trailing direction, which the content pop leaves to it as
    /// it leaves a `swiperight` row's (§8.4).
    var takesLeadingSwipe: Bool {
        let leading = effectiveUserInterfaceLayoutDirection == .rightToLeft ? "left" : "right"
        return !disabled && discreteSwipes.contains { $0.word == leading && ($0.touches ?? 1) == 1 }
    }
    /// The node of the editor `view` is in, below `boundary`.
    static func editingNode(_ view: UIView?, below boundary: UIView) -> NodeView? {
        guard nativeEditor(view, below: boundary) else { return nil }
        var current = view
        while let v = current, v !== boundary {
            if let node = v as? NodeView, node.textArea != nil || node.field != nil { return node }
            current = v.superview
        }
        return nil
    }
}
#endif
