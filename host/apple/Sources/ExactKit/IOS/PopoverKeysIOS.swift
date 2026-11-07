#if os(iOS)
import UIKit

/// Stand down this session's software keys behind a snapshot while a native card owns presentation
final class StoodDownKeys {
    private weak var presenter: Presenter?
    private let field: HeldNode
    private weak var editor: UIView?
    private weak var window: UIWindow?
    let top: CGFloat
    private let holder: UIView
    private let again: UIView
    private var observers: [NSObjectProtocol] = []
    private(set) var returning = false
    private(set) var blurred = false
    private var done = false
    private var expectedFrame: CGRect?

    var node: NodeView? { presenter.flatMap { field.live(in: $0) } }
    var heldEditor: UIView? {
        guard !blurred, let node, let editor, let window, editor.window === window,
              node.field === editor || node.textArea === editor, presenter?.mounts(editor) == true else { return nil }
        return editor
    }
    func suspends(_ node: NodeView) -> Bool { !blurred && self.node === node }
    func ended() { if returning { finish(restoring: false) } }

    init?(presenter: Presenter) {
        guard let editor = presenter.keyboardEditor, let node = presenter.editor,
              node.field === editor || node.textArea === editor,
              let window = editor.window, let top = presenter.keyboardTop, top < window.bounds.height,
              let keys = Self.keyboard, !keys.isHidden,
              let picture = keys.snapshotView(afterScreenUpdates: false), let again = keys.snapshotView(afterScreenUpdates: false) else { return nil }
        self.presenter = presenter; field = HeldNode(node); self.editor = editor; self.window = window
        self.top = top; self.again = again
        holder = UIView(frame: CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height - top))
        holder.clipsToBounds = true
        holder.isUserInteractionEnabled = false
        again.isUserInteractionEnabled = false
        picture.frame = window.convert(keys.bounds, from: keys).offsetBy(dx: 0, dy: -top)
        holder.addSubview(picture)
        window.addSubview(holder)
        presenter.menus.cards.keys = self
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let next = note.object as? UIView, next !== self.editor, next.isFirstResponder else { return }
                finish(restoring: false)
            })
        }
        let selection = presenter.fieldSelections.current(node)
        var resigned = false
        UIView.performWithoutAnimation { resigned = editor.resignFirstResponder() }
        guard resigned else {
            presenter.menus.cards.keys = nil
            holder.removeFromSuperview()
            return nil
        }
        presenter.fieldSelections.set(node, selection, notify: false)
        presenter.refitKeyboard()
        if done { return nil }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        again.removeFromSuperview(); holder.removeFromSuperview()
    }

    /// End logical editing once when the author blurs or another responder takes it
    func blur() {
        guard !blurred else { return }
        blurred = true
        guard let presenter, let node else { return }
        if editor?.isFirstResponder == true {
            _ = editor?.resignFirstResponder()
            finish(restoring: false)
            return
        }
        if presenter.editing === node { presenter.editing = nil }
        presenter.commitEdit(node.id, node.fieldText, change: node.handlers.contains("change"))
        presenter.blur(node.id)
    }

    func focus(selectText: Bool) {
        guard let presenter, let node else { return }
        let wasBlurred = blurred
        blurred = false
        presenter.editing = node
        if wasBlurred { presenter.focus(node.id) }
        if selectText { presenter.fieldSelections.selectAll(node) }
    }

    func reconcile() {
        guard let node, heldEditor != nil || blurred, !node.formDisabled, !node.inert,
              !sequence(first: node as UIView, next: \.superview).contains(where: { $0.isHidden || ($0 as? NodeView)?.cssVisibilityHidden == true }) else {
            finish(restoring: false)
            return
        }
    }

    /// Keep ownership until UIKit completes the returning software keyboard
    func bringBack() {
        guard !returning, !done else { return }
        returning = true
        guard !blurred, let editor = heldEditor else { finish(restoring: false); return }
        if let next = FirstResponder.current as? UIView, next is UIKeyInput, next !== editor, next !== presenter?.session?.view {
            finish(restoring: false)
            return
        }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, accepts(note), returning else { return }
                expectedFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                coverReturningKeys()
            })
        }
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, accepts(note), returning, self.editor?.isFirstResponder == true else { return }
                if let expectedFrame, note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect != expectedFrame { return }
                finish()
            })
        }
        guard editor.becomeFirstResponder() else { finish(restoring: false); return }
    }

    func giveBack() {
        if !blurred, let editor = heldEditor { _ = editor.becomeFirstResponder() }
        finish()
    }

    private func accepts(_ note: Notification) -> Bool {
        guard let window else { return false }
        return (note.object as? UIScreen).map { $0 === window.screen } ?? true
    }
    private func coverReturningKeys() {
        guard let keys = Self.keyboard, again.superview == nil else { return }
        again.frame = keys.bounds
        keys.addSubview(again)
    }

    func finish(restoring: Bool = true) {
        guard !done else { return }
        done = true
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        again.removeFromSuperview(); holder.removeFromSuperview()
        guard let presenter, presenter.menus.cards.keys === self else { return }
        presenter.menus.cards.keys = nil
        if !restoring || editor?.isFirstResponder != true { blur() }
        presenter.refitKeyboard()
        presenter.menus.cards.changed()
    }

    private static weak var keyboard: UIWindow?
    private static var watching: NSObjectProtocol?
    static func watch() {
        guard watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            if let window = note.object as? UIWindow, String(describing: type(of: window)).contains("RemoteKeyboard") { keyboard = window }
        }
    }
}

extension Presenter {
    var keysNode: NodeView? { menus.cards.keys.flatMap { $0.blurred ? nil : $0.node } }
    var heldKeyboardEditor: UIView? { menus.cards.keys?.heldEditor }
}
#endif

#if os(iOS) || os(tvOS)
extension Presenter {
    var keysStoodDown: Bool {
        #if os(iOS)
        menus.cards.keys != nil
        #else
        false
        #endif
    }
}
#endif
