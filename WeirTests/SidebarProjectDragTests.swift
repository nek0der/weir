// SidebarProjectDragTests.swift
// Weir — the reorder of the projects on the layer over the sidebar's list.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("SidebarProjectDrag")
struct SidebarProjectDragTests {
    private let step: CGFloat = 36
    private let entries = (0..<5).map { SidebarProjectDrag.Entry(id: UUID(), name: "p\($0)", paletteIndex: nil, isCollapsed: true) }

    private var ids: [UUID] {
        entries.map(\.id)
    }

    /// Takes the measured header ten points below its top and gathers it.
    private func drag(from index: Int, height: CGFloat = 500, top: CGFloat = 200) -> SidebarProjectDrag {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = height
        drag.setHeaderTop(top, of: ids[index])
        #expect(drag.begin(ids[index], entries: entries, startY: top + 10, pointerY: top + 10))
        drag.gather()
        return drag
    }

    @Test func anotherDragBeginsOnlyAfterThePreviousReleaseFinishes() async throws {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        try #require(drag.begin(ids[0], entries: entries, startY: 10, pointerY: 10))
        let first = try #require(drag.dragID)

        func expectRefusal(in phase: SidebarProjectDrag.Phase) {
            #expect(!drag.begin(ids[1], entries: Array(entries.reversed()), startY: 80, pointerY: 100))
            #expect(drag.phase == phase)
            #expect(drag.sourceID == ids[0])
            #expect(drag.dragID == first)
            #expect(drag.entries == entries)
            #expect(drag.pointerY == 10)
        }

        expectRefusal(in: .gathering)
        drag.gather()
        expectRefusal(in: .carrying)
        #expect(drag.release() == ids)
        expectRefusal(in: .returning)

        await drag.finishRelease(travel: .zero, fade: .zero)

        #expect(drag.phase == nil)
        #expect(drag.sourceID == nil)
        #expect(drag.dragID == nil)
        try #require(drag.begin(ids[0], entries: entries, startY: 20, pointerY: 20))
        #expect(drag.phase == .gathering)
        #expect(drag.sourceID == ids[0])
        #expect(try #require(drag.dragID) != first)
    }

    @Test func aHeaderNotAmongTheEntries_doesNotBegin() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        #expect(!drag.begin(UUID(), entries: entries, startY: 0, pointerY: 0))
        #expect(drag.phase == nil)
        #expect(drag.sourceID == nil)
        #expect(drag.dragID == nil)
        #expect(drag.entries.isEmpty)
    }

    @Test func nothingMoves_afterTheRelease() {
        let drag = drag(from: 2)
        drag.move(pointerY: 210 + step)
        let reordered = [ids[0], ids[1], ids[3], ids[2], ids[4]]
        #expect(drag.entries.map(\.id) == reordered)
        #expect(drag.release() == reordered)
        let pointer = drag.pointerY
        let top = drag.firstLineTop

        drag.move(pointerY: 900)
        drag.scrollAtEdge()
        #expect(drag.release().isEmpty)

        #expect(drag.phase == .returning)
        #expect(drag.entries.map(\.id) == reordered)
        #expect(drag.pointerY == pointer)
        #expect(drag.firstLineTop == top)
    }

    @Test func aLaterBeginUsesTheOriginalPressOffset() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = 500
        drag.setHeaderTop(100, of: ids[1])
        #expect(drag.begin(ids[1], entries: entries, startY: 110, pointerY: 150))
        #expect(drag.liftedTop == 140)
    }

    @Test func beforeTheListReportsItsHeight_theHeaderIsNotClamped() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.setHeaderTop(100, of: ids[1])
        #expect(drag.begin(ids[1], entries: entries, startY: 110, pointerY: 110))
        #expect(drag.liftedTop == 100)
    }

    @Test func measuredHeadersStartInPlaceAndEveryHeaderGathersAroundTheHeldOne() throws {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = 500
        drag.setHeaderTop(40, of: ids[0])
        drag.setHeaderTop(120, of: ids[1])
        try #require(drag.begin(ids[1], entries: entries, startY: 130, pointerY: 130))
        #expect(drag.phase == .gathering)
        #expect(drag.top(of: ids[0]) == 40)
        #expect(drag.top(of: ids[1]) == 120)
        #expect(ids.map(drag.isShown) == [true, true, false, false, false])

        drag.gather()

        #expect(drag.phase == .carrying)
        #expect(ids.allSatisfy(drag.isShown))
        #expect(ids.map(drag.top) == [84, 120, 156, 192, 228])
        #expect(drag.isLifted(ids[1]))
    }

    @Test func movingPastHalfALineReordersAndReturningToTheStartRestoresOrder() {
        let drag = drag(from: 2)
        drag.move(pointerY: 210 + step * 0.4)
        #expect(drag.entries.map(\.id) == ids)
        drag.move(pointerY: 210 + step * 0.6)
        #expect(drag.entries.map(\.id) == [ids[0], ids[1], ids[3], ids[2], ids[4]])
        drag.move(pointerY: 210 - step * 0.4)
        #expect(drag.entries.map(\.id) == ids)
        drag.move(pointerY: 210 - step * 0.6)
        #expect(drag.entries.map(\.id) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        drag.move(pointerY: 210)
        #expect(drag.entries.map(\.id) == ids)
        #expect(drag.release() == ids)
    }

    @Test func theHeldHeader_staysInSight() {
        let drag = drag(from: 2)
        drag.move(pointerY: -500)
        #expect(drag.liftedTop == 0)
        drag.move(pointerY: 2000)
        #expect(drag.liftedTop == 472)
    }

    @Test func aHeaderHeldStillAtAnEdge_doesNotScroll() {
        let drag = drag(from: 2, height: 100, top: 72)
        #expect(drag.liftedTop == 72)
        #expect(drag.firstLineTop == 0)

        drag.scrollAtEdge()

        #expect(drag.firstLineTop == 0)
        #expect(drag.entries.map(\.id) == ids)
    }

    @Test(arguments: [false, true])
    func edgeScrollingMovesOneLineThenStopsAtTheContentLimit(atTop: Bool) {
        let drag = drag(from: atTop ? 4 : 0, height: 100, top: 0)
        #expect(drag.firstLineTop == (atTop ? -144 : 0))
        drag.move(pointerY: atTop ? -500 : 900)
        let heldTop: CGFloat = atTop ? 0 : 72
        #expect(drag.liftedTop == heldTop)

        drag.scrollAtEdge()

        #expect(drag.firstLineTop == (atTop ? -108 : -36))
        #expect(drag.entries.map(\.id) == (atTop ? [ids[0], ids[1], ids[2], ids[4], ids[3]] : [ids[1], ids[2], ids[3], ids[0], ids[4]]))
        #expect(drag.liftedTop == heldTop)
        for _ in 0..<8 {
            drag.scrollAtEdge()
        }
        let cap: CGFloat = atTop ? 0 : -80
        let order = atTop ? [ids[4], ids[0], ids[1], ids[2], ids[3]] : [ids[1], ids[2], ids[3], ids[4], ids[0]]
        #expect(drag.firstLineTop == cap)
        #expect(drag.entries.map(\.id) == order)
        drag.scrollAtEdge()
        #expect(drag.firstLineTop == cap)
        #expect(drag.entries.map(\.id) == order)
    }

    @Test func theLayer_keepsTheListHidden_untilTheHeadersAreBack() async {
        let drag = drag(from: 2)
        #expect(drag.hidesList)
        #expect(drag.hidesHeader(ids[2]))
        _ = drag.release()
        #expect(drag.hidesList)
        await drag.finishRelease(travel: .zero, fade: .zero)
        #expect(!drag.hidesList)
        #expect(!drag.hidesHeader(ids[2]))
    }

    @Test func theHeaders_returnToTheListsNewPlaces() {
        let drag = drag(from: 2)
        drag.setHeaderTop(236, of: ids[3])
        drag.move(pointerY: 210 + step)
        #expect(drag.release() == [ids[0], ids[1], ids[3], ids[2], ids[4]])
        #expect(drag.phase == .returning)
        #expect(drag.top(of: ids[2]) == 200)
        #expect(drag.top(of: ids[3]) == 236)

        drag.setHeaderTop(260, of: ids[2])
        drag.setHeaderTop(192, of: ids[3])
        #expect(drag.top(of: ids[2]) == 260)
        #expect(drag.top(of: ids[3]) == 192)
        drag.setHeaderTop(nil, of: ids[3])
        #expect(!drag.isShown(ids[3]))
        #expect(drag.isShown(ids[2]))
    }
}
