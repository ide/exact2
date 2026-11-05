#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

final class QueuedAlertIOSTests: XCTestCase {
    private var window: UIWindow?
    private var presenter: Presenter?
    private var pressed: [UInt32] = []

    override func tearDown() {
        presenter?.menus.reset()
        if let controller = window?.rootViewController {
            waitFor("the owned alert dismisses") { controller.presentedViewController == nil }
        }
        window?.isHidden = true
        window = nil
        presenter = nil
        super.tearDown()
    }

    func testErrorsWaitInOrderWithoutBlockingTheVisibleConfirmation() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "queued errors use native alert presentation") }
        let (p, controller) = try page()
        for accept in [false, true] {
            showFirst(p, controller)
            p.dialogCommand("showModal", "climate-failed")
            let error = try XCTUnwrap(p.views[20])
            let waiting = try XCTUnwrap(p.menus.openModally(error))
            XCTAssertTrue(waiting)
            p.dialogCommand("showModal", "command-failed")
            p.dialogCommand("showModal", "climate-failed")
            XCTAssertTrue(p.menus.nativeConfirmation === p.views[10], "the visible alert owns input, not the waiting error")
            XCTAssertFalse(p.menus.inTransition, "a waiting error must not block the person's choice")
            XCTAssertEqual((controller.presentedViewController as? UIAlertController)?.title, "Lock your vehicle?")
            XCTAssertEqual(p.menus.activate(try XCTUnwrap(p.views[accept ? 12 : 13])), true)
            waitForTitle("Couldn't save climate settings", p, controller)
            XCTAssertEqual(pressed, accept ? [12] : [], "the original choice dispatches once; Cancel dispatches nothing")
            close("climate-failed", p)
            waitForTitle("Command didn't go through", p, controller)
            close("command-failed", p)
            waitFor("all requested errors close without a duplicate") { controller.presentedViewController == nil && !p.menus.inTransition }
        }
    }

    func testClosingAWaitingErrorRemovesOnlyThatError() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "queued errors use native alert presentation") }
        let (p, controller) = try page()
        showFirst(p, controller)
        p.dialogCommand("showModal", "climate-failed")
        try requireWaiting(p, 20)
        p.dialogCommand("showModal", "command-failed")
        close("climate-failed", p)
        XCTAssertFalse(p.menus.isOpen(try XCTUnwrap(p.views[20])))
        XCTAssertEqual((controller.presentedViewController as? UIAlertController)?.title, "Lock your vehicle?")
        close("confirm-lock", p)
        waitForTitle("Command didn't go through", p, controller)
        close("command-failed", p)
        waitFor("no cancelled error follows") { controller.presentedViewController == nil && !p.menus.inTransition }
    }

    func testARecycledWaitingDialogCannotReceiveTheOldRequest() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "queued errors use native alert presentation") }
        let (p, controller) = try page()
        showFirst(p, controller)
        p.dialogCommand("showModal", "climate-failed")
        let old = try XCTUnwrap(p.views[20]), incarnation = old.incarnation
        try requireWaiting(p, 20)
        p.dialogCommand("showModal", "command-failed")
        p.apply(wireBatch([
            ["op": "roots", "ids": [10, 30]],
            ["op": "destroy", "id": 22], ["op": "destroy", "id": 21], ["op": "destroy", "id": 20],
        ] + dialog(20, "climate-failed", "A replacement dialog") + [["op": "roots", "ids": [10, 20, 30]]]))
        XCTAssertTrue(p.views[20] !== old || p.views[20]?.incarnation != incarnation)
        XCTAssertFalse(p.menus.isOpen(try XCTUnwrap(p.views[20])))
        p.dialogCommand("showModal", "climate-failed")
        close("confirm-lock", p)
        waitForTitle("Command didn't go through", p, controller)
        close("command-failed", p)
        waitForTitle("A replacement dialog", p, controller)
        close("climate-failed", p)
        waitFor("the replacement closes") { controller.presentedViewController == nil && !p.menus.inTransition }

        p.apply(wireBatch([
            ["op": "create", "id": 40, "kind": "control", "handlers": [], "props": ["type": "button", "commandfor": "climate-failed", "command": "show-modal"]],
            ["op": "roots", "ids": [10, 20, 30, 40]],
        ]))
        showFirst(p, controller)
        XCTAssertTrue(p.menus.openConfirmation(from: try XCTUnwrap(p.views[40]), popover: try XCTUnwrap(p.views[20]), modal: true, dispatchPress: false))
        p.dialogCommand("showModal", "command-failed")
        p.apply(wireBatch([["op": "roots", "ids": [10, 20, 30]], ["op": "destroy", "id": 40]]))
        close("confirm-lock", p)
        waitForTitle("Command didn't go through", p, controller)
        XCTAssertFalse(p.menus.isOpen(try XCTUnwrap(p.views[20])), "a waiting invocation cannot outlive its source")
    }

    func testAnExternalDismissalStillPresentsTheWaitingError() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "external dismissal uses UIKit's alert lifetime") }
        let (p, controller) = try page()
        showFirst(p, controller)
        p.dialogCommand("showModal", "climate-failed")
        try requireWaiting(p, 20)
        controller.dismiss(animated: false)
        waitForTitle("Couldn't save climate settings", p, controller)
        XCTAssertEqual(pressed, [])
    }

    func testRemovingTheVisibleDialogPreservesAnUnrelatedWaitingError() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "removing a presented alert uses UIKit dismissal") }
        let (p, controller) = try page()
        showFirst(p, controller)
        p.dialogCommand("showModal", "climate-failed")
        try requireWaiting(p, 20)
        p.apply(wireBatch([
            ["op": "roots", "ids": [20, 30]],
            ["op": "destroy", "id": 13], ["op": "destroy", "id": 12],
            ["op": "destroy", "id": 11], ["op": "destroy", "id": 10],
        ]))
        waitForTitle("Couldn't save climate settings", p, controller)
        XCTAssertEqual(pressed, [])
    }

    func testMovingTheVisibleAlertKeepsItAheadOfWaitingErrors() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "moving a presentation needs a window scene") }
        let (p, controller) = try page()
        showFirst(p, controller)
        let old = try XCTUnwrap(controller.presentedViewController)
        p.dialogCommand("showModal", "climate-failed")
        try requireWaiting(p, 20)
        let unrelated = NodeView(id: 90, kind: "view", presenter: p)
        let finish = p.menus.retire(over: controller, removing: unrelated)
        controller.dismiss(animated: false) { finish(); p.menus.resumeAfterRouteDismissal() }
        waitFor("the visible alert moves before the waiting error") {
            controller.presentedViewController != nil && controller.presentedViewController !== old && !p.menus.inTransition
        }
        XCTAssertEqual((controller.presentedViewController as? UIAlertController)?.title, "Lock your vehicle?")
        close("confirm-lock", p)
        waitForTitle("Couldn't save climate settings", p, controller)
    }

    func testResetDiscardsWaitingErrors() throws {
        guard hostedWindowScene() != nil else { throw missing("scene", "reset dismisses the native presentation") }
        let (p, controller) = try page()
        showFirst(p, controller)
        p.dialogCommand("showModal", "climate-failed")
        try requireWaiting(p, 20)
        p.menus.reset()
        waitFor("reset leaves no presentation") { controller.presentedViewController == nil && !p.menus.inTransition }
        XCTAssertFalse(p.menus.isOpen(try XCTUnwrap(p.views[20])))
        showFirst(p, controller)
        close("confirm-lock", p)
        waitFor("the old error does not return") { controller.presentedViewController == nil && !p.menus.inTransition }
    }

    private func page() throws -> (Presenter, UIViewController) {
        let scene = try XCTUnwrap(hostedWindowScene())
        let p = Presenter(), window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(p.viewport)
        p.viewport.frame = controller.view.bounds
        p.buttonFace = { id in
            var face = ButtonFace()
            face.title = id == 12 ? "Lock" : id == 13 ? "Cancel" : "OK"
            return face
        }
        p.onPress = { [weak self] in self?.pressed.append($0) }
        self.window = window
        presenter = p
        p.apply(wireBatch(dialog(10, "confirm-lock", "Lock your vehicle?")
            + dialog(20, "climate-failed", "Couldn't save climate settings")
            + dialog(30, "command-failed", "Command didn't go through")
            + [["op": "roots", "ids": [10, 20, 30]]]))
        return (p, controller)
    }

    private func dialog(_ id: Int, _ name: String, _ title: String) -> [[String: Any]] {
        var operations: [[String: Any]] = [
            ["op": "create", "id": id, "kind": "view", "props": ["id": name, "semanticTag": "dialog", "accessibilityRole": "alertdialog", "accessibilityLabel": title]],
            ["op": "create", "id": id + 1, "kind": "text", "props": ["text": "A request completed while a different confirmation was open."]],
            ["op": "create", "id": id + 2, "kind": "control", "handlers": id == 10 ? ["press"] : [], "props": ["type": "button", "commandfor": name, "command": "close"]],
        ]
        if id == 10 {
            operations.append(["op": "create", "id": id + 3, "kind": "control", "handlers": [], "props": ["type": "button", "commandfor": name, "command": "close"]])
        }
        operations.append(["op": "children", "id": id, "ids": id == 10 ? [id + 1, id + 2, id + 3] : [id + 1, id + 2]])
        return operations
    }

    private func requireWaiting(_ p: Presenter, _ id: UInt32) throws {
        let dialog = try XCTUnwrap(p.views[id])
        let modal = try XCTUnwrap(p.menus.openModally(dialog))
        XCTAssertTrue(modal)
    }

    private func showFirst(_ p: Presenter, _ controller: UIViewController) {
        p.dialogCommand("showModal", "confirm-lock")
        waitForTitle("Lock your vehicle?", p, controller)
    }

    private func close(_ name: String, _ p: Presenter) { p.dialogCommand("close", name) }

    private func waitForTitle(_ title: String, _ p: Presenter, _ controller: UIViewController) {
        waitFor("the alert titled \(title) presents") {
            (controller.presentedViewController as? UIAlertController)?.title == title && !p.menus.inTransition
        }
    }
}
#endif
