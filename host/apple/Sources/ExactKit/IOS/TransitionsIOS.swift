// A CSS transition Core Animation plays (the host's `animate` op): the engine
// handed it over (`Engine::play_transition`) and presents its target, which the
// same batch's `present` sets as the model value; this adds the curve, the
// engine's own values played linearly, so a fade costs one op instead of a
// batch a frame. A transition that turns back replaces it from where the
// engine says it stands. Under the agent the engine samples instead.
#if os(iOS) || os(tvOS)
import QuartzCore
import UIKit

extension Presenter {
    func playTransition(_ op: BatchOp) {
        let id = op.id
        // A flat leaf draws into its parent's layer: it needs its own to fade.
        if flats.isFlat(id) { flats.promote(id) }
        guard let view = views[id] ?? leaving[id]?.view, op.payload["property"] as? String == "opacity",
              let values = (op.payload["values"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), values.count >= 2
        else { return }
        let duration = (op.payload["duration"] as? NSNumber)?.doubleValue ?? 0
        let delay = (op.payload["delay"] as? NSNumber)?.doubleValue ?? 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = values.map { NSNumber(value: $0) }
        fade.calculationMode = .linear
        fade.duration = max(duration, 1.0 / 60)
        if delay > 0 { fade.beginTime = CACurrentMediaTime() + delay }
        // Before it starts, its first value shows, as a delayed CSS
        // transition holds its start value.
        fade.fillMode = .backwards
        view.layer.add(fade, forKey: "exact.transition.opacity")
    }
}
#endif
