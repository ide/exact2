// Every `button` is a UIButton (exact2 on iOS): UIKit tracks its touch —
// the highlight, the cancel when a finger drags off or a scroll takes it,
// the disabled state, accessibility — and a release inside presses the node
// (or opens the confirmation it invokes) as a tap on the box would.
//
// How it looks is still the author's box, the content dimming while held
// as a system custom button's does (or easing to its `press-scale`, when
// it has one). Two looks are the platform's own: a button whose material
// is glass, and one naming a configuration with `-exact-apple-button-style`
// (Exact's vendor property for Apple's own button styles, which only the
// Apple hosts read: `glass`, `prominent-glass`, `filled`, `gray`, `tinted`,
// `plain`; another platform's would be its own property). Its one text is the title (its font
// and colour) and its one symbol image the image (size, weight, tint),
// placed as the boxes stand; `accent-color` is a filled style's background.
// Those boxes then paint nowhere else. A button whose content is richer
// keeps the author's look.
#if os(iOS)
import UIKit

final class NativeButtonHost {
    private weak var presenter: Presenter?
    private var buttons: [UInt32: NativeButton] = [:]
    init(presenter: Presenter) { self.presenter = presenter }

    /// After a batch: every button's UIButton made or brought up to date.
    func sync() {
        guard let presenter else { return }
        for id in presenter.buttonNodes {
            guard let v = presenter.views[id], v.kind == "button" else {
                buttons.removeValue(forKey: id)?.detach()
                presenter.buttonNodes.remove(id)
                continue
            }
            let b = buttons[id].flatMap { $0.owner === v ? $0 : nil } ?? NativeButton(owner: v)
            buttons[id] = b
            b.update()
        }
        for (id, b) in buttons where !presenter.buttonNodes.contains(id) {
            b.detach()
            buttons[id] = nil
        }
    }

    func reset() {
        buttons.values.forEach { $0.detach() }
        buttons.removeAll()
    }
}

final class NativeButton: UIButton {
    weak var owner: NodeView?
    /// Boxes the configuration draws instead.
    private var drawn: [NodeView] = []
    private var configured = false
    private var signature = ""

    init(owner: NodeView) {
        self.owner = owner
        super.init(frame: owner.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addAction(UIAction { [weak self] _ in
            guard let owner = self?.owner, let presenter = owner.presenter, presenter.views[owner.id] === owner,
                  !owner.disabled else { return }
            // A press blurs the field being edited, as a click on a button
            // blurs a page's input (NodeView's own tap did the same).
            if presenter.contextRetainsFocus(owner) != true { presenter.viewport.endEditing(true) }
            if !presenter.menus.invokeConfirmation(owner) { presenter.press(owner.id) }
        }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet {
            guard !configured, isHighlighted != oldValue, let owner else { return }
            if owner.number("press_scale", 1) != 1 { owner.pressed = isHighlighted; return }
            let views = owner.container.subviews.filter { $0 is NodeView }
            if isHighlighted { views.forEach { $0.alpha = 0.5 } }
            else {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    views.forEach { $0.alpha = 1 }
                }
            }
        }
    }

    func detach() {
        drawn.forEach { $0.isHidden = false }
        drawn = []
        owner?.materialView?.isHidden = false
        removeFromSuperview()
    }

    func update() {
        guard let owner else { return }
        if superview !== owner { owner.addSubview(self) }
        if frame != owner.bounds { frame = owner.bounds }
        if owner.subviews.last !== self { owner.bringSubviewToFront(self) }
        isEnabled = !owner.disabled
        accessibilityIdentifier = owner.props["testId"] ?? owner.props["id"]
        accessibilityLabel = owner.props["accessibilityLabel"]

        let explicit = owner.style["exact_apple_button_style"]?.string.flatMap { $0 == "none" ? nil : $0 }
        let glass = Materials.glass(owner.materialRequest)
        var nodes: [NodeView] = []
        func collect(_ v: UIView) {
            for case let n as NodeView in v.subviews where n !== owner { nodes.append(n); collect(n.container) }
        }
        if explicit != nil || glass { collect(owner.container) }
        let texts = nodes.filter { $0.kind == "text" }
        let symbols = nodes.filter { $0.kind == "image" && ($0.imageSource ?? "").hasPrefix("symbol:") }
        let simple = (explicit != nil || glass) && texts.count <= 1 && symbols.count <= 1 && !(texts.isEmpty && symbols.isEmpty)
            && nodes.allSatisfy { texts.contains($0) || symbols.contains($0) || ($0.kind == "view" && $0.handlers.isEmpty) }
        guard simple else {
            if configured || !drawn.isEmpty {
                configuration = nil
                drawn.forEach { $0.isHidden = false }
                drawn = []
                owner.materialView?.isHidden = false
                configured = false
                signature = ""
            }
            return
        }
        let style = explicit ?? "glass"
        let text = texts.first, symbol = symbols.first
        let title = text.map { $0.paragraphSpec().runs.map(\.text).joined() }
        let radius = owner.number("border_radius", owner.number("border_radius_top_left"))
        let a = symbol.map { $0.convert($0.bounds, to: owner) } ?? .zero, b = text.map { $0.convert($0.bounds, to: owner) } ?? .zero
        let key = [style, title ?? "", symbol?.props["symbolName"] ?? "", "\(symbol?.number("font_size") ?? 0)",
                   "\(symbol?.color("tint_color", .label) ?? .clear)", "\(text?.color("text_color", .label) ?? .clear)",
                   "\(text?.number("font_size") ?? 0)", "\(text?.number("font_weight") ?? 0)", "\(radius)", "\(owner.bounds.size)",
                   "\(a)", "\(b)", "\(owner.color("accent_color", .clear))"].joined(separator: "|")
        if key != signature {
            signature = key
            configuration = NativeButton.configuration(style, owner: owner, text: text, symbol: symbol, title: title, radius: radius, symbolBox: a, textBox: b)
        }
        configured = true
        drawn.filter { !nodes.contains($0) }.forEach { $0.isHidden = false }
        drawn = nodes
        nodes.forEach { if !$0.isHidden { $0.isHidden = true } }
        if glass { owner.materialView?.isHidden = true }
    }

    private static func configuration(_ style: String, owner: NodeView, text: NodeView?, symbol: NodeView?, title: String?,
                                      radius: CGFloat, symbolBox a: CGRect, textBox b: CGRect) -> UIButton.Configuration {
        var config: UIButton.Configuration
        switch style {
        case "glass": if #available(iOS 26.0, *) { config = .glass() } else { config = .gray() }
        case "prominent-glass": if #available(iOS 26.0, *) { config = .prominentGlass() } else { config = .filled() }
        case "filled": config = .filled()
        case "gray": config = .gray()
        case "tinted": config = .tinted()
        default: config = .plain()
        }
        let short = min(owner.bounds.width, owner.bounds.height)
        config.cornerStyle = radius > 0 && radius * 2 >= short - 0.5 ? .capsule : .fixed
        if config.cornerStyle == .fixed { config.background.cornerRadius = radius }
        let accent = owner.color("accent_color", .clear)
        if accent != .clear { config.baseBackgroundColor = accent }
        if let text, let title {
            config.title = title
            let font = UIFont.systemFont(ofSize: text.number("font_size", 17), weight: weight(text.number("font_weight", 400)))
            let color = text.color("text_color", .label)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming; out.font = font; out.foregroundColor = color; return out
            }
            config.titleLineBreakMode = .byTruncatingTail
            config.baseForegroundColor = color
        }
        if let symbol {
            let points = symbol.number("font_size", 17)
            config.image = UIImage(systemName: symbol.props["symbolName"] ?? "",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: points, weight: symbolWeight(symbol.number("font_weight", 400))))?
                .withTintColor(symbol.color("tint_color", .label), renderingMode: .alwaysOriginal)
        }
        // Layout rows stay in the kernel: the boxes' frames say how the
        // symbol and the title stand, and how far apart.
        if symbol != nil, text != nil {
            let stacked = b.minY >= a.maxY - 1
            config.imagePlacement = stacked ? .top : .leading
            let glyph = config.image?.size ?? a.size
            config.imagePadding = max(0, stacked ? b.minY - a.maxY + (a.height - glyph.height) / 2 : b.minX - a.maxX + (a.width - glyph.width) / 2)
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        return config
    }

    static func weight(_ w: CGFloat) -> UIFont.Weight {
        switch w { case ..<150: .ultraLight; case ..<250: .thin; case ..<350: .light; case ..<450: .regular
        case ..<550: .medium; case ..<650: .semibold; case ..<750: .bold; case ..<850: .heavy; default: .black }
    }
    static func symbolWeight(_ w: CGFloat) -> UIImage.SymbolWeight {
        switch w { case ..<150: .ultraLight; case ..<250: .thin; case ..<350: .light; case ..<450: .regular
        case ..<550: .medium; case ..<650: .semibold; case ..<750: .bold; case ..<850: .heavy; default: .black }
    }
}
#endif
