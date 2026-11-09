#if os(iOS) || os(tvOS)
import UIKit

/// A header's search field as UIKit's search controller (LLP 1075.003
/// §9.6): text, focus and blur go to the authored field's handlers.
final class HeaderSearch: NSObject, UISearchBarDelegate, UISearchControllerDelegate, UITextFieldDelegate {
    let controller = UISearchController(searchResultsController: nil)
    weak var host: NavigationHost?
    /// The field's placeholder is drawn in an authored colour, not UIKit's.
    var paintsPlaceholder = false
    /// The field's `value` the bar last showed: one that differs is the app's write.
    var value: String?
    /// The field's text is drawn in its own colour or the design's FieldText; its fill is the design's Field, not UIKit's capsule.
    var paintsInk = false, paintsGround = false
    /// The scope bar's tabs, and the segment last chosen or set (LLP 1134 D3).
    var scopeTabs: [UInt32] = [], scopeIDs: [String?] = [], scopeSettled: Int?
    weak var scopeList: NodeView?
    /// UIKit's field's text: the node's own colour, else the design's
    /// FieldText where it overrides it, else UIKit's (LLP 1115 D4, LLP 1121
    /// D9); and its fill, the design's Field where it overrides it. Set
    /// again on a live retheme.
    func ink() {
        #if !os(tvOS)
        guard let field else { return }
        let text = controller.searchBar.searchTextField
        // The field's own tint is its node's accent: its text, placeholder and caret in the tint resolve by it
        text.tintColor = field.ownAccent
        // Any `backgroundColor`, nil too, replaces UIKit's capsule (iOS 26, measured): written only where a design names a Field, cleared (unfilled) only where one was.
        if let ground = field.fieldGroundColor { text.backgroundColor = ground; paintsGround = true }
        else if paintsGround { text.backgroundColor = nil; paintsGround = false }
        if field.showsOwnTextColor || ThemeRoles.color("FieldText", in: field) != nil {
            text.textColor = field.fieldInk
            paintsInk = true
        } else if paintsInk {
            text.textColor = .label
            paintsInk = false
        }
        #endif
    }
    weak var field: NodeView? {
        didSet {
            if oldValue !== field { oldValue?.headerField = nil; acceptingDismissal = false }
            #if os(iOS)
            if oldValue !== field { retireSwipeDown() }
            field?.headerField = controller.searchBar.searchTextField
            field?.applyFieldDirection()
            controller.searchBar.searchTextField.pasteDelegate = field
            syncSwipeDown()
            #endif
        }
    }
    private weak var textDelegate: UITextFieldDelegate?
    private var editingCompletion: (value: String, finish: () -> Void)?
    private var acceptingDismissal = false
    init(host: NavigationHost) {
        self.host = host
        super.init()
        controller.searchBar.delegate = self
        controller.delegate = self
        #if os(iOS)
        controller.searchResultsUpdater = self
        textDelegate = controller.searchBar.searchTextField.delegate
        controller.searchBar.searchTextField.delegate = self
        #endif
        controller.obscuresBackgroundDuringPresentation = false
        controller.hidesNavigationBarDuringPresentation = true
    }
    /// The navigation item the controller is on.
    weak var item: UINavigationItem?
    /// The field scrolls away with the content only while it is empty
    /// (`NavigationHost.searchField`), and never when its author made it
    /// stick vertically, CSS's way to keep a box in view as its scroller
    /// scrolls (React Navigation's `hideWhenScrolling={false}`): `position:
    /// sticky` with a `top` or `bottom` that is not `auto` (CSS Positioned
    /// Layout 3 §3.4: a box with both `auto` does not stick on that axis).
    func applyHiding() {
        #if os(iOS)
        guard let item else { return }
        let sticks = field.map { f in
            f.layoutPosition == "sticky" && ["top", "bottom"].contains { f.style[$0]?.length(basis: 0) != nil }
        } ?? false
        let hides = (field?.props["value"] ?? "").isEmpty && !sticks
        if item.hidesSearchBarWhenScrolling != hides { item.hidesSearchBarWhenScrolling = hides }
        #endif
    }
    func willPresentSearchController(_ search: UISearchController) {
        acceptingDismissal = false
    }
    func didPresentSearchController(_ search: UISearchController) {
        #if os(iOS)
        syncSwipeDown()
        showScopes()
        #endif
    }
    func willDismissSearchController(_ search: UISearchController) {
        #if os(iOS)
        retireSwipeDown()
        #endif
        // A disappearing route keeps its query; closing search accepts UIKit's reset
        acceptingDismissal = editingCompletion == nil && host?.changing == false && host?.presenter.modals.inTransition == false
    }
    func didDismissSearchController(_ search: UISearchController) {
        let accepts = acceptingDismissal
        acceptingDismissal = false
        if accepts {
            let text = search.searchBar.text ?? ""
            searchBar(search.searchBar, textDidChange: text)
            if let field, let presenter = host?.presenter, presenter.views[field.id] === field {
                // Close also commits its reset when the Search key or a drag already ended editing
                presenter.commitEdit(field.id, text, change: field.handlers.contains("change"))
            }
        }
        applyHiding()
        #if os(iOS)
        showScopes()
        #endif
    }
    func searchBar(_ bar: UISearchBar, textDidChange text: String) {
        guard let field, let presenter = host?.presenter, presenter.views[field.id] === field else { return }
        field.typedText(text)
        field.applyFieldDirection() // a `direction` that came while it composed (LLP 1001 §1)
    }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard field?.textField(textField, shouldChangeCharactersIn: range, replacementString: string) ?? true else { return false }
        return textDelegate?.textField?(textField, shouldChangeCharactersIn: range, replacementString: string) ?? true
    }
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        guard field?.textFieldShouldClear(textField) ?? true else { return false }
        return textDelegate?.textFieldShouldClear?(textField) ?? true
    }
    func textFieldDidChangeSelection(_ textField: UITextField) {
        textDelegate?.textFieldDidChangeSelection?(textField)
        field?.textFieldDidChangeSelection(textField)
        field?.applyFieldDirection() // a `direction` that came while it composed (LLP 1001 §1)
    }
    // UISearchBar remains the recipient of UIKit's focus, return and private callbacks.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (textDelegate?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        textDelegate?.responds(to: selector) == true ? textDelegate : nil
    }
    func searchBarTextDidBeginEditing(_ bar: UISearchBar) {
        #if os(iOS)
        syncSwipeDown()
        #endif
        host?.presenter.searchEditingChanged()
        guard let field else { return }
        host?.presenter.fieldSelections.focused(field)
        host?.presenter.focus(field.id)
    }
    /// The keyboard's Search key is this field's Return (LLP 1115.000 D9.2):
    /// its `submit`, then the keyboard goes away, as a hand-built search
    /// bar's delegate resigns it, and the search stays as typed.
    func searchBarSearchButtonClicked(_ bar: UISearchBar) {
        if let field, let presenter = host?.presenter, presenter.views[field.id] === field {
            presenter.commitEdit(field.id, bar.text ?? "", change: field.handlers.contains("change"))
            if field.handlers.contains("submit") { presenter.submit(field.id) }
        }
        bar.resignFirstResponder()
    }
    func searchBarTextDidEndEditing(_ bar: UISearchBar) {
        #if os(iOS)
        retireSwipeDown()
        #endif
        host?.presenter.searchEditingChanged()
        let completion = editingCompletion
        editingCompletion = nil
        if let field, let presenter = host?.presenter, presenter.views[field.id] === field {
            // UIKit can clear a dismissed bar before delivering its end-of-editing callback
            let value = completion?.value ?? bar.text ?? ""
            presenter.commitEdit(field.id, value, change: field.handlers.contains("change"))
            presenter.blur(field.id)
        }
        if let completion { host?.presenter.afterBatch(completion.finish) }
    }

    /// Keep the authored field alive until UIKit delivers its final edit and blur.
    func endEditing(completion: @escaping () -> Void) -> Bool {
        guard let field, let presenter = host?.presenter, presenter.views[field.id] === field,
              let editor = field.headerField, editor.isEditing else { return false }
        if editingCompletion == nil {
            editingCompletion = (editor.text ?? "", completion)
            controller.isActive = false
            controller.searchBar.endEditing(true)
        }
        return true
    }

    #if os(iOS)
    private(set) var swipeDown: HeaderSearchSwipe?
    /// Attach after editing begins: UIKit replaces recognizers while mounting its search field.
    private func syncSwipeDown() {
        if let swipeDown, !swipeDown.eligible { retireSwipeDown() }
        guard swipeDown == nil, let field, controller.searchBar.searchTextField.isFirstResponder else { return }
        let swipe = HeaderSearchSwipe(self, field: field)
        swipeDown = swipe
        controller.searchBar.searchTextField.addGestureRecognizer(swipe)
        if !swipe.eligible { retireSwipeDown() }
    }
    private func retireSwipeDown() {
        if let swipeDown { swipeDown.view?.removeGestureRecognizer(swipeDown) }
        swipeDown = nil
    }
    #endif
}

#if os(iOS)
/// Dismiss the keys and keep search active; let the field's delegates commit its query and blur.
final class HeaderSearchSwipe: UISwipeGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var search: HeaderSearch?
    private let source: HeldNode
    private var began: TimeInterval?
    private var contact: PressPath?

    init(_ search: HeaderSearch, field: NodeView) {
        self.search = search
        source = HeldNode(field)
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(dismissKeyboard))
        direction = .down
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    override func reset() { super.reset(); began = nil; contact = nil }

    var eligible: Bool {
        guard let search, search.swipeDown === self, let presenter = search.host?.presenter,
              let node = source.live(in: presenter), search.field === node, !node.inert,
              let editor = view as? UISearchTextField, editor.window != nil, editor.isFirstResponder, editor.isEnabled,
              node.headerField === editor, search.item?.searchController === search.controller,
              search.controller.isActive, !search.controller.isBeingDismissed,
              presenter.menus.eligible(node, inBar: true) else { return false }
        // Check UIKit's path too; the authored header is hidden only because the bar projects it.
        return sequence(first: editor as UIView, next: \.superview).allSatisfy { !$0.isHidden && $0.isUserInteractionEnabled }
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gesture === self, eligible, touch.type == .direct, let editor = view else { return false }
        var hit = touch.view
        while let current = hit, current !== editor {
            if current is UIControl { return false }
            hit = current.superview
        }
        guard hit === editor else { return false }
        if numberOfTouches == 0, let presenter = search?.host?.presenter, let node = source.live(in: presenter) {
            began = touch.timestamp
            contact = PressPath(from: node, presenter: presenter)
        }
        return true
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === self, eligible, let began, let presenter = search?.host?.presenter,
              contact?.isLive(in: presenter) == true, let node = source.live(in: presenter) else { return false }
        return node.selectionMovedAt < began
    }
    private func nativeGesture(_ other: UIGestureRecognizer) -> Bool {
        guard !(other is DiscreteSwipe), let editor = view, let owner = other.view else { return false }
        return owner === editor || owner.isDescendant(of: editor)
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === self && nativeGesture(other)
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        gesture === self && nativeGesture(other) && other is UILongPressGestureRecognizer
    }
    @objc func dismissKeyboard() {
        guard state == .recognized, gestureRecognizerShouldBegin(self) else { return }
        _ = view?.resignFirstResponder()
    }
}

extension HeaderSearch: UISearchResultsUpdating {
    func updateSearchResults(for search: UISearchController) {
        // UIKit resets the query before ending editing, without the bar's text-change callback
        guard acceptingDismissal else { return }
        searchBar(search.searchBar, textDidChange: search.searchBar.text ?? "")
    }
}
#endif

#endif
