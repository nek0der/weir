# ADR 0009: Window colors from the theme

- Status: Accepted.
- Date: 2026-11-27.
- Amends: [ADR 0008](0008-terminal-ground-from-the-theme.md), by letting the
  person give the rest of the window the theme's colors.

## Context

ADR 0008 paints a terminal theme's background under the terminal area and
leaves the rest of the window in its tokens, so the window reads as one app
whichever theme the terminal shows. A person who chose a dark blue or a warm
light theme then sees the terminal area in the theme's colors beside a
header, a sidebar, and panels in Weir's grays.

The tokens (`SupervisionTokens`) were chosen against each other: text
reaches 4.5:1 and marks 3:1 on every surface they are drawn on, and the
tests hold every such pair. More than 450 places draw a token's color, many
outside a view's body.

## Decision

- **The window can take the theme's colors, and does not by default.**
  Settings → Appearance → Terminal Colors has a switch, stored as
  `appearance.terminalTheme.scope = "window"`. Left off, the window keeps
  its tokens, as ADR 0008 decided.
- **The appearance stays primary.** A side takes its theme's colors only
  when the theme's background is of that side's brightness, so a dark theme
  chosen for light appearance colors the terminal area and leaves the window
  light. A side whose background is the bundled default's keeps its tokens.
- **The theme's colors are derived from the tokens.** The window is the
  theme's background and the text its foreground. Each other neutral surface
  keeps its step in CIELAB lightness from the `window` token, in the
  background's hue; each quiet ink sits between the background and the
  foreground where its token sits between `window` and `text`; a state's soft
  fill keeps its own hue at the lightness its token has relative to `window`
  (`WindowColorResolver`). A color sRGB cannot hold at that lightness loses
  saturation, never lightness. A background darker than the deepest step
  below `window` would leave the well and the page no room, so there the
  window stands that far above black, and the terminal area alone keeps
  the background. The state colors and badge edges keep their values unless
  one has to move toward black or white to keep its contrast. The
  Antigravity badge, which has no edge under the tokens, draws one only
  where its blue had to move.
- **Room is made before a theme is refused.** A foreground close to its
  background leaves the quiet ink, moved up to its ratio, too close to the
  text to tell apart, so the text steps away from the window, and the
  faintest ink back toward it, until they read apart.
- **Every contrast the tokens keep is kept, or the side keeps its tokens.**
  The pairs the tests hold the tokens to are one list in the app
  (`TokenContrastRequirements`), and the resolver holds a theme's colors to
  the same list. It also keeps the quiet words apart from the plain ones and
  the states apart from each other by a CIELAB difference of 12, or as far
  as the tokens are. The foreground must be lighter than the background in
  dark and darker in light, and the system's label color must read at 4.5:1
  on the surfaces its controls stand on, since the controls Weir does not
  color itself keep it. A side that cannot keep all of it, or whose surfaces
  would leave the lightness range, keeps every token: a window half in a
  theme's colors and half in the tokens was never checked.
- **The colors reach a view through its environment.** A token's color is a
  `ShapeStyle` (`ThemedStyle`) that resolves the theme's color for its role
  from `\.weirWindowColors` as the view draws, else the token. Both sides are
  held at once, so an appearance switch needs no new value, and an equal
  value set again redraws nothing. Each window's root sets it, and every
  sheet, popover, and hosted view that Weir builds passes it on with the
  accent.
- **Some surfaces keep the tokens whatever the theme.** These are the
  floating panels' material, the menu bar extra, toasts, and images drawn
  for menus. They were checked against the tokens only, and a toast inverts
  the appearance, so it would need the other side's theme.

## Consequences

- With the switch off, every color is the token's, as before.
- With it on, nearly every theme colors the window. Of the 819 themes
  Ghostty 1.3.2-dev ships, all 178 light themes and
  616 of 641 dark ones pass; the rest keep the tokens on their side, and
  Settings names them.
- On a near-black theme the window is a little lighter than the terminal
  area, as the tokens' window is lighter than their terminal.
- The text can be lighter or darker than the theme's own foreground, where
  the foreground stands too close to the background for a quieter ink to
  read apart from it.
- AppKit views that draw tokens keep the tokens' own colors, except review's
  rows, which take the theme's text, quiet ink, and fills. Their colors read
  the theme in use as they draw, so a pooled row draws a new theme without
  being configured again.
- The Settings window, drawn in the system's form colors, and the image of
  a dragged pane keep their own colors.
- A pair of tokens drawn together that no requirement lists is not checked
  under a theme. A new pair belongs in `TokenContrastRequirements`.

## Alternatives considered

- **Swapping the tokens' static values for the theme's.** The tokens are
  not isolated to the main actor and are read while drawing, so changing
  them in place would race with the views that read them.
- **Taking the theme's colors where they pass and the tokens elsewhere.**
  The tokens were chosen against each other, so a window half in a theme's
  colors and half in the tokens holds pairs nobody checked.
- **Switching the appearance to the theme's brightness.** The appearance is
  the person's choice in Settings → Appearance, and ADR 0008 keeps it
  primary; a dark theme chosen for light appearance would otherwise turn
  the window dark.
- **Turning it on by default.** Everyone who picked a terminal theme would
  find the whole window changed, where ADR 0008 kept the rest of the window
  in its tokens so that the window reads as one app.
