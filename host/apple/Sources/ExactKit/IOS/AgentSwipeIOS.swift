#if os(iOS) || os(tvOS)
import UIKit

// LLP 1057.001 §8.7 on UIKit: `tap <target> swipe <direction> [at <x> <y>]`.
// UIKit synthesizes no touch, so the swipe is delivered `recognized`, once a
// finger there would reach the node's own recognizer, asked by the predicates
// its recognizers' delegate asks (`DiscreteSwipeIOS.swift`). With `check` the
// driver's touch runner swipes for real instead (`--touch platform`): one
// finger, 120 points that way over 100 ms, a path that must stay inside the
// window. On tvOS the remote's swipe goes to the node holding the focus.
extension Agent {
    func swipeTap(_ req: [String: Any], _ delivered: ([String: Any], UIView?) -> [String: Any]) -> [String: Any] {
        guard let word = req["swipe"] as? String, ["left", "right", "up", "down"].contains(word) else {
            return ["malformed": true, "error": "swipe: expected left, right, up or down"]
        }
        guard let v = view(req), let win = v.window else { return miss(req) }
        let named = "tap #\(v.id) swipe \(word)"
        guard !v.disabled, let swipe = v.discreteSwipes.first(where: { $0.word == word }) else {
            return ["error": "\(named): it takes no swipe to the \(word)\(v.disabled ? " while disabled" : ""); its `swipe-direction` names the directions"]
        }
        let check = req["check"] as? Bool == true
        if check, let touches = swipe.touches, touches > 1 {
            return ["error": "\(named): the touch runner swipes with one finger, and its swipe takes \(touches)"]
        }
        var reply: [String: Any] = ["tapped": Int(v.id), "swipe": word]
        #if os(tvOS)
        guard let focused = UIFocusSystem.focusSystem(for: win)?.focusedItem as? UIView, focused === v || focused.isDescendant(of: v) else {
            return ["error": "\(named): the remote's swipe goes where the focus is, and the focus is not in it"]
        }
        presenter.swipe(v.id, word)
        reply["delivery"] = "recognized"
        return delivered(reply, v)
        #else
        if req["at"] != nil {
            guard let at = req["at"] as? [Double], at.count == 2, at.allSatisfy(\.isFinite) else { return ["error": "tap at needs two finite numbers"] }
        }
        guard let start = tapPoint(req, node: v) else { return ["error": "\(named): it has no box on screen"] }
        let whole = box(v)
        guard whole.contains(start) else {
            return ["error": "\(named) at: (\(Agent.r2(start.x - whole.minX)), \(Agent.r2(start.y - whole.minY))) is outside its \(Agent.r2(whole.width))×\(Agent.r2(whole.height)) box"]
        }
        let vp = presenter.viewport
        let p = vp.convert(CGPoint(x: start.x + vp.pageOrigin.x, y: start.y + vp.pageOrigin.y), to: nil)
        reply["at"] = [Agent.r2(start.x), Agent.r2(start.y)]
        awaitAppOverlay(at: p, in: win)
        let seen = win.hitTest(p, with: nil)
        if let why = offscreen(v, box: CGRect(origin: start, size: .zero), hit: seen) { return ["error": "\(named): \(why)"] }
        let hit = seen ?? v
        if let why = obscured(v, at: p, hit: hit) { return ["error": "\(named): \(why)"] }
        if let why = swipeRefusal(v, swipe, hit: hit, at: p, in: win, path: check) { return ["error": "\(named): \(why)"] }
        if check { reply["checked"] = true; return reply }
        presenter.swipe(v.id, word)
        reply["delivery"] = "recognized"
        return delivered(reply, hit)
        #endif
    }

    #if os(iOS)
    /// Why a finger at `p` in the window, landing on `hit`, would not be
    /// `swipe`'s, or nil (§8.4, §8.7).
    private func swipeRefusal(_ v: NodeView, _ swipe: DiscreteSwipe, hit: UIView, at p: CGPoint, in win: UIWindow, path: Bool) -> String? {
        let leading = win.effectiveUserInterfaceLayoutDirection == .rightToLeft ? win.bounds.width - p.x : p.x
        if Double(leading) < Gesture.edge { return "it starts at the screen's leading edge, which the system's Back keeps (rule 1)" }
        if CanvasInputs.owns(hit) { return "a canvas that takes input has the touch" }
        // Up the hit path to the node: it must be on it, and nothing between may keep the contact
        var at: UIView? = hit
        while let current = at, current !== v {
            if let node = current as? NodeView, node.discreteSwipes.contains(where: { $0.word == swipe.word && $0.touches == swipe.touches }) {
                return "#\(node.id), nearer on the hit path, takes that swipe (rule 3)"
            }
            at = current.superview
        }
        if at == nil { return "\((hit as? NodeView).map { "#\($0.id)" } ?? "a \(Swift.type(of: hit))") is hit there and is not inside it, so its recognizers would not see the touch" }
        if v.pressBoundary(from: hit, editors: false) { return "a `press` between the hit and it keeps the contact (rule 3)" }
        // Scroll views and continuous recognizers on the whole hit path begin first and take the contact
        let travel = DiscreteSwipe.travel(swipe.word), vertical = travel.y != 0
        at = hit
        while let current = at {
            if let scroll = current as? UIScrollView, NodeView.scrolls(scroll, travel: travel, from: win.convert(p, to: scroll)) {
                let owner = sequence(first: scroll as UIView, next: { $0.superview }).lazy.compactMap { $0 as? NodeView }.first
                return "\(owner.map { "#\($0.id)'s scroll view" } ?? "a \(Swift.type(of: scroll))") scrolls that way and takes the contact (§8.4)"
            }
            if let node = current as? NodeView, !node.disabled {
                // As their `gestureRecognizerShouldBegin` asks (`NodeViewIOS.swift`): a `pan` with an `auto` or
                // `manipulation` `touch-action` begins any way, another where its `touch-action` leaves no pan to
                // the scroller; a `swiperight` as `SwipeRecognition` accepts the travel, there too
                let action = node.style["touch_action"]?.string ?? "auto"
                let pans = node.layoutPanRecognizer != nil && SwipeInput.allows(node)
                    && (action == "auto" || action == "manipulation" || !node.allowsTouchPan(travel))
                let swipesRight = node.swipeRecognizer != nil && !node.allowsTouchPan(travel)
                    && SwipeRecognition.accepts(x: Double(travel.x) * 1000, y: Double(travel.y) * 1000, presentedX: Double(node.translate.x))
                let drags = node.transformRecognizer != nil || (vertical && (node.reorderPan != nil || node.heightRecognizer != nil))
                if pans || swipesRight || drags { return "#\(node.id)'s drag on the hit path begins that way and takes the contact (§8.4)" }
            }
            at = current.superview
        }
        if path {
            let end = CGPoint(x: p.x + travel.x * 120, y: p.y + travel.y * 120)
            if !win.bounds.contains(end) { return "the touch runner's 120-point path leaves the window" }
        }
        return nil
    }
    #endif
}
#endif
