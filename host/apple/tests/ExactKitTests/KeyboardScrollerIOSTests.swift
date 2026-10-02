#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// One scroller takes a drag (LLP 1008 §9): the keyboard's overlap goes to
/// the scroller of the focused field's screen, never to the app root under
/// it — an app root made scrollable by the overlap took the drag from the
/// screen's scroller, whose keyboardDismissMode then never ran. With no
/// screen scroller, the app root is the screen's and takes it, with the
/// root's dismissal.
final class KeyboardScrollerIOSTests: XCTestCase {
    private var window: UIWindow!

    private func presenter(_ ops: [[String: Any]]) -> Presenter {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch(ops))
        return p
    }

    func testTheFieldsScreenScrollerTakesTheOverlapAndTheAppRootDoesNot() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "view", "style": ["overflow_y": "scroll"], "props": ["keyboardDismissMode": "interactive"]],
            ["op": "create", "id": 3, "kind": "input"],
            ["op": "children", "id": 2, "ids": [3]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 800.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 400.0, "h": 800.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 100.0, "w": 400.0, "h": 44.0],
        ])
        let screen = try XCTUnwrap(p.views[2]?.scroll)
        let field = try XCTUnwrap(p.views[3]?.field)
        XCTAssertTrue(field.becomeFirstResponder())
        p.applyKeyboard(top: 500, duration: 0, curve: 0)
        XCTAssertEqual(screen.contentInset.bottom, 300 - window.safeAreaInsets.bottom, "the screen's scroller is inset by what the keyboard covers past the bottom safe area")
        XCTAssertEqual(p.viewport.contentInset.bottom, 0, "the app root stays unscrollable")
        XCTAssertEqual(p.keyboardInset, 300, "the env value is still the overlap")
        XCTAssertEqual(screen.keyboardDismissMode, .interactive)
        p.applyKeyboard(top: nil, duration: 0, curve: 0)
        XCTAssertEqual(screen.contentInset.bottom, 0, "given back when the keyboard goes")
    }

    func testWithNoScreenScrollerTheAppRootIsTheScreensAndDismissesAsTheRootAsks() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "props": ["keyboardDismissMode": "interactive"]],
            ["op": "create", "id": 3, "kind": "input"],
            ["op": "children", "id": 1, "ids": [3]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 800.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 100.0, "w": 400.0, "h": 44.0],
        ])
        let field = try XCTUnwrap(p.views[3]?.field)
        XCTAssertTrue(field.becomeFirstResponder())
        p.applyKeyboard(top: 500, duration: 0, curve: 0)
        XCTAssertEqual(p.viewport.contentInset.bottom, 300)
        XCTAssertEqual(p.viewport.keyboardDismissMode, .interactive)
        p.applyKeyboard(top: nil, duration: 0, curve: 0)
        XCTAssertEqual(p.viewport.contentInset.bottom, 0)
        XCTAssertEqual(p.viewport.keyboardDismissMode, .none)
    }
}
#endif
