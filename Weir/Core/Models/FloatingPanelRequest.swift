// FloatingPanelRequest.swift
// Weir — what a presentation publishes while its floating panel is open.

import CoreGraphics
import Foundation

/// An open floating panel, as its presentation publishes it: an identity
/// minted per opening, and the frame it hangs from in global coordinates.
protocol FloatingPanelRequest: Identifiable where ID == UUID {
    var anchor: CGRect { get }
}
