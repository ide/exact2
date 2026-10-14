// The keyboard moves with the screen that holds it, as in UIKit, which never
// resizes a view controller's view for the keyboard. Exact lays every route
// out in one viewport that ends at the keyboard's top, so while a transition
// takes the keyboard's screen away the session is laid out without the
// keyboard, and the leaving route shows a picture of itself over its live
// view, whose field stays first responder: UIKit carries the keyboard off
// with the card, and back if a swipe is cancelled. A video or an animation in
// the leaving route holds its frame meanwhile, as on `RouteController.freeze()`.
#if os(iOS) || os(tvOS)
import UIKit

final class KeyboardReveal {
    weak var source: RouteController?
    let picture: UIView
    /// The source node's opacity, given back when the reveal ends; a
    /// `present` of its opacity meanwhile lands here
    var opacity: CGFloat
    let accessibilityHidden: Bool
    /// Whether the session is laid out without the keyboard: until the
    /// destination takes the keyboard for itself
    var leaving = true
    /// The pop it was prepared for, once UIKit began it
    var transition: ObjectIdentifier?

    init(source: RouteController, picture: UIView) {
        self.source = source
        self.picture = picture
        opacity = source.node.alpha
        accessibilityHidden = source.view.accessibilityElementsHidden
    }

    func conceals(_ view: UIView) -> Bool { source?.node === view }

    func contains(_ view: UIView) -> Bool {
        guard let node = source?.node else { return false }
        return view === node || view.isDescendant(of: node)
    }
}

extension NavigationHost {
    /// The reveal for a back swipe, as it is recognized: UIKit builds the
    /// transition's cards at the container's size when it begins. False when
    /// the owed work this drains leaves the route unable to go back.
    func beginKeyboardReveal() -> Bool {
        // tvOS has no on-screen keyboard that leaves with a screen
        #if os(iOS)
        guard !changing, let nav = primaryNavigation, let source = nav.topViewController as? RouteController,
              nav.viewControllers.count > 1, let reveal = revealKeyboard(leaving: source, in: nav) else { return true }
        // Held while preparing: owed work drained here must not move the stack under the gesture
        settlingReveal = true
        presenter.session?.drainFill()
        let stands = { [self] in
            primaryNavigation === nav && modalNavigation == nil && nav.topViewController === source
                && nav.viewControllers.count > 1 && back != nil && presenter.views[source.node.id] === source.node
                && keyboardRoute() === source
        }
        var ready = stands()
        if ready {
            fitWithoutKeyboard(nav)
            // The refit applies a batch too
            ready = stands()
        }
        settlingReveal = false
        guard ready else {
            settleKeyboardReveal()
            return false
        }
        // UIKit begins the pop in the turn that recognized it; a gesture that
        // fails or is cancelled first begins none, and the reveal ends
        DispatchQueue.main.async { [weak self, weak reveal] in
            guard let self, let reveal, keyboardReveal === reveal, reveal.transition == nil else { return }
            settleKeyboardReveal()
        }
        #endif
        return true
    }

    /// UIKit is about to animate a push or a pop it was not asked for by a
    /// gesture (its Back button or menu, the app's own change), in `willShow`,
    /// before it lays out the cards it animates. A leaving route that holds
    /// the keyboard is revealed, as for a swipe. A push holds the session's
    /// keyboard edge until it settles: the arriving field takes the keyboard
    /// as the push starts (`viewIsAppearing`), and the viewport ending at the
    /// rising keys would cut both routes off while they slide.
    func beginKeyboardTransition(_ transition: UIViewControllerTransitionCoordinator, in nav: UINavigationController) {
        #if os(iOS)
        guard primaryNavigation === nav, let source = transition.viewController(forKey: .from) as? RouteController,
              let destination = transition.viewController(forKey: .to) else { return }
        let id = ObjectIdentifier(transition)
        if let reveal = revealKeyboard(leaving: source, in: nav) {
            reveal.transition = id
            settlingReveal = true
            fitWithoutKeyboard(nav)
            settlingReveal = false
        }
        if !pops(from: source, to: destination, in: nav) { pushHold = id }
        // Ended here too when `didShow` is not this stack's (a tab switched meanwhile)
        transition.animate(alongsideTransition: nil) { [weak self] _ in self?.transitionEnded(id) }
        #endif
    }

    /// A pop: the destination stood below the leaving route when the stack
    /// last stood still (a route it did not hold is pushed). With no record
    /// yet, the leaving route has left the stack.
    func pops(from source: UIViewController, to destination: UIViewController, in nav: UINavigationController) -> Bool {
        if let settled = settledStacks[ObjectIdentifier(nav)], let above = settled.firstIndex(of: ObjectIdentifier(source)) {
            return settled.firstIndex(of: ObjectIdentifier(destination)).map { $0 < above } ?? false
        }
        return !nav.viewControllers.contains(source)
    }

    /// The transition `id` ended: its hold and its reveal go, if they are still its.
    private func transitionEnded(_ id: ObjectIdentifier) {
        if pushHold == id {
            pushHold = nil
            presenter.session?.view?.fit()
        }
        if keyboardReveal?.transition == id { settleKeyboardReveal() }
    }

    /// The departing route pictured and hidden under its picture, when it is
    /// the primary stack's route that holds this session's keyboard.
    private func revealKeyboard(leaving source: RouteController, in nav: UINavigationController) -> KeyboardReveal? {
        guard keyboardReveal == nil, primaryNavigation === nav, modalNavigation == nil, !presenter.modals.active,
              presenter.keyboardPolicy == "resizes-content", presenter.keyboardInset > 0,
              keyboardRoute() === source, source.isViewLoaded,
              let picture = source.view.snapshotView(afterScreenUpdates: false) else { return nil }
        picture.frame = source.view.bounds
        // Pinned to the top, never stretched, as `freeze()` pins its picture
        picture.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        picture.isAccessibilityElement = false
        let reveal = KeyboardReveal(source: source, picture: picture)
        source.view.addSubview(picture)
        source.view.accessibilityElementsHidden = true
        source.node.alpha = 0
        source.node.renderFilter()
        keyboardReveal = reveal
        return reveal
    }

    /// The session laid out without the keyboard, and the containers with
    /// it: UIKit sizes a transition from their laid-out views.
    private func fitWithoutKeyboard(_ nav: UINavigationController) {
        presenter.session?.view?.fit()
        primaryOwner?.view.layoutIfNeeded()
        nav.view.layoutIfNeeded()
    }

    /// The route whose field holds this session's keyboard: an Exact field, a
    /// native module's editor or a header's search field.
    func keyboardRoute() -> RouteController? {
        guard let responder = FirstResponder.current as? UIView, responder.window != nil else { return nil }
        return controllers.values.first { route in
            guard route.isViewLoaded else { return false }
            if responder.isDescendant(of: route.view) { return true }
            if let search = route.search?.controller.searchBar, responder.isDescendant(of: search) { return true }
            return false
        }
    }

    /// The focus moved during the transition: when the route being revealed took
    /// the keyboard, the session is laid out with that keyboard.
    func keyboardOwnerChanged() {
        guard let reveal = keyboardReveal, reveal.leaving, let owner = keyboardRoute(), owner !== reveal.source else { return }
        reveal.leaving = false
        presenter.session?.view?.fit()
    }

    /// UIKit began a transition: a swipe's reveal belongs to it when it is the
    /// interactive pop of the route the reveal pictures, and ends otherwise.
    func bindKeyboardReveal(to transition: UIViewControllerTransitionCoordinator?) {
        guard let reveal = keyboardReveal, reveal.transition == nil else { return }
        if let transition, interactiveTransition, transition.viewController(forKey: .from) === reveal.source {
            let id = ObjectIdentifier(transition)
            reveal.transition = id
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.transitionEnded(id) }
        } else {
            settleKeyboardReveal()
        }
    }

    /// The transition ended (`didShow`, completed or cancelled) or never began:
    /// navigation sync held, the session fitted to the keyboard UIKit shows
    /// now while the picture still covers the source, then the source given back.
    func settleKeyboardReveal() {
        guard let reveal = keyboardReveal else { return }
        settlingReveal = true
        reveal.leaving = false
        presenter.session?.view?.fit()
        endKeyboardReveal()
        settlingReveal = false
        if pendingSync, !changing { sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil)) }
    }

    /// The picture taken away and the live route given back its opacity, its
    /// filter's picture and its accessibility.
    func endKeyboardReveal() {
        guard let reveal = keyboardReveal else { return }
        keyboardReveal = nil
        if let source = reveal.source {
            source.node.alpha = reveal.opacity
            source.node.renderFilter()
            source.view.accessibilityElementsHidden = reveal.accessibilityHidden
        }
        // The keyboard as the refit observed it, not a hide UIKit announced for a pop it then cancelled
        if presenter.keyboardInset == 0 { presenter.pinnedRoom.release() }
        reveal.picture.removeFromSuperview()
    }
}
#endif
