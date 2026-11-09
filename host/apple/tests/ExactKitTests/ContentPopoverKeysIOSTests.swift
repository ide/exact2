#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

final class ContentPopoverKeysIOSTests: XCTestCase {
    private final class InteractivePresenter: UIViewController {
        let transition: SheetDismissal
        init(_ transition: SheetDismissal) { self.transition = transition; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { nil }
        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            // Keep the invoker mounted while the existing dismissal animator supplies UIKit's coordinator
            controller.modalPresentationStyle = .overFullScreen
            controller.transitioningDelegate = transition
            if #available(iOS 26.0, *) { controller.preferredTransition = nil }
            super.present(controller, animated: animated, completion: completion)
        }
    }
    private var session: ExactSession?
    private var window: UIWindow?

    override func tearDown() {
        let responder = FirstResponder.current as? UIView
        let hidden = window != nil && responder?.window === window && (responder is UITextField || responder is UITextView)
            ? expectation(forNotification: UIResponder.keyboardDidHideNotification, object: nil) : nil
        window?.endEditing(true)
        session?.destroy(); session = nil
        if let hidden { wait(for: [hidden], timeout: 10) }
        window?.isHidden = true; window = nil
        super.tearDown()
    }

    private func page(in scene: UIWindowScene, transition: SheetDismissal? = nil) throws -> (Presenter, ExactView) {
        let session = ExactApp.shared.makeSession(label: "content-popover-keys-\(UUID().uuidString)")
        self.session = session
        let window = UIWindow(windowScene: scene), view = ExactView(session: session)
        let root = transition.map { InteractivePresenter($0) as UIViewController } ?? UIViewController()
        self.window = window
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
        view.frame = root.view.bounds
        root.view.addSubview(view)
        XCTAssertNil(session.boot(plan: try fixturePlan("GLASS_PRESS"), size: window.bounds.size).error)
        view.layoutIfNeeded()
        let p = session.presenter
        try focusDraft(p)
        return (p, view)
    }

    private func focusDraft(_ p: Presenter) throws {
        let window = try XCTUnwrap(window), editor = try XCTUnwrap(node("card-draft").textArea)
        let agent = Agent(session: try XCTUnwrap(session))
        var shownFrame: CGRect?
        let deadline = Date().addingTimeInterval(10)
        let shown = expectation(forNotification: UIResponder.keyboardDidShowNotification, object: nil) { note in
            guard shownFrame == nil, editor.isFirstResponder, editor.window === window,
                  (note.object as? UIScreen).map({ $0 === window.screen }) ?? true,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
            let end = window.convert(frame, from: window.screen.coordinateSpace)
            guard end.intersection(window.bounds).height > 50 else { return false }
            shownFrame = end
            return true
        }
        p.focusElement(["card-draft"])
        wait(for: [shown], timeout: 10)
        let end = try XCTUnwrap(shownFrame, "did-show must describe the owned displayed keyboard")
        var callbacksFinished = false
        DispatchQueue.main.async { callbacksFinished = true }
        waitFor("the displayed software keyboard settles", cap: max(0, deadline.timeIntervalSinceNow), facts: { self.keyboardFacts(p) }) {
            window.layoutIfNeeded()
            return callbacksFinished && editor.isFirstResponder && p.keyboardTop.map { abs($0 - end.minY) < 0.5 } == true && !agent.nativeInFlight()
        }
        XCTAssertTrue(editor.isFirstResponder)
    }

    private func node(_ testId: String) throws -> NodeView {
        try XCTUnwrap(session?.presenter.views.values.first { $0.props["testId"] == testId }, testId)
    }
    private func text(_ testId: String) throws -> String { try node(testId).props["text"] ?? "" }
    private func keyboardFacts(_ p: Presenter) -> String {
        let card = (try? node("composer-card")).flatMap { PopoverLayer.containing($0)?.card }
        return "top=\(String(describing: p.keyboardTop)), editor=\(String(describing: p.keyboardEditor)), focus=\(p.focusedNode?.props["testId"] ?? "none"), held=\(p.keysStoodDown), returning=\(p.menus.cards.keys?.returning == true), card=\(String(describing: card?.phase)), busy=\(p.menus.inTransition)"
    }

    private func open(_ p: Presenter) throws -> PopoverCard {
        p.menus.action("showPopover", ["composer-card", "card-open"])
        waitFor("the card over stood-down keys", cap: 10, facts: { self.keyboardFacts(p) }) { !p.menus.inTransition }
        let card = try XCTUnwrap(PopoverLayer.containing(try node("composer-card"))?.card)
        XCTAssertNotNil(card.view.window)
        XCTAssertTrue(p.keysStoodDown, "this test must exercise the real keyboard stand-down")
        XCTAssertFalse(try XCTUnwrap(p.menus.cards.keys, keyboardFacts(p)).returning)
        return card
    }

    func testInteractiveCancellationAndCompletionKeepSettlementAndKeyboardOwnershipUntilTheyEnd() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "UIKit must drive the card's interactive coordinator") }
        let cancellation = SheetDismissal()
        let (p, _) = try page(in: scene, transition: cancellation), draft = try node("card-draft"), editor = try XCTUnwrap(draft.textArea)
        editor.selectedRange = NSRange(location: 2, length: 4)
        let card = try open(p), held = try XCTUnwrap(p.menus.cards.keys), agent = Agent(session: try XCTUnwrap(session))
        card.dismiss(animated: true)
        waitFor("the real interactive card dismissal begins", cap: 10) { cancellation.started && card.transitionCoordinator?.isInteractive == true }
        cancellation.interaction.update(0.4)
        XCTAssertTrue(p.menus.inTransition, "the held native gesture is unsettled before any close request")
        XCTAssertTrue(agent.nativeInFlight())
        XCTAssertTrue(p.menus.isOpen(try node("composer-card")))
        XCTAssertTrue(p.menus.cards.keys === held)
        XCTAssertFalse(held.returning)
        XCTAssertTrue(p.focusedNode === draft)
        let coordinator = try XCTUnwrap(card.transitionCoordinator)
        var cancelled = false
        XCTAssertTrue(coordinator.animate(alongsideTransition: nil) { context in cancelled = context.isCancelled })
        cancellation.interactive = false
        cancellation.interaction.cancel()
        if !cancelled { XCTAssertTrue(p.menus.inTransition, "the cancellation animation is still unsettled") }
        waitFor("the cancelled card remains presented", cap: 10) { cancelled && card.transitionCoordinator == nil && !p.menus.inTransition }
        XCTAssertNotNil(card.presentingViewController)
        XCTAssertTrue(p.menus.isOpen(try node("composer-card")))
        XCTAssertTrue(p.menus.cards.keys === held)
        XCTAssertFalse(held.returning)
        XCTAssertTrue(p.focusedNode === draft)
        XCTAssertEqual(try text("card-blurs"), "Blur 0")

        let completion = SheetDismissal()
        card.transitioningDelegate = completion
        card.dismiss(animated: true)
        waitFor("the second interactive dismissal begins", cap: 10) { completion.started && card.transitionCoordinator?.isInteractive == true }
        completion.interaction.update(0.4)
        XCTAssertTrue(p.menus.inTransition)
        p.menus.action("hidePopover", ["composer-card"])
        p.menus.action("showPopover", ["composer-card", "card-open"])
        let next = try XCTUnwrap(PopoverLayer.containing(try node("composer-card"))?.card)
        XCTAssertFalse(next === card)
        XCTAssertNil(next.presentingViewController, "the opening waits for the interactive owner to retire")
        XCTAssertTrue(p.menus.cards.keys === held)
        completion.interactive = false
        completion.interaction.finish()
        XCTAssertTrue(p.menus.inTransition)
        waitFor("the completed dismissal admits the queued opening", cap: 10) { !p.menus.inTransition && next.viewIfLoaded?.window != nil }
        XCTAssertNil(card.presentingViewController)
        XCTAssertTrue(p.menus.cards.keys === held, "the queued opening keeps the same keyboard hold")
        XCTAssertFalse(held.returning)
        XCTAssertTrue(p.focusedNode === draft)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the last owner returns native selection and keys", cap: 10) { !p.keysStoodDown && !p.menus.inTransition && editor.isFirstResponder }
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
    }

    func testTheCardPreservesFocusAndSelectionAndSelectTextAppliesWhenKeysReturn() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "software keys and card presentation need the hosted scene") }
        let (p, _) = try page(in: scene), draft = try node("card-draft"), editor = try XCTUnwrap(draft.textArea)
        editor.selectedRange = NSRange(location: 2, length: 4)
        let focuses = try text("card-focuses"), blurs = try text("card-blurs"), top = try XCTUnwrap(p.keyboardTop)
        _ = try open(p)
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertTrue(p.focusedNode === draft)
        XCTAssertTrue(p.keyboardEditor === editor, "the same route keeps its keyboard allocation")
        XCTAssertEqual(try XCTUnwrap(p.keyboardTop), top, accuracy: 0.5)
        XCTAssertEqual(try text("card-focuses"), focuses)
        XCTAssertEqual(try text("card-blurs"), blurs)
        p.press(try node("card-select").id)
        p.press(try node("card-choose").id)
        waitFor("the selected draft and real keys return", cap: 10) { !p.keysStoodDown && !p.menus.inTransition && editor.isFirstResponder }
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: draft.fieldText.utf16.count))
        XCTAssertEqual(try text("card-focuses"), focuses, "returning native focus is the same logical focus")
        XCTAssertEqual(try text("card-blurs"), blurs)
        XCTAssertEqual(try text("card-choices"), "Choices 1")
        _ = try open(p)
        p.press(try node("card-blur").id)
        waitFor("an authored blur releases the keys", cap: 10) { !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
    }

    func testANewCardWaitsOnReturningKeysAndDoesNotReviveAnOldOpening() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "keyboard completion needs the hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        let first = try open(p), held = try XCTUnwrap(p.menus.cards.keys)
        var reopened = false
        var queued: PopoverCard?
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            guard p.menus.cards.keys === held, held.returning, !reopened else { return }
            reopened = true
            XCTAssertEqual(first.phase, .finished)
            XCTAssertNil(first.presentingViewController)
            // Queue during the real will-show; presentation must wait for keyboard completion
            p.menus.action("showPopover", ["composer-card", "card-open"])
            queued = (try? self.node("composer-card")).flatMap { PopoverLayer.containing($0)?.card }
            XCTAssertNotNil(queued)
            XCTAssertNil(queued?.presentingViewController)
            XCTAssertTrue(p.menus.cards.keys === held)
            XCTAssertTrue(held.returning)
            XCTAssertTrue(p.menus.inTransition)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("a new opening after the keyboard's completion", cap: 10, facts: { self.keyboardFacts(p) }) {
            reopened && !p.menus.inTransition && p.keysStoodDown
        }
        let current = try XCTUnwrap(PopoverLayer.containing(try node("composer-card"))?.card)
        XCTAssertTrue(current === queued)
        XCTAssertFalse(current === first)
        XCTAssertEqual(first.phase, .finished)
        XCTAssertNotNil(current.view.window)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the final owned keys return", cap: 10) { !p.menus.inTransition && !p.keysStoodDown && editor.isFirstResponder }
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
    }

    func testAFieldInTheCardTakesFocusAndTheOldDraftDoesNotTakeItBack() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "native editor handoff needs the hosted scene") }
        let (p, _) = try page(in: scene), draft = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        p.focusElement(["card-editor"])
        let inner = try node("card-editor"), field = try XCTUnwrap(inner.field)
        waitFor("the card's field owns input", cap: 10) { field.isFirstResponder && !p.keysStoodDown }
        XCTAssertTrue(p.focusedNode === inner)
        XCTAssertTrue(p.keyboardEditor === field)
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the field's card retires", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(draft.isFirstResponder)
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertNil(p.focusedNode)
    }

    func testAnAuthoredBlurWhileTheKeysReturnEndsThatOwnershipOnce() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "a returning keyboard needs the hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        var blurred = false
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            guard p.menus.cards.keys?.returning == true, !blurred else { return }
            blurred = true
            DispatchQueue.main.async { p.blurElement(["card-draft"]) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the authored blur cancels returning input", cap: 10) { blurred && !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
    }

    func testANativeChildReturnsItsOwnInputSelectionToTheParentCard() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "nested keyboard ownership needs the hosted scene") }
        let (p, _) = try page(in: scene)
        let parent = try open(p)
        let shown = expectation(forNotification: UIResponder.keyboardDidShowNotification, object: nil)
        p.focusElement(["card-editor"])
        wait(for: [shown], timeout: 10)
        let inner = try node("card-editor"), field = try XCTUnwrap(inner.field)
        field.text = "Inner selection"
        inner.fieldChanged()
        p.fieldSelections.set(inner, FieldSelection(start: 1, end: 4))
        p.press(try node("card-native-open").id)
        waitFor("the native child stands down its parent's field", cap: 10) { !p.menus.inTransition && p.keysStoodDown }
        XCTAssertTrue(p.focusedNode === inner)
        p.menus.action("hidePopover", ["card-native"])
        waitFor("the parent card regains its input", cap: 10) { !p.menus.inTransition && !p.keysStoodDown && field.isFirstResponder }
        XCTAssertEqual(inner.liveSelection, NSRange(location: 1, length: 3))
        XCTAssertNotNil(parent.view.window)
        XCTAssertTrue(p.menus.isOpen(try node("composer-card")))
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the parent card leaves", cap: 10) { !p.menus.inTransition }
    }

    func testAnEditorOutsideTheSessionKeepsInputWhenTheCardCloses() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "external editor ownership needs the hosted scene") }
        let (p, _) = try page(in: scene), draft = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        let foreign = UITextField(frame: CGRect(x: 20, y: 100, width: 200, height: 44))
        try XCTUnwrap(window?.rootViewController?.view).addSubview(foreign)
        XCTAssertTrue(foreign.becomeFirstResponder())
        waitFor("the external editor ends the old keyboard hold", cap: 10) { !p.keysStoodDown }
        XCTAssertNil(p.keyboardEditor, "another native owner is outside this session")
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the card's dismissal leaves that owner alone", cap: 10) { !p.menus.inTransition }
        XCTAssertTrue(foreign.isFirstResponder)
        XCTAssertFalse(draft.isFirstResponder)
        XCTAssertNil(p.focusedNode)
    }

    func testDisablingTheDraftReleasesItsKeyboardAndGlassSurface() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "keyboard retirement needs the hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        p.press(try node("card-disable-field").id)
        XCTAssertFalse(p.keysStoodDown)
        let pill = try node("card-pill")
        XCTAssertFalse(pill.materialInteractive)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the disabled field's card retires", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testRemovingTheDraftWhileItsKeysStandDownDoesNotRestoreIt() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "field removal needs the hosted keyboard") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        p.press(try node("card-remove-field").id)
        XCTAssertNil(p.views.values.first { $0.props["testId"] == "card-draft" })
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertFalse(try node("card-pill").materialInteractive)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the removed field's card leaves", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(editor.window)
    }

    func testUnmountAndRebootDoNotReviveTheirRetiredKeyboardOwners() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "unmount and reboot need the hosted keyboard") }
        let (p, view) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        view.removeFromSuperview()
        waitFor("unmount retires the native presentation", cap: 10) { !p.menus.inTransition }
        XCTAssertTrue(p.menus.presented.isEmpty)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertFalse(editor.isFirstResponder)
        let root = try XCTUnwrap(window?.rootViewController)
        root.view.addSubview(view)
        try focusDraft(p)
        let card = try open(p), draft = try node("card-draft")
        let session = try XCTUnwrap(session)
        let generation = session.generation
        // Preserve carried state while checking that retirement sends no events into the replacement
        let focuses = try text("card-focuses"), blurs = try text("card-blurs")
        XCTAssertNil(session.boot(plan: try fixturePlan("GLASS_PRESS"), size: try XCTUnwrap(window).bounds.size).error)
        waitFor("reboot retires the old native owner", cap: 10) { !p.menus.inTransition }
        XCTAssertEqual(session.generation, generation + 1)
        XCTAssertFalse(try node("card-draft") === draft)
        XCTAssertNil(card.presentingViewController)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertEqual(try text("card-focuses"), focuses)
        XCTAssertEqual(try text("card-blurs"), blurs)
        waitForMainQueue("retirement callbacks after reboot")
        XCTAssertFalse(p.menus.inTransition)
        XCTAssertFalse(try XCTUnwrap(node("card-draft").textArea).isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertEqual(try text("card-focuses"), focuses)
        XCTAssertEqual(try text("card-blurs"), blurs)
    }
}
#endif
