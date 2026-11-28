// TerminalGround.swift
// Weir — the ground Weir paints under the terminal area, and the colors of the marks drawn on it.

import Foundation
import WeirDomain

/// What a view drawn on the terminal area needs from the terminal theme for
/// one appearance: the ground to paint, if any, and the colors the marks on
/// it take.
///
/// `TerminalThemeStore.ground(for:tokens:)` makes one; views read its values
/// and do no color math. A `nil` color means "keep the token": the ground is
/// not painted, or the token already stands out against it, or no step
/// toward black or white makes it do so.
struct TerminalGround: Equatable {
    /// The token colors a ground corrects, for the current appearance.
    struct Tokens: Equatable {
        var waiting: RGB8
        var stopped: RGB8
        var accent: RGB8
    }

    /// What the painted ground is laid over, so a mark is checked against
    /// the color the person sees as well as the ground's own.
    ///
    /// The ground is drawn at the surface's opacity, and a pane without
    /// focus fades its terminal, ground included, to the unfocused pane
    /// opacity; the frame and the ring above it do not fade. What shows
    /// through is the surface token under the pane. Below a surface opacity
    /// of 1 the wallpaper shows through both, which we cannot read, so we
    /// take the surface token as what lies under the ground there too.
    struct Backdrop: Equatable {
        /// The surface token under the pane (`SupervisionTokens.window`).
        var surface: RGB8
        /// The surface's opacity (`supervisionSurfaceOpacity`).
        var surfaceOpacity: Double
        /// Appearance → Unfocused pane opacity.
        var unfocusedPaneOpacity: Double

        /// The colors a mark on `ground` is seen against: the ground
        /// itself, and the ground over the surface in a focused pane and
        /// in one without focus.
        func grounds(for ground: RGB8) -> [RGB8] {
            let focused = ground.composited(over: surface, opacity: surfaceOpacity)
            let unfocused = ground.composited(over: surface, opacity: surfaceOpacity * unfocusedPaneOpacity)
            var result = [ground]
            for color in [focused, unfocused] where !result.contains(color) {
                result.append(color)
            }
            return result
        }
    }

    /// How the terminal's scroller knob is drawn. Ours rather than AppKit's,
    /// so this value stays free of AppKit.
    enum KnobStyle: Equatable {
        /// AppKit's own choice, from the window's appearance.
        case automatic
        /// A light knob, for a dark ground.
        case light
        /// A dark knob, for a light ground.
        case dark
    }

    /// The contrast a mark needs against the ground: what WCAG asks of a
    /// graphical object.
    static let markContrast = 3.0

    /// What a side whose theme paints nothing gets: every token as it is.
    static let unpainted = TerminalGround(ground: nil, waiting: nil, stopped: nil, accent: nil, knobStyle: .automatic)

    /// The color to paint under the terminal area; `nil` paints nothing.
    var ground: RGB8?
    /// The pane attention frame's color while the agent waits.
    var waiting: RGB8?
    /// The pane attention frame's color once the agent stopped.
    var stopped: RGB8?
    /// The accent of a mark drawn over the terminal area (a drop target's
    /// ring).
    var accent: RGB8?
    var knobStyle: KnobStyle

    /// Resolves every value for `ground`. A `nil` ground is `unpainted`.
    /// With `backdrop`, a mark reaches `markContrast` against every color
    /// `Backdrop.grounds(for:)` lists; without it, against `ground` alone.
    static func resolve(ground: RGB8?, tokens: Tokens, backdrop: Backdrop? = nil) -> TerminalGround {
        guard let ground else { return .unpainted }
        let grounds = backdrop?.grounds(for: ground) ?? [ground]
        func corrected(_ token: RGB8) -> RGB8? {
            let result = OnGroundColor.resolve(token, on: grounds, ratio: markContrast)
            return result.isReached && result.color != token ? result.color : nil
        }
        return TerminalGround(
            ground: ground,
            waiting: corrected(tokens.waiting),
            stopped: corrected(tokens.stopped),
            accent: corrected(tokens.accent),
            knobStyle: knobStyle(on: ground)
        )
    }

    /// The knob for `ground`: dark where black stands out against it more
    /// than white does, else light; AppKit's own when nothing is painted.
    /// Chosen by contrast rather than by `TerminalThemeBrightness`, whose
    /// line sits at a luminance of 0.5: a ground somewhat below it, such as
    /// `#bbbbbb`, already shows a dark knob better. The one rule both the
    /// panes and the quick terminal follow.
    static func knobStyle(on ground: RGB8?) -> KnobStyle {
        guard let ground else { return .automatic }
        let black = RGB8(r: 0, g: 0, b: 0)
        let white = RGB8(r: 255, g: 255, b: 255)
        return ground.contrast(with: black) > ground.contrast(with: white) ? .dark : .light
    }
}

extension TerminalThemeStore {
    /// The background to paint under the terminal area on `side`, or `nil`
    /// when the theme there is the bundled default's (`paintsGround(for:)`)
    /// or has not been read.
    func paintedGround(for side: TerminalThemeBrightness) -> RGB8? {
        guard paintsGround(for: side) else { return nil }
        return palette(for: side)?.background
    }

    /// The ground and the corrected marks for `side`.
    func ground(
        for side: TerminalThemeBrightness,
        tokens: TerminalGround.Tokens,
        backdrop: TerminalGround.Backdrop? = nil
    ) -> TerminalGround {
        TerminalGround.resolve(ground: paintedGround(for: side), tokens: tokens, backdrop: backdrop)
    }
}
