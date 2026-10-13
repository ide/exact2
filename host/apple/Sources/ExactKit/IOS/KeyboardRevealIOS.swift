// A back swipe that takes the keyboard away with the screen it leaves. UIKit
// never resizes a view controller's view for the keyboard: during its pop the
// screen being revealed is whole, and the keys leave with the departing card.
// Exact lays every route out in one viewport that ends at the keyboard's top,
// so for the swipe the session is laid out as if no keyboard were up, and the
// departing route shows as the picture it showed when the swipe began. Its
// live view stays underneath, transparent, with its field first responder, so
// UIKit carries the keyboard off with the card and brings it back if the swipe
// is cancelled. This is `RouteController.freeze()`'s trade, made for the
// interactive pop: a video or an animation in the departing route holds its
// frame until the swipe ends.
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
    /// The interactive pop it was prepared for, once UIKit began it
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
        guard keyboardReveal == nil, !changing, let nav = primaryNavigation, modalNavigation == nil, !presenter.modals.active,
              presenter.keyboardPolicy == "resizes-content", presenter.keyboardInset > 0,
              let source = nav.topViewController as? RouteController, nav.viewControllers.count > 1,
              keyboardRoute() === source, source.isViewLoaded,
              let picture = source.view.snapshotView(afterScreenUpdates: false) else { return true }
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
            presenter.session?.view?.fit()
            // UIKit sizes the transition from the containers' laid-out views, now
            primaryOwner?.view.layoutIfNeeded()
            nav.view.layoutIfNeeded()
            // The refit applies a batch too
            ready = stands()
        }
        settlingReveal = false
        guard ready else {
            abortKeyboardReveal()
            return false
        }
        // UIKit begins the pop in the turn that recognized it; a gesture that
        // fails or is cancelled first begins none, and the reveal ends
        DispatchQueue.main.async { [weak self, weak reveal] in
            guard let self, let reveal, keyboardReveal === reveal, reveal.transition == nil else { return }
            abortKeyboardReveal()
        }
        #endif
        return true
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

    /// UIKit began a transition: the reveal belongs to it when it is the
    /// interactive pop of the route the reveal pictures, and ends otherwise.
    func bindKeyboardReveal(to transition: UIViewControllerTransitionCoordinator?) {
        guard let reveal = keyboardReveal, reveal.transition == nil else { return }
        if let transition, interactiveTransition, transition.viewController(forKey: .from) === reveal.source {
            reveal.transition = ObjectIdentifier(transition)
        } else {
            abortKeyboardReveal()
        }
    }

    /// The swipe ended (`didShow`), completed or cancelled: the viewport is
    /// fitted to the keyboard as it is now, then the live route is shown again.
    func settleKeyboardReveal() {
        guard keyboardReveal != nil else { return }
        abortKeyboardReveal()
    }

    /// Navigation sync held, the session fitted to the keyboard UIKit shows
    /// now while the picture still covers the source, then the source given back.
    func abortKeyboardReveal() {
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
