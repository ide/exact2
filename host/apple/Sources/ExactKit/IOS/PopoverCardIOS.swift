// A content popover opened from a glass control is UIKit's popover, zoomed
// out of that glass (iOS 26's `UIViewControllerTransition.zoom`), with no
// arrow and no adaptation to a sheet. UIKit's platter is its surface; its
// dimming, tap outside and pull to dismiss close it. With the keyboard up it
// lies over the keys. Nothing in the app's window draws above the keyboard's
// window, so the keys stand down behind a picture of themselves: the
// picture keeps the editing route's room (`Presenter.heldKeys`), the editor
// resigns without animation and keeps the app's focus, and when the last
// card holding them has gone the editor takes the keys back under a second
// picture in the keyboard's own window, which comes away once UIKit says
// they have arrived. The cards a session shows wait on one another
// (`PopoverCards`): one opens after a card still closing, a presentation in
// flight or returning keys are done.
#if os(iOS)
import UIKit

/// The cards this session shows, in opening order, and what each waits on.
/// The keys are the presenter's (`heldKeys`); this is where the last card
/// holding them lets them go, and where a batch checks that each card's
/// nodes and the keys' editor are still the ones they were made for.
final class PopoverCards {
    private weak var host: MenuHost?
    private var cards: [PopoverCard] = []
    private var queued = false
    private var waitingOn: ObjectIdentifier?
    init(_ host: MenuHost) { self.host = host }
    private var keys: StoodDownKeys? { host?.presenter?.heldKeys }

    var inTransition: Bool { queued || cards.contains { $0.closing || $0.phase != .shown } || keys?.returning == true }
    /// The card a popover opened now is hosted by (`PopoverLayer.mount`): the last one up and staying.
    var top: PopoverCard? { cards.last { !$0.closing && $0.phase != .waiting && $0.phase != .finished } }

    /// Shows `popover` as a card when it opens from a glass control (see the
    /// file's head); false when it lifts into Exact's own layer instead, as
    /// under the agent's painted presentation.
    func show(_ popover: NodeView, in layer: PopoverLayer, from source: UInt32?) -> Bool {
        guard let host, let presenter = host.presenter else { return false }
        if let card = layer.card {
            guard card.valid(in: presenter) else { card.withdraw(); return true }
            layer.mount(in: presenter)
            card.fit(popover)
            present(card)
            return true
        }
        // A manual popover keeps its own dismissal, which UIKit's popover would take
        guard #available(iOS 26.0, *), !ExactEnv.agentPaints, popover.props["popover"] != "manual", let name = popover.props["id"],
              let opener = source.flatMap({ presenter.views[$0] }), opener.window != nil,
              Materials.glass(opener.materialKind), opener.materialView != nil else { return false }
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
        if popover.superview !== layer { layer.addSubview(popover) }
        if popover.isHidden { popover.isHidden = false }
        popover.updateMaterial()
        card.fit(popover)
        present(card)
        return true
    }

    // Presents a waiting card once nothing is in its way: a card closing, a
    // presentation or dismissal in flight above the window's root, or keys
    // returning. One in flight is waited on (`wait`); the rest come back
    // through `changed`.
    private func present(_ card: PopoverCard) {
        guard card.phase == .waiting, !card.closing, !cards.contains(where: { $0 !== card && $0.closing }),
              keys?.returning != true, let host, let presenter = host.presenter,
              let opener = card.opener.live(in: presenter), opener.window != nil, let glass = opener.materialView,
              var controller = presenter.viewport.window?.rootViewController else { return }
        while let next = controller.presentedViewController {
            if next.isBeingDismissed || next.isBeingPresented { wait(for: next); return }
            controller = next
        }
        guard controller.viewIfLoaded?.window === opener.window else { return }
        card.phase = .presenting
        // A card opened from inside another shares the keys it stood down
        if presenter.heldKeys == nil { _ = StoodDownKeys(presenter: presenter) }
        card.keys = presenter.heldKeys
        card.modalPresentationStyle = .popover
        if let chrome = card.popoverPresentationController {
            chrome.delegate = card
            chrome.sourceView = glass
            chrome.sourceRect = glass.bounds
            chrome.permittedArrowDirections = []
        }
        if #available(iOS 26.0, *) { card.preferredTransition = .zoom { [weak glass] _ in glass } }
        controller.present(card, animated: true) { [weak card, weak self] in
            guard let card, card.phase == .presenting else { return }
            card.phase = .shown
            self?.changed()
        }
    }

    // Comes back once the transition `controller` is in has ended; one with
    // no coordinator (unanimated) is revisited by the next `changed`.
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

    /// Revisits the cards once per turn after something ended: a card closing
    /// dismisses when it can, the popovers find their hosts (a waiting card
    /// presents), and the keys return after the last card holding them has
    /// gone, when UIKit can show them again. What it reads is the state then,
    /// never what asked for the turn: a card gone or keys retired meanwhile
    /// are not revived.
    func changed() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            for card in cards.reversed() where card.closing { card.dismissWhenReady() }
            host?.rehostPopovers()
            if let keys, !cards.contains(where: { $0.keys === keys }) { keys.bringBack() }
        }
    }

    /// After a batch: the keys' editor is still theirs to return to, and each
    /// card's popover and opener are still the nodes it was made for.
    func sync() {
        guard let presenter = host?.presenter else { return }
        keys?.reconcile()
        for card in cards where !card.closing && !card.valid(in: presenter) { card.withdraw() }
    }

    func finished(_ card: PopoverCard) {
        cards.removeAll { $0 === card }
        changed()
    }

    /// A native presentation over a card (an alert) left without a transition
    /// coordinator to wait on: a card closing behind it may go now.
    func resumeClosing() { if cards.contains(where: \.closing) { changed() } }

    /// A rotation while a card is up: its box, the pictures and the zoom's
    /// source are the old orientation's, so every card goes at once and the
    /// keyboard comes back as UIKit brings it.
    func rotated() {
        keys?.giveBack()
        for card in cards.reversed() { card.withdraw(animated: false) }
    }

    /// The session's view left its window, or its tree is reset: the cards,
    /// presented from the window, go with it, the popovers they host too,
    /// and the keys are let go. Under a reset the old tree is told nothing
    /// (`StoodDownKeys.finish`).
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
    /// Waiting: made, presented once what it waits on is done. Presenting
    /// and shown: UIKit's. Retiring child: its own presented stack going
    /// before it. Dismissing: UIKit's dismissal, a pull's included. Finished:
    /// gone, never to come back.
    enum Phase { case waiting, presenting, shown, retiringChild, dismissing, finished }
    var phase = Phase.waiting
    /// Asked to go, by the app or by UIKit: it dismisses when it can.
    private(set) var closing = false
    /// Closes the popover once UIKit dismisses the card; cleared when the
    /// app closes the popover itself (`close`).
    var gone: (() -> Void)?
    /// The keys it stood down, or shares with the card it opened from, owned
    /// by the presenter until they are back.
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

    /// The box it shows, which takes back its own surface once it has left.
    var popover: NodeView? { content.node }

    /// Still the card of the nodes it was made for: a popover or an opener the
    /// tree replaced (a node forgotten, a view the pool reused) is not.
    func valid(in presenter: Presenter) -> Bool {
        guard let pop = content.live(in: presenter), pop.props["popover"] != nil, pop.props["popover"] != "manual",
              opener.live(in: presenter) != nil else { return false }
        return true
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if turning == nil, let scene = presentingViewController?.view.window?.windowScene {
            turning = scene.observe(\.effectiveGeometry, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue?.interfaceOrientation, let new = change.newValue?.interfaceOrientation, old != new else { return }
                self?.owner?.rotated()
            }
        }
        // Hidden until the zoom's first frame: the card is laid out at its full
        // size before the zoom applies its start. Only as it is presented: a
        // pull that is cancelled brings it back under a coordinator already done.
        guard animated, isBeingPresented, let coordinator = transitionCoordinator else { return }
        view.isHidden = true
        coordinator.animate(alongsideTransition: { [weak self] _ in self?.view.isHidden = false },
                            completion: { [weak self] _ in self?.view.isHidden = false })
    }

    // The card starts to go: the popover closes now, as HTML's light dismiss
    // closes it at the tap. A pull, which can still be cancelled, closes it
    // once done, and a cancelled one leaves it shown.
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
        // A child presentation covering the card is not its going
        if isBeingDismissed || presentingViewController == nil { finish() }
        DispatchQueue.main.async { [weak self] in self?.popover?.updateMaterial() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { withdraw(); finish() }
    // A popover on a phone too, where UIKit would make it a sheet
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    /// The popover's box, from its top-left corner, is the card.
    func fit(_ popover: NodeView) {
        let size = popover.bounds.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if popover.center != center { popover.center = center }
        if preferredContentSize != size { preferredContentSize = size }
    }

    /// Goes as UIKit or a rotation takes it: the popover closes now.
    func withdraw(animated: Bool = true) {
        let end = gone
        gone = nil
        close(animated: animated)
        end?()
    }

    /// Closes it as the app asked: its box goes back to its page, and a
    /// picture of the box shrinks back into the opener, once UIKit can
    /// dismiss it (`dismissWhenReady`).
    func close(animated: Bool = true) {
        gone = nil
        if !animated { self.animated = false }
        guard !closing else { dismissWhenReady(); return }
        closing = true
        keepPicture()
        dismissWhenReady()
        owner?.changed()
    }

    // A picture of the box stays in the card as the box leaves it
    private func keepPicture() {
        guard viewIfLoaded?.window != nil, let picture = view.snapshotView(afterScreenUpdates: false) else { return }
        picture.isUserInteractionEnabled = false
        view.addSubview(picture)
    }

    /// Dismisses a closing card when UIKit can: shown, not already going, and
    /// with nothing it presented still up. Its own presented stack goes first,
    /// and only that stack: what presented those unwinds its own state.
    func dismissWhenReady() {
        guard closing else { return }
        if phase == .waiting { finish(); return }
        guard phase == .shown, !isBeingDismissed else { return }
        if let child = presentedViewController {
            var at: UIViewController? = child
            while let next = at {
                if next.isBeingPresented || next.isBeingDismissed { owner?.wait(for: next); return }
                at = next.presentedViewController
            }
            phase = .retiringChild
            dismiss(animated: animated) { [weak self] in
                guard let self, phase == .retiringChild else { return }
                phase = .shown
                owner?.changed()
            }
            return
        }
        phase = .dismissing
        guard presentingViewController != nil else { finish(); return }
        dismiss(animated: animated) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard phase != .finished else { return }
        let end = gone
        gone = nil; closing = true; phase = .finished; turning = nil
        end?()
        owner?.finished(self)
    }
}

/// The keys stood down behind a picture of themselves for a card, held by
/// the presenter (`heldKeys`) until they are back or gone. They belong to
/// one editor, the node it was found in and the window it was in
/// (`heldEditor`); a replacement of any of these, a node disabled, hidden,
/// removed or reset, another responder taking the keys, or the app's blur
/// ends the hold without them (`finish(restoring: false)`), once, and tells
/// the app its editing ended then. Their return is UIKit's to complete: the
/// pictures come away at the keyboard notification that describes the keys
/// this editor asked for, on this window's screen, never on a clock. Keys
/// UIKit never reports back (a hardware keyboard's, a floating one's) stay
/// held, with their editor editing, until something above ends the hold.
final class StoodDownKeys {
    private weak var presenter: Presenter?
    /// The node the editor was found in: a field's, a text area's, or the
    /// route whose projected search field it is. None for an editor no node
    /// owns (the session's prompt, a native module's input), whose hold is
    /// the editor's identity alone and tells the app nothing.
    private let field: HeldNode?
    private weak var editor: UIView?
    private weak var window: UIWindow?
    /// The keys' top in window coordinates, which the editing route keeps.
    let top: CGFloat
    /// The keys from their top down, in the app's window where they were.
    private let holder: UIView
    /// A second picture, for the keyboard's own window as the keys return.
    private let again: UIView
    private var observers: [NSObjectProtocol] = []
    private(set) var returning = false
    /// The app blurred the editor while the card was up: its editing ended
    /// then (`blur`), and the keys go instead of coming back.
    private(set) var blurred = false
    private var done = false
    /// Where UIKit said the returning keys would end, from the will-show or
    /// will-change that announced them (`bringBack`).
    private var expectedFrame: CGRect?

    /// The node, while it is still the node the editor was found in.
    var node: NodeView? { presenter.flatMap { p in field.flatMap { $0.live(in: p) } } }
    /// The editor, while the hold still names it: in its window and mounted in
    /// the session (or the session's prompt), and its node's own while it has
    /// one. Blurred or not: its route keeps the keys' room until the hold ends.
    var editorKeepingRoom: UIView? {
        guard !done, let presenter, let editor, let window, editor.window === window,
              presenter.mounts(editor) || editor === presenter.keyboardPrompt else { return nil }
        if let field {
            guard let node = field.live(in: presenter), node.field === editor || node.textArea === editor || node.headerField === editor else { return nil }
        }
        return editor
    }
    /// The editor the keys return to: the one keeping the room, unless the app blurred it.
    var heldEditor: UIView? { blurred ? nil : editorKeepingRoom }
    /// Whether an end of `node`'s native editing is this hold's doing: the
    /// resignation that stood the keys down, or a loss while they return.
    func suspends(_ node: NodeView) -> Bool { !blurred && !done && self.node === node }
    /// The editor's native editing ended. During the stand-down that is its
    /// resignation, expected and not an end of the app's editing. While the
    /// keys return it is a loss of the editor (another responder, the keys
    /// dismissed): the hold ends without them.
    func ended() { if returning { finish(restoring: false) } }

    /// Stands the keys down; nil when they are not up, or when the editor
    /// refuses to resign and so keeps them.
    init?(presenter: Presenter) {
        guard let editor = presenter.keyboardEditor, let window = editor.window, let top = presenter.keyboardTop,
              top < window.bounds.height, let keys = Self.keyboard, !keys.isHidden,
              let picture = keys.snapshotView(afterScreenUpdates: false),
              let again = keys.snapshotView(afterScreenUpdates: false) else { return nil }
        // The node whose editor this is; one found around another kind of input is not its owner
        let node = presenter.editor.flatMap { $0.field === editor || $0.textArea === editor || $0.headerField === editor ? $0 : nil }
        self.presenter = presenter; field = node.map(HeldNode.init); self.editor = editor; self.window = window
        self.top = top; self.again = again
        holder = UIView(frame: CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height - top))
        holder.clipsToBounds = true
        holder.isUserInteractionEnabled = false
        again.isUserInteractionEnabled = false
        picture.frame = window.convert(keys.bounds, from: keys).offsetBy(dx: 0, dy: -top)
        holder.addSubview(picture)
        window.addSubview(holder)
        presenter.heldKeys = self
        // Another editor taking the keys, this session's or not, ends the hold
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let next = note.object as? UIView, next !== self.editor, next.isFirstResponder else { return }
                finish(restoring: false)
            })
        }
        // The selection as the editor shows it, kept for the keys' return: UIKit
        // puts a field's caret at the end as it takes the focus (`TextField`)
        let selection = node.map { presenter.fieldSelections.current($0) }
        var resigned = false
        UIView.performWithoutAnimation { resigned = editor.resignFirstResponder() }
        guard resigned else {
            presenter.heldKeys = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            holder.removeFromSuperview()
            return nil
        }
        if let node, let selection { presenter.fieldSelections.set(node, selection, notify: false) }
        presenter.refitKeyboard()
        if done { return nil }
    }

    // Its session went first: the pictures go with it
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        again.removeFromSuperview()
        holder.removeFromSuperview()
    }

    /// The app's blur while the keys stand down or return: the editing ends
    /// now, once, as its `change` and its blur, and the keys do not come back
    /// (they slide away as the card closes; an editor already returning
    /// resigns, which ends its editing as any resignation does).
    func blur() {
        guard !blurred else { return }
        blurred = true
        guard let presenter else { return }
        if editor?.isFirstResponder == true {
            _ = editor?.resignFirstResponder()
            finish(restoring: false)
            return
        }
        if let node {
            if presenter.editing === node { presenter.editing = nil }
            presenter.commitEdit(node.id, node.fieldText, change: node.handlers.contains("change"))
            presenter.blur(node.id)
        }
        if returning { finish(restoring: false) }
    }

    /// The app's focus on the held node while the keys stand down: a blur
    /// asked before is undone (the keys will come back, and the node hears its
    /// focus again), and `selectText` selects as it would in the editor.
    func focus(selectText: Bool) {
        guard let presenter, let node else { return }
        let wasBlurred = blurred
        blurred = false
        presenter.editing = node
        if wasBlurred { presenter.focus(node.id) }
        if selectText { presenter.fieldSelections.selectAll(node) }
    }

    /// After a batch, and before the keys return: the hold still names an
    /// editor the app could focus, or it ends without the keys.
    func reconcile() {
        guard !done else { return }
        guard blurred || heldEditor != nil else { finish(restoring: false); return }
        guard let node else { return }
        guard !node.formDisabled, !node.inert,
              !sequence(first: node as UIView, next: \.superview).contains(where: { $0.isHidden || ($0 as? NodeView)?.cssVisibilityHidden == true }) else {
            finish(restoring: false)
            return
        }
    }

    /// The node is leaving the tree: the hold ends before the node is
    /// forgotten, its editing ended while it can still be told.
    func released(_ id: UInt32) { if field?.id == id { finish(restoring: false) } }

    /// The last card holding the keys has gone: the editor takes them back,
    /// and the pictures come away once UIKit says they have arrived. Keys
    /// whose editor the app blurred slide away instead. An editor the hold no
    /// longer names, one another responder has replaced, or one that refuses
    /// the keys ends the hold without them.
    func bringBack() {
        guard !returning, !done else { return }
        reconcile()
        guard !done else { return }
        returning = true
        if blurred { slideAway(); return }
        guard let editor = heldEditor else { finish(restoring: false); return }
        if let next = FirstResponder.current as? UIView, next is UIKeyInput, next !== editor, next !== presenter?.session?.view {
            finish(restoring: false)
            return
        }
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, returning, accepts(note) else { return }
                expectedFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                coverReturningKeys()
            })
        }
        // Done at the notification that ends what the will-notification announced:
        // the same end frame, this editor still the responder
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, returning, accepts(note), self.editor?.isFirstResponder == true,
                      let expectedFrame, note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect == expectedFrame else { return }
                finish()
            })
        }
        guard editor.becomeFirstResponder() else { finish(restoring: false); return }
    }

    /// The keys back at once, without the pictures, as UIKit brings them: a
    /// rotation, whose geometry the pictures were not drawn for. An editor
    /// that does not take them ends its editing here.
    func giveBack() {
        guard !done else { return }
        if !returning, !blurred, let editor = heldEditor { _ = editor.becomeFirstResponder() }
        finish()
    }

    // A keyboard notification for this window's screen, while this hold is the
    // presenter's and its editor is in that window; another app's keys in a
    // shared screen are not these
    private func accepts(_ note: Notification) -> Bool {
        guard let window, presenter?.heldKeys === self, editor?.window === window,
              note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false else { return false }
        return Self.names(note.object, screen: window.screen)
    }

    /// Whether a keyboard notification's object names `screen`: UIKit posts
    /// them with the screen whose keys they describe, and one naming no
    /// screen is taken as this one's. Identity alone, so a test on a single
    /// display, where no second `UIScreen` can be had, can ask about another.
    static func names(_ object: Any?, screen: AnyObject) -> Bool {
        (object as? UIScreen).map { $0 === screen } ?? true
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
    // so the route's foot rides on the picture's top. The hold is the
    // presenter's no more from the start: a card may stand new keys down meanwhile.
    private func slideAway() {
        guard let presenter, presenter.heldKeys === self, holder.window != nil, !ExactEnv.agentFreezes else { finish(restoring: false); return }
        presenter.heldKeys = nil
        UIView.animate(withDuration: 0.25, delay: 0, options: [UIView.AnimationOptions(rawValue: 7 << 16), .beginFromCurrentState], animations: { [holder] in
            holder.frame.origin.y += holder.bounds.height
            presenter.refitKeyboard()
        }, completion: { [weak self] _ in self?.finish(restoring: false) })
        presenter.menus.cards.changed()
    }

    /// The pictures come away and the route has the keyboard UIKit has.
    /// `restoring`: the keys came back to the editor; otherwise, or when the
    /// editor did not take them, its editing ends here, once (`blur`). Under
    /// a reset nothing is told: the editing was the old tree's.
    func finish(restoring: Bool = true) {
        guard !done else { return }
        done = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        again.removeFromSuperview()
        holder.removeFromSuperview()
        guard let presenter, presenter.heldKeys === self else { return }
        presenter.heldKeys = nil
        if presenter.resetting {
            blurred = true
            presenter.edited = nil
            if editor?.isFirstResponder == true { _ = editor?.resignFirstResponder() }
        } else if !restoring || editor?.isFirstResponder != true { blur() }
        presenter.refitKeyboard()
        presenter.menus.cards.changed()
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
    /// The node whose keys stand down for a card while it keeps the focus:
    /// none once the app blurred it, and none for an editor no node owns.
    var keysNode: NodeView? { heldKeys.flatMap { $0.blurred ? nil : $0.node } }
}
#endif

#if os(iOS) || os(tvOS)
extension MenuHost {
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
    func resumeClosingCards() {
        #if os(iOS)
        cards.resumeClosing()
        #endif
    }
}
#endif
