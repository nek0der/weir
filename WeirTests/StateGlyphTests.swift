// StateGlyphTests.swift
// Weir — the state glyphs as their legend draws them, in light and dark, with Increase Contrast and Reduce Motion.

import AppKit
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct StateGlyphTests {
    private typealias Tokens = SupervisionTokens
    private typealias Geometry = StateGlyphGeometry
    private nonisolated static let sizes: [CGFloat] = [15, 11]

    // MARK: - VoiceOver

    @Test(arguments: [
        (StateGlyph.Kind.needsApproval, "Needs approval", "承認待ち"),
        (.needsAnswer, "Needs answer", "回答待ち"),
        (.needsResponse, "Needs response", "応答待ち"),
        (.needsSignIn, "Needs sign-in", "サインイン待ち"),
        (.stopped, "Stopped", "停止"),
        (.unread, "Unread", "未読"),
        (.unreadWorkingAfterTurn, "Unread, working in the background", "未読、バックグラウンドで作業中"),
        (.running, "Running", "実行中"),
        (.idle, "Idle", "待機中"),
        (.workingAfterTurn, "Working in the background", "バックグラウンドで作業中"),
        (.unknown, "Unknown", "不明")
    ])
    func eachState_keepsItsName(kind: StateGlyph.Kind, english: String, japanese: String) {
        #expect(kind.name.resolved(in: Locale(identifier: "en")) == english)
        #expect(kind.name.resolved(in: Locale(identifier: "ja")) == japanese)
    }

    // MARK: - Reduce Motion

    @Test(arguments: [false, true])
    func theRunningArcAndOrbit_turnOnlyWithoutReduceMotion(reduceMotion: Bool) {
        #expect((RunningArc.turn(isTurning: !reduceMotion) != nil) == !reduceMotion)
        #expect((StateGlyphOrbit.turn(isTurning: !reduceMotion) != nil) == !reduceMotion)
        #expect(StateGlyphOrbit.restingAngle == .degrees(45))
    }

    // MARK: - What the environment says

    @Test(arguments: [StateGlyph.Kind.running, .workingAfterTurn, .unread])
    func theEnvironment_reachesTheFace(kind: StateGlyph.Kind) {
        let glyph = StateGlyph(kind: kind, size: 11)

        let standard = glyph.face(isReduceMotionOn: false, contrast: .standard)
        let increased = glyph.face(isReduceMotionOn: true, contrast: .increased)

        #expect(standard.kind == kind)
        #expect(increased.kind == kind)
        #expect(standard.size == 11)
        #expect(increased.size == 11)
        #expect(standard.isTurning)
        #expect(!increased.isTurning)
        #expect(!standard.isContrastIncreased)
        #expect(increased.isContrastIncreased)
        #expect(standard.unreadInk == Tokens.unread.color)
        #expect(increased.unreadInk == Tokens.unread.color)
    }

    /// We keep unread blue independent of the person's accent, including
    /// accents that otherwise resemble waiting or stopped states.
    @Test(arguments: AccentColor.allCases, [false, true])
    func theUnreadInk_isFixedBlue(_ accent: AccentColor, isDark: Bool) throws {
        let glyph = StateGlyph(kind: .unread)
            .environment(\.weirAccent, WeirColor.accent(for: accent))
            .environment(\.colorScheme, isDark ? .dark : .light)
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = Self.scale
        let pixels = try Pixels(#require(renderer.cgImage), unit: WeirLayout.Supervision.stateGlyphSize / 14 * Self.scale)
        Self.expect(pixels, at: (8, 8), is: Tokens.unread.value(isDark: isDark), "the fixed blue unread dot")
    }

    @Test(arguments: [false, true])
    func theUnreadBlue_clearsEveryIconGround(isDark: Bool) {
        let blue = Tokens.unread.value(isDark: isDark)
        for ground in AccentIconRule.grounds(isDark: isDark) {
            #expect(ContrastRatio.between(blue, ground) >= 3, "Unread blue on \(ground), dark: \(isDark)")
        }
    }

    // MARK: - Geometry

    @Test(arguments: sizes)
    func theRings_thickenWithIncreaseContrast(size: CGFloat) {
        let standard = Geometry(size: size, isContrastIncreased: false)
        let increased = Geometry(size: size, isContrastIncreased: true)
        #expect(standard.ringWidth(.idle) == 1)
        #expect(increased.ringWidth(.idle) == 1.5)
        #expect(abs(standard.ringWidth(.unread) - size * 1.6 / 14) < 0.001)
        #expect(abs(increased.ringWidth(.unread) - (size * 1.6 / 14 + 0.5)) < 0.001)
        #expect(standard.idleInk == Tokens.faint)
        #expect(increased.idleInk == Tokens.muted)
    }

    // MARK: - Drawing

    @Test(arguments: [false, true], sizes)
    func eachGlyph_drawsTheLegendsShape(isDark: Bool, size: CGFloat) throws {
        let red = Tokens.stopped.value(isDark: isDark)
        let white = SRGB(0xFFFFFF)
        let stopped = try Self.render(.stopped, isDark: isDark, size: size)
        Self.expect(stopped, at: (8, 6.4), is: white, "the stopped bar")
        Self.expect(stopped, at: (8, 9.9), is: red, "the gap in the exclamation mark")
        Self.expect(stopped, at: (8, 11.6), is: white, "the stopped dot")
        Self.expect(stopped, at: (4.5, 8), is: red, "the stopped disc")
        Self.expectMark(stopped, in: white)

        let amber = Tokens.waitingGlyph.value(isDark: isDark)
        let waitingInk = Tokens.onWaiting.value(isDark: isDark)
        for kind in [StateGlyph.Kind.needsApproval, .needsAnswer, .needsResponse, .needsSignIn] {
            let waiting = try Self.render(kind, isDark: isDark, size: size)
            Self.expect(waiting, at: (8.05, 3.92), is: waitingInk, "the top of the question mark's hook")
            Self.expect(waiting, at: (6.98, 7.93), is: amber, "the disc under the hook")
            Self.expect(waiting, at: (8, 9.4), is: waitingInk, "the question mark's stem")
            Self.expect(waiting, at: (8, 10.6), is: amber, "the gap in the question mark")
            Self.expect(waiting, at: (8, 12), is: waitingInk, "the question mark's dot")
            Self.expect(waiting, at: (4.5, 8), is: amber, "the waiting disc")
            Self.expectMark(waiting, in: waitingInk)
        }

        let blue = Tokens.unread.value(isDark: isDark)
        let unread = try Self.render(.unread, isDark: isDark, size: size)
        Self.expect(unread, at: (8, 8), is: blue, "the unread dot")
        Self.expect(unread, at: (8, 1.8), is: blue, "the unread ring")
        #expect(Self.alpha(unread, at: (4.5, 8)) < 0.05, "the unread ring leaves the disc empty")

        let faint = Tokens.faint.value(isDark: isDark)
        let idle = try Self.render(.idle, isDark: isDark, size: size)
        Self.expect(idle, at: (8, 1.45), is: faint, "the idle ring")
        #expect(Self.alpha(idle, at: (8, 8)) < 0.05, "inside the idle ring")

        let running = try Self.render(.running, isDark: isDark, size: size)
        Self.expect(running, at: (12.3, 12.3), is: Tokens.running.value(isDark: isDark), "the stationary quarter arc")
        Self.expect(running, at: (3.7, 3.7), is: Tokens.line.value(isDark: isDark), "the track opposite the arc")
        #expect(Self.alpha(running, at: (8, 8)) < 0.05)
    }

    @Test(arguments: [false, true], sizes)
    func workAfterATurn_addsADotOnTheRing(isDark: Bool, size: CGFloat) throws {
        let dot = Tokens.text.value(isDark: isDark)
        let blue = Tokens.unread.value(isDark: isDark)
        for increased in [false, true] {
            let gain: CGFloat = increased ? 0.5 : 0
            let idleInk = (increased ? Tokens.muted : Tokens.faint).value(isDark: isDark)
            let cases: [(StateGlyph.Kind, CGFloat)] = [
                (.workingAfterTurn, 1 + gain),
                (.unreadWorkingAfterTurn, size * 1.6 / 14 + gain)
            ]
            for (kind, width) in cases {
                let ringInk = kind == .workingAfterTurn ? idleInk : blue
                // The ring's middle line, projected at 45° and 225° in the
                // 16-unit drawing square.
                let offset = Double((size - width) * 7 / size) / sqrt(2.0)
                let pixels = try Self.render(kind, isDark: isDark, size: size, isContrastIncreased: increased)
                Self.expect(pixels, at: (8 + offset, 8 - offset), is: dot, "the dot at the upper right")
                Self.expect(pixels, at: (8 - offset, 8 + offset), is: ringInk, "the ring opposite the dot")
                if kind == .workingAfterTurn {
                    #expect(Self.alpha(pixels, at: (8, 8)) < 0.05)
                } else {
                    Self.expect(pixels, at: (8, 8), is: blue, "the unread dot")
                }
            }
        }
    }

    @Test(arguments: sizes, [Geometry.Ring.idle, .unread])
    func theOrbitingDot_isCenteredOnItsRing_andWiderThanIt(size: CGFloat, ring: StateGlyphGeometry.Ring) {
        let standard = Geometry(size: size, isContrastIncreased: false)
        let increased = Geometry(size: size, isContrastIncreased: true)
        let width: CGFloat = ring == .idle ? 1 : size * 1.6 / 14
        #expect(abs(standard.orbitRadius(on: ring) - (size - width) / 2) < 0.001)
        #expect(abs(increased.orbitRadius(on: ring) - (size - width - 0.5) / 2) < 0.001)
        #expect(abs(standard.orbitDotDiameter(on: ring) - max(2.4, width * 1.8)) < 0.001)
        #expect(abs(increased.orbitDotDiameter(on: ring) - max(2.4, (width + 0.5) * 1.8)) < 0.001)
        #expect(increased.orbitDotDiameter(on: ring) > standard.orbitDotDiameter(on: ring))
    }

    /// The dot's ink, the body text's, stands at least 2:1 from the ring it
    /// rides on in both appearances, the faint idle ring and the `muted` one
    /// Increase Contrast draws alike.
    @Test(arguments: [false, true])
    func theOrbitingDot_standsApartFromTheIdleRing(isDark: Bool) {
        for isContrastIncreased in [false, true] {
            let least = 2.0
            let geometry = Geometry(size: 15, isContrastIncreased: isContrastIncreased)
            let dot = geometry.orbitInk.value(isDark: isDark)
            let ring = geometry.idleInk.value(isDark: isDark)
            #expect(ContrastRatio.between(dot, ring) >= least, "contrast \(isContrastIncreased): \(dot.hexBytes) on \(ring.hexBytes)")
        }
        #expect(Geometry(size: 15, isContrastIncreased: false).orbitInk == Tokens.text)
        #expect(Geometry(size: 15, isContrastIncreased: true).orbitInk == Tokens.text)
    }

    @Test(arguments: [false, true], sizes)
    func theUnknownGlyph_isADashedRing(isDark: Bool, size: CGFloat) throws {
        for increased in [false, true] {
            let pixels = try Self.render(.unknown, isDark: isDark, size: size, isContrastIncreased: increased)
            let width: CGFloat = increased ? 1.5 : 1
            let radius = Double((size - width) * 7 / size)
            let muted = Tokens.muted.value(isDark: isDark)
            #expect(Self.alpha(pixels, at: (8, 8)) < 0.05)

            // Ignore the antialiased transition pixels before counting
            // alternations, including the transition across the sample seam.
            var sectors: [Bool] = []
            for step in 0..<96 {
                let angle = Double(step) * 2 * .pi / 96
                let sample = Self.pixel(pixels, at: (8 + radius * cos(angle), 8 + radius * sin(angle)))
                if sample.alpha > 0.95 {
                    Self.expectColor(sample.color, is: muted, "the unknown ring")
                    sectors.append(true)
                } else if sample.alpha < 0.1 {
                    sectors.append(false)
                }
            }
            let transitions = zip(sectors, sectors.dropFirst() + sectors.prefix(1)).count { $0 != $1 }
            #expect(transitions >= 12, "alternating dashes and gaps at \(size)pt, contrast \(increased)")
        }
    }

    /// The unknown ring's dashes and gaps share its length equally, and
    /// Increase Contrast thickens it as it does the idle ring.
    @Test func theUnknownDashes_splitTheRing_andThickenWithIncreaseContrast() throws {
        for isContrastIncreased in [false, true] {
            let geometry = Geometry(size: 15, isContrastIncreased: isContrastIncreased)
            let width = geometry.ringWidth(.unknown)
            #expect(width == geometry.ringWidth(.idle))
            let dash = geometry.unknownDash
            try #require(dash.count == 2)
            // Drawn with round caps, each dash shows a line's width longer
            // than its pattern, which the gap gives back.
            let shownDash = dash[0] + width
            let shownGap = dash[1] - width
            #expect(abs(shownDash - shownGap) < 0.001)
            let length = CGFloat.pi * (15 - width)
            #expect(abs((dash[0] + dash[1]) * CGFloat(Geometry.unknownDashCount) - length) < 0.001)
        }
        #expect(Geometry(size: 15, isContrastIncreased: false).unknownInk == Tokens.muted)
    }

    /// A folded project heading draws its marks at that compact size: the
    /// face sizes itself, so a frame around a full-size glyph would not.
    @Test(arguments: [SessionRowFact.Glyph.needsAnswer, .stopped, .running])
    func aFoldedHeadingsMarks_drawAtTheCompactSize(glyph: SessionRowFact.Glyph) {
        let face = SidebarProjectHeaderView.mark(glyph).stateGlyph
            .face(isReduceMotionOn: true, contrast: .standard)
        #expect(face.size == WeirLayout.Supervision.stateGlyphCompactSize)
        #expect(!SidebarProjectHeaderView.mark(glyph).stateGlyph.face(isReduceMotionOn: false, contrast: .standard).isTurning)
    }

    /// Increase Contrast widens the idle ring into what was empty, and
    /// draws it in `muted`.
    @Test(arguments: [false, true])
    func increaseContrast_widensAndDeepensTheIdleRing(isDark: Bool) throws {
        let standard = try Self.render(.idle, isDark: isDark)
        let increased = try Self.render(.idle, isDark: isDark, isContrastIncreased: true)
        let inside = (8.0, 2.2)
        #expect(Self.alpha(standard, at: inside) < 0.3)
        Self.expect(increased, at: inside, is: Tokens.muted.value(isDark: isDark), "the widened idle ring")
    }

    // MARK: - Rendering

    private static let scale: CGFloat = 4

    /// `kind` drawn at `size`, four times over.
    private static func render(
        _ kind: StateGlyph.Kind,
        isDark: Bool,
        size: CGFloat = WeirLayout.Supervision.stateGlyphSize,
        isContrastIncreased: Bool = false
    ) throws -> Pixels {
        let face = StateGlyphFace(
            kind: kind,
            size: size,
            isTurning: false,
            isContrastIncreased: isContrastIncreased,
            unreadInk: Tokens.unread.color
        )
        .environment(\.colorScheme, isDark ? .dark : .light)
        let renderer = ImageRenderer(content: face)
        renderer.scale = scale
        return try Pixels(#require(renderer.cgImage), unit: size / 14 * scale)
    }

    /// An image's pixels in sRGB, eight bits a channel, premultiplied.
    struct Pixels {
        let width: Int
        /// One of the square's units, in pixels.
        let unit: CGFloat
        let bytes: [UInt8]

        init(_ image: CGImage, unit: CGFloat) throws {
            width = image.width
            self.unit = unit
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            try #require(drawn)
            self.bytes = bytes
        }

        /// The pixel `x` across and `y` down: its color with the alpha
        /// taken out, and its alpha.
        func at(x: Int, y: Int) -> (color: SRGB, alpha: Double) {
            let offset = (y * width + x) * 4
            let alpha = Double(bytes[offset + 3]) / 255
            func channel(_ index: Int) -> Double {
                alpha > 0 ? Double(bytes[offset + index]) / 255 / alpha : 0
            }
            return (SRGB(red: channel(0), green: channel(1), blue: channel(2)), alpha)
        }
    }

    /// The pixel at a point of the glyph's 16-unit square.
    private static func pixel(_ pixels: Pixels, at point: (Double, Double)) -> (color: SRGB, alpha: Double) {
        pixels.at(
            x: Int(((point.0 - 1) * pixels.unit).rounded(.down)),
            y: Int(((point.1 - 1) * pixels.unit).rounded(.down))
        )
    }

    private static func alpha(_ pixels: Pixels, at point: (Double, Double)) -> Double {
        pixel(pixels, at: point).alpha
    }

    /// A landmark has an opaque interior and the expected ink.
    private static func expect(
        _ pixels: Pixels,
        at point: (Double, Double),
        is expected: SRGB,
        _ what: String
    ) {
        let (color, alpha) = pixel(pixels, at: point)
        #expect(alpha > 0.95, "\(what): alpha \(alpha)")
        Self.expectColor(color, is: expected, what)
    }

    private static func expectColor(_ color: SRGB, is expected: SRGB, _ what: String) {
        #expect(matches(color, expected), "\(what): \(color.hexBytes) for \(expected.hexBytes)")
    }

    private static func matches(_ color: SRGB, _ expected: SRGB) -> Bool {
        abs(color.red - expected.red) < 0.03
            && abs(color.green - expected.green) < 0.03
            && abs(color.blue - expected.blue) < 0.03
    }

    /// The mark's opaque pixels leave a margin inside the 14-unit disc.
    private static func expectMark(_ pixels: Pixels, in ink: SRGB) {
        var farthest: CGFloat = 0
        for y in 0..<pixels.width {
            for x in 0..<pixels.width {
                let sample = pixels.at(x: x, y: y)
                guard sample.alpha > 0.95, Self.matches(sample.color, ink) else { continue }
                let dx = (CGFloat(x) + 0.5) / pixels.unit - 7
                let dy = (CGFloat(y) + 0.5) / pixels.unit - 7
                farthest = max(farthest, hypot(dx, dy))
            }
        }
        #expect(farthest > 0 && farthest < 6.5)
    }
}
