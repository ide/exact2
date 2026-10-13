// @ref LLP 1069.001 D5 — `input type="range"` is a `UISlider`: HTML's
// `input` as the thumb moves, `change` as the finger lifts, each value
// clamped and snapped to `step` as HTML sanitizes it, and the thumb with it,
// as a browser's moves from step to step (`step="any"` glides) with no tick
// marks, as HTML draws none without a `list`; the thumb stays where the
// person put it until the bound value changes (D4, amended).
#if os(iOS)
import UIKit

extension ControlHost {
    func makeRange() -> UIControl {
        let slider = UISlider()
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(rangeMoved(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(rangeReleased(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func configureRange(_ slider: UISlider, _ owner: NodeView, accent: UIColor?, keepsTint: Bool = false) {
        let range = RangeSpec(owner.props)
        assign(slider, \.minimumValue, Float(range.min))
        assign(slider, \.maximumValue, Float(range.max))
        // The accent is the slider's tint, which draws its filled track as a default slider's: grey behind a modal
        if !keepsTint { assign(slider, \.tintColor, accent) }
        // The bound value is written when it changes, as the web build writes
        // an input's `value` (LLP 1069.001 D4, amended 2026-10-04).
        let bound = owner.props["value"] ?? ""
        if !slider.isTracking, appliedRange[owner.id] != bound {
            appliedRange[owner.id] = bound
            let shown = Float(range.shown(owner.props))
            if slider.value != shown { slider.setValue(shown, animated: false) }
        }
        assign(slider, \.accessibilityValue, RangeSpec.format(range.sanitize(Double(slider.value))))
    }

    /// The value the slider reports: its position, snapped as HTML would.
    private func reported(_ slider: UISlider) -> (UInt32, String)? {
        let id = UInt32(slider.tag)
        guard let owner = presenter.views[id] else { return nil }
        return (id, RangeSpec.format(RangeSpec(owner.props).sanitize(Double(slider.value))))
    }

    @objc func rangeMoved(_ slider: UISlider) {
        guard let (id, value) = reported(slider) else { return }
        // Snap the thumb to the step as it moves
        if let snapped = Float(value), slider.value != snapped { slider.value = snapped }
        guard value != lastRange[id] else { return }
        lastRange[id] = value
        presenter.controlValue(id, value, input: true, change: false)
    }

    @objc func rangeReleased(_ slider: UISlider) {
        // Cleared before the liveness check, so a slider whose row went
        // mid-drag leaves nothing behind.
        lastRange[UInt32(slider.tag)] = nil
        guard let (id, value) = reported(slider) else { return }
        presenter.controlValue(id, value, input: false, change: true)
        if let owner = presenter.views[id] { configureRange(slider, owner, accent: nil, keepsTint: true) }
    }

    /// The agent's `type <range> <n>` (D9): the value a drag released
    /// there reports, `input` then `change`.
    func typeRange(_ slider: UISlider, _ node: NodeView, _ text: String) -> [String: Any] {
        guard let n = Double(text.trimmingCharacters(in: .whitespaces)), n.isFinite else { return ["error": "\"\(text)\" is not a number"] }
        let value = RangeSpec.format(RangeSpec(node.props).sanitize(n))
        slider.setValue(Float(value) ?? slider.value, animated: false)
        presenter.controlValue(node.id, value, input: true, change: true)
        if let owner = presenter.views[node.id] { configureRange(slider, owner, accent: nil, keepsTint: true) }
        return ["typed": Int(node.id), "value": RangeSpec.format(RangeSpec(node.props).sanitize(Double(slider.value))), "delivery": "host-activation", "native": "control"]
    }
}
#endif
