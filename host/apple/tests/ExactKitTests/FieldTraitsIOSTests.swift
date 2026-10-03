#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// A field's UIKit traits follow its props through a batch that repeats
/// them and one that changes them: writing only on change (a focused field
/// told the same traits again reloads its input views, and the AutoFill bar
/// above the keyboard drops out and back) never leaves a trait stale.
/// UITextField forwards its trait setters to a private object, so the
/// writes themselves are not countable here; the bar was seen on a device.
final class FieldTraitsIOSTests: XCTestCase {
    private var window: UIWindow!

    func testTraitsFollowThePropsAndASameBatchLeavesThemAlone() throws {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "input", "props": ["type": "email"], "handlers": ["submit"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 44.0],
        ]))
        let f = try XCTUnwrap(p.views[1]?.field)
        XCTAssertEqual(f.keyboardType, .emailAddress)
        XCTAssertEqual(f.textContentType, .emailAddress)
        XCTAssertEqual(f.returnKeyType, .go)
        XCTAssertFalse(f.isSecureTextEntry)

        // The same props again, as a focus move's batch carries them.
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["type": "email"], "clear": []]]))
        XCTAssertEqual(f.textContentType, .emailAddress, "unchanged props leave the traits as they were")
        XCTAssertEqual(f.keyboardType, .emailAddress)

        // A change still reaches UIKit: nothing goes stale.
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["type": "password"], "clear": []]]))
        XCTAssertTrue(f.isSecureTextEntry)
        XCTAssertEqual(f.textContentType, .password)
        XCTAssertEqual(f.keyboardType, .default)
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["disabled": "true"], "clear": []]]))
        XCTAssertFalse(f.isEnabled)
    }
}
#endif
