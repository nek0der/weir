// PanePlacementStore.swift
// Weir — where each pane of the drawn tab stands on the session's surface, measured once per pane.

import SwiftUI

/// A pane's frame on the session's surface, with the surface's size from
/// the same reading, so a resize never pairs one moment's place with
/// another's size.
struct PanePlacement: Equatable {
    var frame: CGRect
    var surface: CGSize

    init(frame: CGRect, surface: CGSize) {
        self.frame = frame
        self.surface = surface
    }

    /// From one reading of a pane's geometry: `surfaceBounds` is the
    /// surface's rectangle in the pane's own coordinates
    /// (`GeometryProxy.bounds(of:)`), `nil` off a surface.
    init?(size: CGSize, surfaceBounds: CGRect?) {
        guard let surfaceBounds else { return nil }
        self.init(
            frame: CGRect(origin: CGPoint(x: -surfaceBounds.minX, y: -surfaceBounds.minY), size: size),
            surface: surfaceBounds.size
        )
    }

    /// Which of the pane's edges and corners are the surface's.
    var fit: SurfaceFrameFit {
        SurfaceFrameFit.fit(frame: frame, surface: surface)
    }
}

/// The placements of the drawn tab's panes. Each pane writes its own as
/// it is laid out (`PaneContainerView`), and everything drawn around a
/// pane reads it here instead of measuring the pane again: the attention
/// and conversation frames, the drop ring, and a frame's seam, which also
/// needs where the panes beside it stand. Only what reads a placement is
/// drawn again when it moves, so a resize costs nothing while no frame
/// shows.
@MainActor
@Observable
final class PanePlacementStore {
    private(set) var placements: [UUID: PanePlacement] = [:]

    func set(_ placement: PanePlacement?, for paneID: UUID) {
        guard placements[paneID] != placement else { return }
        placements[paneID] = placement
    }

    /// Drops the panes no longer drawn. A pane that leaves does not remove
    /// its own entry: its view can disappear after its replacement for the
    /// same pane (a zoom) has already written the new place.
    func retain(only paneIDs: Set<UUID>) {
        let gone = placements.keys.filter { !paneIDs.contains($0) }
        for paneID in gone {
            placements[paneID] = nil
        }
    }
}
