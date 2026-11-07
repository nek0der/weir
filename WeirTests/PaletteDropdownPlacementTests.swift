// PaletteDropdownPlacementTests.swift
// Weir — where the palette's dropdown stands across the window.

import CoreGraphics
import Testing
@testable import Weir

struct PaletteDropdownPlacementTests {
    struct Placement: Sendable {
        let fieldMidX: CGFloat
        var containerWidth: CGFloat = 1200
        let expectedX: CGFloat
    }

    @Test(arguments: [
        Placement(fieldMidX: 600, expectedX: 320),
        Placement(fieldMidX: 200, expectedX: 6),
        Placement(fieldMidX: 1100, expectedX: 634),
        Placement(fieldMidX: 286, expectedX: 6),
        Placement(fieldMidX: 914, expectedX: 634),
        Placement(fieldMidX: 250, containerWidth: 500, expectedX: 6)
    ])
    func theDropdown_centersOnTheField_withinTheWindow(_ placement: Placement) {
        #expect(PaletteDropdownPlacement.originX(
            fieldMidX: placement.fieldMidX, width: 560, containerWidth: placement.containerWidth
        ) == placement.expectedX)
    }
}
