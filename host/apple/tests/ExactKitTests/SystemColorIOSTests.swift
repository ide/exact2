#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// LLP 1081 D5: a colour row naming a platform colour shows UIKit's own
/// colour for the view's traits, and its fallback where UIKit has none.
final class SystemColorIOSTests: XCTestCase {
    private func channels(_ c: UIColor, _ traits: UITraitCollection) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        _ = c.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Double($0) * 255 }
    }

    func testARoleIsUIKitsColourInEachAppearanceAndLevel() throws {
        let value: BatchValue = ["sys": "secondarySystemBackgroundColor", "c": [[1, 2, 3, 255], [4, 5, 6, 255]]]
        XCTAssertTrue(value.isSchemeColor, "an appearance change is something to it")
        let dark = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .dark)])
        let elevated = UITraitCollection(traitsFrom: [dark, UITraitCollection(userInterfaceLevel: .elevated)])
        XCTAssertEqual(try XCTUnwrap(value.channels(dark: false)), channels(.secondarySystemBackground, UITraitCollection(userInterfaceStyle: .light)))
        XCTAssertEqual(try XCTUnwrap(value.channels(dark: true)), channels(.secondarySystemBackground, dark))
        XCTAssertEqual(try XCTUnwrap(value.channels(dark: true, elevated: true)), channels(.secondarySystemBackground, elevated))
        XCTAssertNotEqual(value.channels(dark: true), value.channels(dark: true, elevated: true), "a sheet's dark grey is lighter")
    }

    func testANameUIKitLacksIsTheFallback() {
        let missing: BatchValue = ["sys": "systemNoSuchHueColor", "c": [[1, 2, 3, 255], [4, 5, 6, 255]]]
        XCTAssertEqual(missing.channels(dark: true), [4, 5, 6, 255])
    }

    func testANodesTextColourRowFollowsItsTraits() throws {
        let p = Presenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": ["sys": "systemGroupedBackgroundColor", "c": [[0, 0, 0, 255], [0, 0, 0, 255]]]]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 100.0, "h": 100.0],
        ]))
        let node = try XCTUnwrap(p.views[1])
        XCTAssertTrue(try XCTUnwrap(node.style["background_color"]).isSystemColor)
        window.overrideUserInterfaceStyle = .light
        window.updateTraitsIfNeeded(); window.layoutIfNeeded(); node.updateTraitsIfNeeded()
        XCTAssertEqual(node.drawsDark, window.overrideUserInterfaceStyle == .dark)
        XCTAssertEqual(node.channels("background_color"), channels(.systemGroupedBackground, UITraitCollection(userInterfaceStyle: .light)))
        window.overrideUserInterfaceStyle = .dark
        window.updateTraitsIfNeeded(); window.layoutIfNeeded(); node.updateTraitsIfNeeded()
        XCTAssertEqual(node.drawsDark, window.overrideUserInterfaceStyle == .dark)
        XCTAssertEqual(node.channels("background_color"), channels(.systemGroupedBackground, UITraitCollection(userInterfaceStyle: .dark)))
    }
}
#endif
