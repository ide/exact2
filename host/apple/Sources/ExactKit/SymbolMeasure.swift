// @ref LLP 1035.004.000 — a system symbol's box, measured in layout as a
// paragraph is (exact_set_symbol_measure), so the first layout has it; the
// view that draws the glyph reports the same size from the same function,
// so nothing moves when it does.
import CExact
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum SymbolMeasure {
    /// The glyph for `name` at `points` and a CSS weight, nil when the OS has
    /// none by that name.
    static func image(_ name: String, points: CGFloat, weight: CGFloat) -> SymbolImage? {
        guard !name.isEmpty else { return nil }
        let index = min(8, max(0, Int((weight / 100).rounded()) - 1))
        let size = points > 0 ? points : 1
        #if os(iOS)
        let weights: [UIImage.SymbolWeight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weights[index]))
        #else
        let weights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weights[index]))
        #endif
    }

    /// The box a symbol takes: its glyph's size, or an em square when the OS
    /// has no such glyph (LLP 1035.004.000 D2); none at a point size of 0.
    static func size(_ name: String, points: CGFloat, weight: CGFloat) -> CGSize? {
        guard points > 0 else { return nil }
        return image(name, points: points, weight: weight)?.size ?? CGSize(width: points, height: points)
    }

    /// The kernel's symbol measurer, on the runtime's thread.
    static let measure: ExactSymbolFn = { _, name, len, points, weight, out in
        guard let out else { return 0 }
        let text = name != nil && len > 0 ? String(decoding: UnsafeBufferPointer(start: name, count: len), as: UTF8.self) : ""
        guard let size = SymbolMeasure.size(text, points: CGFloat(points), weight: CGFloat(weight)) else { return 0 }
        out[0] = Float(size.width); out[1] = Float(size.height)
        return 1
    }
}
