// The keys stood down for a content card and their return
// (PopoverCardIOS.swift): the ten scenarios of the upstream suite against
// the pinned owner (`Presenter.heldKeys`), then the ways a hold ends without
// the keys and the completions it must not accept. Every test drives the
// hosted scene's real software keyboard: without it a test skips, or fails
// under EXACT_REQUIRED (Coverage.swift).
#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

final class ContentPopoverKeysIOSTests: XCTestCase {
    // The waits of the upstream suite (its EventWaits.swift), private to this
    // suite: the main loop runs in 5 ms turns until `done`, and fails only at
    // `cap`, so a loaded machine delays a pass instead of failing it.
    @discardableResult
    private func waitFor(_ what: String, late: TimeInterval = 2, cap: TimeInterval = 30, facts: () -> String = { "" },
                         file: StaticString = #filePath, line: UInt = #line, _ done: () -> Bool) -> TimeInterval {
        let began = Date(), until = began.addingTimeInterval(cap)
        var turns = 0, slowest = 0.0
        while !done(), Date() < until {
            let turn = Date()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            slowest = max(slowest, Date().timeIntervalSince(turn))
            turns += 1
        }
        let took = Date().timeIntervalSince(began)
        let seen = facts()
        let said = "took \(String(format: "%.3f", took)) s over \(turns) turns, the slowest \(String(format: "%.3f", slowest)) s" + (seen.isEmpty ? "" : ", \(seen)")
        guard done() else {
            XCTFail("\(what): \(said)", file: file, line: line)
            return took
        }
        if took > late {
            let note = XCTAttachment(string: "LATE-PASS \(name) \(what): \(said)")
            note.name = "LATE-PASS \(what)"
            note.lifetime = .keepAlways
            add(note)
            print("LATE-PASS \(name) \(what): \(said)")
        }
        return took
    }

    /// A block queued with `DispatchQueue.main.async` before this call has run when it returns.
    private func waitForMainQueue(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var ran = false
        DispatchQueue.main.async { ran = true }
        waitFor(what, file: file, line: line) { ran }
    }

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
    /// An editor that can refuse to give the keys up, or to take them back.
    private final class RefusingTextView: UITextView {
        var refusesReturn = false
        var refusesResignation = false
        override func becomeFirstResponder() -> Bool { refusesReturn ? false : super.becomeFirstResponder() }
        override func resignFirstResponder() -> Bool { refusesResignation ? false : super.resignFirstResponder() }
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

    /// The composer page in the hosted scene, its draft focused with the
    /// software keys up. `replacement` stands in for the draft's text view.
    private func page(in scene: UIWindowScene, transition: SheetDismissal? = nil, replacement: UITextView? = nil) throws -> (Presenter, ExactView) {
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
        if let replacement {
            let draft = try node("card-draft"), original = try XCTUnwrap(draft.textArea)
            replacement.frame = original.frame
            replacement.text = original.text
            replacement.delegate = draft
            original.removeFromSuperview()
            draft.textArea = replacement
            draft.addSubview(replacement)
        }
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
    private func card(_ testId: String = "composer-card") -> PopoverCard? { (try? node(testId)).flatMap { PopoverLayer.containing($0)?.card } }
    private func keyboardFacts(_ p: Presenter) -> String {
        "top=\(String(describing: p.keyboardTop)), editor=\(String(describing: p.keyboardEditor)), focus=\(p.focusedNode?.props["testId"] ?? "none"), held=\(p.keysStoodDown), returning=\(p.heldKeys?.returning == true), card=\(String(describing: card()?.phase)), busy=\(p.menus.inTransition)"
    }

    /// Opens the composer card over the draft's keys, stood down.
    private func open(_ p: Presenter) throws -> PopoverCard {
        p.menus.action("showPopover", ["composer-card", "card-open"])
        waitFor("the card over stood-down keys", cap: 10, facts: { self.keyboardFacts(p) }) { !p.menus.inTransition }
        let card = try XCTUnwrap(card())
        XCTAssertNotNil(card.view.window)
        XCTAssertTrue(p.keysStoodDown, "this test must exercise the real keyboard stand-down")
        XCTAssertFalse(try XCTUnwrap(p.heldKeys, keyboardFacts(p)).returning)
        return card
    }

    /// Runs `act` once, as the returning keys announce themselves (their will-show).
    private func whileReturning(_ p: Presenter, _ act: @escaping () -> Void) -> NSObjectProtocol {
        var acted = false
        return NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            guard p.heldKeys?.returning == true, !acted else { return }
            acted = true
            DispatchQueue.main.async(execute: act)
        }
    }

    // MARK: The upstream suite's scenarios

    func testInteractiveCancellationAndCompletionKeepSettlementAndKeyboardOwnershipUntilTheyEnd() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "UIKit must drive the card's interactive coordinator") }
        let cancellation = SheetDismissal()
        let (p, _) = try page(in: scene, transition: cancellation), draft = try node("card-draft"), editor = try XCTUnwrap(draft.textArea)
        editor.selectedRange = NSRange(location: 2, length: 4)
        let card = try open(p), held = try XCTUnwrap(p.heldKeys), agent = Agent(session: try XCTUnwrap(session))
        card.dismiss(animated: true)
        waitFor("the real interactive card dismissal begins", cap: 10) { cancellation.started && card.transitionCoordinator?.isInteractive == true }
        cancellation.interaction.update(0.4)
        XCTAssertTrue(p.menus.inTransition, "the held native gesture is unsettled before any close request")
        XCTAssertTrue(agent.nativeInFlight())
        XCTAssertTrue(p.menus.isOpen(try node("composer-card")))
        XCTAssertTrue(p.heldKeys === held)
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
        XCTAssertFalse(card.view.isHidden, "a cancelled pull shows the card again")
        XCTAssertTrue(p.menus.isOpen(try node("composer-card")))
        XCTAssertTrue(p.heldKeys === held)
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
        let next = try XCTUnwrap(self.card())
        XCTAssertFalse(next === card)
        XCTAssertNil(next.presentingViewController, "the opening waits for the interactive owner to retire")
        XCTAssertEqual(next.phase, .waiting)
        XCTAssertTrue(p.heldKeys === held)
        completion.interactive = false
        completion.interaction.finish()
        XCTAssertTrue(p.menus.inTransition)
        waitFor("the completed dismissal admits the queued opening", cap: 10) { !p.menus.inTransition && next.viewIfLoaded?.window != nil }
        XCTAssertNil(card.presentingViewController)
        XCTAssertEqual(card.phase, .finished)
        XCTAssertTrue(p.heldKeys === held, "the queued opening keeps the same keyboard hold")
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
        XCTAssertTrue(p.editing === draft, "standing down is no end of the editing")
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
        XCTAssertNil(p.keyboardEditor)
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
    }

    func testANewCardWaitsOnReturningKeysAndDoesNotReviveAnOldOpening() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "keyboard completion needs the hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        let first = try open(p), held = try XCTUnwrap(p.heldKeys)
        var reopened = false
        var queued: PopoverCard?
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            guard p.heldKeys === held, held.returning, !reopened else { return }
            reopened = true
            XCTAssertEqual(first.phase, .finished)
            XCTAssertNil(first.presentingViewController)
            // Queue during the real will-show; presentation must wait for keyboard completion
            p.menus.action("showPopover", ["composer-card", "card-open"])
            queued = self.card()
            XCTAssertNotNil(queued)
            XCTAssertEqual(queued?.phase, .waiting)
            XCTAssertNil(queued?.presentingViewController)
            XCTAssertTrue(p.heldKeys === held)
            XCTAssertTrue(held.returning)
            XCTAssertTrue(p.menus.inTransition)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("a new opening after the keyboard's completion", cap: 10, facts: { self.keyboardFacts(p) }) {
            reopened && !p.menus.inTransition && p.keysStoodDown
        }
        let current = try XCTUnwrap(card())
        XCTAssertTrue(current === queued)
        XCTAssertFalse(current === first)
        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(current.phase, .shown)
        XCTAssertNotNil(current.view.window)
        XCTAssertFalse(p.heldKeys === held, "the new card stood new keys down")
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
        let observer = whileReturning(p) { blurred = true; p.blurElement(["card-draft"]) }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the authored blur cancels returning input", cap: 10) { blurred && !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
        waitForMainQueue("the blur's turn")
        XCTAssertEqual(try text("card-blurs"), "Blur 1", "the hold ended once")
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
        XCTAssertTrue(p.heldKeys?.node === inner)
        p.menus.action("hidePopover", ["card-native"])
        waitFor("the parent card regains its input", cap: 10) { !p.menus.inTransition && !p.keysStoodDown && field.isFirstResponder }
        XCTAssertEqual(inner.liveSelection, NSRange(location: 1, length: 3))
        XCTAssertNotNil(parent.view.window)
        XCTAssertEqual(parent.phase, .shown)
        XCTAssertTrue(p.menus.isOpen(try node("composer-card")))
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the parent card leaves", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(p.keysStoodDown, "the parent's retired hold is not revived by its own leaving")
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
        waitFor("the draft hears its blur", cap: 10) { (try? self.text("card-blurs")) == "Blur 1" }
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
        XCTAssertTrue(try node("card-draft").formDisabled)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertNil(p.keyboardEditor)
        waitFor("the disabled draft hears its blur", cap: 10) { (try? self.text("card-blurs")) == "Blur 1" }
        let pill = try node("card-pill")
        // The upstream assertion, kept: the pin's `glassAnswersTouch` (GlassGroup.swift) counts a
        // disabled field as the pill's field, so on the pin alone this is expected to fail (review.md)
        XCTAssertFalse(pill.materialInteractive)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the disabled field's card retires", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertFalse(p.keysStoodDown)
    }

    func testRemovingTheDraftWhileItsKeysStandDownDoesNotRestoreIt() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "field removal needs the hosted keyboard") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        p.press(try node("card-remove-field").id)
        XCTAssertNil(p.views.values.first { $0.props["testId"] == "card-draft" })
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertNil(p.keyboardEditor)
        XCTAssertFalse(try node("card-pill").materialInteractive)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the removed field's card leaves", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(editor.window)
        XCTAssertFalse(p.keysStoodDown)
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
        let focuses = try text("card-focuses"), blurs = try text("card-blurs"), changes = try text("card-changes")
        XCTAssertNil(session.boot(plan: try fixturePlan("GLASS_PRESS"), size: try XCTUnwrap(window).bounds.size).error)
        waitFor("reboot retires the old native owner", cap: 10) { !p.menus.inTransition }
        XCTAssertEqual(session.generation, generation + 1)
        XCTAssertFalse(try node("card-draft") === draft)
        XCTAssertNil(card.presentingViewController)
        XCTAssertEqual(card.phase, .finished)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertEqual(try text("card-focuses"), focuses)
        XCTAssertEqual(try text("card-blurs"), blurs)
        XCTAssertEqual(try text("card-changes"), changes)
        waitForMainQueue("retirement callbacks after reboot")
        XCTAssertFalse(p.menus.inTransition)
        XCTAssertFalse(try XCTUnwrap(node("card-draft").textArea).isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertEqual(try text("card-focuses"), focuses)
        XCTAssertEqual(try text("card-blurs"), blurs)
    }

    // MARK: Holds that end without the keys, and completions that are not theirs

    func testARefusedResignationLeavesTheLiveEditorAndNoSnapshotOwner() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "real software input requires a hosted scene") }
        let editor = RefusingTextView()
        let (p, _) = try page(in: scene, replacement: editor)
        editor.selectedRange = NSRange(location: 2, length: 4)
        editor.refusesResignation = true
        defer { editor.refusesResignation = false }
        p.menus.action("showPopover", ["composer-card", "card-open"])
        waitFor("the card presents without a false keyboard hold", cap: 10, facts: { self.keyboardFacts(p) }) { !p.menus.inTransition }
        XCTAssertNotNil(card()?.view.window)
        XCTAssertFalse(p.keysStoodDown)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(p.keyboardEditor === editor)
        XCTAssertTrue(p.focusedNode === (try node("card-draft")))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the card leaves the editor as it was", cap: 10) { !p.menus.inTransition }
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
    }

    func testARefusedReturnEndsTheEditingAndAllowsANewEditingSession() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "real software input requires a hosted scene") }
        let editor = RefusingTextView()
        let (p, _) = try page(in: scene, replacement: editor)
        editor.selectedRange = NSRange(location: 2, length: 4)
        _ = try open(p)
        editor.refusesReturn = true
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("failed restoration retires the owner", cap: 10, facts: { self.keyboardFacts(p) }) { !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertNil(p.keyboardEditor)
        waitFor("the draft hears its blur", cap: 10) { (try? self.text("card-blurs")) == "Blur 1" }
        editor.refusesReturn = false
        try focusDraft(p)
        _ = try open(p)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("a subsequent editing session returns normally", cap: 10) { !p.keysStoodDown && !p.menus.inTransition && editor.isFirstResponder }
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 4))
    }

    func testANativeEndWhileReturningEndsTheEditingOnceWithItsChange() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "real keyboard return requires a hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        editor.insertText("!")
        waitFor("the native input reaches the draft", cap: 10) { editor.text.contains("!") }
        XCTAssertEqual(try text("card-changes"), "Change 0")
        _ = try open(p)
        var ended = false
        let observer = whileReturning(p) { ended = true; XCTAssertTrue(editor.resignFirstResponder()) }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("native resignation cancels the pending return", cap: 10) { ended && !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertNil(p.editing)
        waitFor("the draft hears its change and blur", cap: 10) { (try? self.text("card-blurs")) == "Blur 1" && (try? self.text("card-changes")) == "Change 1" }
        waitForMainQueue("the end's turn")
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
        XCTAssertEqual(try text("card-changes"), "Change 1")
    }

    func testSuspensionPreservesThePendingEditUntilAnAuthoredBlurCommitsOnce() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "logical edits require the hosted keyboard") }
        let (p, _) = try page(in: scene), draft = try node("card-draft"), editor = try XCTUnwrap(draft.textArea)
        editor.insertText("!")
        waitFor("the native input reaches the draft", cap: 10) { editor.text.contains("!") }
        XCTAssertEqual(try text("card-changes"), "Change 0")
        _ = try open(p)
        XCTAssertEqual(try text("card-changes"), "Change 0", "standing down is not an editing commit")
        XCTAssertTrue(p.editing === draft)
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the same editing session returns", cap: 10) { !p.keysStoodDown && !p.menus.inTransition && editor.isFirstResponder }
        XCTAssertEqual(try text("card-changes"), "Change 0")
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
        _ = try open(p)
        p.press(try node("card-blur").id)
        waitFor("the authored blur commits the pending edit", cap: 10) { !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertEqual(try text("card-changes"), "Change 1")
        XCTAssertEqual(try text("card-blurs"), "Blur 1")
        XCTAssertNil(p.focusedNode)
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testAMismatchedFrameOrAnotherScreenDoesNotCompleteTheReturn() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "completion matching requires the real keyboard") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        let window = try XCTUnwrap(self.window)
        // The screen test the return applies (`StoodDownKeys.names`). UIKit
        // refuses a `UIScreen` made here (-[UIScreen init] raises), so on one
        // display another screen is an identity that is not this window's;
        // the notification below goes out only when a real second screen is connected.
        XCTAssertTrue(StoodDownKeys.names(window.screen, screen: window.screen))
        XCTAssertTrue(StoodDownKeys.names(nil, screen: window.screen), "a notification naming no screen is this window's")
        XCTAssertFalse(StoodDownKeys.names(window.screen, screen: NSObject()), "another screen's keys are not this window's")
        let otherScreen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first { $0 !== window.screen }
        if otherScreen == nil {
            let note = XCTAttachment(string: "\(name): one display; another screen's keyboard notification is checked by StoodDownKeys.names alone, not posted")
            note.name = "single display"
            note.lifetime = .keepAlways
            add(note)
        }
        editor.selectedRange = NSRange(location: 2, length: 4)
        _ = try open(p)
        let held = try XCTUnwrap(p.heldKeys)
        var challenged = false
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            guard p.heldKeys === held, held.returning, !challenged else { return }
            challenged = true
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            DispatchQueue.main.async {
                XCTAssertTrue(p.heldKeys === held)
                XCTAssertTrue(editor.isFirstResponder)
                let center = NotificationCenter.default
                // Another geometry on this screen: not the keys this editor asked for
                center.post(name: UIResponder.keyboardDidChangeFrameNotification, object: note.object,
                            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: -10000, y: -10000, width: 1, height: 1), UIResponder.keyboardIsLocalUserInfoKey: true])
                XCTAssertTrue(p.heldKeys === held, "another geometry cannot complete this return")
                // The expected geometry on another screen object: not this window's keys
                if let end {
                    if let otherScreen {
                        center.post(name: UIResponder.keyboardDidShowNotification, object: otherScreen,
                                    userInfo: [UIResponder.keyboardFrameEndUserInfoKey: end, UIResponder.keyboardIsLocalUserInfoKey: true])
                        XCTAssertTrue(p.heldKeys === held, "another screen's keys cannot complete this return")
                    }
                    // Another app's keys, with this geometry on this screen
                    center.post(name: UIResponder.keyboardDidShowNotification, object: note.object,
                                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: end, UIResponder.keyboardIsLocalUserInfoKey: false])
                    XCTAssertTrue(p.heldKeys === held, "another app's keys cannot complete this return")
                }
                XCTAssertTrue(held.returning)
                XCTAssertTrue(p.menus.inTransition)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the actual keyboard completion releases ownership", cap: 10, facts: { self.keyboardFacts(p) }) { challenged && !p.keysStoodDown && !p.menus.inTransition && editor.isFirstResponder }
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
    }

    func testARotationWhileTheKeysReturnGivesThemBackAtOnce() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "a returning keyboard needs the hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        editor.selectedRange = NSRange(location: 2, length: 4)
        _ = try open(p)
        var turned = false
        // What the card's orientation observer calls as the scene turns (PopoverCard.viewWillAppear)
        let observer = whileReturning(p) { turned = true; p.menus.cards.rotated() }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the rotation ends the hold with the keys", cap: 10, facts: { self.keyboardFacts(p) }) { turned && !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertTrue(editor.isFirstResponder, "the editor keeps the keys UIKit brings")
        XCTAssertTrue(p.focusedNode === (try node("card-draft")))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(try text("card-blurs"), "Blur 0")
        XCTAssertTrue(p.menus.presented.isEmpty)
    }

    func testDisablingTheDraftWhileItsKeysReturnEndsTheEditing() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "a returning keyboard needs the hosted scene") }
        let (p, _) = try page(in: scene), editor = try XCTUnwrap(node("card-draft").textArea)
        _ = try open(p)
        var disabled = false
        let observer = whileReturning(p) { disabled = true; p.press((try? self.node("card-disable-field"))?.id ?? 0) }
        defer { NotificationCenter.default.removeObserver(observer) }
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the batch that disables the draft ends its hold", cap: 10, facts: { self.keyboardFacts(p) }) { disabled && !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertTrue(try node("card-draft").formDisabled, "the press reached the closed card's button")
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        XCTAssertNil(p.keyboardEditor)
        waitFor("the disabled draft hears its blur", cap: 10) { (try? self.text("card-blurs")) == "Blur 1" }
    }

    func testAReplacedEditorWhileItsKeysStandDownDoesNotTakeThemBack() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "a returning keyboard needs the hosted scene") }
        let (p, _) = try page(in: scene), draft = try node("card-draft"), editor = try XCTUnwrap(draft.textArea)
        _ = try open(p)
        // The node's editor is another view now, as a restyle that rebuilds it leaves the node
        let replacement = UITextView(frame: editor.frame)
        replacement.text = editor.text
        replacement.delegate = draft
        editor.removeFromSuperview()
        draft.textArea = replacement
        draft.addSubview(replacement)
        XCTAssertTrue(p.keysStoodDown, "the hold stands until a batch or the return checks it")
        XCTAssertNil(p.keyboardEditor, "the hold names an editor the node no longer has")
        p.menus.action("hidePopover", ["composer-card"])
        waitFor("the return finds the editor replaced and ends the hold", cap: 10, facts: { self.keyboardFacts(p) }) { !p.keysStoodDown && !p.menus.inTransition }
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertFalse(replacement.isFirstResponder)
        XCTAssertNil(p.focusedNode)
        waitFor("the draft hears its blur", cap: 10) { (try? self.text("card-blurs")) == "Blur 1" }
    }
}
#endif
