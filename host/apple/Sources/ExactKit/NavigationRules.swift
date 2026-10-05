// The rules UIKit's navigation, sheet, keyboard and focus projection
// follows (LLP 1035.001 D1–D5, D8), as pure functions of what the
// presenter knows — no controller, no window, no run loop, no clock — so
// the macOS test target can hold every one of them and a reader finds the
// contract in one place. `NavigationIOS.swift`, `ModalIOS.swift` and
// `PresenterIOS.swift` apply them; nothing here decides what UIKit owns
// (recognition, progress, cancellation, animation).
//
// @ref LLP 1035.001 §3; LLP 1008 §9
import Foundation

enum NavigationRules {
    /// @ref LLP 1038 D6 — controller identities, not URLs: animate a
    /// push/pop only when either complete list is a prefix of the other.
    static func isPushOrPop<T: Equatable>(from: [T], to: [T]) -> Bool {
        from.starts(with: to) || to.starts(with: from)
    }

    /// D1: the routes are the first root's children carrying a
    /// `navigationKey`, in tree order, and the stack is the prefix through
    /// the one whose key is the root's. `nil` when the root's key matches
    /// no route: the stack is left alone and the refusal is journaled.
    static func stack(routeKeys: [String], selected: String) -> Range<Int>? {
        guard let index = routeKeys.firstIndex(of: selected) else { return nil }
        return 0..<(index + 1)
    }

    /// D4: presentation boundaries split the selected prefix into retained
    /// owners. A later push stays in the most recent presentation's stack.
    static func segments(presentations: [String?]) -> [Range<Int>] {
        var starts = [0]
        for (index, kind) in presentations.enumerated() where kind == "modal" || kind == "fullscreen" {
            starts.append(index)
        }
        return zip(starts, starts.dropFirst() + [presentations.count]).map { $0..<$1 }
    }

    /// LLP 1035.001.000 D2: what native navigation shows, by route key —
    /// the selected tab, its stack, and each presented layer's stack, lowest
    /// first. Alerts, popovers, menus and the share sheet are not in it, nor
    /// a sheet's detent: they are not navigation.
    struct Snapshot: Equatable {
        var tab: String?
        var stack: [String]
        var presented: [[String]]
        /// The selected path through every layer, root first.
        var chain: [String] { stack + presented.flatMap { $0 } }
    }

    /// What the platform did, as a destination (D3).
    ///
    /// Invariant I1 (LLP 1035.001.000): a transition back carries where it
    /// went, never how many screens it took. One platform transition may
    /// remove any number of screens — the back button's menu, a sheet with
    /// its own stack, nested sheets — so nothing here or in the host counts
    /// pops, and no delivery assumes one transition is one screen.
    enum Change: Equatable {
        /// The person went back to the route keyed so: a pop of any depth, a
        /// dismissed sheet with whatever it had pushed, nested sheets at once.
        case backTo(String)
        /// UIKit selected this tab (the More list).
        case select(String)
    }

    /// D3: the host changed nothing since it applied `applied`, so whatever
    /// differs in `observed` is the platform's. How it happened — the back
    /// button, its menu, a swipe, a sheet pulled down, a gesture yet to come —
    /// is not the question; nil when nothing changed (a cancelled swipe) or
    /// UIKit holds something the host never set.
    static func platformChange(applied: Snapshot, observed: Snapshot) -> Change? {
        if let tab = observed.tab, tab != applied.tab { return .select(tab) }
        let a = applied.chain, o = observed.chain
        guard let last = o.last, o.count < a.count, Array(a.prefix(o.count)) == o else { return nil }
        return .backTo(last)
    }

    /// D4: whether `key` is a route beneath the app's top — a destination
    /// the app can still be taken back to. Not when it is the top already, or
    /// gone from the chain (the app has moved elsewhere: its state wins).
    static func isBeneath(_ key: String, in app: [String]) -> Bool {
        guard let index = app.firstIndex(of: key) else { return false }
        return index < app.count - 1
    }

    /// LLP 1035.001.001 D3: leaving is the app's to permit. A platform Back
    /// is a close request on every route it removes (HTML's `closedby`,
    /// which Exact extends to routes): permitted when the navigator hears
    /// `traverse` — else nothing could tell the app — and none of the routes
    /// it removes, given by their `closedby`, says `none`.
    static func backPermitted(removing closedby: [String?], traverses: Bool) -> Bool {
        traverses && !closedby.contains("none")
    }

    /// D1: whether an interactive pop may begin at all — a stack to pop, no
    /// transition in flight, no sheet in transition, leaving permitted (D6),
    /// and no context preview anywhere in the session.
    static func popMayBegin(depth: Int, inFlight: Bool, modalActive: Bool, permitted: Bool, contextPreviewActive: Bool) -> Bool {
        depth > 1 && !inFlight && !modalActive && permitted && !contextPreviewActive
    }

    /// D1's arbitration for a pan: past the 20-point edge a pan that starts
    /// over a `swiperight` node is that node's; otherwise the pan must be
    /// more horizontal than vertical. The edge itself stays navigation's.
    static func panMayBegin(startX: CGFloat, overSwipeRight: Bool, velocity: CGPoint) -> Bool {
        if startX >= 20 && overSwipeRight { return false }
        return velocity.x > abs(velocity.y)
    }

    /// D4: geometry deferred behind a sheet replays as a batch would apply
    /// it — every frame before any content size, node ids ascending.
    static func replayOrder(deferred: [UInt32: Set<String>]) -> [(id: UInt32, kind: String)] {
        var out: [(id: UInt32, kind: String)] = []
        for kind in ["frame", "content"] {
            for id in deferred.keys.sorted() where deferred[id]?.contains(kind) == true {
                out.append((id, kind))
            }
        }
        return out
    }

    /// D5: a keyboard notification is a session's business only when one of
    /// its own editors is editing, or it still holds an inset from a show it
    /// applied; another session's keyboard in the same window is not.
    static func keyboardConcerns(editing: Bool, holdsInset: Bool) -> Bool {
        editing || holdsInset
    }

    /// D5: the viewport freeze that keeps a composer beside a sideways-moving
    /// keyboard applies only to an initially interactive navigation
    /// transition outside a sheet — never to a sheet's vertical dismissal.
    static func freezesViewport(modalActive: Bool, inFlight: Bool, initiallyInteractive: Bool) -> Bool {
        !modalActive && inFlight && initiallyInteractive
    }

    /// D3 (as it stands): why a `focus(id)` command cannot be delivered now,
    /// or `nil` when it can. The reason is journaled, never silent.
    static func focusRefusal(mounted: Bool, disabled: Bool, zeroSize: Bool, hiddenAncestor: Bool, inertAncestor: Bool) -> String? {
        if !mounted { return "not mounted" }
        if disabled { return "disabled" }
        if zeroSize { return "zero size" }
        if hiddenAncestor { return "hidden ancestor" }
        if inertAncestor { return "inert ancestor" }
        return nil
    }
}
