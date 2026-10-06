// The platform's own size for a control whose size is fixed (a switch, a
// checkbox, a radio, a slider's height), handed to the kernel's first layout
// (exact_set_control_measure), so a control is never laid out as a web
// control and then moved when the host reports it. Read from the very
// controls the host makes, once, on the main thread; the kernel asks on its
// own thread and reads only that table.
import CExact
import Foundation
#if os(iOS)
import UIKit
#endif

enum ControlMeasure {
    /// Sizes by `ControlKind::code`, measured once.
    nonisolated(unsafe) private static var sizes: [UInt32: CGSize] = [:]
    private static let measured: Void = {
        #if os(iOS)
        // As ControlHost reports them (ValueControlsIOS `naturalSize`).
        sizes[0] = ExactCheckbox(frame: .zero).intrinsicContentSize
        sizes[1] = UISwitch().intrinsicContentSize
        sizes[2] = ExactRadio(frame: .zero).intrinsicContentSize
        sizes[5] = CGSize(width: 129, height: ceil(UISlider().intrinsicContentSize.height))
        #endif
    }()

    /// The kernel's control measurer, its table measured now (main thread).
    static func prepared() -> ExactControlFn? {
        _ = measured
        return sizes.isEmpty ? nil : measure
    }

    private static let measure: ExactControlFn = { _, kind, out in
        guard let out, let size = sizes[kind], size.width > 0, size.height > 0 else { return 0 }
        out[0] = Float(size.width); out[1] = Float(size.height)
        return 1
    }
}
