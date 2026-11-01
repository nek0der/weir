// DemoCaptureRegion.swift
// Weir — tells the capture script where a demo layer's surface is, so its crop follows the layout.

import SwiftUI

extension View {
    /// Reports this view's frame to `scripts/screenshot.sh` while demo mode
    /// opens one of `layers`. Nothing is added in any other run, and `isReady`
    /// is not even read, so a normal launch observes nothing more. The script
    /// stops when no report arrives, so a surface that failed to appear never
    /// becomes an image. `cornerRadius` rounds a floating surface's crop.
    @ViewBuilder
    func reportsDemoCaptureRegion(
        for layers: DemoFixture.OpenLayer...,
        cornerRadius: CGFloat = 0,
        isReady: @autoclosure () -> Bool = true
    ) -> some View {
        if let layer = DemoFixture.openLayer, layers.contains(layer) {
            modifier(DemoCaptureRegionReporter(cornerRadius: cornerRadius, isReady: isReady()))
        } else {
            self
        }
    }
}

private struct DemoCaptureRegionReporter: ViewModifier {
    let cornerRadius: CGFloat
    let isReady: Bool
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onChange(of: frame) { report() }
            .onChange(of: isReady) { report() }
    }

    private func report() {
        guard isReady, !frame.isEmpty else { return }
        DemoFixture.writeCaptureRegion(frame, cornerRadius: cornerRadius)
    }
}
