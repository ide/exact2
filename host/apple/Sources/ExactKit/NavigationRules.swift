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

    /// D4: how many of the app's own Backs take its chain to `key`; nil when
    /// `key` is its top or not in it (the app has gone elsewhere: its state wins).
    static func backs(app: [String], to key: String) -> Int? {
        guard let index = app.firstIndex(of: key), index < app.count - 1 else { return nil }
        return app.count - 1 - index
    }

    /// D6: leaving a route is the app's to permit. A Back control in the
    /// route decides — enabled, it permits; disabled, it refuses. With none,
    /// an app whose root hears `traverse` is told by that event, and with a
    /// visit beneath Back still goes (LLP 1115 D5: `navigate` with its
    /// location, or the runner's own `back`), so leaving is permitted.
    static func backPermitted(hasControl: Bool, controlEnabled: Bool, traverses: Bool, beneath: Bool = false) -> Bool {
        hasControl ? controlEnabled : traverses || beneath
    }

    /// D1: the Back control is resolved at use, never captured at a
    /// gesture's start: the lowest view id among live controls whose HTML
    /// `id` is the container's `navigationBack`, that handle `press`, and are
    /// enabled and owned by the active route. `nil` when no such control is live — and
    /// then no gesture may begin and no dismissal may complete.
    static func backControl<Control>(
        named target: String?,
        among controls: [Control],
        id: (Control) -> UInt32,
        htmlID: (Control) -> String?,
        pressable: (Control) -> Bool,
        disabled: (Control) -> Bool,
        inActiveRoute: (Control) -> Bool
    ) -> Control? {
        guard let target else { return nil }
        return controls
            .filter { htmlID($0) == target && pressable($0) && !disabled($0) && inActiveRoute($0) }
            .min { id($0) < id($1) }
    }

    /// How the platform's Back (its button, edge swipe, sheet swipe-down)
    /// goes from the selected route.
    enum Back: Equatable {
        /// Press the authored Back control, this view.
        case press(UInt32)
        /// Deliver this location to the navigation root's `navigate`.
        case navigate(String)
        /// The runner's own `back` of the router (no `navigate` handler).
        case pop
    }

    /// LLP 1115 D5, Back is always there: a route that declares a Back
    /// control (a live element in it whose `id` is the root's
    /// `navigationBack`) goes back by pressing it, and is refused while it
    /// does not resolve (disabled, or no `press`) — the author's say, as
    /// D1 has it. A route that declares none still goes back, as a
    /// hand-built UIKit screen does and as the web's history Back does
    /// (LLP 1038 D11, amended 2026-10-03): the root's `navigate` with the
    /// location of the visit beneath, or with no `navigate` handler the
    /// runner's own `back` of the router, the same on the web. With no
    /// visit beneath there is nothing to go back to, and it is refused.
    static func back(control: UInt32?, declared: Bool, hearsNavigate: Bool, beneath: () -> String?) -> Back? {
        if let control { return .press(control) }
        guard !declared, let location = beneath(), !location.isEmpty else { return nil }
        return hearsNavigate ? .navigate(location) : .pop
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
    /// No motion yet is no evidence against: UIKit's pop recognizers ask
    /// before the finger has moved (a real swipe read zero velocity and zero
    /// travel there), having judged the direction themselves.
    /// The direction a pop's `shouldBegin` judges: the pan's velocity, or
    /// its travel so far when the velocity is still zero (LLP 1057.001 §7).
    static func popDirection(velocity: CGPoint, travel: CGPoint) -> CGPoint {
        velocity == .zero ? travel : velocity
    }

    static func panMayBegin(startX: CGFloat, overSwipeRight: Bool, velocity: CGPoint) -> Bool {
        if startX >= 20 && overSwipeRight { return false }
        if velocity == .zero { return true }
        return velocity.x > abs(velocity.y)
    }

    /// D1: `closedby="none"` refuses the platform's dismissal gesture and
    /// Escape; anything else (`closerequest`, absent) permits them. Explicit
    /// Close is the app's own control either way.
    static func modalRefusesDismissal(closedby: String?) -> Bool {
        closedby == "none"
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

    /// D5: a stack change waits a turn when it arrives in a batch that put
    /// the keyboard away (shown, with no editor of the session's left): the
    /// viewport's growth is applied after the batch, and a transition begun
    /// before it keeps the routes at the keyboard's height to its end. Under
    /// the agent nothing animates, so nothing waits.
    static func waitsForKeyboardViewport(applying: Bool, keyboardShown: Bool, editing: Bool,
                                         agentFreezes: Bool, stackChanges: Bool) -> Bool {
        applying && keyboardShown && !editing && !agentFreezes && stackChanges
    }

    /// A presentation's background view, back in the home it left: its
    /// frame then, grown or shrunk on each flexible axis by what its home
    /// did meanwhile, as autoresizing would have done had it stayed.
    static func restoredFrame(_ frame: CGRect, homeThen: CGSize, homeNow: CGSize,
                              flexibleWidth: Bool, flexibleHeight: Bool) -> CGRect {
        var out = frame
        if flexibleWidth { out.size.width = max(0, out.width + homeNow.width - homeThen.width) }
        if flexibleHeight { out.size.height = max(0, out.height + homeNow.height - homeThen.height) }
        return out
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
