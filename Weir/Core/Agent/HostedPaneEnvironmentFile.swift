// HostedPaneEnvironmentFile.swift
// Weir — removes the pane environments a tmux-hosted launch saved and its session never read.

import Foundation

/// With tmux hosting on, an agent's shim saves its pane's exported variables,
/// the person's secrets among them, to a 0600 file named `weir-hosted-env.*`
/// in a temporary folder only this user can change, and the tmux session's
/// first command reads it back and deletes it within moments
/// (`weir_save_pane_environment` and `weir_hosted_env_reader` in
/// `agent-shim/runtime-common.sh`). A session that never runs, because the
/// server failed to start or the session was killed at once, leaves the file
/// behind. The next hosted launch removes such files, but a person who turns
/// hosting off would keep one for good, so Weir removes them at launch too.
enum HostedPaneEnvironmentFile {
    /// The start of every saved environment's name, as the shim's `mktemp`
    /// template writes it.
    static let namePrefix = "weir-hosted-env."

    /// How old a file must be before it counts as left behind. A session
    /// reads its file within moments of the launch that wrote it, so a
    /// minute is past any launch still under way; the shim's own sweep
    /// uses the same age.
    static let staleAfter: TimeInterval = 60

    /// The folders the shim may have written to: TMPDIR, as a pane inherits
    /// it from Weir, and the folder macOS keeps for this user. A pane whose
    /// shell set TMPDIR to another private folder saves there, and only the
    /// next hosted launch from such a pane sweeps it.
    static var defaultDirectories: [URL] {
        var paths: [String] = []
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"], !temporary.isEmpty {
            paths.append(temporary)
        }
        if let userTemporary = darwinUserTemporaryDirectory() {
            paths.append(userTemporary)
        }
        var seen: Set<String> = []
        return paths
            .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
    }

    /// Deletes every saved environment in `directories` older than
    /// `staleAfter`. Only regular files with the shim's name are touched.
    static func removeOrphans(in directories: [URL] = defaultDirectories, now: Date = Date()) {
        // A test host runs the app's launch too; the user's own folders are
        // not a test's to clean.
        guard !WeirPaths.isRunningInTests || directories != defaultDirectories else { return }
        let fm = FileManager.default
        for directory in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasPrefix(namePrefix) {
                let url = directory.appendingPathComponent(name)
                guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > staleAfter
                else { continue }
                // One that cannot be removed now is tried again at the
                // next launch and by the next hosted launch's sweep.
                try? SecureFileWrite.removeItem(at: url)
            }
        }
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, the folder `getconf
    /// DARWIN_USER_TEMP_DIR` names to the shim; nil when it has none.
    private static func darwinUserTemporaryDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
