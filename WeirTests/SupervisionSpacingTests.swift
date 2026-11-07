// SupervisionSpacingTests.swift
// Weir — the supervision UI's spacing roles: where a list's headings stand.

import SwiftUI
import Testing
@testable import Weir

struct SupervisionSpacingTests {
    private typealias Layout = WeirLayout.Supervision

    @Test func aListsFirstHeading_standsAsAPopoversHeading_andLaterOnesAStepFurther() {
        // The first heading sits right under what is above the list: 12pt
        // from a popover's edge, as the title bar dropdowns' heading does.
        #expect(Layout.popoverInset + Layout.headingInsets(isFirst: true).top == 12)
        // A heading after rows starts a group: 12pt above it.
        #expect(Layout.headingInsets(isFirst: false).top == 12)
        // Every heading's words line up with the rows' (16pt from the edge).
        for isFirst in [true, false] {
            let heading = Layout.headingInsets(isFirst: isFirst)
            #expect(Layout.popoverInset + heading.leading == 16)
            #expect(Layout.paletteHeadingInsets(isFirst: isFirst) == heading)
            #expect(Layout.notificationDayInsets(isFirst: isFirst) == heading)
        }
        #expect(Layout.popoverInset + Layout.popoverRowInsets.leading == Layout.popoverWordsInset)
        #expect(Layout.popoverWordsInset == 16)
    }

    @Test func aPopoversField_keepsItsFocusRingClearOfTheEdge() {
        let margins = Layout.popoverFieldMargins
        for margin in [margins.top, margins.leading, margins.trailing] {
            let fieldInset = Layout.popoverInset + margin
            #expect(fieldInset == Layout.popoverFieldInset)
            #expect(fieldInset - Layout.focusRingOutset == 12)
        }
        #expect(margins.bottom - Layout.focusRingOutset == 8)
    }
}
