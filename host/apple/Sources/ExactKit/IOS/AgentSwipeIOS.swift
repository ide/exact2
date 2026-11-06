#if os(iOS) || os(tvOS)
import UIKit

extension Agent {
    /// UIKit synthesizes no touch. `check` admits the touch runner's path
    /// without dispatch; otherwise this proves the recognized swipe's wiring.
    func swipeTap(_ req: [String: Any]) -> [String: Any] {
        if let bad = swipeMalformed(req, checking: true) { return bad }
        #if os(tvOS)
        return ["delivery": "unsupported", "reason": "tvOS makes no swipe (LLP 1057.001 §8.2)"]
        #else
        guard panContact == nil, contact == nil, canvasContact == nil else {
            return ["error": "a contact is already down; use `tap up` or `tap cancel` first"]
        }
        settleForPress()
        guard let v = view(req), let win = v.window else { return miss(req) }
        let word = req["swipe"] as! String, named = "tap #\(v.id) swipe \(word)"
        guard SwipeInput.allows(v) else { return ["error": "\(named): it is hidden, disabled or inert"] }
        guard let swipe = v.discreteSwipes.first(where: { $0.word == word && $0.isEnabled }) else {
            return ["error": "\(named): it takes no swipe that way; its `swipe-direction` names the directions"]
        }
        let check = req["check"] as? Bool == true
        if check, swipe.touches != 1 { return ["error": "\(named): the touch runner swipes with one finger, and its swipe takes \(swipe.touches)"] }
        let at = req["at"] as? [Double]
        let local = at.map { CGPoint(x: v.bounds.minX + $0[0], y: v.bounds.minY + $0[1]) } ?? CGPoint(x: v.bounds.midX, y: v.bounds.midY)
        guard v.bounds.contains(local) else { return ["error": "\(named): at must be inside its box"] }
        let p = v.drawnPoint(local), vp = presenter.viewport
        let q = vp.convert(p, from: nil), start = CGPoint(x: q.x - vp.pageOrigin.x, y: q.y - vp.pageOrigin.y)
        guard p.x.isFinite, p.y.isFinite, win.bounds.contains(p) else { return ["error": "\(named): its start is outside the window"] }
        let seen = win.hitTest(p, with: nil)
        if let why = offscreen(v, box: CGRect(origin: start, size: .zero), hit: seen) { return ["error": "\(named): \(why)"] }
        guard let hit = seen else { return ["error": "\(named): nothing is under its start"] }
        if let why = obscured(v, at: p, hit: hit) ?? swipeRefusal(v, swipe, hit: hit, at: p, in: win, path: check) {
            return ["error": "\(named): \(why)"]
        }
        var reply: [String: Any] = ["tapped": Int(v.id), "swipe": word, "at": [Agent.r2(start.x), Agent.r2(start.y)]]
        if check {
            let aim = aimed(v, at: p, local: start, in: win, space: win.windowScene?.coordinateSpace ?? win.screen.coordinateSpace, hit: hit)
            reply["checked"] = true
            reply["aim"] = aim["aim"]
            return reply
        }
        let target = HeldNode(v)
        presenter.supersedePress()
        MainActor.assumeIsolated { HeldState.input(at: hit) }
        guard target.live(in: presenter) === v, SwipeInput.allows(v), v.discreteSwipes.contains(where: { $0 === swipe }) else {
            return ["error": "\(named): its swipe is no longer eligible"]
        }
        presenter.swipe(v.id, word)
        reply["delivery"] = "recognized"
        return reply
        #endif
    }

    #if os(iOS)
    private func swipeRefusal(_ v: NodeView, _ swipe: DiscreteSwipe, hit: UIView, at p: CGPoint, in win: UIWindow, path: Bool) -> String? {
        if v.startsAtBackEdge(swipe.word, x: p.x) { return "it starts within the left 20 points, which Back keeps (rule 1)" }
        if CanvasInputs.owns(hit) { return "a canvas that takes input has the touch" }
        guard hit === v || hit.isDescendant(of: v) else { return "the hit is outside it, so its recognizers would not see the touch" }
        if v.pressBoundary(from: hit, editors: false) { return "a `press` between the hit and it keeps the contact (rule 3)" }
        var at: UIView? = hit
        while let current = at, current !== v {
            if let node = current as? NodeView, SwipeInput.allows(node), !node.pressBoundary(from: hit, editors: false),
               node.discreteSwipes.contains(where: { $0.isEnabled && $0.word == swipe.word && $0.touches == swipe.touches }) {
                return "#\(node.id), nearer on the hit path, takes that swipe (rule 3)"
            }
            at = current.superview
        }
        at = hit
        var scrollBelow = false
        while let current = at {
            if current.gestureRecognizers?.contains(where: { $0.numberOfTouches > 0 }) == true {
                return "a contact is already down on the hit path; lift it first"
            }
            if let scroll = current as? UIScrollView {
                if NodeView.scrolls(scroll, touches: swipe.touches, travel: swipe.travel, from: win.convert(p, to: scroll)) {
                    return "a \(Swift.type(of: scroll)) scrolls that way and takes the contact (§8.4)"
                }
                scrollBelow = true
            }
            if let node = current as? NodeView, SwipeInput.allows(node), !node.hitsNativeEditor(hit) {
                let localTravel = node.convert(CGPoint(x: p.x + swipe.travel.x, y: p.y + swipe.travel.y), from: nil)
                let start = node.convert(p, from: nil), travel = CGPoint(x: localTravel.x - start.x, y: localTravel.y - start.y)
                let pans = node.layoutPanRecognizer?.admitsTouches(swipe.touches) == true && node.layoutPanMayBegin(travel)
                    && !node.pressBoundary(from: hit, presses: false)
                let boundary = node.pressBoundary(from: hit)
                let right = !boundary && node.swipeRecognizer?.admitsTouches(swipe.touches) == true && node.swipeRightMayBegin(velocity: swipe.travel, start: p.x)
                let drags = !boundary && DragLink.installed?.blocksSwipe(node, touches: swipe.touches, travel: swipe.travel, from: p, scrollBelow: scrollBelow) == true
                if pans || right || drags { return "#\(node.id)'s drag on the hit path begins that way and takes the contact (§8.4)" }
            }
            at = current.superview
        }
        if path {
            let end = CGPoint(x: p.x + swipe.travel.x * 120, y: p.y + swipe.travel.y * 120)
            if !win.bounds.contains(end) { return "the touch runner's 120-point path leaves the window" }
        }
        return nil
    }
    #endif
}
#endif
