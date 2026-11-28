// TerminalColorsSection.swift
// Weir — the Settings → Appearance section that picks the terminal theme for light and for dark.

import SwiftUI
import WeirDomain

/// Two pickers, one per appearance. The appearance picker above decides
/// which side shows; these decide what each side looks like.
struct TerminalColorsSection: View {
    @Environment(SettingsStore.self) private var store
    @Environment(TerminalThemeStore.self) private var terminalTheme
    @Environment(\.controlActiveState) private var controlActiveState
    /// The themes in every folder; `nil` until the folders were first read,
    /// so a chosen theme is not called missing before then.
    @State private var entries: [TerminalThemeCatalog.Entry]?

    /// How many times the window has become key while the pane was shown.
    @State private var keyCount = 0

    /// What makes the folders read again. A theme file can be added while
    /// the pane is shown, from a pane's shell or from another app, and the
    /// terminal finds it on its next reload; a list read only on appear
    /// would then call the chosen theme missing. So the folders are read
    /// again whenever a choice changes and whenever the window becomes key,
    /// which is when the person comes back from adding a file. Losing key
    /// reads nothing.
    private struct CatalogReadTrigger: Equatable {
        var light: TerminalThemeRef?
        var dark: TerminalThemeRef?
        var keyCount: Int
    }

    var body: some View {
        Section {
            picker(
                "Light theme",
                side: .light,
                searchID: SettingsSearchCatalog.terminalThemeLight.id
            )
            // On a row rather than the section, as `FileApplicationSection`
            // loads its list: a row is a view the form shows.
            .task(id: catalogReadTrigger) {
                await loadEntries()
            }
            .onChange(of: controlActiveState) { _, state in
                if state == .key {
                    keyCount += 1
                }
            }
            picker(
                "Dark theme",
                side: .dark,
                searchID: SettingsSearchCatalog.terminalThemeDark.id
            )
            SettingsToggle(
                "Color the window with the theme",
                isOn: Binding(
                    get: { store.settings.appearance.terminalTheme.scope == .window },
                    set: { store.settings.appearance.terminalTheme.scope = $0 ? .window : .terminal }
                )
            )
            .settingsSearchTarget(SettingsSearchCatalog.terminalThemeWindow.id)
        } header: {
            Text("Terminal Colors")
        } footer: {
            VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceXS) {
                if let missingNames {
                    SettingsFootnote("Weir couldn’t use the terminal theme “\(missingNames)”, so it uses the default.")
                }
                if let unfollowedNames {
                    SettingsFootnote(
                        "The window keeps its own colors for “\(unfollowedNames)”: its colors can’t keep every text and mark readable."
                    )
                }
                SettingsFootnote("Themes are read from \(Self.userFolder) and from Ghostty.app.")
            }
        }
    }

    /// The user theme folder as Ghostty finds it, `$XDG_CONFIG_HOME` included,
    /// written with `~` for the home folder.
    private static var userFolder: String {
        let folder = TerminalThemeCatalog(resourcesDir: nil).userDirectory?.path ?? "~/.config/ghostty/themes"
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    private func picker(
        _ title: LocalizedStringKey,
        side: TerminalThemeBrightness,
        searchID: String
    ) -> some View {
        let selected = store.settings.appearance.terminalTheme.ref(for: side)
        return Picker(title, selection: Binding<TerminalThemeRef?>(
            get: { TerminalThemeChoices.tag(for: selected, side: side) },
            set: { store.settings.appearance.terminalTheme.choose($0, for: side) }
        )) {
            SettingsDefaultMark.title(Text(verbatim: GhosttyConfigBridge.defaultThemeRef(for: side).name), isDefault: true)
                .tag(TerminalThemeRef?.none)
            ForEach(TerminalThemeChoices.choices(entries: entries, side: side, selected: selected)) { choice in
                label(for: choice)
                    .tag(TerminalThemeRef?.some(choice.ref))
            }
        }
        .accessibilityLabel(Text(title))
        .settingsSearchTarget(searchID)
    }

    private func label(for choice: TerminalThemeChoice) -> Text {
        let name = choice.ref.name
        switch choice.kind {
        case .theme(isNameShared: false):
            return Text(verbatim: name)
        case .theme(isNameShared: true):
            return Text("\(name) (\(Self.folderName(choice.ref.origin)))")
        case .missing:
            return Text("\(name) (Missing)")
        }
    }

    /// The folder a theme of `origin` is read from, as the footnote names
    /// it; only shown beside a name two folders share.
    private static func folderName(_ origin: TerminalThemeOrigin) -> String {
        switch origin {
        case .bundled: "Weir"
        case .user: userFolder
        case .ghostty: "Ghostty.app"
        }
    }

    /// The names of the current choices that the last config build could
    /// not find, or `nil` when every choice was found. A side counts only
    /// while its choice is still the one that went missing, so a new pick
    /// clears the note before the reload that confirms it.
    private var missingNames: String? {
        let selection = store.settings.appearance.terminalTheme
        let names = terminalTheme.fallbacks.compactMap { side, ref -> String? in
            guard let current = selection.ref(for: side), TerminalThemeChoices.isSame(current, ref) else { return nil }
            return ref.name
        }
        guard !names.isEmpty else { return nil }
        return Set(names).sorted().joined(separator: ", ")
    }

    /// The chosen themes the window could not take its colors from, while
    /// it is set to: a theme whose background is the side's brightness and
    /// differs from the default's, yet gave the window nothing
    /// (`WindowColorResolver`). A theme of the other brightness is left out:
    /// the appearance decides, and the picker already says which side it is.
    private var unfollowedNames: String? {
        let selection = store.settings.appearance.terminalTheme
        guard selection.scope == .window else { return nil }
        let names = [TerminalThemeBrightness.light, .dark].compactMap { side -> String? in
            guard let ref = selection.ref(for: side), terminalTheme.paintsGround(for: side),
                  let palette = terminalTheme.palette(for: side),
                  TerminalThemeBrightness(background: palette.background) == side
            else { return nil }
            let colors = side == .dark ? terminalTheme.windowColors.dark : terminalTheme.windowColors.light
            return colors.isEmpty ? ref.name : nil
        }
        guard !names.isEmpty else { return nil }
        return Set(names).sorted().joined(separator: ", ")
    }

    private var catalogReadTrigger: CatalogReadTrigger {
        let selection = store.settings.appearance.terminalTheme
        return CatalogReadTrigger(light: selection.light, dark: selection.dark, keyCount: keyCount)
    }

    /// Reads every theme folder off the main actor: a Ghostty app holds a
    /// few hundred themes, and each file is opened to read its background.
    /// The previous list stays shown until the new one is read, so a read
    /// again does not blank the pickers. A read the trigger replaced is
    /// canceled: it stops opening files, and what it read is dropped
    /// rather than written over a newer list.
    private func loadEntries() async {
        let catalog = TerminalThemeCatalog(resourcesDir: GhosttyApp.resolveResourcesDir())
        let read = Task.detached(priority: .userInitiated) {
            catalog.entries()
        }
        let result = await withTaskCancellationHandler {
            await read.value
        } onCancel: {
            read.cancel()
        }
        guard !Task.isCancelled else { return }
        entries = result
    }
}
