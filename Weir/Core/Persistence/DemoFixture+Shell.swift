// DemoFixture+Shell.swift
// Weir — the shell a demo pane types its scene into, kept apart from the contributor's own.

import Foundation

extension DemoFixture {
    /// The program every demo pane runs in place of the contributor's login
    /// shell. Each scene is a command line typed into the pane
    /// (`DemoFixture.scene`), so the shell that reads it would keep it in its
    /// history: the contributor's own shell writes `~/.zsh_history`, and each
    /// run of the capture scripts typed a dozen scene lines there. A scene is
    /// also written for zsh, which a contributor's fish or bash would not be.
    static let shellCommand = "/bin/zsh"

    /// The bundled startup file `shellCommand` reads instead of the
    /// contributor's: it keeps no history, masks the prompt, and loads
    /// Ghostty's shell integration. Nil when a bundle was built without it.
    static var shellStartupDirectoryURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("demo-shell", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `environment` as a demo pane's shell gets it. `startupDirectory` is
    /// where it reads its startup files; with none, `/var/empty`, which holds
    /// none, so the contributor's are still never read, and the history file
    /// /etc/zshrc names there cannot be written.
    /// `panesReady` is where the capture script waits for each scene.
    static func shellEnvironment(
        over environment: [String: String],
        startupDirectory: URL?,
        panesReady: String
    ) -> [String: String] {
        var env = environment
        env["ZDOTDIR"] = startupDirectory?.path ?? "/var/empty"
        // No history file, even before the startup files run, and none taken
        // over from the environment the app was launched from.
        env["HISTFILE"] = ""
        env["SAVEHIST"] = "0"
        // Keep a real user@host out of the hero screenshot (the startup
        // file sets the prompt). HOST/HOSTNAME are "localhost" rather than a
        // made-up name because the shell integration sends HOST as the host
        // of its OSC 7 working-directory reports, and libghostty drops a
        // report whose host is neither this machine's name nor "localhost"
        // — every demo pane then had no working directory.
        env["USER"] = "demo"
        env["HOSTNAME"] = "localhost"
        env["HOST"] = "localhost"
        // Where the capture script waits for this pane's scene (`DemoFixture.scene`).
        env["WEIR_DEMO_PANES_READY"] = panesReady
        return env
    }
}
