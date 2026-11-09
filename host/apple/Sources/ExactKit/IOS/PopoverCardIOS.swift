#if os(iOS)
import UIKit

/// Keep native content cards and their retiring controllers in this session's ownership
final class PopoverCards {
    private weak var host: MenuHost?
    private var cards: [PopoverCard] = []
    private var queued = false
    private var waitingOn: ObjectIdentifier?
    var keys: StoodDownKeys?
    init(_ host: MenuHost) { self.host = host }

    var inTransition: Bool { queued || cards.contains { $0.closing || $0.phase != .shown } || keys?.returning == true }
    var top: PopoverCard? { cards.last { !$0.closing && $0.phase != .waiting && $0.phase != .finished } }

    func show(_ popover: NodeView, in layer: PopoverLayer, from source: UInt32?) -> Bool {
        guard let host, let presenter = host.presenter else { return false }
        if let card = layer.card {
            guard card.valid(in: presenter) else { card.withdraw(); return true }
            layer.mount(in: presenter)
            card.fit(popover)
            present(card)
            return true
        }
        guard #available(iOS 26.0, *), !ExactEnv.agentPaints, popover.props["popover"] != "manual",
              popover.props["accessibilityRole"] != "menu", !host.isConfirmation(popover),
              let name = popover.props["id"], let opener = source.flatMap({ presenter.views[$0] }),
              host.eligible(opener), opener.window != nil, Materials.glass(opener.materialKind), opener.materialView != nil else { return false }
        let card = PopoverCard(popover, opener: opener, owner: self)
        card.keys = keys
        card.gone = { [weak host, weak card, weak layer] in
            guard layer?.card === card else { return }
            host?.drop(name)
        }
        layer.card = card
        cards.append(card)
        card.loadViewIfNeeded()
        card.view.bounds.size = popover.bounds.size
        layer.mount(in: presenter)
        layer.addSubview(popover)
        popover.isHidden = false
        popover.updateMaterial()
        card.fit(popover)
        present(card)
        return true
    }

    private func present(_ card: PopoverCard) {
        guard card.phase == .waiting, !card.closing, !cards.contains(where: { $0 !== card && $0.closing }),
              keys?.returning != true, let host, let presenter = host.presenter,
              let opener = card.opener.live(in: presenter),
              var controller = ViewPresentation.controller(for: opener, fallbackToWindow: true) else { return }
        while let next = controller.presentedViewController {
            if next.isBeingDismissed || next.isBeingPresented { wait(for: next); return }
            controller = next
        }
        if controller.isBeingDismissed || controller.isBeingPresented { wait(for: controller); return }
        guard controller.viewIfLoaded?.window === opener.window, let glass = opener.materialView else { return }
        card.phase = .presenting
        if keys == nil { keys = StoodDownKeys(presenter: presenter) }
        card.keys = keys
        card.modalPresentationStyle = .popover
        if let chrome = card.popoverPresentationController {
            chrome.delegate = card
            chrome.sourceView = glass
            chrome.sourceRect = glass.bounds
            chrome.permittedArrowDirections = []
        }
        if #available(iOS 26.0, *) { card.preferredTransition = .zoom { [weak glass] _ in glass } }
        controller.present(card, animated: !ExactEnv.agentFreezes) { [weak card, weak self] in
            guard let card, card.phase == .presenting else { return }
            card.phase = .shown
            self?.changed()
        }
    }

    fileprivate func wait(for controller: UIViewController) {
        guard let transition = controller.transitionCoordinator, waitingOn != ObjectIdentifier(transition as AnyObject) else { return }
        let token = ObjectIdentifier(transition as AnyObject)
        waitingOn = token
        let accepted = transition.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, waitingOn == token else { return }
            waitingOn = nil
            changed()
        }
        if !accepted, waitingOn == token { waitingOn = nil }
    }

    /// Revisit current openings after UIKit completes, without keeping an old show request alive
    func changed() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            for card in cards.reversed() where card.closing { card.dismissWhenReady() }
            host?.rehostPopovers()
            // Return input after its last card retires, when UIKit can present the keyboard again
            if let keys, !cards.contains(where: { $0.keys === keys }) { keys.bringBack() }
        }
    }

    func sync() {
        guard let presenter = host?.presenter else { return }
        keys?.reconcile()
        for card in cards where !card.closing && !card.valid(in: presenter) { card.withdraw() }
    }

    func finished(_ card: PopoverCard) {
        cards.removeAll { $0 === card }
        changed()
    }

    func resumeClosing() { if cards.contains(where: \.closing) { changed() } }

    func rotated() {
        keys?.giveBack()
        for card in cards.reversed() { card.withdraw(animated: false) }
    }

    func reset() {
        for popover in (host?.presented ?? []).reversed() {
            guard PopoverLayer.containing(popover)?.cardOwner != nil, let name = popover.props["id"] else { continue }
            host?.drop(name)
        }
        keys?.finish(restoring: false)
        for card in cards.reversed() { card.close(animated: false) }
    }
}

final class PopoverCard: UIViewController, UIPopoverPresentationControllerDelegate {
    enum Phase { case waiting, presenting, shown, retiringChild, dismissing, finished }
    var phase = Phase.waiting
    private(set) var closing = false
    var gone: (() -> Void)?
    weak var keys: StoodDownKeys?
    let opener: HeldNode
    private let content: HeldNode
    private weak var owner: PopoverCards?
    private var animated = true
    private var turning: NSKeyValueObservation?

    init(_ popover: NodeView, opener: NodeView, owner: PopoverCards) {
        content = HeldNode(popover); self.opener = HeldNode(opener); self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    func valid(in presenter: Presenter) -> Bool {
        guard let pop = content.live(in: presenter), pop.props["popover"] != nil,
              let source = opener.live(in: presenter), source.window != nil else { return false }
        return presenter.menus.eligible(source) && pop.props["popover"] != "manual" && pop.props["accessibilityRole"] != "menu"
    }

    override func loadView() { view = UIView(); view.backgroundColor = .clear }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if turning == nil, let scene = presentingViewController?.view.window?.windowScene {
            turning = scene.observe(\.effectiveGeometry, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue?.interfaceOrientation, let new = change.newValue?.interfaceOrientation, old != new else { return }
                self?.owner?.rotated()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        if let transition = transitionCoordinator, transition.isInteractive {
            phase = .dismissing
            transition.animate(alongsideTransition: nil) { [weak self] context in
                guard let self else { return }
                if context.isCancelled {
                    phase = .shown
                    owner?.changed()
                } else { withdraw(); finish() }
            }
            return
        }
        withdraw()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Keep the owner when a child presentation merely covers its card
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { withdraw(); finish() }
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    func fit(_ popover: NodeView) {
        let size = popover.bounds.size, center = CGPoint(x: popover.bounds.width / 2, y: popover.bounds.height / 2)
        if preferredContentSize != size { preferredContentSize = size }
        if popover.center != center { popover.center = center }
    }

    func withdraw(animated: Bool = true) {
        let end = gone
        gone = nil
        close(animated: animated)
        end?()
    }

    func close(animated: Bool = true) {
        gone = nil
        if !animated { self.animated = false }
        guard !closing else { dismissWhenReady(); return }
        closing = true
        if viewIfLoaded?.window != nil, let picture = view.snapshotView(afterScreenUpdates: false) {
            picture.isUserInteractionEnabled = false
            view.addSubview(picture)
        }
        dismissWhenReady()
        owner?.changed()
    }

    func dismissWhenReady() {
        guard closing else { return }
        if phase == .waiting { finish(); return }
        guard phase == .shown else { return }
        if isBeingDismissed { return }
        if let child = presentedViewController {
            var at: UIViewController? = child
            while let next = at {
                if next.isBeingPresented || next.isBeingDismissed { owner?.wait(for: next); return }
                at = next.presentedViewController
            }
            phase = .retiringChild
            // Dismiss only this card's child stack; its native owners unwind their own state
            dismiss(animated: animated && !ExactEnv.agentFreezes) { [weak self] in
                guard let self, phase == .retiringChild else { return }
                phase = .shown
                owner?.changed()
            }
            return
        }
        phase = .dismissing
        guard presentingViewController != nil else { finish(); return }
        dismiss(animated: animated && !ExactEnv.agentFreezes) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard phase != .finished else { return }
        let end = gone
        gone = nil; closing = true; phase = .finished; turning = nil
        end?()
        owner?.finished(self)
    }
}
#endif

#if os(iOS) || os(tvOS)
extension MenuHost {
    func resumeClosingCards() {
        #if os(iOS)
        cards.resumeClosing()
        #endif
    }
    func showsCard(_ popover: NodeView, in layer: PopoverLayer, from source: UInt32?) -> Bool {
        #if os(iOS)
        return cards.show(popover, in: layer, from: source)
        #else
        return false
        #endif
    }
    var cardsInTransition: Bool {
        #if os(iOS)
        cards.inTransition
        #else
        false
        #endif
    }
    func syncCards() {
        #if os(iOS)
        cards.sync()
        #endif
    }
    func unmountCards() {
        #if os(iOS)
        cards.reset()
        #endif
    }
}
#endif
