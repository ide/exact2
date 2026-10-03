// @ref CSS UI 4 §6.1 — `user-select` on iOS, its used value as the spec's
// (`UserSelect.swift`). Exact's iOS UA sheet makes the root's parent `none`
// (LLP 1001), as UIKit selects no label, so nothing is selectable until an
// author says so. A label is never selected in place there (LLP
// 1001's declared deviation): a box that starts a selectable region gives a
// long press the system edit menu's Copy for that region's text, as
// SwiftUI's `textSelection` does on iPhone.
#if os(iOS)
import UIKit

final class TextCopy: NSObject, UIEditMenuInteractionDelegate {
    weak var owner: NodeView?
    let press: UILongPressGestureRecognizer
    private(set) var menu: UIEditMenuInteraction!

    init(_ owner: NodeView) {
        self.owner = owner
        press = UILongPressGestureRecognizer()
        super.init()
        press.addTarget(self, action: #selector(pressed(_:)))
        press.delaysTouchesEnded = false
        // The node's own arbitration: a field or editor inside keeps its
        // long press (loupe, selection), as `contextmenu`'s does.
        press.delegate = owner
        menu = UIEditMenuInteraction(delegate: self)
        owner.addGestureRecognizer(press)
        owner.addInteraction(menu)
        // VoiceOver's way to the same Copy: a long press is not.
        owner.accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Copy")) { [weak owner] _ in
            guard let owner else { return false }
            UIPasteboard.general.string = TextCopy.text(of: owner)
            return true
        }]
    }

    func remove() {
        guard let owner else { return }
        owner.removeGestureRecognizer(press)
        owner.removeInteraction(menu)
        owner.accessibilityCustomActions = nil
    }

    /// Whether `view` starts a selectable region: its used value is `text`,
    /// `contain` or `all`, set on it (`auto` only continues its parent's),
    /// and not inside an `all` it belongs to, which is selected whole. An
    /// editable element keeps its own selection; an author's `contextmenu`
    /// owns the long press.
    static func starts(_ view: NodeView) -> Bool {
        guard !view.editsText, !view.handlers.contains("contextmenu") else { return false }
        let computed = view.style["user_select"]?.string ?? "auto"
        guard ["text", "contain", "all"].contains(computed) else { return false }
        return !(computed == "all" && view.parentNode?.userSelect == "all")
    }

    /// After a batch: the nodes that start a region have the menu, and no
    /// others. Only nodes that set a selectable value can start one.
    static func sync(_ p: Presenter) {
        var starting = Set<UInt32>()
        for id in p.selectableNodes {
            if let view = p.views[id], starts(view) { starting.insert(id) }
        }
        for id in p.copyNodes.subtracting(starting) {
            p.views[id]?.textCopy?.remove()
            p.views[id]?.textCopy = nil
        }
        for id in starting.subtracting(p.copyNodes) {
            if let view = p.views[id] { view.textCopy = TextCopy(view) }
        }
        p.copyNodes = starting
    }

    /// What Copy writes: the region's text in order, each node's by its
    /// used value. A `none` node is left out, but not its descendants that
    /// are selectable again; a secure field's text never is.
    static func text(of view: NodeView) -> String {
        text(of: view, parentUsed: view.parentNode?.userSelect ?? "none")
    }
    private static func text(of view: NodeView, parentUsed: String) -> String {
        let used = view.userSelect(parentUsed: parentUsed)
        var parts: [String] = []
        if used != "none" {
            if view.kind == "text" {
                let text = view.paragraphSpec().runs.map(\.text).joined() as NSString
                parts.append(view.selectableText(text, in: NSRange(location: 0, length: text.length), used: used))
            }
            if let f = view.field, !f.isSecureTextEntry, let t = f.text { parts.append(t) }
            if let t = view.textArea?.text { parts.append(t) }
        }
        for case let child as NodeView in view.container.subviews {
            parts.append(text(of: child, parentUsed: used))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let owner, !owner.disabled, !owner.inert, !TextCopy.text(of: owner).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let at = CGPoint(x: owner.bounds.midX, y: owner.bounds.minY)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: at))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let owner else { return nil }
        let copy = UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = TextCopy.text(of: owner)
        }
        return UIMenu(children: [copy])
    }

    /// The menu points at the box, as at a selected label.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        owner?.bounds ?? .zero
    }
}
#endif
