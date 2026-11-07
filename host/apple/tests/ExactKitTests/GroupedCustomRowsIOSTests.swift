#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit
@testable import ExactGroupedLists

/// A custom grouped row, its views carried into a list cell, drawn as a
/// standard cell beside it is (Harmony, 2026-10-21). UIKit, so a simulator
/// runs it.
final class GroupedCustomRowsIOSTests: GroupedListFixture {
    /// A custom row first, a standard row of the same symbol after it.
    func customFirst() -> GroupedListModel {
        GroupedListModel(style: "inset-grouped", sections: [
            .init(view: 2, header: nil, footer: nil, rows: [
                Row(view: 21, custom: true, pressable: true),
                Row(view: 10, symbol: "person.circle", title: "Profile", accessory: "disclosure", pressable: true),
                Row(view: 11, title: "Notifications", secondary: "On", accessory: "disclosure", pressable: true),
            ]),
        ])
    }

    func testACustomRowsSymbolIsAListCellsImageAndItsLineStartsUnderItsContent() throws {
        let p = presenter { self.customFirst() }
        // The kernel's boxes for a row of a leading symbol (the sheet's 24 by
        // 20, 16 in), its content inset 56 past it, spanning its card.
        p.apply(wireBatch([
            ["op": "create", "id": 30, "kind": "image", "props": ["imageSource": "symbol:person", "symbolName": "person.circle"], "style": ["font_size": 17.0, "object_fit": "contain"]],
            ["op": "create", "id": 31, "kind": "image", "props": ["imageSource": "symbol:forward-chevron", "symbolName": "chevron.forward"], "style": ["font_size": 17.0]],
            ["op": "children", "id": 21, "ids": [30, 31]],
            ["op": "frame", "id": 21, "x": 0.0, "y": 0.0, "w": 370.0, "h": 61.0],
            ["op": "frame", "id": 30, "x": 16.0, "y": 20.5, "w": 24.0, "h": 20.0],
            ["op": "frame", "id": 31, "x": 344.0, "y": 23.0, "w": 10.0, "h": 14.0],
        ]))
        let row = try XCTUnwrap(p.views[21]), leaf = try XCTUnwrap(p.views[30])
        row.kernelContentBox = CGRect(x: 56, y: 0, width: 298, height: 61)
        // The next batch carries the row again, which notes its line and lays
        // the list out again for it.
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "custom"]]]))
        let l = try list(p)
        l.collection.layoutIfNeeded()
        let custom = try cell(p, 21), standard = try cell(p, 10)
        XCTAssertTrue(row.superview === custom.contentView)
        XCTAssertTrue(leaf.listSymbol, "the first child, a symbol")
        XCTAssertFalse(try XCTUnwrap(p.views[31]).listSymbol, "an accessory's chevron is no leading symbol")
        // UIKit draws a cell's image at the large scale of the body's size
        // (its `preferredSymbolConfiguration`), at its own size, centred.
        func images(_ v: UIView) -> [UIImageView] { (v as? UIImageView).map { [$0] } ?? v.subviews.flatMap(images) }
        let theirs = try XCTUnwrap(images(standard.contentView).first { $0.frame.width > 20 })
        let ours = try XCTUnwrap(leaf.symbolView)
        let drawn = try XCTUnwrap(ours.image).size
        XCTAssertEqual(drawn.width, theirs.bounds.width, accuracy: 0.5, "the symbol as wide as the standard row's")
        XCTAssertEqual(drawn.height, theirs.bounds.height, accuracy: 0.5, "and as tall")
        XCTAssertEqual(ours.contentMode, .center)
        XCTAssertFalse(ours.clipsToBounds, "its own size, past the sheet's box")
        XCTAssertEqual(ours.convert(ours.bounds, to: custom).midX, theirs.convert(theirs.bounds, to: standard).midX, accuracy: 0.5,
                       "centred where the standard row's is")
        // The line under the custom row starts under its content, where the
        // standard row's starts under its text.
        func lines(_ v: UIView) -> [UIView] { (String(describing: type(of: v)).contains("Separator") ? [v] : []) + v.subviews.flatMap(lines) }
        let found = lines(l.collection).map { $0.convert($0.bounds, to: l.collection) }
        let under = { (cell: UICollectionViewCell) -> CGRect? in
            let frame = cell.convert(cell.bounds, to: l.collection)
            return found.first { abs($0.maxY - frame.maxY) < 1.5 }.map { $0.offsetBy(dx: -frame.minX, dy: 0) }
        }
        let mine = try XCTUnwrap(under(custom), "a line under the custom row")
        let theirLine = try XCTUnwrap(under(standard), "a line under the standard row")
        XCTAssertEqual(mine.minX, 56, accuracy: 0.5, "under its content")
        XCTAssertEqual(mine.minX, theirLine.minX, accuracy: 0.5, "as the standard row's")
        // Its content moves in a batch that keeps its height: the line follows.
        row.kernelContentBox = CGRect(x: 16, y: 0, width: 338, height: 61)
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "moved"]]]))
        l.collection.layoutIfNeeded()
        let moved = lines(l.collection).map { $0.convert($0.bounds, to: l.collection) }
        let frame = custom.convert(custom.bounds, to: l.collection)
        let line = try XCTUnwrap(moved.first { abs($0.maxY - frame.maxY) < 1.5 })
        XCTAssertEqual(line.minX - frame.minX, 16, accuracy: 0.5, "the line where the content now starts")
    }

    /// Right to left the kernel mirrors the row's insets, and the line starts
    /// past its symbol from the right; a row the model drops takes its mark
    /// with it.
    func testRightToLeftTheLineIsTheKernelsAndADroppedRowTakesItsMark() throws {
        var dropped = false
        let p = presenter(style: ["direction": "rtl"]) { dropped ? GroupedListModel(style: "inset-grouped", sections: [.init(view: 2, header: nil, footer: nil, rows: [
            Row(view: 10, symbol: "person.circle", title: "Profile", accessory: "disclosure", pressable: true),
        ])]) : self.customFirst() }
        p.apply(wireBatch([
            ["op": "create", "id": 30, "kind": "image", "props": ["imageSource": "symbol:person", "symbolName": "person.circle"], "style": ["font_size": 17.0, "object_fit": "contain"]],
            ["op": "children", "id": 21, "ids": [30]],
            ["op": "frame", "id": 21, "x": 0.0, "y": 0.0, "w": 370.0, "h": 61.0],
            ["op": "frame", "id": 30, "x": 330.0, "y": 20.5, "w": 24.0, "h": 20.0],
        ]))
        let row = try XCTUnwrap(p.views[21]), image = try XCTUnwrap(p.views[30])
        row.kernelContentBox = CGRect(x: 16, y: 0, width: 298, height: 61)
        let l = try list(p)
        XCTAssertEqual(l.collection.effectiveUserInterfaceLayoutDirection, .rightToLeft, "the list's direction")
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "custom"]]]))
        l.collection.collectionViewLayout.invalidateLayout()
        l.collection.layoutIfNeeded()
        // Where UIKit draws it is not read here: this fixture's window has no
        // scene, and the list layout's environment stays left to right in it.
        XCTAssertEqual(try XCTUnwrap(try list(p).lineStart(21)), 56, accuracy: 0.5, "from the right, past the symbol")
        XCTAssertTrue(image.listSymbol)
        dropped = true
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "dropped"]]]))
        XCTAssertFalse(image.listSymbol, "the row the model dropped takes its mark")
    }

    /// An image its author sized or fitted is left as laid out, and a mark
    /// goes with the list.
    func testAnAuthoredImageIsLeftAsLaidOutAndAMarkGoesWithTheList() throws {
        let p = presenter { self.customFirst() }
        p.apply(wireBatch([
            ["op": "create", "id": 30, "kind": "image", "props": ["imageSource": "symbol:person", "symbolName": "person.circle"], "style": ["font_size": 17.0, "object_fit": "cover"]],
            ["op": "children", "id": 21, "ids": [30]],
            ["op": "frame", "id": 30, "x": 16.0, "y": 20.5, "w": 24.0, "h": 20.0],
        ]))
        let image = try XCTUnwrap(p.views[30])
        XCTAssertFalse(image.listSymbol, "its author's fit")
        p.apply(wireBatch([["op": "style", "id": 30, "style": ["font_size": 17.0, "object_fit": "contain", "written": ["width", "height"]]],
                           ["op": "frame", "id": 30, "x": 16.0, "y": 14.0, "w": 32.0, "h": 32.0]]))
        XCTAssertFalse(image.listSymbol, "its author's size")
        // The sheet's slot, at whatever size its ramps give it.
        p.apply(wireBatch([["op": "style", "id": 30, "style": ["font_size": 17.0, "object_fit": "contain"]],
                           ["op": "frame", "id": 30, "x": 16.0, "y": 16.5, "w": 32.11, "h": 26.76]]))
        XCTAssertTrue(image.listSymbol, "the sheet's slot")
        // A fit its author wrote, even the sheet's own value, is theirs.
        p.apply(wireBatch([["op": "style", "id": 30, "style": ["font_size": 17.0, "object_fit": "contain", "written": ["object_fit"]]]]))
        XCTAssertFalse(image.listSymbol, "its author's contain")
        p.apply(wireBatch([["op": "style", "id": 30, "style": ["font_size": 17.0, "object_fit": "contain"]]]))
        XCTAssertTrue(image.listSymbol)
        // At an accessibility size too, drawn at UIKit's smaller size there.
        window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        window.layoutIfNeeded() // traits reach the views at layout
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "large"]]]))
        XCTAssertTrue(image.listSymbol, "an accessibility size")
        let base = UIImage.SymbolConfiguration(pointSize: 33)
        XCTAssertEqual(image.symbolShape(base), base.applying(UIImage.SymbolConfiguration(pointSize: 25.14)).applying(UIImage.SymbolConfiguration(scale: .large)))
        window.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        window.layoutIfNeeded()
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "xxxl"]]]))
        XCTAssertTrue(image.listSymbol, "the largest size short of them")
        host(p).lists[1]?.remove()
        XCTAssertFalse(image.listSymbol, "gone with the list")
    }

    /// A cell UIKit gives to another custom row takes that row's height,
    /// which is no resize: the layout already knows each row's height. When
    /// it was one, two cells handed back and forth between rows of two
    /// heights at a long list's bottom edge laid the list out again on every
    /// turn, and Hackers' feed spun a core at rest (LLP 1141.001 D13).
    func testACellTakingAnotherRowsHeightLaysNothingOutAgain() throws {
        let p = presenter {
            var m = self.model()
            m.sections[0].header = nil
            m.sections[0].footer = nil
            m.sections[0].rows[0] = Row(view: 10, custom: true, pressable: true)
            m.sections[0].rows[1] = Row(view: 11, custom: true, pressable: true)
            return m
        }
        p.apply(wireBatch([["op": "frame", "id": 10, "x": 16.0, "y": 0.0, "w": 354.0, "h": 85.0],
                           ["op": "frame", "id": 11, "x": 16.0, "y": 85.0, "w": 354.0, "h": 79.0]]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let l = try list(p)
        let a = try XCTUnwrap(try cell(p, 10) as? GroupedCell), b = try XCTUnwrap(try cell(p, 11) as? GroupedCell)
        let pathA = try XCTUnwrap(l.collection.indexPath(for: a)), pathB = try XCTUnwrap(l.collection.indexPath(for: b))
        XCTAssertEqual([a.height, b.height], [85, 79])
        XCTAssertFalse(l.resized, "laid out")
        // UIKit shows each cell for the other's row, then gives them back.
        l.collectionView(l.collection, willDisplay: a, forItemAt: pathB)
        l.collectionView(l.collection, willDisplay: b, forItemAt: pathA)
        XCTAssertTrue(try XCTUnwrap(p.views[11]).superview === a.contentView)
        XCTAssertEqual(a.height, 79, "the cell takes its new row's height")
        XCTAssertFalse(l.resized, "which the layout already has")
        l.collectionView(l.collection, willDisplay: a, forItemAt: pathA)
        l.collectionView(l.collection, willDisplay: b, forItemAt: pathB)
        XCTAssertFalse(l.resized)
        // A row whose own height changes still lays the list out again.
        p.apply(wireBatch([["op": "frame", "id": 11, "x": 16.0, "y": 85.0, "w": 354.0, "h": 120.0]]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try cell(p, 11).bounds.height, 120, accuracy: 0.5, "its row grew")
    }

    /// A finger held on a custom row keeps it pressed, its cell highlighted,
    /// through a batch, which puts the row back in its authored place and
    /// carries it into its cell again; the lift presses it once.
    func testAPressHeldOnACustomRowGoesOnThroughABatch() throws {
        let p = presenter { self.model(custom: true) }
        var presses: [UInt32] = []
        p.onPress = { presses.append($0) }
        let row = try XCTUnwrap(p.views[21])
        let touch = RowTouch(row, at: CGPoint(x: 100, y: 30))
        row.touchesBegan([touch], with: nil)
        XCTAssertTrue(row.pressed)
        XCTAssertTrue(try cell(p, 21).isHighlighted, "its cell's press")
        p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "held"]]]))
        let carried = try cell(p, 21)
        XCTAssertTrue(row.superview === carried.contentView, "carried again")
        XCTAssertTrue(row.pressed, "still pressed after the batch")
        XCTAssertTrue(carried.isHighlighted, "and still highlighted")
        row.touchesEnded([touch], with: nil)
        XCTAssertEqual(presses, [21], "the lift presses it")
        XCTAssertFalse(row.pressed)
        XCTAssertFalse(try cell(p, 21).isHighlighted)
    }

    func testAWindowDetachedCustomRowCancelsItsHeldContactAndAcceptsAFreshPress() throws {
        let p = presenter { self.model(custom: true) }
        let ancestor = p.viewport, parent = try XCTUnwrap(p.viewport.superview)
        let index = try XCTUnwrap(parent.subviews.firstIndex(of: ancestor))
        defer {
            if ancestor.superview !== parent { parent.insertSubview(ancestor, at: min(index, parent.subviews.count)) }
            window.isHidden = true
        }
        let row = try XCTUnwrap(p.views[21]), native = try cell(p, 21)
        let physicalParent = native.contentView
        XCTAssertTrue(row.superview === physicalParent)
        XCTAssertTrue(row.window === window)
        var presses: [UInt32] = []
        p.onPress = { presses.append($0) }
        let oldTouch = RowTouch(row, at: CGPoint(x: 100, y: 30))
        row.touchesBegan([oldTouch], with: nil)
        let oldContact = try XCTUnwrap(row.pressContact)
        XCTAssertTrue(oldContact.touch === oldTouch)
        XCTAssertTrue(oldContact.ownsPress)
        XCTAssertFalse(oldContact.routesBubbledPress)
        XCTAssertFalse(oldContact.cancelled)
        XCTAssertTrue(row.pressed)
        XCTAssertTrue(native.isHighlighted)

        ancestor.removeFromSuperview()
        XCTAssertNil(ancestor.window)
        XCTAssertNil(row.window)
        XCTAssertTrue(p.views[21] === row)
        XCTAssertTrue(row.superview === physicalParent, "only the ancestor leaves its window")
        XCTAssertTrue(row.pressContact === oldContact)
        XCTAssertTrue(oldContact.touch === oldTouch)
        XCTAssertTrue(oldContact.cancelled, "window loss retires the still-held direct contact")
        XCTAssertFalse(row.pressed)
        XCTAssertFalse(native.isHighlighted)
        XCTAssertEqual(presses, [])
        row.touchesEnded([oldTouch], with: nil)
        XCTAssertEqual(presses, [], "the detached contact's old lift cannot activate")
        XCTAssertFalse(row.pressed)
        XCTAssertFalse(native.isHighlighted)
        let feedbackDeadline = Date().addingTimeInterval(5)
        while (row.pressPaint.down || row.pressPaint.releaseHeld || !row.press.atRest), Date() < feedbackDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(row.pressPaint.down)
        XCTAssertFalse(row.pressPaint.releaseHeld)
        XCTAssertTrue(row.press.atRest)
        XCTAssertEqual(presses, [])

        parent.insertSubview(ancestor, at: min(index, parent.subviews.count))
        window.layoutIfNeeded()
        XCTAssertTrue(row.window === window)
        XCTAssertTrue(p.views[21] === row)
        let currentCell = try cell(p, 21)
        XCTAssertTrue(row.superview === currentCell.contentView)
        let freshTouch = RowTouch(row, at: CGPoint(x: 100, y: 30))
        row.touchesBegan([freshTouch], with: nil)
        let freshContact = try XCTUnwrap(row.pressContact)
        XCTAssertFalse(freshContact === oldContact)
        XCTAssertTrue(freshContact.touch === freshTouch)
        XCTAssertFalse(freshContact.cancelled)
        XCTAssertTrue(row.pressed)
        XCTAssertTrue(currentCell.isHighlighted)
        row.touchesEnded([freshTouch], with: nil)
        XCTAssertEqual(presses, [21], "a fresh contact after reattachment activates exactly once")
        XCTAssertFalse(row.pressed)
        XCTAssertFalse(currentCell.isHighlighted)
    }

    /// A held custom row in a sidebar fades as far as UIKit fades its own
    /// label, unless it peeks: then the lift alone shows the press.
    func testAHeldCustomRowFadesAsUIKitsOwnContentDoesUnlessItPeeks() throws {
        let follower = try XCTUnwrap(try list(presenter { self.model(custom: true) }).stateFollower)
        let menu = NoMenu()
        func alpha(_ appearance: UICollectionLayoutListConfiguration.Appearance, highlighted: Bool, selected: Bool = false, peeks: Bool = false) throws -> (ours: CGFloat, label: CGFloat) {
            let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 400),
                                        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: appearance)))
            window.addSubview(view)
            defer { view.removeFromSuperview() }
            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { _, _, _ in }
            let source = UICollectionViewDiffableDataSource<Int, Int>(collectionView: view) { view, path, item in
                view.dequeueConfiguredReusableCell(using: registration, for: path, item: item)
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems([0])
            source.apply(snapshot, animatingDifferences: false)
            view.layoutIfNeeded()
            let cell = try XCTUnwrap(view.cellForItem(at: IndexPath(item: 0, section: 0)) as? UICollectionViewListCell)
            if peeks {
                let row = UIView()
                row.addInteraction(UIContextMenuInteraction(delegate: menu))
                cell.contentView.addSubview(row)
            }
            var state = cell.configurationState
            state.isHighlighted = highlighted
            state.isSelected = selected
            follower(cell, state)
            let label = cell.defaultContentConfiguration().updated(for: state).textProperties.resolvedColor().resolvedColor(with: cell.traitCollection)
            return (cell.contentView.alpha, label.cgColor.alpha)
        }
        let held = try alpha(.sidebarPlain, highlighted: true)
        XCTAssertLessThan(held.ours, 1, "a sidebar's held row fades")
        XCTAssertEqual(held.ours, held.label, accuracy: 0.01, "as far as UIKit's own label")
        XCTAssertEqual(try alpha(.sidebarPlain, highlighted: true, peeks: true).ours, 1, "one that peeks keeps its content")
        XCTAssertEqual(try alpha(.sidebarPlain, highlighted: true, selected: true).ours, 1, "selected, on the accent")
        XCTAssertEqual(try alpha(.sidebarPlain, highlighted: false).ours, 1)
        XCTAssertEqual(try alpha(.plain, highlighted: true).ours, 1, "a plain list's held row fills its ground instead")
    }

    func testAnAuthoredPressKeepsItsBoundsAcrossCarryAndRestore() throws {
        let p = presenter { self.model(custom: true) }
        defer { window.isHidden = true }
        let row = try XCTUnwrap(p.views[21]), groupedList = try list(p)
        let original = row.bounds, cellCenter = row.center
        p.apply(wireBatch([["op": "style", "id": 21, "style": ["press_scale": 0.9]]]))
        let touch = GeometryTouch(row)
        var presses: [UInt32] = []
        p.onPress = { presses.append($0) }
        row.touchesBegan([touch], with: nil)
        XCTAssertTrue(row.pressed)
        let contact = try XCTUnwrap(row.pressContact)
        for turn in 0..<3 {
            p.apply(wireBatch([["op": "props", "id": 21, "set": ["testId": "geometry-\(turn)"]]]))
            XCTAssertTrue(row.superview === (try cell(p, 21)).contentView)
            XCTAssertTrue(row.pressed && row.pressContact === contact && !contact.cancelled, "the held contact goes on through carry \(turn)")
            XCTAssertEqual(row.bounds.width, original.width, accuracy: 0.001)
            XCTAssertEqual(row.bounds.height, original.height, accuracy: 0.001)
            XCTAssertEqual(row.transform.a, 0.9, accuracy: 0.001)
            XCTAssertEqual(row.transform.d, 0.9, accuracy: 0.001)
            XCTAssertEqual(row.center.x, cellCenter.x, accuracy: 0.001)
            XCTAssertEqual(row.center.y, cellCenter.y, accuracy: 0.001)
        }
        let home = try XCTUnwrap(row.grid).drawn
        groupedList.restore()
        XCTAssertEqual(row.bounds.size, home.size)
        XCTAssertEqual(row.center.x, home.midX, accuracy: 0.001)
        XCTAssertEqual(row.center.y, home.midY, accuracy: 0.001)
        XCTAssertEqual(row.transform.a, 0.9, accuracy: 0.001)
        XCTAssertTrue(row.pressed && row.pressContact === contact && !contact.cancelled, "the held contact goes on through an explicit restore")
        p.apply(wireBatch([]))
        let native = try cell(p, 21)
        XCTAssertTrue(row.superview === native.contentView)
        XCTAssertTrue(row.pressed && row.pressContact === contact && !contact.cancelled, "and through the carry that follows")
        touch.point = native.contentView.convert(CGPoint(x: cellCenter.x + original.width / 2 + 8, y: cellCenter.y), to: nil)
        row.touchesMoved([touch], with: nil)
        XCTAssertTrue(row.pressPaint.outside)
        row.touchesCancelled([touch], with: nil)
        row.touchesEnded([touch], with: nil)
        XCTAssertEqual(presses, [])
        XCTAssertFalse(row.hasPressContact, "the cancelled contact cannot activate")
        XCTAssertFalse(row.pressed || native.isHighlighted)
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !row.pressPaint.down && !row.press.releaseHeld && row.press.to == 1
                && row.transform == .identity
        }, object: nil)
        wait(for: [released], timeout: 2)
        XCTAssertFalse(row.hasPressContact)
        XCTAssertFalse(row.pressed || native.isHighlighted || row.pressPaint.down || row.press.releaseHeld)
        XCTAssertEqual(row.press.to, 1)
        XCTAssertEqual(row.transform, .identity)
        XCTAssertEqual(row.bounds.size, original.size)
        XCTAssertEqual(presses, [], "no callback arrives while the young release settles")
        // A fresh press where the row is drawn now, carried in its cell,
        // presses it once; its young release is held until the press has
        // shown, then settles back to identity.
        let fresh = GeometryTouch(row)
        row.touchesBegan([fresh], with: nil)
        XCTAssertTrue(row.pressed)
        XCTAssertFalse(row.pressContact === contact, "a fresh contact, not the cancelled one")
        XCTAssertEqual(row.bounds.size, original.size)
        XCTAssertEqual(row.transform.a, 0.9, accuracy: 0.001)
        row.touchesEnded([fresh], with: nil)
        XCTAssertEqual(presses, [21], "a fresh press after the carries activates once")
        XCTAssertFalse(row.pressed || native.isHighlighted)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !row.press.releaseHeld && row.press.to == 1 && row.transform == .identity
        }, object: nil)
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(row.hasPressContact)
        XCTAssertEqual(row.bounds.size, original.size)
        XCTAssertEqual(presses, [21])
    }

    private final class GeometryTouch: UITouch {
        let target: UIView
        var point: CGPoint
        init(_ target: UIView) {
            self.target = target
            point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            super.init()
        }
        override var view: UIView? { target }
        override func location(in view: UIView?) -> CGPoint { view.map { $0.convert(point, from: nil) } ?? point }
    }

    private final class NoMenu: NSObject, UIContextMenuInteractionDelegate {
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? { nil }
    }

    private final class RowTouch: UITouch {
        let target: UIView, point: CGPoint
        init(_ target: UIView, at point: CGPoint) { self.target = target; self.point = point; super.init() }
        override var view: UIView? { target }
        override func location(in view: UIView?) -> CGPoint { target.convert(point, to: view) }
    }
}
#endif
