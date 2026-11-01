// ProjectWindowState+SidebarWidth.swift
// Weir — the width a window's sidebar is drawn at, from the layout's constants.

import CoreGraphics

extension ProjectWindowState {
    /// The width this window's sidebar is drawn at, against the body last
    /// measured (`SupervisionWindowWidths.sidebarDrawnWidth`). Read by
    /// everything that needs the sidebar's width on screen (the sidebar,
    /// its divider, the changes panel's layout, and the approval card), so
    /// none of them goes by the saved width while the window holds the
    /// sidebar narrower.
    var sidebarDrawnWidth: CGFloat {
        SupervisionWindowWidths.sidebarDrawnWidth(
            saved: selection.sidebarWidth,
            range: WeirLayout.Supervision.sidebarWidthRange,
            bodyWidth: changesPanelSharedWidth,
            surfaceGap: WeirLayout.Supervision.surfaceSpacing,
            sessionMinWidth: WeirLayout.reviewMinWidth
        )
    }

    /// Where the session's surface starts, from the window's leading edge:
    /// past the window's margin, the rail and the sidebar while each shows.
    /// What the approval card lines up with, wherever it stands.
    var sessionSurfaceMinX: CGFloat {
        let layout = WeirLayout.Supervision.self
        let rail = areRailsHidden ? 0 : layout.railWidth + layout.surfaceGap
        let sidebar = isSidebarPresented ? sidebarDrawnWidth + layout.surfaceSpacing : 0
        return layout.surfaceGap + rail + sidebar
    }

    /// The widest the sidebar can be drawn in this window now
    /// (`SupervisionWindowWidths.sidebarDrawnMaxWidth`).
    var sidebarDrawnMaxWidth: CGFloat {
        SupervisionWindowWidths.sidebarDrawnMaxWidth(
            range: WeirLayout.Supervision.sidebarWidthRange,
            bodyWidth: changesPanelSharedWidth,
            surfaceGap: WeirLayout.Supervision.surfaceSpacing,
            sessionMinWidth: WeirLayout.reviewMinWidth
        )
    }
}
