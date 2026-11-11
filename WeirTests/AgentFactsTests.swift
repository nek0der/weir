// AgentFactsTests.swift
// Weir — each agent's names, commands, home, badge, and shell quoting, each read from its one owner, as they were.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Agent facts")
struct AgentFactsTests {

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
        case .kiro: "Kiro"
        }
        #expect(rowName == expected)
        #expect(rowName == AgentCatalog.entry(for: kind).displayName)
        #expect(SessionRowFactText.agentName(.agent(kind), locale: Locale(identifier: "ja")) == rowName)
        #expect((rowName != AgentProviderRegistry.displayName(for: kind)) == (kind == .claude))
    }

    // MARK: - Commands

    @Test("launch and new conversation commands use each agent's executable", arguments: AgentKind.allCases)
    func commands_useTheAgentsExecutable(kind: AgentKind) {
        let launch = switch kind {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        case .opencode: "opencode"
        case .kiro: "kiro-cli"
        }
        // Kiro's hooks load only under its v3 engine, which a person who
        // used Kiro 2 may not have chosen yet, so a conversation Weir starts
        // asks for it.
        let start = kind == .kiro ? "kiro-cli --v3" : launch
        #expect(kind.launchCommand == launch)
        #expect(kind.startCommand == start)
        for cwd in [nil, ""] as [String?] {
            #expect(kind.newConversationCommand(cwd: cwd) == start)
        }
        #expect(kind.newConversationCommand(cwd: "/tmp/repo") == "cd '/tmp/repo' && \(start)")
        #expect(kind.newConversationCommand(cwd: "/Users/foo/Weir Dev/bar's repo")
            == "cd '/Users/foo/Weir Dev/bar'\\''s repo' && \(start)")
        #expect(kind.newConversationCommand(cwd: "/tmp/a\nb") == nil)
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
        case .kiro: "kiro-cli"
        }
        let folders = switch kind {
        case .claude: ["~/.claude/local", "~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        case .codex, .antigravity: ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]
        case .opencode: ["/opt/homebrew/bin", "/usr/local/bin", "~/.opencode/bin", "~/.local/bin"]
        case .kiro: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
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
        case .kiro: "/Users/someone/.kiro"
        }
        #expect(AgentProviderRegistry.defaultHome(of: kind.rawValue, under: "/Users/someone") == expected)
        let url = AgentProviderRegistry.defaultHome(of: kind, under: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        #expect(url.path == expected)
        #expect(url.hasDirectoryPath)
        #expect(kind.homeFolderName == "." + kind.rawValue)
        #expect(AgentKind.homeFolderName(ofProvider: kind.rawValue) == kind.homeFolderName)
    }

    /// The guard protects the Codex home that holds the person's config,
    /// under each home it knows.
    @Test("the test write guard protects the default Codex home")
    func writeGuard_protectsTheDefaultCodexHome() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let codex = AgentProviderRegistry.defaultHome(of: .codex, under: home)
        #expect(TestWriteGuard.protectedRoots.contains(codex))
        #expect(TestWriteGuard.protectedFolder(containing: codex.appendingPathComponent("config.toml")) == .codexHome)
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
        case .kiro:
            AgentBrand(
                letters: "Ki",
                fill: .solid(SupervisionTokens.kiro),
                foreground: SupervisionTokens.badgeForeground,
                edge: SupervisionTokens.kiroEdge
            )
        }
        #expect(brand == expected)
        #expect(SessionRowFactText.badge(.agent(kind), locale: .english) == brand.letters)
        #expect(SessionRowFactText.badge(.agent(kind), locale: Locale(identifier: "ja")) == brand.letters)
    }

    // MARK: - Shell quoting

    @Test("shell quoting preserves each argument", arguments: [
        ("/tmp/repo", "'/tmp/repo'"),
        ("/Users/foo/Weir Dev/bar's repo", "'/Users/foo/Weir Dev/bar'\\''s repo'"),
        ("", "''"),
        ("'", "''\\'''"),
        ("a'b'c", "'a'\\''b'\\''c'"),
        ("plain", "'plain'"),
        ("it's", "'it'\\''s'")
    ])
    func shellQuote_isOneForm(value: String, quoted: String) {
        #expect(ShellQuote.single(value) == quoted)
        #expect(DemoFixture.scene([], prompt: "p", end: .prompt, title: value).contains("printf '\\033]2;%s\\007' \(quoted) && "))
    }

    @Test func theInstaller_quotesTheExecutablePath() {
        #expect(CodexHookInstaller.executableCommand(for: URL(fileURLWithPath: "/Applications/x y'z")) == "'/Applications/x y'\\''z'")
    }

    // MARK: - Typed control characters

    /// One rule for what may not be typed into a terminal, whichever text
    /// holds it: C0, DEL, and C1, and nothing else.
    @Test(
        "text holds a typed control exactly when one of its scalars is C0, DEL, or C1",
        arguments: [
            ("", false), ("/compact", false), ("é", false), ("/tmp/repo", false), ("é 日本", false), ("\u{A0}", false), ("\u{0}", true), (
                "\u{1F}",
                true
            ),
            ("a\nb", true), ("\t", true), ("\u{7F}", true), ("\u{80}", true), ("\u{9B}", true), ("\u{9F}", true), ("x\u{1B}[200~", true)
        ]
    )
    func containsTypedControl_isAnyScalarsRule(text: String, isControl: Bool) {
        #expect(text.containsTypedControl == isControl)
        #expect(text.containsTypedControl == text.unicodeScalars.contains(where: \.isTypedControl))
        #expect(text[...].containsTypedControl == isControl)
        // Every caller refuses, or types, the same text.
        #expect((AgentKind.claude.newConversationCommand(cwd: "/tmp/\(text)") == nil) == isControl)
    }

}
