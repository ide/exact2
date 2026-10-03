// A symbol image on UIKit (`image "symbol:<role>"`, LLP 1011, 1035.004.000):
// the node stays an image leaf; a UIImageView draws the glyph and its tint.
// Moved out of NodeViewIOS.swift (the 1,500-line cap), as NodeSymbolMac.swift.
#if os(iOS) || os(tvOS)
import UIKit

extension NodeView {
    // A symbol's box is Exact's; UIKit renders its glyph, including pixel alignment.
    func clearSymbol() {
        symbolView?.removeFromSuperview(); symbolView = nil; symbolKey = nil; symbolFound = false
    }
    func updateSymbol() {
        guard kind == "image", let source = imageSource, source.hasPrefix("symbol:") else { return }
        isAccessibilityElement = false
        let name = props["symbolName"] ?? "", points = number("font_size", 16)
        let weights: [UIImage.SymbolWeight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let index = min(8, max(0, Int((number("font_weight", 400) / 100).rounded()) - 1))
        let key = "\(source):\(name):\(points):\(index):\(symbolLookKey)"
        if symbolKey != key {
            symbolKey = key; loadGeneration += 1
            let generation = loadGeneration
            image = name.isEmpty ? nil : symbolImage(name, symbolConfiguration(UIImage.SymbolConfiguration(pointSize: points > 0 ? points : 1, weight: weights[index])))
            symbolFound = image != nil; if points <= 0 { image = nil }
            if name.isEmpty, !source.hasPrefix("symbol:sf/"), symbolRefusal != source { symbolRefusal = source; presenter?.session?.log("image \(source) refused: unknown symbol role") }
            if !name.isEmpty || source.hasPrefix("symbol:sf/") { symbolRefusal = nil }
            let leaf = symbolView ?? UIImageView()
            if symbolView == nil { symbolView = leaf; addSubview(leaf) }
            // An authored colour is the symbol's own, drawn into it: UIKit
            // dims a tint behind an alert, and only the accent should dim
            // (SwiftUI's foregroundStyle stays; its tint greys).
            let mono = (style["symbol_rendering"]?.string ?? "monochrome") == "monochrome"
            if mono, let own = symbolTint { image = image?.withTintColor(own, renderingMode: .alwaysOriginal) }
            showSymbol(image, on: leaf); leaf.isAccessibilityElement = false; leaf.isUserInteractionEnabled = false
            // The size layout measured already (SymbolMeasure): no move.
            presenter?.queueIntrinsicSize(self, generation: generation, SymbolMeasure.size(name, points: points, weight: number("font_weight", 400)))
        }
        symbolView?.tintColor = symbolTint // `nil` inherits UIKit's live tint
        if let leaf = symbolView { applySymbolEffect(leaf) }
        layoutSymbol()
    }
    func layoutSymbol() {
        guard let leaf = symbolView else { return }
        let uniform = number("border_width")
        let content = bounds.insetBy(left: number("border_width_left", uniform) + number("padding_left"), top: number("border_width_top", uniform) + number("padding_top"), right: number("border_width_right", uniform) + number("padding_right"), bottom: number("border_width_bottom", uniform) + number("padding_bottom"))
        leaf.frame = content; leaf.clipsToBounds = true
        switch style["object_fit"]?.string ?? "fill" {
        case "contain": leaf.contentMode = .scaleAspectFit
        case "cover": leaf.contentMode = .scaleAspectFill
        case "none": leaf.contentMode = .center
        case "scale-down":
            let size = image?.size ?? .zero
            leaf.contentMode = size.width <= content.width && size.height <= content.height ? .center : .scaleAspectFit
        default: leaf.contentMode = .scaleToFill
        }
        // A square box clips nothing the content box does not.
        if cornerRadii(in: bounds).allSatisfy({ $0 == 0 }) { if leaf.layer.mask != nil { leaf.layer.mask = nil }; return }
        let path = roundedPath(in: bounds).cgPath
        var transform = CGAffineTransform(translationX: -content.minX, y: -content.minY)
        let mask = CAShapeLayer(); mask.path = path.copy(using: &transform); leaf.layer.mask = mask
    }
}
#endif
