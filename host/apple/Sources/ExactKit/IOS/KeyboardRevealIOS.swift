// A pop that takes the keyboard away with the screen it leaves: a back swipe,
// UIKit's Back button or its menu, or the app's own pop. UIKit never resizes a
// view controller's view for the keyboard: during its pop the screen being
// revealed is whole, and the keys leave with the departing card. Exact lays
// every route out in one viewport that ends at the keyboard's top, so for the
// pop the session is laid out as if no keyboard were up, and the departing
// route shows as the picture it showed when the pop began. Its live view stays
// underneath, transparent, with its field first responder, so UIKit carries
// the keyboard off with the card and brings it back if a swipe is cancelled.
// This is `RouteController.freeze()`'s trade, made for the pop: a video or an
// animation in the departing route holds its frame until the pop ends.
#if os(iOS) || os(tvOS)
import UIKit

final class KeyboardReveal {
    weak var source: RouteController?
    let picture: UIView
    /// The source node's opacity, given back when the swipe is cancelled; a
    /// `present` of its opacity during the swipe lands here
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
    /// As the pop gesture is recognized, before UIKit builds its transition
    /// at the container's size: when the top route of the primary stack holds
    /// this session's keyboard, its picture laid over it, the live route
    /// hidden under the picture, and the session laid out without the keyboard.
    /// False when the owed work this drains leaves the route unable to go
    /// back: the gesture must not begin then.
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

    /// UIKit is about to animate a pop it was not asked for by a gesture (its
    /// Back button or menu, the app's own pop): when the route leaving holds
    /// this session's keyboard, the reveal is made for this transition, in
    /// `willShow`, before UIKit lays out the cards it animates.
    func beginKeyboardReveal(for transition: UIViewControllerTransitionCoordinator, in nav: UINavigationController) {
        #if os(iOS)
        // A pop: back to a route UIKit has shown before (a push shows one it has not)
        guard !transition.initiallyInteractive, let source = transition.viewController(forKey: .from) as? RouteController,
              (transition.viewController(forKey: .to) as? RouteController)?.appeared == true,
              let reveal = revealKeyboard(leaving: source, in: nav) else { return }
        reveal.transition = ObjectIdentifier(transition)
        settlingReveal = true
        fitWithoutKeyboard(nav)
        settlingReveal = false
        #endif
    }

    /// UIKit is about to animate a push: the session keeps its viewport for
    /// the push. The arriving route's field takes the keyboard as the push
    /// starts (`viewIsAppearing`), and the session's one viewport, UIKit's
    /// containers in it, would end at the keyboard's top as the keys rose,
    /// cutting both routes off below it while they slid. UIKit never resizes
    /// its containers for the keyboard; the session is fitted to it once the
    /// push settles (`didShow`).
    func holdViewportForPush(_ transition: UIViewControllerTransitionCoordinator, in nav: UINavigationController) {
        #if os(iOS)
        guard primaryNavigation === nav, presenter.keyboardPolicy == "resizes-content",
              let source = transition.viewController(forKey: .from) as? RouteController, source.appeared,
              let destination = transition.viewController(forKey: .to) as? RouteController, !destination.appeared else { return }
        pushHoldsViewport = true
        #endif
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

    /// The focus moved during the swipe: when the route being revealed took
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
            reveal.transition = ObjectIdentifier(transition)
        } else {
            settleKeyboardReveal()
        }
    }

    /// The pop ended (`didShow`, completed or cancelled) or never began:
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
