// ReviewOpenInEditorTests.swift
// Weir — pins which line Review's open action sends to the editor, so it
// is always the one the reader sees highlighted or the file's first change.

import SwiftUI
import Testing
@testable import Weir

@MainActor
struct ReviewOpenInEditorTests {
    /// A replacement at line 11 with context on both sides.
    private let lines = [
        ReviewLine(id: 0, kind: .context, text: "a", oldLine: 10, newLine: 10),
        ReviewLine(id: 1, kind: .removed, text: "b", oldLine: 11, newLine: nil),
        ReviewLine(id: 2, kind: .added, text: "c", oldLine: nil, newLine: 11),
        ReviewLine(id: 3, kind: .context, text: "d", oldLine: 12, newLine: 12),
        ReviewLine(id: 4, kind: .context, text: "e", oldLine: 13, newLine: 13),
        ReviewLine(id: 5, kind: .context, text: "f", oldLine: 14, newLine: 14)
    ]

    private final class Opened {
        var lines: [Int] = []
    }

    /// The selection behind a live binding, for the paths that write it.
    private final class Live {
        var selection = ReviewDiffSelection()
        var composeCount = 0
    }

    private func makeTable(
        selecting ids: [Int],
        text: ReviewTextSelection = ReviewTextSelection(),
        opened: Opened,
        live: Live? = nil,
        locale: Locale = Locale(identifier: "en")
    ) -> ReviewDiffTable {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        var selection = ReviewDiffSelection()
        selection.selectText(text)
        if let first = ids.first {
            selection.updateLines { lines in
                lines.select(first)
                if let last = ids.last, last != first {
                    lines.extend(to: last)
                }
            }
        }
        // The lines from row 1, under the file's header.
        return ReviewTableFixture.table(
            file,
            rows: lines.enumerated().map { ReviewRow(id: $0.offset, kind: .code($0.element)) },
            lines: lines,
            key: "open",
            selection: live.map { live in Binding(get: { live.selection }, set: { live.selection = $0 }) }
                ?? .constant(selection),
            composer: .closed,
            locale: locale,
            onCompose: { live?.composeCount += 1 },
            onOpenLine: { line, _ in opened.lines.append(line) }
        )
    }

    @Test func keyWithNothingSelectedOpensTheFirstChange() {
        let opened = Opened()
        let coordinator = makeTable(selecting: [], opened: opened).makeCoordinator()
        #expect(coordinator.handle(.openInEditor))
        #expect(opened.lines == [11])
    }

    @Test("The open key uses the top line regardless of selection direction", arguments: [[3, 4], [4, 3]])
    func keyOpensTheTopOfTheSelection(ids: [Int]) {
        let opened = Opened()
        let coordinator = makeTable(selecting: ids, opened: opened).makeCoordinator()
        #expect(coordinator.handle(.openInEditor))
        #expect(opened.lines == [12])
    }

    @Test("The menu opens the selection's top inside the run and the clicked line outside it", arguments: [
        (5, 12),
        (1, 10)
    ])
    func clickOpensTheSelectionOrTheClickedLine(row: Int, expectedLine: Int) {
        let opened = Opened()
        makeTable(selecting: [3, 5], opened: opened).makeCoordinator().openInEditor(clickedRow: row)
        #expect(opened.lines == [expectedLine])
    }

    /// The menu names the line, so a removal's new place is visible before
    /// the editor opens.
    @Test func titleNamesTheLineAndTheApp() {
        let coordinator = makeTable(selecting: [1], opened: Opened()).makeCoordinator()
        #expect(coordinator.openInEditorTitle(clickedRow: 2) == "Open Line 11 in Default Application")
    }

    /// The menu is AppKit, outside SwiftUI's environment, so it is written
    /// in the locale the table is handed rather than the launch language.
    @Test func titleFollowsTheTablesLocale() {
        let ja = Locale(identifier: "ja")
        let coordinator = makeTable(selecting: [1], opened: Opened(), locale: ja).makeCoordinator()
        #expect(coordinator.openInEditorTitle(clickedRow: 2) == "デフォルトのアプリケーションで 11 行目を開く")
    }

    /// Text dragged over lines 2 and 3, which are rows 3 and 4 under the
    /// file's header.
    private var draggedText: ReviewTextSelection {
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 4, lineID: 3, side: nil, utf16Offset: 1),
            to: ReviewTextPosition(rowIndex: 3, lineID: 2, side: nil, utf16Offset: 0)
        )
        return text
    }

    @Test func draggedTextSpansItsRowsTopFirst() {
        #expect(draggedText.rowRange == 3...4)
        #expect(ReviewTextSelection().rowRange == nil)
    }

    @Test("The open key and a click inside dragged text open its top", arguments: [nil as Int?, 5])
    func openInEditorOpensTheTopOfDraggedText(clickedRow: Int?) {
        let opened = Opened()
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 6, lineID: 5, side: nil, utf16Offset: 1),
            to: ReviewTextPosition(rowIndex: 4, lineID: 3, side: nil, utf16Offset: 0)
        )
        let coordinator = makeTable(selecting: [], text: text, opened: opened).makeCoordinator()
        if let clickedRow {
            coordinator.openInEditor(clickedRow: clickedRow)
        } else {
            #expect(coordinator.handle(.openInEditor))
        }
        #expect(opened.lines == [12])
    }

    @Test func keyOpensALaterSingleRowTextSelection() {
        let opened = Opened()
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 4, lineID: 3, side: nil, utf16Offset: 0),
            to: ReviewTextPosition(rowIndex: 4, lineID: 3, side: nil, utf16Offset: 1)
        )
        let coordinator = makeTable(selecting: [], text: text, opened: opened).makeCoordinator()
        #expect(coordinator.handle(.openInEditor))
        #expect(opened.lines == [12])
    }

    /// The comment key comments on the lines the dragged text covers, in
    /// one press.
    @Test func commentKeyTakesTheDraggedLines() {
        let live = Live()
        live.selection.selectText(draggedText)
        let coordinator = makeTable(selecting: [], opened: Opened(), live: live).makeCoordinator()
        #expect(coordinator.handle(.comment))
        #expect(live.selection.lines.startLineID == 2)
        #expect(live.selection.lines.endLineID == 3)
        #expect(live.selection.text.isEmpty)
        #expect(live.composeCount == 1)
    }

    /// `j` after a drag steps on from the dragged lines, not from the top.
    @Test func nextLineAfterADragStepsFromIt() {
        let live = Live()
        var text = ReviewTextSelection()
        text.select(
            from: ReviewTextPosition(rowIndex: 1, lineID: 0, side: nil, utf16Offset: 0),
            to: ReviewTextPosition(rowIndex: 2, lineID: 1, side: nil, utf16Offset: 1)
        )
        live.selection.selectText(text)
        let coordinator = makeTable(selecting: [], opened: Opened(), live: live).makeCoordinator()
        #expect(coordinator.handle(.nextLine))
        #expect(live.selection.lines.startLineID == 2)
        #expect(live.selection.lines.endLineID == 2)
        #expect(live.selection.text.isEmpty)
    }

    /// `k` after an upward drag goes on upward from where the drag ended,
    /// past the top of what was dragged.
    @Test func previousLineAfterAnUpwardDragGoesAboveIt() {
        let live = Live()
        live.selection.selectText(draggedText)
        let coordinator = makeTable(selecting: [], opened: Opened(), live: live).makeCoordinator()
        #expect(coordinator.handle(.previousLine))
        #expect(live.selection.lines.startLineID == 1)
        #expect(live.selection.lines.endLineID == 1)
    }

    /// The arrows are the line keys, so they move the same way `j` / `k` do.
    @Test func arrowsAreTheLineKeys() throws {
        func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> ReviewTableKey? {
            let event = try NSEvent.testKeyDown(keyCode: keyCode, modifiers: modifiers.union([.numericPad, .function]))
            return ReviewTableKey(event: event)
        }
        #expect(try key(125) == .nextLine)
        #expect(try key(126) == .previousLine)
        #expect(try key(125, .shift) == .extendNextLine)
        #expect(try key(126, .shift) == .extendPreviousLine)
        #expect(try key(125, .command) == nil)
        #expect(try key(123) == nil)
    }
}
