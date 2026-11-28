# ADR 0008: Terminal ground from the theme

- Status: Accepted.
- Date: 2026-11-27.
- Amended by: [ADR 0009](0009-window-colors-from-the-theme.md), which lets
  the person give the rest of the window the theme's colors.

## Context

Weir passes `background-opacity = 0` to libghostty as a forced override, so
the terminal's cells are transparent and the window's own surfaces show
through them. That keeps the window translucent and its tokens consistent,
but it means a terminal theme colors only the text and the ANSI palette.
Weir's bundled pair (`Apple System Colors Light` and `Apple System Colors`)
has a background close to the window's light and dark tokens, so its text
reads on them.

Settings → Appearance now lets the person choose a theme for each
appearance from Weir's bundle, `~/.config/ghostty/themes`, or an installed
Ghostty app. With the cells transparent, a dark theme's light text sat on
the light token ground, and a light theme's dark text on the dark one. The
theme's background, which its text was made for, was never drawn.

Review colored code with fixed system colors (keywords pink, strings red,
numbers orange, comments gray), so a chosen theme changed the terminal's
colors and left the code in review as it was.

libghostty resolves a `light:…,dark:…` theme pair only for the side it
finalizes, so reading one config does not give both sides' colors.

libghostty also loads a theme file as a config file. A theme can set any
key, including `command` and `initial-command`, so a theme file from a
folder Weir does not control could change what a new pane runs.

## Decision

- **Weir paints the theme's background under the terminal area only.** The
  ground is drawn under each pane's terminal (`PaneContainerView`) and under
  the quick terminal, at the surface's opacity, so translucency and Reduce
  Transparency behave as before. The pane header, the pane strip, the
  sidebar, review, and the other panels keep their tokens, so the window
  reads as one app whichever theme the terminal shows. The cells stay
  transparent, and the forced override with them.
- **The appearance stays primary.** Settings → Appearance (Follow System,
  Light, Dark) picks the side, and the side picks the theme. A pane shows
  the light theme's ground in light appearance and the dark theme's in
  dark. The theme does not switch the window's appearance.
- **Only color keys from a theme reach libghostty.** Weir names a theme it
  ships by its path in the bundle. For a theme from any other folder, Weir
  reads the file when it builds the config (UTF-8, at most 64 KiB), keeps
  only `palette`, `background`, `foreground`, `cursor-color`,
  `cursor-text`, `selection-background`, `selection-foreground`, and
  `bold-color` lines whose values it can check (a `#rrggbb` color, a
  palette index from 0 to 255, and the literal values Ghostty accepts for
  those keys), writes them in one form to a copy of its own, and names that
  copy in the `theme` line
  (`GhosttyConfigBridge.TerminalThemeSource`). A theme's job is its colors,
  and this keeps a theme from setting anything else. A file that cannot be
  read, is larger than that, or sets no `background` Weir can read falls
  back to the bundled default for that side, and Weir reports it as it
  reports a missing file.
- **A copy's name is its content.** A copy is named
  `ghostty-theme-<pid>-<side>-<hash>.weir`, where the hash is the first 16
  hex digits of the SHA-256 of its colors, and is written only when no file
  has that name. libghostty opens the copy again on an appearance switch, so
  a name that held new colors while the running config still named it would
  give the terminal the new colors under the old ground if the reload then
  failed. With content names, a path never changes what it holds, and the
  `theme` line changes whenever the colors do.
- **Both sides are read back from libghostty.** Weir builds one probe config
  per side, whose theme line names that side's file for both, and reads its
  `background`, `foreground`, and palette
  (`GhosttyConfigBridge.readBackPalettes`).
  The probes name the files the written config names, the copies included,
  so the painted ground and the terminal's colors come from one reading of
  the theme file.
  The probes load the person's Ghostty config first when Weir does, so a
  `background` set there wins as it does in the terminal. Reading what
  libghostty resolved, rather than parsing theme files, keeps the ground
  equal to what the terminal uses.
- **The bundled pair paints nothing.** When a side's read-back background
  equals the bundled default's, no ground is drawn, so the default look is
  unchanged from builds before the setting existed.
- **Marks on the ground are corrected against it.** The pane attention frame
  and the drop target ring move toward black or white until they reach 3:1
  against a painted ground and against that ground laid over the surface
  token at the surface's opacity, with and without the unfocused pane
  opacity (`OnGroundColor`, `TerminalGround.Backdrop`). The frame and the
  ring do not fade with a pane, but the ground under them does, and a mix
  of two colors can be darker or lighter than both, so the mix is checked
  itself. Where no color reaches 3:1 against every ground checked, the mark
  keeps its token color. Below a surface opacity of 1 the wallpaper also
  shows through, which Weir cannot read, so the surface token stands in for
  it. The scroller knob is dark where black contrasts the ground more than
  white, else light. Nothing is corrected while nothing is painted.
- **The ground follows the theme only.** A background a program sets for
  its pane with OSC 11 does not change it.
- **Review takes its syntax colors from the theme's ANSI colors.** Keywords
  take ANSI 5 (magenta), strings 1 (red), numbers 3 (yellow), and comments
  8 (bright black), which keeps the hues review drew before and keeps
  comments gray, so a comment on an added line is not green on green
  (`SyntaxRole`). Review's surfaces keep their tokens, so each color is
  corrected toward black or white until it reaches 3:1 against the surface,
  the added and removed line fills over it, and the selected line's fill,
  on each appearance (`SyntaxColors`). The fill under changed characters
  is not among them: it covers a few characters, and holding the colors to
  it as well washed many themes' hues out. The theme colors all four kinds
  or none: when one color reaches 3:1 at no step, or two of the four, or
  one and the plain text, are closer than a CIELAB difference of 12, review
  keeps its system colors. When a side's ANSI colors equal the bundled
  default's, review keeps its system colors on that side too, so the
  default look is unchanged. Review holds both sides in one dynamic color,
  so an appearance switch needs no reload; a theme change reloads the
  table's rows, as an accent change does.

## Consequences

- A chosen theme's text stands on the theme's own background, with the
  contrast the theme was made for.
- The terminal area can differ in color from the header above it and the
  panels beside it. That boundary is intended: it marks where the theme
  applies.
- Each config reload builds two probe configs, one per side, and the launch
  two more for the bundled pair. Each writes a one-line file to the
  temporary folder and removes it once read.
- A chosen theme outside the bundle is read on each settings change, to
  tell whether the terminal configuration changed, and again when the
  config is written. Its copies are kept in a `terminal-themes` folder
  under Application Support, not in the temporary folder with the
  generated config: libghostty opens a copy again on every appearance
  switch, and macOS removes files in the temporary folder that have gone
  unused for days. Once a new config is in use, at launch or after a
  reload, Weir removes the copies of its own process that the config no
  longer names and the copies of processes that have exited. A failed
  reload removes nothing, and a running process's copies are never
  removed.
- An edit to a theme file reaches the terminal when the config is next
  built, not when the appearance switches. Any settings change starts that
  build once the file's colors differ from the copy.
- A theme line Weir drops, such as a 3-digit color, a color name, or a key
  outside the list, has no effect, even where Ghostty itself would accept
  it.
- Most themes color review: of the 819 themes Ghostty 1.3.2-dev ships, 163
  of 178 light themes and 493 of 641 dark ones pass
  the checks above. The rest keep the system colors, as does a theme whose
  colors are not distinct enough on Weir's surfaces.
- A syntax color can differ from the same ANSI color in the terminal,
  because review's surfaces are not the theme's background.
- Review follows the ANSI colors libghostty resolved, so with Advanced →
  Ghostty config on, palette lines in the person's Ghostty config color
  review too, as a `background` there paints the ground, even with the
  bundled pair chosen.

## Alternatives considered

- **Opaque cells, with the theme's background drawn by libghostty.**
  Dropping `background-opacity = 0` would draw the theme's background, but
  the forced override is what keeps the compositor path working. Painting
  under the transparent cells gives the same color and keeps it.
- **The theme's colors over the whole window.** The header, the sidebar,
  and the panels were chosen against the tokens, not against a theme's
  background, so taking the theme's colors there needs every contrast
  checked again. ADR 0009 does that, as a choice the person turns on.
- **Reading the background from the theme file.** Weir would have to
  evaluate the file as libghostty does, the person's Ghostty config
  included. Reading back what libghostty resolved keeps the ground equal to
  what the terminal uses.
- **Naming a third-party theme file by its own path.** libghostty would load
  every key in it, `command` and `initial-command` included, so a theme
  could change what a new pane runs.
- **One copy per side under a fixed name.** libghostty opens the copy again
  on an appearance switch, so new colors written under that name before a
  reload that then failed would give the terminal colors its ground does
  not match.
