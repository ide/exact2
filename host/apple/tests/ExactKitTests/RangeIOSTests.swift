#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// `input type="range"` is a UISlider (LLP 1069.001 D5).
///   bun host/apple/build.mjs --test --ios
final class RangeIOSTests: XCTestCase {
    private var window: UIWindow!

    /// A browser's thumb snaps to `step` as it is dragged; UISlider's would
    /// glide between steps while the value it reports jumps.
    func testTheThumbSnapsToTheStepAsItMoves() throws {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "control", "props": ["type": "range", "min": "65", "max": "85", "step": "1", "value": "72"],
             "handlers": ["input", "change"], "style": [:]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 28.0],
        ]))
        let slider = try XCTUnwrap(p.controls.controls[1] as? UISlider)
        XCTAssertEqual(slider.value, 72)
        slider.value = 73.4
        p.controls.rangeMoved(slider) // what UIKit sends as the thumb moves (a test bundle has no app to route target-actions)
        XCTAssertEqual(slider.value, 73, "snapped down to the nearest step")
        slider.value = 73.6
        p.controls.rangeMoved(slider) // what UIKit sends as the thumb moves (a test bundle has no app to route target-actions)
        XCTAssertEqual(slider.value, 74, "and up")
    }
}
#endif
