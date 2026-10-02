// CSS `user-select: text | all` on iOS. A label there is never selected in
// place: a long press on it offers the system edit menu's Copy for its whole
// text, as SwiftUI's `textSelection` does on iPhone. The box's text is its
// own (a `text` node) or its descendants', in order, joined by spaces.
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

    /// Installs or removes the menu as the node's `user-select` says. An
    /// author's `contextmenu` handler owns the long press, so it wins.
    static func apply(_ view: NodeView) {
        let on = ["text", "all"].contains(view.style["user_select"]?.string ?? "auto") && !view.handlers.contains("contextmenu")
        if on, view.textCopy == nil { view.textCopy = TextCopy(view) }
        if !on, let copy = view.textCopy {
            view.removeGestureRecognizer(copy.press)
            view.removeInteraction(copy.menu)
            view.accessibilityCustomActions = nil
            view.textCopy = nil
        }
    }

    /// What Copy writes: the node's text as it reads, without the parts
    /// that say `user-select: none` (CSS leaves those out of a copy).
    static func text(of view: NodeView) -> String {
        if view.style["user_select"]?.string == "none" { return "" }
        if view.kind == "text" { return view.paragraphSpec().runs.map(\.text).joined() }
        return view.container.subviews
            .compactMap { ($0 as? NodeView).map(text(of:)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
