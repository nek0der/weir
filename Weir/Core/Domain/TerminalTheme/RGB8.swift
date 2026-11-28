// RGB8.swift
// Weir — an 8-bit sRGB color as libghostty reports it, with WCAG contrast and CIELAB difference.

import Foundation

/// An opaque 8-bit-per-channel sRGB color.
package struct RGB8: Equatable, Hashable, Sendable {
    package var r: UInt8
    package var g: UInt8
    package var b: UInt8

    package init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// The WCAG 2 relative luminance, from 0 (black) to 1 (white).
    package var relativeLuminance: Double {
        0.2126 * Self.linear(r) + 0.7152 * Self.linear(g) + 0.0722 * Self.linear(b)
    }

    /// The WCAG 2 contrast ratio between this color and `other`, from 1 to 21.
    /// The order of the two colors does not matter.
    package func contrast(with other: RGB8) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// This color laid over `backdrop` at `opacity` (0...1), mixed per
    /// sRGB channel as the window server composites a translucent layer.
    package func composited(over backdrop: RGB8, opacity: Double) -> RGB8 {
        let alpha = min(1, max(0, opacity))
        func channel(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8((Double(top) * alpha + Double(bottom) * (1 - alpha)).rounded())
        }
        return RGB8(r: channel(r, backdrop.r), g: channel(g, backdrop.g), b: channel(b, backdrop.b))
    }

    /// The CIE 1976 color difference (ΔE*ab) between this color and
    /// `other`, in CIELAB under D65. About 2 is the smallest difference a
    /// reader notices side by side; colors 10 or more apart read as
    /// different colors at a glance.
    package func difference(from other: RGB8) -> Double {
        zip(lab, other.lab).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    /// L*, a*, and b*, in that order.
    package var lab: [Double] {
        let red = Self.linear(r)
        let green = Self.linear(g)
        let blue = Self.linear(b)
        // sRGB to XYZ, each divided by the D65 white point.
        let x = (0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.95047
        let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let z = (0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
        }
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
    }

    /// The color with CIELAB (D65) `lightness`, `a`, and `b`, the inverse
    /// of `lab`, or `nil` when no sRGB color has them: `lightness` outside
    /// 0...100, or a hue more saturated than sRGB holds at that lightness.
    package init?(lightness: Double, a: Double, b: Double) {
        guard (0...100).contains(lightness), let linear = Self.linearRGB(lightness: lightness, a: a, b: b) else {
            return nil
        }
        self.init(r: Self.encoded(linear[0]), g: Self.encoded(linear[1]), b: Self.encoded(linear[2]))
    }

    /// The color with CIELAB `lightness` and the hue of `a` and `b`, its
    /// chroma reduced as far as sRGB needs, so the lightness is kept
    /// exactly and only the saturation gives way. `nil` for a `lightness`
    /// outside 0...100.
    package init?(lightness: Double, keepingHueOf a: Double, _ b: Double) {
        guard (0...100).contains(lightness) else { return nil }
        if let color = RGB8(lightness: lightness, a: a, b: b) {
            self = color
            return
        }
        // The neutral at that lightness is always in gamut, so a binary
        // search on the chroma's share finds the most saturated one that is.
        var low = 0.0
        var high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if Self.linearRGB(lightness: lightness, a: a * mid, b: b * mid) != nil {
                low = mid
            } else {
                high = mid
            }
        }
        guard let color = RGB8(lightness: lightness, a: a * low, b: b * low) else { return nil }
        self = color
    }

    /// Linear sRGB for a CIELAB color, or `nil` when a channel falls
    /// outside 0...1 by more than rounding.
    private static func linearRGB(lightness: Double, a: Double, b: Double) -> [Double]? {
        let fy = (lightness + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200
        func inverse(_ t: Double) -> Double {
            t > 6.0 / 29 ? t * t * t : 108.0 / 841 * (t - 4.0 / 29)
        }
        let x = inverse(fx) * 0.95047
        let y = inverse(fy)
        let z = inverse(fz) * 1.08883
        let channels = [
            3.2406 * x - 1.5372 * y - 0.4986 * z,
            -0.9689 * x + 1.8758 * y + 0.0415 * z,
            0.0557 * x - 0.2040 * y + 1.0570 * z
        ]
        let tolerance = 1e-4
        guard channels.allSatisfy({ $0 >= -tolerance && $0 <= 1 + tolerance }) else { return nil }
        return channels.map { min(1, max(0, $0)) }
    }

    private static func encoded(_ linear: Double) -> UInt8 {
        let gamma = linear <= 0.003_130_8 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8((min(1, max(0, gamma)) * 255).rounded())
    }

    private static func linear(_ channel: UInt8) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
