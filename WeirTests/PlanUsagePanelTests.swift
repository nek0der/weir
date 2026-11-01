// PlanUsagePanelTests.swift
// Weir — the plan usage panel: where it opens beside its rail button, and how it shares the window's layers.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

@Suite("Plan usage placement")
struct PlanUsagePlacementTests {
    private static let window = CGSize(width: 1200, height: 800)

    /// The button is in the rail's bottom group, so the panel's bottom is
    /// level with the columns' bottom (the sidebar's foot) rather than with
    /// the button, and it grows up to the columns' top.
    @Test("opens beside its button, level with the columns' bottom")
    func fromTheRailsBottom_itOpensBeside_levelWithTheColumnsBottom() {
        let button = RailPanelAnchor(
            frame: CGRect(x: 4, y: 700, width: 32, height: 32),
            columnTop: 44,
            columnBottom: 760
        )
        let place = FloatingPanelPlacement.besideRailBottom(anchor: button, panelWidth: 340, container: Self.window)
        #expect(place == .init(leading: 46, bottom: 760, maximumHeight: 716))
    }

    @Test("stays inside the window near its edges")
    func nearTheWindowsEdges_itStaysInside() {
        let low = RailPanelAnchor(frame: CGRect(x: 1000, y: 780, width: 32, height: 32), columnTop: 0, columnBottom: 800)
        let place = FloatingPanelPlacement.besideRailBottom(anchor: low, panelWidth: 340, container: Self.window)
        // Pulled in from the trailing edge, above the bottom margin, and
        // never above the top margin.
        #expect(place.leading == 854)
        #expect(place.bottom == 794)
        #expect(place.maximumHeight == 788)
    }
}

@MainActor
@Suite("Plan usage layer")
struct PlanUsageLayerTests {
    @Test("opening closes the window's other layers, and a second click closes it")
    func opening_closesTheWindowsOtherLayers_andASecondClickClosesIt() {
        let session = WorkspaceSession()
        let window = ProjectWindowState(selection: WindowSelection())
        window.notificationHistory.isPresented = true
        session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window.id)

        window.togglePlanUsage(session: session)
        #expect(window.planUsage.isPresented)
        #expect(!window.notificationHistory.isPresented)
        #expect(session.commandPaletteState == nil)
        #expect(!window.isAnotherLayerOpen(than: .planUsage, session: session))

        window.togglePlanUsage(session: session)
        #expect(!window.planUsage.isPresented)
    }

    /// The panel shows every account, not one project's, so moving the
    /// window to another project leaves it open, as the notification history.
    @Test("a project switch leaves the panel open")
    func aProjectSwitch_leavesThePanelOpen() {
        #expect(!WindowProjectSwitch.layersLeft.contains(.planUsage))
        #expect(!WindowProjectSwitch.layersLeft.contains(.notificationHistory))
    }
}
