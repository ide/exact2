#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// `input type="range"` is a UISlider (LLP 1069.001 D5), whose thumb moves
/// from step to step as a browser's does.
///   bun host/apple/build.mjs --test --ios
final class RangeIOSTests: XCTestCase {
    private var window: UIWindow!

    private func slider(_ props: [String: String]) throws -> (Presenter, UISlider) {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "control", "props": ["type": "range"].merging(props) { $1 },
             "handlers": ["input", "change"], "style": [:]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 28.0],
        ]))
        return (p, try XCTUnwrap(p.controls.controls[1] as? UISlider))
    }

    /// The thumb moves from step to step with no tick marks drawn, as a
    /// browser's range without a `list` shows none.
    func testTheThumbSnapsToTheStepWithNoTicks() throws {
        let (p, s) = try slider(["min": "65", "max": "85", "step": "1", "value": "72"])
        XCTAssertEqual(s.value, 72)
        if #available(iOS 26.0, *) { XCTAssertEqual(s.trackConfiguration?.ticks.count ?? 0, 0) }
        s.value = 73.4
        p.controls.rangeMoved(s) // what UIKit sends as the thumb moves (a test bundle routes no target-actions)
        XCTAssertEqual(s.value, 73, "on the nearest step")
    }

    /// A span that is no multiple of the step ends at the last step under `max`, as HTML's does.
    func testAStepThatDoesNotDivideTheSpanStopsBelowMax() throws {
        let (p, s) = try slider(["min": "0", "max": "10", "step": "3", "value": "6"])
        s.value = 9.9
        p.controls.rangeMoved(s)
        XCTAssertEqual(s.value, 9, accuracy: 1e-5)
    }

    /// `step="any"` glides; any other step snaps the thumb as it moves.
    func testAnyStepGlidesAndTooManyStepsSnapAsTheThumbMoves() throws {
        let (p, s) = try slider(["min": "0", "max": "100", "step": "any", "value": "40"])
        s.value = 40.25
        p.controls.rangeMoved(s) // what UIKit sends as the thumb moves (a test bundle routes no target-actions)
        XCTAssertEqual(s.value, 40.25)
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["min": "0", "max": "5000", "step": "1"]]]))
        s.value = 73.6
        p.controls.rangeMoved(s)
        XCTAssertEqual(s.value, 74, "snapped as it moves")
        // Back to gliding: a value set is the value shown
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["step": "any"]]]))
        s.value = 2.5
        XCTAssertEqual(s.value, 2.5)
    }

    func testTinyStepsKeepTheValue() throws {
        let (p, s) = try slider(["min": "0", "max": "100", "step": "1e-300", "value": "40"])
        XCTAssertEqual(s.value, 40)
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["step": "1e-20"]]]))
        XCTAssertEqual(s.value, 40)
    }
}

#endif
