#if os(iOS)
import QuartzCore
import UIKit
import XCTest
@testable import ExactKit

/// A transition the engine hands over is one Core Animation curve, not a
/// batch a frame (TransitionsIOS.swift).
final class TransitionsIOSTests: XCTestCase {
    func testAnAnimateOpIsALinearKeyframeFadeOverTheTarget() throws {
        let p = Presenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 100.0, "h": 40.0],
        ]))
        p.apply(wireBatch([
            ["op": "animate", "id": 1, "property": "opacity", "delay": 0.0, "duration": 0.25, "values": [1.0, 0.8, 0.6]],
            ["op": "present", "id": 1, "property": "opacity", "x": 0.6, "y": 0.0],
        ]))
        let view = try XCTUnwrap(p.views[1])
        XCTAssertEqual(view.alpha, 0.6, accuracy: 0.001, "the model is the target")
        let fade = try XCTUnwrap(view.layer.animation(forKey: "exact.transition.opacity") as? CAKeyframeAnimation)
        XCTAssertEqual(fade.values as? [NSNumber], [1.0, 0.8, 0.6].map { NSNumber(value: $0) })
        XCTAssertEqual(fade.duration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(fade.calculationMode, .linear)
    }
}
#endif
