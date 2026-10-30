#if os(macOS)
import AppKit

// LLP 1057.001 §8.7 on AppKit: `tap <target> swipe <direction> [at <x> <y>]`
// is a trackpad's three-finger swipe, `swipe(with:)`, at the target's middle or
// `at` in it: the view under the point gets it and the responder chain carries
// it up, as the window routes a trackpad's. AppKit has no public constructor
// for the event; a gesture CGEvent of IOHID's swipe type (16) carries its
// direction mask (1 up, 2 down, 4 left, 8 right), as a pinch's carries its
// zoom. The tracked two-finger path is not driven: what reaches it is decided
// by every scroller under the pointer (§8.2), which `DiscreteSwipeMacTests`
// proves instead.
extension Agent {
    func swipeTap(_ req: [String: Any]) -> [String: Any] {
        guard let word = req["swipe"] as? String, let mask = ["up": 1, "down": 2, "left": 4, "right": 8][word] else {
            return ["malformed": true, "error": "swipe: expected left, right, up or down"]
        }
        guard let v = view(req), let win = v.window else { return ["error": "no view \(req["id"] ?? "?") on screen"] }
        if presenter.alerts.presented != nil { return ["error": "view \(v.id) is behind an alert"] }
        if presenter.dialogs.blocks(v) { return ["error": "view \(v.id) is blocked by a modal dialog"] }
        if v.placedAncestor?.placementHidden == true { return ["error": "placed child is hidden"] }
        guard presenter.toolbar.visible(v), !v.inert else { return ["error": "view \(v.id) is hidden or inert"] }
        let named = "tap #\(v.id) swipe \(word)"
        guard v.takesSwipe(word) else {
            return ["error": "\(named): it takes no swipe to the \(word): its `swipe-direction` names none, it is disabled, or it names a `touch-count`, which AppKit does not report"]
        }
        let local: CGPoint?
        switch req["at"] {
        case nil: local = nil
        case let raw as [Double] where raw.count == 2 && raw.allSatisfy(\.isFinite): local = CGPoint(x: raw[0], y: raw[1])
        default: return ["malformed": true, "error": "at needs two finite numbers"]
        }
        let b = v.tapBox(box(v))
        let p = local.map { v.convert($0, to: nil) } ?? pointerPoint(CGPoint(x: b.midX, y: b.midY), in: win)
        // A node in a window of its own (a sheet, a popover) may stand outside the viewport, as for a click
        let clip = presenter.viewport.contentView, apart = clip.window != nil && win !== clip.window
        let port: NSView = presenter.navigation.split.pane(holding: v) ?? clip
        if !apart, !port.bounds.contains(port.convert(p, from: nil)) {
            return ["error": "\(named): its start is outside the \(port === clip ? "viewport" : "detail's pane"); scroll it into view first"]
        }
        guard let hit = win.contentView?.hitTest(p) else { return ["error": "\(named): nothing is under its start"] }
        // Up the responder chain from the view under the point: the first that takes the swipe has it
        var responder: NSResponder? = hit
        while let r = responder, r !== v {
            if let node = r as? NodeView, node.takesSwipe(word) { return ["error": "\(named): #\(node.id), nearer on the responder chain, takes it"] }
            responder = r.nextResponder
        }
        if responder == nil {
            return ["error": "\(named): it is not on the responder chain of what is under its start (\((hit as? NodeView).map { "#\($0.id)" } ?? "\(Swift.type(of: hit))"))"]
        }
        guard let cg = CGEvent(source: nil), let type = CGEventType(rawValue: 29),
              let hidType = CGEventField(rawValue: 110), let direction = CGEventField(rawValue: 115) else { return ["error": "no gesture event"] }
        cg.type = type
        cg.setIntegerValueField(hidType, value: 16)
        cg.setIntegerValueField(direction, value: Int64(mask))
        guard let event = Agent.windowEvent(cg, at: p, in: win, flags: []), event.type == .swipe else { return ["error": "no swipe event at a window point (CGEventSetWindowLocation)"] }
        hit.swipe(with: event)
        session.presenter.settlePump()
        let at = local.map { [Agent.r2($0.x), Agent.r2($0.y)] } ?? [Agent.r2(b.midX), Agent.r2(b.midY)]
        return ["tapped": Int(v.id), "swipe": word, "at": at, "delivery": "platform"]
    }
}
#endif
