// Behind a modal UIKit greys a control as a whole (`tintAdjustmentMode`): a
// configured button's title and symbol, whatever their colours. A button
// Exact draws itself (a `button` with no `appearance`) is boxes and text of
// the author's colours, which no tint reaches, so behind a modal it shows a
// picture of itself, greyed and faded, standing where it stands while the
// box itself is masked to nothing, as a CSS `filter` shows (`BoxFilter`). It
// still takes hits and is still what the accessibility tree reads. Content
// outside a control keeps its colours, as a label's do: a symbol there does
// not follow the tint's dimming, nor does the box it is drawn from (`NodeView.updateSymbol`).
#if os(iOS) || os(tvOS)
import UIKit

final class ControlDim {
    /// The greyed picture, in the box's superlayer just above it
    let picture = CALayer()
    /// The box's mask while dimmed (nothing of it shows), and the one it had
    private let hide = CALayer()
    private let mask: CALayer?

    /// How strongly the picture shows: UIKit's dimmed foreground reads about
    /// as light as label grey at this opacity on a light or dark ground
    static let opacity: Float = 0.45

    init?(_ box: NodeView) {
        guard let parent = box.layer.superlayer, box.bounds.width > 0, box.bounds.height > 0,
              let image = Self.greyed(box.layer, scale: box.window?.screen.scale ?? box.traitCollection.displayScale) else { return nil }
        mask = box.layer.mask
        for l in [picture, hide] { l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "transform": NSNull()] }
        picture.contents = image
        picture.contentsScale = box.window?.screen.scale ?? box.traitCollection.displayScale
        picture.bounds = box.layer.bounds
        picture.anchorPoint = box.layer.anchorPoint
        picture.position = box.layer.position
        picture.transform = box.layer.transform
        picture.opacity = box.layer.opacity * Self.opacity
        parent.insertSublayer(picture, above: box.layer)
        box.layer.mask = hide
    }

    /// The box's own look again
    func remove(from box: NodeView) {
        picture.removeFromSuperlayer()
        if box.layer.mask === hide { box.layer.mask = mask }
    }

    /// The layer as it shows, with every colour's saturation taken away: a
    /// saturation blend of grey over it, inside its own alpha.
    private static func greyed(_ layer: CALayer, scale: CGFloat) -> CGImage? {
        let size = layer.bounds.size
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let mask = layer.mask
        layer.mask = nil
        layer.render(in: ctx)
        layer.mask = mask
        guard let drawn = ctx.makeImage() else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.resetClip()
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.clip(to: full, mask: drawn)
        ctx.setBlendMode(.saturation)
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(full)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

extension NodeView {
    /// A button Exact draws itself, greyed as a whole behind a modal
    func syncControlDim() {
        let dims = kind == "button" && !isNativeButton && tintAdjustmentMode == .dimmed && !hasBoxFilter && window != nil
        if dims, controlDim == nil {
            controlDim = ControlDim(self)
        } else if !dims, let dim = controlDim {
            controlDim = nil
            dim.remove(from: self)
            applyBoxMask()
        }
    }
}
#endif
