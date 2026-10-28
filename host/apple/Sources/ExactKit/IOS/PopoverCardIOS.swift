// A content popover opened from a glass control is UIKit's popover, zoomed
// out of that glass (iOS 26's `UIViewControllerTransition.zoom`), with no
// arrow and no adaptation to a sheet. UIKit's platter is its surface; its
// dimming, tap outside and pull to dismiss close it. With the keyboard up it
// lies over the keys. Nothing in the app's window draws above the keyboard's
// window, so the keys stand down behind a picture of themselves: the
// picture keeps the editing route's room (`Presenter.heldKeys`), the editor
// resigns without animation and keeps the app's focus, and when the card
// closes the editor takes the keys back under a second picture in the
// keyboard's own window, which comes away once they have arrived.
#if os(iOS)
import UIKit

final class PopoverCard: UIViewController, UIPopoverPresentationControllerDelegate {
    /// Closes the popover once UIKit dismisses the card; cleared when the
    /// app closes the popover itself (`close`).
    var gone: (() -> Void)?
    /// The keys it stood down, owned by the presenter until they are back.
    weak var keys: StoodDownKeys?
    /// The box it shows, which takes back its own surface once it has left.
    weak var popover: NodeView?
    private var turning: NSKeyValueObservation?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A rotation while the card is up: its box, the pictures and the zoom's
        // source are the old orientation's, so it goes at once and the keyboard
        // comes back as UIKit brings it
        if turning == nil, let scene = presentingViewController?.view.window?.windowScene {
            turning = scene.observe(\.effectiveGeometry, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue?.interfaceOrientation, let new = change.newValue?.interfaceOrientation, old != new else { return }
                self?.keys?.giveBack()
                self?.presentingViewController?.dismiss(animated: false)
            }
        }
        // Hidden until the zoom's first frame: the card is laid out at its full
        // size before the zoom applies its start
        guard animated, let coordinator = transitionCoordinator else { return }
        view.isHidden = true
        coordinator.animate(alongsideTransition: { [weak self] _ in self?.view.isHidden = false },
                            completion: { [weak self] _ in self?.view.isHidden = false })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        turning = nil
        leave()
        DispatchQueue.main.async { [weak popover] in popover?.updateMaterial() }
    }

    /// The popover's box, from its top-left corner, is the card.
    func fit(_ popover: NodeView) {
        let size = popover.bounds.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if popover.center != center { popover.center = center }
        if preferredContentSize != size { preferredContentSize = size }
    }

    /// Closes it as the app asked: its box goes back to its page, and a
    /// picture of the box shrinks back into the opener.
    func close() {
        gone = nil
        guard let presenting = presentingViewController, !isBeingDismissed else { return }
        keepPicture()
        presenting.dismiss(animated: true)
    }

    // A popover on a phone too, where UIKit would make it a sheet
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    // The card starts to go: the popover closes now, as HTML's light dismiss
    // closes it at the tap. A press on the opener once UIKit takes touches
    // again opens it after this card has gone. A pull, which can still be
    // cancelled, closes it once done.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if transitionCoordinator?.isInteractive != true { leave() }
    }

    // The box goes back to its page, a picture of it shrinking in its place,
    // and the keys come back, outside the batch that may have closed it
    private func leave() {
        DispatchQueue.main.async { [weak keys] in keys?.bringBack() }
        guard let gone else { return }
        self.gone = nil
        keepPicture()
        gone()
    }

    // A picture of the box stays in the card as the box leaves it
    private func keepPicture() {
        if view.window != nil, let picture = view.snapshotView(afterScreenUpdates: false) { view.addSubview(picture) }
    }
}

/// The keys stood down behind a picture of themselves for a card, held by
/// the presenter (`heldKeys`) until they are back or gone.
final class StoodDownKeys {
    private weak var presenter: Presenter?
    weak var editor: UIView?
    /// The keys' top in window coordinates, which the editing route keeps.
    let top: CGFloat
    /// The app blurred the editor while the card was up: the keys go.
    var blurred = false
    /// The keys from their top down, in the app's window where they were.
    private let holder: UIView
    /// A second picture, for the keyboard's own window as the keys return.
    private let again: UIView
    private var observers: [NSObjectProtocol] = []

    // Its session went first: the pictures go with it
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        again.removeFromSuperview()
        holder.removeFromSuperview()
    }
    private(set) var returning = false
    private var done = false

    /// Stands the keys down; nil when they are not up.
    init?(presenter: Presenter) {
        guard let editor = presenter.keyboardEditor, let window = editor.window, let top = presenter.keyboardTop,
              top < window.bounds.height, let keys = Self.keyboard, !keys.isHidden,
              let picture = keys.snapshotView(afterScreenUpdates: false),
              let again = keys.snapshotView(afterScreenUpdates: false) else { return nil }
        self.presenter = presenter
        self.editor = editor
        self.top = top
        self.again = again
        holder = UIView(frame: CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height - top))
        holder.clipsToBounds = true
        holder.isUserInteractionEnabled = false
        picture.frame = keys.frame.offsetBy(dx: 0, dy: -top)
        holder.addSubview(picture)
        window.addSubview(holder)
        presenter.heldKeys = self
        UIView.performWithoutAnimation { _ = editor.resignFirstResponder() }
        presenter.refitKeyboard()
    }

    /// The editor takes the keys back; the pictures come away once they
    /// have arrived, or a second later if they never do.
    func bringBack() {
        guard !returning, !done else { return }
        returning = true
        if blurred { slideAway(); return }
        guard let editor, editor.window != nil else { finish(); return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.coverReturningKeys()
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish()
        })
        editor.becomeFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish() }
    }

    /// The keys back at once, without the pictures, as UIKit brings them.
    func giveBack() {
        guard !returning, !done else { return }
        if !blurred { editor?.becomeFirstResponder() }
        finish()
    }

    // The keyboard's window is above the app's, and `isHidden` or `alpha` set
    // on it is undone as UIKit shows it, so the picture goes inside it.
    private func coverReturningKeys() {
        guard let keys = Self.keyboard, again.superview == nil else { return }
        again.frame = keys.bounds
        keys.addSubview(again)
    }

    // The keys leave as a keyboard does: the picture slides down on the
    // keyboard's curve with the route's room let go in the same animation,
    // so the route's foot rides on the picture's top.
    private func slideAway() {
        guard let presenter else { finish(); return }
        let node = presenter.keysNode
        presenter.heldKeys = nil
        UIView.animate(withDuration: 0.25, delay: 0, options: [UIView.AnimationOptions(rawValue: 7 << 16), .beginFromCurrentState], animations: { [holder] in
            holder.frame.origin.y += holder.bounds.height
            presenter.refitKeyboard()
        }, completion: { _ in self.finish() }) // holds itself: the presenter has let it go
        if let node { presenter.blur(node.id) }
    }

    /// The pictures come away and the route has the keyboard UIKit has. An
    /// editor that ends without them reports its blur, held back till now.
    func finish() {
        guard !done else { return }
        done = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        again.removeFromSuperview()
        holder.removeFromSuperview()
        guard let presenter, presenter.heldKeys === self else { return }
        let node = presenter.keysNode
        presenter.heldKeys = nil
        if let node, editor?.isFirstResponder != true { presenter.blur(node.id) }
        presenter.refitKeyboard()
    }

    /// The window UIKit draws the keyboard in. It is in no scene's
    /// `windows` and on a `UIScreen` object of its own; it is heard of as it
    /// becomes visible (`watch`).
    private static weak var keyboard: UIWindow?
    private static var watching: NSObjectProtocol?
    static func watch() {
        guard watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            // Every window posts it, so its class is the filter
            if let window = note.object as? UIWindow, String(describing: type(of: window)).contains("RemoteKeyboard") { keyboard = window }
        }
    }
}

extension Presenter {
    /// The node whose keys stand down for a card.
    var keysNode: NodeView? {
        heldKeys?.editor.flatMap(NodeView.innermost)
    }
}

extension MenuHost {
    /// Shows `popover` as a card when it opens from a glass control (see the
    /// file's head); false when it lifts into Exact's own layer instead, as
    /// under the agent's painted presentation.
    func showsCard(_ popover: NodeView, in layer: PopoverLayer, from source: UInt32?) -> Bool {
        if let card = layer.card {
            if let presenter { layer.mount(in: presenter) }
            card.fit(popover)
            return true
        }
        // A manual popover keeps its own dismissal, which UIKit's popover would take
        guard #available(iOS 26.0, *), !ExactEnv.agentPaints, popover.props["popover"] != "manual", let presenter, let name = popover.props["id"],
              let opener = source.flatMap({ presenter.views[$0] }), opener.window != nil,
              Materials.glass(opener.materialKind), let glass = opener.materialView,
              var host = presenter.viewport.window?.rootViewController else { return false }
        var busy = presenter.heldKeys?.returning == true
        while let next = host.presentedViewController {
            if next.isBeingDismissed { busy = true; break }
            host = next
        }
        // A card still closing, or keys still returning: this one opens after
        if busy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.rehostPopovers() }
            return true
        }
        let card = PopoverCard()
        card.loadViewIfNeeded()
        layer.card = card
        layer.mount(in: presenter)
        if popover.superview !== layer { layer.addSubview(popover) }
        if popover.isHidden { popover.isHidden = false }
        popover.updateMaterial()
        card.popover = popover
        card.fit(popover)
        card.modalPresentationStyle = .popover
        if let chrome = card.popoverPresentationController {
            chrome.delegate = card
            chrome.sourceView = glass
            chrome.sourceRect = glass.bounds
            chrome.permittedArrowDirections = []
        }
        card.preferredTransition = .zoom { [weak glass] _ in glass }
        // A card opened from inside another shares the keys it stood down
        if presenter.heldKeys == nil { card.keys = StoodDownKeys(presenter: presenter) }
        card.gone = { [weak self] in self?.drop(name) }
        host.present(card, animated: true)
        return true
    }
}
#endif
