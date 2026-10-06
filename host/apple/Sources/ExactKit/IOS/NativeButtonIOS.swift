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
            presenter.press(owner.id)
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

    /// Recognizers already made to wait for their scroll view.
    private var waiting = Set<ObjectIdentifier>()

    /// Interactive glass answers a touch through its own recognizers, which
    /// UIScrollView's `delaysContentTouches` does not hold back: in a scroll
    /// view the glass would swell under every swipe. Each of them waits for
    /// the scroll view's delayed-touch recognizer to fail — the moment the
    /// scroll view has decided the touch is not a scroll, when an ordinary
    /// button highlights too.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard configured else { return }
        var ancestor = superview
        while let v = ancestor, !(v is UIScrollView) { ancestor = v.superview }
        guard let scroll = ancestor as? UIScrollView, scroll.delaysContentTouches,
              let delay = scroll.gestureRecognizers?.first(where: { NSStringFromClass(type(of: $0)).contains("DelayedTouchesBegan") })
        else { return }
        func walk(_ v: UIView) {
            for g in v.gestureRecognizers ?? [] where waiting.insert(ObjectIdentifier(g)).inserted {
                g.require(toFail: delay)
            }
            v.subviews.forEach(walk)
        }
        walk(self)
    }

    func detach() {
        drawn.forEach { $0.isHidden = false }
        drawn = []
        owner?.materialView?.isHidden = false
        removeFromSuperview()
    }

    /// The tint dims behind an alert and comes back after it: a face drawn
    /// in `AccentColor` is drawn again in the tint as it now is.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        if configured { update() }
    }

    func update() {
        guard let owner else { return }
        if superview !== owner { owner.addSubview(self) }
        if frame != owner.bounds { frame = owner.bounds }
        if owner.subviews.last !== self { owner.bringSubviewToFront(self) }
        // Its configuration follows at once: UIKit would otherwise draw its
        // own disabled (or enabled) look for a frame before the handler ran.
        if isEnabled == owner.disabled {
            isEnabled = !owner.disabled
            if configured { updateConfiguration() }
        }
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
                   "\(a)", "\(b)", "\(owner.color("accent_color", .clear))", "\(tintColor.resolvedColor(with: traitCollection))"].joined(separator: "|")
        if key != signature {
            signature = key
            var rest = NativeButton.configuration(style, owner: owner, text: text, symbol: symbol, title: title, radius: radius, symbolBox: a, textBox: b, accent: tintColor)
            let (align, inset) = NativeButton.horizontal([a, b], in: owner.bounds.width,
                                                             rtl: effectiveUserInterfaceLayoutDirection == .rightToLeft)
            if contentHorizontalAlignment != align { contentHorizontalAlignment = align }
            rest.contentInsets = inset
            // SwiftUI's bordered styles dim the whole button while pressed,
            // its label too; UIKit's configurations darken only the fill.
            let tint: UIColor = symbol.map { $0.followsTint("tint_color") ? tintColor : $0.color("tint_color", .label) } ?? .label
            let dimImage = rest.image?.withTintColor(tint.withAlphaComponent(0.5), renderingMode: .alwaysOriginal)
            let titleTransformer = rest.titleTextAttributesTransformer
            // The handler goes in before the configuration: assigning a
            // configuration runs the handler installed then, and the old one
            // put the old configuration back (a padding measured after the
            // first layout stayed unshown until a trait change ran the new
            // handler). A plain button's press fade is UIKit's own.
            //
            // Disabled, a system style (filled, tinted, gray, glass) is
            // UIKit's own disabled look, fill and label together. A plain
            // button whose author paints its fill keeps its own colours, as
            // HTML keeps an author's on a disabled button: UIKit's grey would
            // replace only the label, leaving that fill bright behind it.
            let authoredFill = style == "plain" && owner.color("background_color", .clear) != .clear
            configurationUpdateHandler = { button in
                var config = rest
                if !button.isEnabled && authoredFill {
                    config.image = rest.image?.withTintColor(tint, renderingMode: .alwaysOriginal)
                    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                        var out = titleTransformer?(incoming) ?? incoming
                        out.foregroundColor = rest.baseForegroundColor ?? .label
                        return out
                    }
                } else if style != "plain" && button.isHighlighted {
                    config.image = dimImage ?? config.image
                    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                        var out = titleTransformer?(incoming) ?? incoming
                        out.foregroundColor = (rest.baseForegroundColor ?? .label).withAlphaComponent(0.5)
                        return out
                    }
                }
                button.configuration = config
            }
            configuration = rest
            // Behind an alert UIKit dims the tint (the accent) to grey, as the
            // platform should; every other colour here is authored (a title's
            // `color`, a symbol's `tint-color`, an `accent-color` fill) and
            // keeps its look, as SwiftUI's foregroundStyle does. Only a fill
            // the configuration takes from the tint still follows it.
            let fills = ["filled", "tinted", "prominent-glass"].contains(style)
            let fromTint = (fills && (owner.color("accent_color", .clear) == .clear || owner.followsTint("accent_color")))
                || (style == "plain" && text?.followsTint("text_color") == true) || symbol?.followsTint("tint_color") == true
            let adjust: UIView.TintAdjustmentMode = fromTint ? .automatic : .normal
            if tintAdjustmentMode != adjust { tintAdjustmentMode = adjust }
        }
        configured = true
        drawn.filter { !nodes.contains($0) }.forEach { $0.isHidden = false }
        drawn = nodes
        nodes.forEach { if !$0.isHidden { $0.isHidden = true } }
        if glass { owner.materialView?.isHidden = true }
    }

    private static func configuration(_ style: String, owner: NodeView, text: NodeView?, symbol: NodeView?, title: String?,
                                      radius: CGFloat, symbolBox a: CGRect, textBox b: CGRect, accent tintNow: UIColor) -> UIButton.Configuration {
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
        // An `AccentColor` fill is left to the configuration, which takes it
        // from the tint and so dims it with the tint.
        if accent != .clear, !owner.followsTint("accent_color") { config.baseBackgroundColor = accent }
        if let text, let title {
            config.title = title
            let font = UIFont.systemFont(ofSize: text.number("font_size", 17), weight: weight(text.number("font_weight", 400)))
            // `AccentColor` is the tint as UIKit draws it now: grey behind an
            // alert (the button redraws when it changes, tintColorDidChange).
            let color = text.followsTint("text_color") ? tintNow : text.color("text_color", .label)
            // The font only: the colour is the configuration's foreground,
            // which UIKit itself fades while a plain button is held.
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming; out.font = font; return out
            }
            config.titleLineBreakMode = text.number("line_clamp", 0) == 1 ? .byTruncatingTail : .byWordWrapping
            config.baseForegroundColor = color
        }
        if let symbol {
            let points = symbol.number("font_size", 17)
            let sized = UIImage.SymbolConfiguration(pointSize: points, weight: symbolWeight(symbol.number("font_weight", 400)))
            // The authored size, not the scale a configuration would pick for
            // its button's size.
            config.preferredSymbolConfigurationForImage = sized
            let glyph = UIImage(systemName: symbol.props["symbolName"] ?? "", withConfiguration: sized)
            let tint = symbol.followsTint("tint_color") ? tintNow : symbol.color("tint_color", .label)
            if text == nil { config.baseForegroundColor = tint }
            // A symbol in the title's colour is a template UIKit tints and
            // fades with it; one of its own colour is drawn in it.
            let traits = owner.traitCollection
            // Only plain tints its template with the foreground; the other
            // styles draw the symbol in its own colour.
            let same = style == "plain" && (config.baseForegroundColor.map { $0.resolvedColor(with: traits) == tint.resolvedColor(with: traits) } ?? false)
            config.image = same ? glyph : glyph?.withTintColor(tint, renderingMode: .alwaysOriginal)
        }
        // Layout rows stay in the kernel: the boxes' frames say how the
        // symbol and the title stand, and how far apart.
        if symbol != nil, text != nil {
            let stacked = b.minY >= a.maxY - 1
            config.imagePlacement = stacked ? .top : .leading
            let glyph = config.image?.size ?? a.size
            config.imagePadding = max(0, stacked ? b.minY - a.maxY + (a.height - glyph.height) / 2 : b.minX - a.maxX + (a.width - glyph.width) / 2)
        }
        // The kernel sized the box for its content; the configuration adds
        // no padding of its own that would make a fitted title truncate.
        config.contentInsets = .zero
        return config
    }

    /// Where the kernel stood the content across the box: centred (UIKit's
    /// default), or against one side as far in as the boxes are — a row
    /// starting at its padding, as `justify-content` and the padding put it.
    /// The boxes are physical; the insets directional, so right to left
    /// the left gap is the trailing one.
    static func horizontal(_ boxes: [CGRect], in width: CGFloat, rtl: Bool = false) -> (UIControl.ContentHorizontalAlignment, NSDirectionalEdgeInsets) {
        let laid = boxes.filter { !$0.isEmpty }
        guard let first = laid.first else { return (.center, .zero) }
        let content = laid.dropFirst().reduce(first) { $0.union($1) }
        let left = content.minX, right = width - content.maxX
        if abs(left - right) <= 1 { return (.center, .zero) }
        let (start, end) = rtl ? (max(0, right), max(0, left)) : (max(0, left), max(0, right))
        return left < right ? (.left, NSDirectionalEdgeInsets(top: 0, leading: rtl ? 0 : start, bottom: 0, trailing: rtl ? end : 0))
            : (.right, NSDirectionalEdgeInsets(top: 0, leading: rtl ? start : 0, bottom: 0, trailing: rtl ? 0 : end))
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
