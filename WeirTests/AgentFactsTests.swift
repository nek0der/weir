// AgentFactsTests.swift
// Weir — each agent's names, commands, home, badge, and shell quoting, each read from its one owner, as they were.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Agent facts")
struct AgentFactsTests {
    private static let sessionID = "0b3f2c1e-aaaa-4bbb-8ccc-1234567890ab"

    // MARK: - Names

    /// A row's spoken name is the catalog's short name, and differs from the
    /// descriptor's full name only for Claude ("Claude Code"), as before.
    @Test("a row names each agent by the catalog's short name", arguments: AgentKind.allCases)
    func rowName_isTheCatalogsShortName(kind: AgentKind) {
        let rowName = SessionRowFactText.agentName(.agent(kind), locale: .english)
        let expected = switch kind {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        }
        #expect(rowName == expected)
        #expect(rowName == AgentCatalog.entry(for: kind).displayName)
        #expect(SessionRowFactText.agentName(.agent(kind), locale: Locale(identifier: "ja")) == rowName)
        #expect((rowName != AgentProviderRegistry.displayName(for: kind)) == (kind == .claude))
    }

    // MARK: - Commands

    /// The strings each command typed before its launch name came from
    /// `launchCommand`, captured from that code.
    @Test("the launch, resume, and new conversation commands are the ones typed before", arguments: AgentKind.allCases)
    func commands_areTheOnesTypedBefore(kind: AgentKind) {
        let (launch, resume) = switch kind {
        case .claude: ("claude", "claude --resume \(Self.sessionID)")
        case .codex: ("codex", "codex resume \(Self.sessionID)")
        case .antigravity: ("agy", "agy --conversation \(Self.sessionID)")
        case .opencode: ("opencode", "opencode --session \(Self.sessionID)")
        }
        #expect(kind.launchCommand == launch)
        #expect(kind.strictResumeArguments(sessionId: Self.sessionID) == resume)
        let folder = "/Users/foo/Weir Dev/bar's repo"
        let cd = "cd '/Users/foo/Weir Dev/bar'\\''s repo' && "
        for cwd in [nil, ""] as [String?] {
            #expect(kind.strictResumeCommand(sessionId: Self.sessionID, cwd: cwd) == resume)
            #expect(kind.newConversationCommand(cwd: cwd) == launch)
        }
        #expect(kind.strictResumeCommand(sessionId: Self.sessionID, cwd: "/tmp/repo") == "cd '/tmp/repo' && \(resume)")
        #expect(kind.newConversationCommand(cwd: "/tmp/repo") == "cd '/tmp/repo' && \(launch)")
        #expect(kind.strictResumeCommand(sessionId: Self.sessionID, cwd: folder) == cd + resume)
        #expect(kind.newConversationCommand(cwd: folder) == cd + launch)
        #expect(kind.strictResumeCommand(sessionId: Self.sessionID, cwd: "/tmp/a\nb") == nil)
        #expect(kind.newConversationCommand(cwd: "/tmp/a\nb") == nil)
        #expect(kind.strictResumeCommand(sessionId: "-r", cwd: "/tmp") == nil)
    }

    /// Every name the catalog looks the agent up by is the one it was looked
    /// up by before, at the places it was looked for before.
    @Test("the catalog looks each agent up where it did", arguments: AgentKind.allCases)
    func catalog_looksEachAgentUpWhereItDid(kind: AgentKind) {
        let name = switch kind {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        case .opencode: "opencode"
        }
        let folders = switch kind {
        case .claude: ["~/.claude/local", "~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        case .codex, .antigravity: ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]
        case .opencode: ["/opt/homebrew/bin", "/usr/local/bin", "~/.opencode/bin", "~/.local/bin"]
        }
        let managers = [
            "~/.nvm/versions/node/*/bin/\(name)",
            "~/.local/share/mise/shims/\(name)",
            "~/.asdf/shims/\(name)",
            "~/.volta/bin/\(name)",
            "~/.bun/bin/\(name)",
            "~/Library/pnpm/\(name)"
        ]
        let entry = AgentCatalog.entry(for: kind)
        #expect(entry.executables == [name])
        #expect(entry.knownLocations == folders.map { "\($0)/\(name)" } + managers)
    }

    // MARK: - Homes

    @Test("each agent's default home is its id behind a dot in the home folder", arguments: AgentKind.allCases)
    func defaultHome_isTheDottedID(kind: AgentKind) {
        let expected = switch kind {
        case .claude: "/Users/someone/.claude"
        case .codex: "/Users/someone/.codex"
        case .antigravity: "/Users/someone/.antigravity"
        case .opencode: "/Users/someone/.opencode"
        }
        #expect(AgentProviderRegistry.defaultHome(of: kind.rawValue, under: "/Users/someone") == expected)
        let url = AgentProviderRegistry.defaultHome(of: kind, under: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        #expect(url.path == expected)
        #expect(url.hasDirectoryPath)
        #expect(kind.homeFolderName == "." + kind.rawValue)
        #expect(AgentKind.homeFolderName(ofProvider: kind.rawValue) == kind.homeFolderName)
    }

    /// Worktree admission finds Codex's own worktrees under the same home
    /// folder name, still under the home folder and not `CODEX_HOME`.
    @Test("worktree admission reads Codex's worktrees under its default home")
    func worktreeAdmission_readsTheDefaultCodexHome() {
        func facts(_ path: String) -> WorktreeAdmissionRule.Facts {
            WorktreeAdmissionRule.Facts(path: path, homePath: "/Users/someone")
        }
        #expect(WorktreeAdmissionRule.isAgentPlaced(facts("/Users/someone/.codex/worktrees/abc/repo")))
        #expect(!WorktreeAdmissionRule.isAgentPlaced(facts("/Users/someone/.codex/worktrees")))
        #expect(!WorktreeAdmissionRule.isAgentPlaced(facts("/Users/someone/elsewhere/repo")))
    }

    /// The guard protects the Codex home the installer cleans, under each
    /// home it knows.
    @Test("the test write guard protects the same Codex home the installer cleans")
    func writeGuard_protectsTheDefaultCodexHome() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #expect(TestWriteGuard.protectedRoots.contains(AgentProviderRegistry.defaultHome(of: .codex, under: home)))
    }

    // MARK: - The shim's record export

    /// Only an agent whose recipe carries its hook's own arguments leaves the
    /// record directories to its installer: Codex, as the switch had it.
    @Test("the record directories are left to the installer exactly where the recipe has hook arguments", arguments: AgentKind.allCases)
    func recordExport_followsTheRecipe(kind: AgentKind) {
        let locator = AgentShimLocator(kind)
        #expect(locator.exportsRecordDirectories == (kind != .codex))
        #expect(locator.exportsRecordDirectories == (AgentProviderRegistry.hookArgumentsVariable(for: kind.rawValue) == nil))
        #expect(locator.exportsRecordsWithoutShim == (kind == .claude))
        #expect((locator.shimDirectoryVariable == "WEIR_SHIM_DIR") == (kind == .claude))
    }

    /// With no recipe to read, each agent keeps the answer the switch gave;
    /// with one, the recipe decides, whichever agent it is for.
    @Test("without a recipe each agent keeps the record export it had", arguments: AgentKind.allCases)
    func recordExport_withoutARecipeIsTheOldAnswer(kind: AgentKind) {
        #expect(AgentShimLocator.exportsRecordDirectories(kind, recipe: nil) == (kind != .codex))
        let withArguments = AgentInstallRecipe(environment: [.init(name: "WEIR_X_HOOK_ARGS", value: .hookArguments)])
        let withoutArguments = AgentInstallRecipe(environment: [.init(name: "WEIR_X_STATE_DIR", value: .stateDirectory)])
        #expect(!AgentShimLocator.exportsRecordDirectories(kind, recipe: withArguments))
        #expect(AgentShimLocator.exportsRecordDirectories(kind, recipe: withoutArguments))
        #expect(AgentShimLocator.exportsRecordDirectories(kind, recipe: AgentInstallRecipe()))
    }

    // MARK: - Badge

    @Test("each agent's badge has the letters, fill, ink, and edge it had", arguments: AgentKind.allCases)
    func brand_isTheBadgeItHad(kind: AgentKind) {
        let brand = AgentBrand.of(kind)
        let expected = switch kind {
        case .claude:
            AgentBrand(
                letters: "Cl",
                fill: .solid(SupervisionTokens.claude),
                foreground: SupervisionTokens.badgeForeground,
                edge: SupervisionTokens.claudeEdge
            )
        case .codex:
            AgentBrand(
                letters: "Cx",
                fill: .solid(SupervisionTokens.codex),
                foreground: SupervisionTokens.codexBadgeForeground,
                edge: SupervisionTokens.codexEdge
            )
        case .antigravity:
            AgentBrand(letters: "Ag", fill: .antigravityMesh, foreground: SupervisionTokens.badgeForeground, edge: nil)
        case .opencode:
            AgentBrand(
                letters: "Op",
                fill: .solid(SupervisionTokens.opencode),
                foreground: SupervisionTokens.badgeForeground,
                edge: SupervisionTokens.opencodeEdge
            )
        }
        #expect(brand == expected)
        #expect(SessionRowFactText.badge(.agent(kind), locale: .english) == brand.letters)
        #expect(SessionRowFactText.badge(.agent(kind), locale: Locale(identifier: "ja")) == brand.letters)
    }

    @Test("no two agents share a badge's letters")
    func brand_lettersAreDistinct() {
        let letters = AgentKind.allCases.map { AgentBrand.of($0).letters }
        #expect(Set(letters).count == letters.count)
        #expect(SessionRowFactText.badge(.shell, locale: .english).isEmpty)
    }

    // MARK: - Shell quoting

    /// Every caller's single quote is `ShellQuote.single`: the same word for
    /// the same value, wherever it is typed.
    @Test("one single quote for every caller", arguments: ["/tmp/repo", "/Users/foo/Weir Dev/bar's repo", "", "'", "a'b'c"])
    func shellQuote_isOneForm(value: String) {
        let quoted = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        #expect(ShellQuote.single(value) == quoted)
        #expect(CodexHookInstaller.executableCommand(for: URL(fileURLWithPath: "/Applications/x y'z")) == "'/Applications/x y'\\''z'")
        #expect(DemoFixture.scene([], prompt: "p", end: .prompt, title: value).contains("printf '\\033]2;%s\\007' \(quoted)"))
    }

    // MARK: - Typed control characters

    /// One rule for what may not be typed into a terminal, whichever text
    /// holds it: C0, DEL, and C1, and nothing else.
    @Test(
        "text holds a typed control exactly when one of its scalars is C0, DEL, or C1",
        arguments: [
            ("", false), ("/tmp/repo", false), ("é 日本", false), ("\u{A0}", false), ("\u{1F}", true),
            ("a\nb", true), ("\t", true), ("\u{7F}", true), ("\u{80}", true), ("\u{9F}", true), ("x\u{1B}[200~", true)
        ]
    )
    func containsTypedControl_isAnyScalarsRule(text: String, isControl: Bool) {
        #expect(text.containsTypedControl == isControl)
        #expect(text.containsTypedControl == text.unicodeScalars.contains(where: \.isTypedControl))
        #expect(text[...].containsTypedControl == isControl)
        // Every caller refuses, or types, the same text.
        #expect((AgentKind.claude.newConversationCommand(cwd: "/tmp/\(text)") == nil) == isControl)
    }

    @Test("ShellQuote escapes an embedded quote by closing, escaping, and reopening")
    func shellQuote_goldens() {
        #expect(ShellQuote.single("plain") == "'plain'")
        #expect(ShellQuote.single("it's") == "'it'\\''s'")
        #expect(ShellQuote.single("") == "''")
    }
}
