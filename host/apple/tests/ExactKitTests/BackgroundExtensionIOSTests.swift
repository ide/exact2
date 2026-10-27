#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// LLP 1123 D11: an image's background extension is a view beside the
/// image, outside its subtree, so it must go when the image does.
final class BackgroundExtensionIOSTests: XCTestCase {
    func testAnImagesExtensionGoesWithTheImage() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("UIBackgroundExtensionView is iOS 26's") }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 30, height: 10), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 10))
        }.pngData())
        let p = Presenter(), loader = RasterLoader(), resolver = AssetResolver(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "image", "props": ["backgroundExtension": "auto"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0, "y": 0, "w": 300, "h": 400],
            ["op": "frame", "id": 2, "x": 0, "y": 50, "w": 300, "h": 100],
        ]))
        let page = try XCTUnwrap(p.views[1]), image = try XCTUnwrap(p.views[2])
        // A route whose safe area starts 50 points down, the image on that edge.
        let route = RouteController(page), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        defer { loader.shutdown(); window.isHidden = true }
        window.rootViewController = route
        window.makeKeyAndVisible()
        route.additionalSafeAreaInsets = UIEdgeInsets(top: 50 - route.view.safeAreaInsets.top, left: 0, bottom: 0, right: 0)
        route.view.addSubview(page)
        route.view.layoutIfNeeded()
        image.loadGeneration = 1
        loader.load(image, source: "data:image/png;base64," + png.base64EncodedString(), resolver: resolver)
        let deadline = Date(timeIntervalSinceNow: 5)
        while image.raster == nil, Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertNotNil(image.raster)
        image.syncBackgroundExtension()
        let extensions = { route.view.subviews.filter { $0 is UIBackgroundExtensionView } }
        XCTAssertEqual(extensions().count, 1, "the image meets the safe area's top: \(route.view.safeAreaInsets)")
        p.apply(wireBatch([["op": "destroy", "id": 2], ["op": "children", "id": 1, "ids": []]]))
        XCTAssertTrue(extensions().isEmpty, "the image is destroyed, and its extension with it")
    }
}
#endif
