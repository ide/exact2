#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A bar item's face drawn from a button whose one child is a filled box
/// holding a text or a symbol (an avatar, a badge): CSS's colours and
/// corners at the bar's image size, light and dark, as the platform draws an image that retains its colours.
struct BadgeFace: Equatable {
    /// A bar item's image size; a title's avatar takes the author's.
    static let size: CGFloat = 36
    let size: CGFloat
    let text: String, symbol: String?
    let light: [[Double]], dark: [[Double]]
    let corners: [CGSize]
    /// The box's `background-image`, painted over its colour as the box paints it
    let gradient: BatchValue?
    /// The text's font where its author set one, scaled from the box's side to
    /// the face's; nil, the system's at 0.42 of the face, medium
    let font: PlatformFont?
    #if !os(macOS)
    private let darkScheme: Bool
    #endif
    init?(_ button: NodeView) {
        let kids = button.container.subviews.compactMap { $0 as? NodeView }
        guard kids.count == 1, let box = kids.first else { return nil }
        self.init(box: box)
    }
    /// The face of a filled box holding a text or a symbol (a title's
    /// avatar, §9.10, too). `authored`: draw it at the size the author gave
    /// the box (`faceBoxSize`, the authored points a replaced header has no frame for), between 20
    /// and 44, as a title's avatar is; otherwise at a bar item's 36.
    init?(box: NodeView, authored: Bool = false) {
        guard box.channels("background_color") != nil else { return nil }
        var text = "", symbol: String?, ink: NodeView?
        func walk(_ node: NodeView) {
            for case let child as NodeView in node.container.subviews {
                if child.kind == "image", let name = child.faceSymbol { symbol = symbol ?? name; ink = ink ?? child }
                else if child.isParagraph, text.isEmpty { text = child.accessibleText; ink = ink ?? child }
                else { walk(child) }
            }
        }
        walk(box)
        guard !text.isEmpty || symbol != nil else { return nil }
        let key = "text_color"
        func colours(_ dark: Bool) -> [[Double]] {
            [box.channels("background_color", dark: dark) ?? [0, 0, 0, 0], ink?.channels(key, dark: dark) ?? (dark ? [1, 1, 1, 1] : [0, 0, 0, 1])]
        }
        let given = box.props["faceBoxSize"].flatMap { s -> CGFloat? in
            let parts = s.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGFloat(min(parts[0], parts[1])) : nil
        }
        size = min(max(authored ? given ?? Self.size : Self.size, 20), 44)
        self.text = text; self.symbol = symbol
        light = colours(false); dark = colours(true)
        corners = box.cornerSizes(in: CGRect(x: 0, y: 0, width: size, height: size))
        gradient = box.style["background_image"]
        if let ink, symbol == nil, ["font_family", "font_size", "font_weight"].contains(where: ink.wrote) {
            let side = given ?? min(box.bounds.width, box.bounds.height)
            let scale = side > 0 ? size / side : 1
            font = ink.text?.font(size: ink.number("font_size", PageFacts.defaultRootFontSize) * scale, weight: min(1000, Int(ink.number("font_weight", 400))),
                                  family: Int(ink.number("font_family")), italic: ink.style["font_style"]?.string == "italic")
        } else {
            font = nil
        }
        #if !os(macOS)
        darkScheme = box.drawsDark
        #endif
    }
    // Joined by hand: interpolating an array goes through reflection, and
    // every batch builds each route's source.
    var source: String {
        let rgba = { (c: [[Double]]) in c.map { $0.map { String($0) }.joined(separator: ",") }.joined(separator: ";") }
        var source = "\(text)|\(symbol ?? "")|\(rgba(light))|\(rgba(dark))|\(corners.map { "\($0.width)x\($0.height)" }.joined(separator: ","))|\(size)|\(gradient?.key ?? "")|\(font.map { "\($0.fontName)/\($0.pointSize)" } ?? "")"
        #if !os(macOS)
        source += "|\(darkScheme)"
        #endif
        return source
    }

    #if os(macOS)
    var image: NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: true) { rect in
            let dark = NSAppearance.current.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let colours = dark ? self.dark : self.light
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let outline = BorderPaint.roundedRect(rect, self.corners, shape: nil)
            context.addPath(outline)
            context.setFillColor(TextEngine.color(colours[0]).cgColor)
            context.fillPath()
            self.paintGradient(context, clip: outline, in: rect, dark: dark)
            let ink = TextEngine.color(colours[1])
            if let symbol = self.symbol, let glyph = FaceSymbol.image(symbol, points: self.size * 0.42)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ink])) {
                glyph.draw(in: CGRect(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [.font: self.font ?? NSFont.systemFont(ofSize: self.size * 0.42, weight: .medium), .foregroundColor: ink]
                let fit = (self.text as NSString).size(withAttributes: attrs)
                (self.text as NSString).draw(at: CGPoint(x: (rect.width - fit.width) / 2, y: (rect.height - fit.height) / 2), withAttributes: attrs)
            }
            return true
        }
    }
    #else
    var image: UIImage {
        draw(darkScheme ? dark : light).withRenderingMode(.alwaysOriginal)
    }
    private func draw(_ c: [[Double]]) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { context in
            let outline = BorderPaint.roundedRect(rect, corners, shape: nil)
            TextEngine.color(c[0]).setFill()
            UIBezierPath(cgPath: outline).fill()
            paintGradient(context.cgContext, clip: outline, in: rect, dark: darkScheme)
            let ink = TextEngine.color(c[1])
            if let symbol, let glyph = FaceSymbol.image(symbol, points: size * 0.42, configuration: UIImage.SymbolConfiguration(pointSize: size * 0.42))?.withTintColor(ink, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [.font: font ?? UIFont.systemFont(ofSize: size * 0.42, weight: .medium), .foregroundColor: ink]
                let s = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: CGPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2), withAttributes: attrs)
            }
        }
    }
    #endif

    /// The box's gradients over its colour, the last layer first so the first is on top (LLP 1077 D5)
    private func paintGradient(_ context: CGContext, clip: CGPath, in rect: CGRect, dark: Bool) {
        for layer in Gradient.layers(gradient).reversed() { layer.paint(context, clip: clip, box: rect, dark: dark) }
    }
}

