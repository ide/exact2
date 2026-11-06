#if os(macOS)
import AppKit

// LLP 1057.001 §8.7: an AppKit swipe event at the target's local point.
// AppKit has no public constructor; IOHID's swipe type (16) and direction
// mask (1 up, 2 down, 4 left, 8 right) make it, as a pinch's fields make zoom.
extension Agent {
    func swipeTap(_ req: [String: Any]) -> [String: Any] {
        if let bad = swipeMalformed(req, checking: false) { return bad }
        guard contact == nil, canvasContact == nil else { return ["error": "a contact is already down; use `tap up` or `tap cancel` first"] }
        guard Agent.privateEvents else { return ["developmentOnly": true, "error": "swipe event synthesis needs a development build"] }
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
        let offset = req["at"] as? [Double]
        let local = offset.map { CGPoint(x: v.bounds.minX + $0[0], y: v.bounds.minY + $0[1]) } ?? CGPoint(x: v.bounds.midX, y: v.bounds.midY)
        guard v.bounds.contains(local) else { return ["error": "\(named): at must be inside its box"] }
        let p = v.drawnPoint(local)
        guard p.x.isFinite, p.y.isFinite else { return ["error": "\(named): its start has no finite window point"] }
        // A node in a window of its own (a sheet, a popover) may stand outside the viewport, as for a click
        let clip = presenter.viewport.contentView, apart = clip.window != nil && win !== clip.window
        let port: NSView = presenter.navigation.split.pane(holding: v) ?? clip
        if !apart, !port.bounds.contains(port.convert(p, from: nil)) {
            return ["error": "\(named): its start is outside the \(port === clip ? "viewport" : "detail's pane"); scroll it into view first"]
        }
        guard let content = win.contentView, content.bounds.contains(content.convert(p, from: nil)) else { return ["error": "\(named): its start is outside the window"] }
        let under = TableRowCell.whatIsThere { content.hitTest(content.superview?.convert(p, from: nil) ?? p) }
        guard let hit = under else { return ["error": "\(named): nothing is under its start"] }
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
        let at = [Agent.r2(local.x - v.bounds.minX), Agent.r2(local.y - v.bounds.minY)]
        return ["tapped": Int(v.id), "swipe": word, "at": at, "delivery": "platform"]
    }
}
#endif
