// SurfaceRegistry+PaneOcclusion.swift
// Weir — lets the window registry put terminals to sleep through the surface registry.

/// The window registry hands the union of every window's visible panes
/// here.
extension SurfaceRegistry: PaneOcclusionApplying {}
