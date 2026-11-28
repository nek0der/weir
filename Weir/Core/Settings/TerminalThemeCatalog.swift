// TerminalThemeCatalog.swift
// Weir — lists the Ghostty theme files Weir can offer and resolves a chosen one to its path.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("settings.theme-catalog")

/// The theme folders Weir reads: its own bundle's, the person's Ghostty
/// themes folder, and an installed Ghostty app's.
///
/// Every folder is injectable so tests list fixture files instead of the
/// real `~/.config`. Nothing here writes.
struct TerminalThemeCatalog: Sendable {
    /// A theme file found in one of the folders.
    struct Entry: Equatable, Sendable {
        var ref: TerminalThemeRef
        /// The file's absolute path. The `theme` line names it only for a
        /// bundled theme; any other reaches libghostty as a color-only copy
        /// (`GhosttyConfigBridge.TerminalThemeSource`).
        var path: String
        /// Whether the theme is light or dark, from its `background` line;
        /// `nil` when the file could not be read or sets no background we
        /// can read. The picker decides where such a theme is listed.
        var brightness: TerminalThemeBrightness?
    }

    /// Weir's bundled themes; `nil` when the resources folder is unknown.
    let bundledDirectory: URL?
    /// The person's Ghostty themes folder.
    let userDirectory: URL?
    /// Installed Ghostty apps' themes folders, in the order a ref resolves.
    let ghosttyDirectories: [URL]

    init(bundledDirectory: URL?, userDirectory: URL?, ghosttyDirectories: [URL]) {
        self.bundledDirectory = bundledDirectory
        self.userDirectory = userDirectory
        self.ghosttyDirectories = ghosttyDirectories
    }

    /// Creates the catalog of the folders a running Weir reads.
    ///
    /// The user folder follows Ghostty's own lookup:
    /// `$XDG_CONFIG_HOME/ghostty/themes`, else `~/.config/ghostty/themes`.
    init(
        resourcesDir: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        let configHome: URL = if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        let appThemes = "Ghostty.app/Contents/Resources/ghostty/themes"
        self.init(
            bundledDirectory: resourcesDir.map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("themes", isDirectory: true)
            },
            userDirectory: configHome.appendingPathComponent("ghostty/themes", isDirectory: true),
            ghosttyDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(appThemes),
                homeDirectory.appendingPathComponent("Applications", isDirectory: true)
                    .appendingPathComponent(appThemes)
            ]
        )
    }

    // MARK: - Listing

    /// Returns every theme in every folder, sorted by name, then by origin
    /// (bundled, user, Ghostty) for themes that share a name. A folder that
    /// is missing or unreadable contributes nothing. A canceled task stops
    /// opening files and gets a partial list, which its caller drops.
    func entries() -> [Entry] {
        TerminalThemeOrigin.allCases.flatMap(entries(origin:)).sorted { lhs, rhs in
            switch lhs.ref.name.localizedStandardCompare(rhs.ref.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: Self.order(lhs.ref.origin) < Self.order(rhs.ref.origin)
            }
        }
    }

    /// Returns the themes of one origin, sorted by name. A name found in more
    /// than one Ghostty app is listed once, from the folder `resolve(_:)`
    /// would pick.
    func entries(origin: TerminalThemeOrigin) -> [Entry] {
        var seen: Set<String> = []
        var result: [Entry] = []
        for directory in directories(for: origin) {
            for (name, url) in Self.themeFiles(in: directory) where seen.insert(name).inserted {
                guard !Task.isCancelled else { return result }
                result.append(Entry(
                    ref: TerminalThemeRef(name: name, origin: origin),
                    path: url.path,
                    brightness: Self.brightness(of: url)
                ))
            }
        }
        return result.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    // MARK: - Resolving

    /// Returns the absolute path of the file `ref` names, or `nil` when the
    /// name cannot be written into a `theme` line, would leave its folder,
    /// or names no regular file.
    ///
    /// Builds one path per candidate folder and checks it; it never lists a
    /// folder, because the config bridge calls it on every settings change.
    func resolve(_ ref: TerminalThemeRef) -> String? {
        guard Self.isUsableName(ref.name) else { return nil }
        for directory in directories(for: ref.origin) {
            let url = directory.appendingPathComponent(ref.name, isDirectory: false)
            if Self.isRegularFile(url) {
                return url.path
            }
        }
        return nil
    }

    /// Whether `name` can stand as a theme file name in a `theme` line.
    ///
    /// A bundled theme's path goes into the `theme` line as it is. The line
    /// quotes a path that holds `,`, `"`, or `\`, or that starts or ends with
    /// a space (`GhosttyConfigBridge.themeLineValue`), but cannot hold a line
    /// break. We refuse all of these in a name rather than rely on the
    /// quoting, so a listed name never needs it. Every other
    /// theme reaches the line as a copy Weir names, but one rule for every
    /// origin keeps a name valid in any folder. A `/` or a `.`/`..` name would
    /// leave the themes folder, and a leading `.` is a hidden file, which the
    /// listing skips too.
    static func isUsableName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return false }
        return !name.contains { "/,\"\\".contains($0) || $0.isNewline }
    }

    /// Reads the theme file at `path` as UTF-8 text, or returns `nil` when
    /// it is not a regular file, cannot be read, is larger than
    /// `TerminalThemeFile.maxBytes`, or is not UTF-8.
    ///
    /// The read itself stops one byte past the limit, so a file that grows
    /// after a size check is still refused rather than read whole.
    static func readThemeText(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard isRegularFile(url),
              let handle = try? FileHandle(forReadingFrom: url.resolvingSymlinksInPath())
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: TerminalThemeFile.maxBytes + 1) else { return nil }
        guard data.count <= TerminalThemeFile.maxBytes else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    // MARK: - Helpers

    private func directories(for origin: TerminalThemeOrigin) -> [URL] {
        switch origin {
        case .bundled: bundledDirectory.map { [$0] } ?? []
        case .user: userDirectory.map { [$0] } ?? []
        case .ghostty: ghosttyDirectories
        }
    }

    private static func order(_ origin: TerminalThemeOrigin) -> Int {
        TerminalThemeOrigin.allCases.firstIndex(of: origin) ?? 0
    }

    /// The usable theme files directly in `directory`, by name.
    private static func themeFiles(in directory: URL) -> [(String, URL)] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            log.error("theme folder unreadable: \(String(describing: error), privacy: .private)")
            return []
        }
        return contents.compactMap { listed in
            // Rebuilt from `directory`, as `resolve(_:)` builds it: the listing
            // can name the folder through another spelling (`/private/var`).
            let name = listed.lastPathComponent
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard isUsableName(name), isRegularFile(url) else { return nil }
            return (name, url)
        }
    }

    /// Whether `url` is, or links to, a regular file. A linked theme counts,
    /// since dotfile managers link the themes folder's files; a FIFO or a
    /// folder does not, as reading one could block or fail.
    private static func isRegularFile(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func brightness(of url: URL) -> TerminalThemeBrightness? {
        guard let text = readThemeText(atPath: url.path),
              let background = TerminalThemeFile.parseBackground(text)
        else { return nil }
        return TerminalThemeBrightness(background: background)
    }
}
