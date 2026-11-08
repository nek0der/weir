// DemoFixtureTests.swift
// Weir — CI guard for the fixed demo session that powers the hero screenshot.
//
// We don't anchor on every pane's text (that drifts with copy edits), only on
// the structure the screenshot pipeline and AGENTS.md promise: three
// projects, the selected worktree and tab, the window's layout, rows named by
// their agents' tabs, the shell directory the script starts in, the pull
// requests, the staged turns, the schema version, and a clean JSON round-trip.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("DemoFixture")
@MainActor
struct DemoFixtureTests {
    @Test func openLayers_haveTheNamesTheCaptureScriptPasses() {
        #expect(DemoFixture.OpenLayer(rawValue: "needs-attention") == .needsAttention)
        #expect(DemoFixture.OpenLayer(rawValue: "all-projects") == .allProjects)
        #expect(DemoFixture.OpenLayer(rawValue: "needsAttention") == nil)
        #expect(DemoFixture.OpenLayer(rawValue: "review") == .review)
        #expect(DemoFixture.OpenLayer(rawValue: "approval-list") == .approvalList)
        #expect(DemoFixture.OpenLayer(rawValue: "approval-card") == .approvalCard)
    }

    /// A staged command must create a PID marker in the capture's readiness directory.
    @Test(arguments: DemoFixture.Slot.allCases)
    func everySlotsScene_writesAReadinessMarker(_ slot: DemoFixture.Slot) async throws {
        let tab = try #require(DemoFixture.snapshot.tabs.first { $0.id == slot.tabID })
        let command = try #require(tab.initialCommands[slot.paneID])
        try await withTempDir { directory in
            let ready = directory.appendingPathComponent("ready", isDirectory: true)
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: false)
            let result = try #require(await runTool(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [
                    "-i", "HOME=\(directory.path)", "ZDOTDIR=\(directory.path)", "PATH=/usr/bin:/bin",
                    "TERM=xterm", "WEIR_DEMO_PANES_READY=\(ready.path)",
                    "/bin/sh", "-c", #"printf '\n' | /bin/zsh -f -c "$1""#, "scene", command
                ],
                workingDirectory: directory,
                timeout: .seconds(5)
            ))
            #expect(result.exitCode == 0, "\(result.stderr)")
            let markers = try FileManager.default.contentsOfDirectory(atPath: ready.path)
            let marker = try #require(markers.first)
            #expect(markers.count == 1)
            #expect((Int(marker) ?? 0) > 0)
            #expect(try Data(contentsOf: ready.appendingPathComponent(marker)).isEmpty)
        }
    }

    @Test func language_isJapaneseOnlyWhenNamed() {
        #expect(DemoFixture.language(named: "ja") == .japanese)
        #expect(DemoFixture.language(named: "en") == .english)
        #expect(DemoFixture.language(named: nil) == .english)
        #expect(DemoFixture.language(named: "JA") == .english)
        #expect(DemoFixture.language(named: "fr") == .english)
    }

    /// Only the layers that show the approval stage one, so the landing
    /// page's captures do not change.
    @Test func onlyTheApprovalLayers_stageAnApproval() {
        #expect(DemoFixture.OpenLayer.allCases.filter(\.stagesApproval) == [.approvalList, .approvalCard])
    }

    @Test func stagedReview_opensWithItsCommentCurrent_andItsCountsTrue() async throws {
        let root = DemoFixture.selectedWorktreeRoot
        let pool = ReviewDraftWriterPool(drafts: DemoReviewDraftStore(), git: DemoReviewRepository())
        #expect(try await pool.root(of: root) == root, "Git is not asked")
        let session = pool.session(root: root)
        let file = DemoFixture.reviewedFile
        #expect(session.lastFileID == file.id)
        #expect(await session.reload(scope: .uncommitted, selectedFileID: nil) == .applied(selectedFileID: file.id))
        let diff = try #require(session.diff)

        #expect(diff.file == file)
        #expect(diff.lines.count(where: { $0.kind == .added }) == 31)
        #expect(diff.lines.count(where: { $0.kind == .removed }) == 4)
        #expect(session.errorMessage == nil)
        let comment = try #require(session.comments.first)
        #expect(session.comments.count == 1)
        #expect(comment.fingerprint == diff.fingerprint)
        #expect(diff.lines.contains { $0.id == comment.anchor.lineID && $0.text == comment.code })
        #expect(session.staleCommentIDs.isEmpty)

        #expect(session.stats[file.id] == ReviewFileStat(added: 31, removed: 4))
        #expect(session.files.count == 5)
        #expect(session.stats.count == 5)
        #expect(session.stats.values.map(\.added).reduce(0, +) == 160)
        #expect(session.stats.values.map(\.removed).reduce(0, +) == 13)
        #expect(DemoFixture.worktreeCounts == .changed(files: 5, added: 160, removed: 13))
    }

    @Test func stagedApproval_staysHeldWhileItsPaneIsOutOfSight_withAClockThatDoesNotMove() throws {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        #expect(session.primarySelection.activeContainerID == DemoFixture.remindersContainer)
        #expect(session.primarySelection.activeTabID == DemoFixture.Slot.reminders.tabID)
        let attention = AttentionState()
        AgentProjectionAdapter.seedRuntimes(fromBadgesIn: session, into: attention)
        let store = DemoFixture.makeApprovalStore()
        store.runtimes = { attention.allRuntimes }
        let now = SuspendingClock.Instant.now
        DemoFixture.stageApproval(in: store, now: now)

        #expect(store.isRunning)
        let input = try JSONSerialization.jsonObject(with: Data(DemoFixture.stagedApproval.inputDescription.utf8))
        #expect(DemoFixture.stagedApproval.inputAddsToSummary == ApprovalControllerConnection.inputAddsToSummary(
            input: input,
            summary: DemoFixture.stagedApproval.summary
        ))
        let key = try #require(store.ledger.entries.keys.first)
        let request = DemoFixture.stagedApproval
        #expect(key == ApprovalKey(epoch: request.epoch, runID: request.runID, requestID: request.requestID))
        #expect(store.pending.map(\.id) == [DemoFixture.stagedApproval.id])
        #expect(store.ledger.entries.count == 1)
        #expect(store.opensCard(key))
        // The request is in the proration worktree's pane, which its decision
        // bar and its sidebar row answer from.
        #expect(store.panes(for: DemoFixture.stagedApproval, in: session).map(\.paneID) == [DemoFixture.Slot.proration.paneID])
        #expect(store.ledger.entries[key]?.state == .held)
        let deadline = try #require(store.serviceDeadlines[DemoFixture.stagedApproval.id])
        #expect(deadline.remaining(at: now) == .seconds(522))
        #expect(deadline.remaining(at: now.advanced(by: .seconds(60))) == .seconds(522))
    }

    @Test func clockShift_movesNowToTheNamedTime_orToTheDefault() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 22)))
        func shown(_ name: String?) -> Date {
            now.addingTimeInterval(DemoFixture.clockShift(named: name, now: now, calendar: calendar))
        }
        let named = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 15)))
        let fallback = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 14, minute: 30)))
        #expect(shown("09:15") == named)
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(shown("00:00") == midnight)
        for invalid in [nil, "25:00", "09:60", "09::15", "09:bad:15", "09:15:bad"] {
            #expect(shown(invalid) == fallback, "Invalid time: \(invalid ?? "<absent>")")
        }
    }

    @Test func appearance_isDarkOnlyWhenNamedSo() {
        #expect(DemoFixture.colorScheme(named: "dark") == .dark)
        #expect(DemoFixture.colorScheme(named: "light") == .light)
        #expect(DemoFixture.colorScheme(named: nil) == .light)
        #expect(DemoFixture.colorScheme(named: "Dark") == .light)
    }

    @Test func snapshot_hasThreeProjects_andTheirWorktrees_inTheDocumentedOrder() throws {
        let snap = DemoFixture.snapshot
        #expect(snap.projects.map(\.name) == ["duesmith", "pdf-worker", "dotfiles"])
        let duesmith = try #require(snap.projects.first)
        #expect(duesmith.worktrees.map(\.label) == [
            "feat/overdue-reminders", "fix/tax-rounding", "feat/proration", "fix/webhook-timeout", "docs/invoices-api",
            "fix/csv-export", "agent-3f2a91", "agent-7c0d44", "agent-a19e5b", "agent-e62b07", "duesmith-bisect"
        ])
        #expect(snap.projects[1].worktrees.map(\.label) == [
            "fix/page-breaks",
            "feat/batch-render",
            "feat/embed-fonts",
            "fix/margin-overflow"
        ])
        // Each project's main folder is a row too: twelve working rows, one
        // ready to clean up, and five other worktrees.
        #expect(snap.projects.reduce(0) { $0 + 1 + $1.worktrees.count } == 18)
        // Weir made the working ones; Git only reported the agents' and
        // the detached one.
        #expect(duesmith.worktrees.map(\.admission) == Array(repeating: .created, count: 6) + Array(repeating: .discovered, count: 5))
        #expect(duesmith.worktrees.last?.gitRef?.branchName == nil, "the detached one has no branch")
        // Pinned, so a scan of folders that do not exist leaves them alone.
        #expect(snap.projects.flatMap(\.worktrees).allSatisfy { $0.origin == .userPinned })
        #expect(snap.recentProjectPaths == snap.projects.map(\.rootURL))
    }

    @Test func restoringTheWindow_selectsReminders_andRestoresItsPanelLayout() throws {
        let window = try #require(DemoFixture.snapshot.windows.first)
        #expect(DemoFixture.snapshot.windows.count == 1)
        #expect(window.projectID == DemoFixture.duesmithProjectID)
        #expect(window.activeContainerID == DemoFixture.remindersContainer)
        #expect(window.activeTabID == DemoFixture.Slot.reminders.tabID)
        #expect(window.frame == WindowFrame(CGRect(x: 16, y: 16, width: 1440, height: 900)))
        #expect(window.sidebarWidth == 264)
        #expect(!window.sidebarHidden)
        #expect(window.isChangesPanelPresented)
        #expect(window.changesPanelWidth == 312)
        #expect(window.isFront)
        let session = WorkspaceSession()
        #expect(session.restore(from: DemoFixture.snapshot) == nil)
        let selection = session.primarySelection
        #expect(selection.shownProjectID == DemoFixture.duesmithProjectID)
        #expect(selection.activeContainerID == DemoFixture.remindersContainer)
        #expect(selection.activeTabID == DemoFixture.Slot.reminders.tabID)
        #expect(selection.sidebarWidth == 264)
        #expect(!selection.sidebarHidden)
        #expect(selection.showsChangesPanel)
        #expect(selection.changesPanelWidth == 312)
    }

    /// The agent's pane is not split: the 100-column rule for opening the
    /// changes panel beside the terminal measures that pane. Codex's tab
    /// beside it shares the worktree, so the panel's timeline shows two
    /// conversations.
    @Test func theSelectedWorktree_isTheAgentsTab_thenCodexs_thenDevAndGit() throws {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let tabs = session.tabs(in: DemoFixture.remindersContainer)
        #expect(tabs.map(\.id) == [DemoFixture.Slot.reminders, .remindersCodex, .dev, .git].map(\.tabID))
        // The pane strip shows the conversations' titles and the shells'
        // last ones, none of them a name the person gave.
        #expect(tabs.map(\.displayTitle) == ["Send overdue reminders", "Migrate the schedules", "dev", "git"])
        #expect(tabs.allSatisfy { $0.titleOverride == nil })
        let agent = try #require(tabs.first)
        #expect(agent.splitTree.allLeafIDs() == [DemoFixture.Slot.reminders.paneID])
        #expect(agent.agentBadges[.claude]?[DemoFixture.Slot.reminders.paneID]?.state == .finished)
        #expect(tabs[1].agentBadges[.codex]?[DemoFixture.Slot.remindersCodex.paneID]?.state == .finished)
    }

    /// A row is named by its branch, never by a name the person gave,
    /// which would put the row's folder on its second line. A worktree with
    /// an agent leads with the agent's tab, which holds that conversation's
    /// name and shows it in the pane strip, and one with shells alone holds
    /// none. The worktrees folded away (the merged one, the agents', the
    /// detached one) have no tab: a tab would make them working rows.
    @Test func everyWorktree_isNamedByItsBranch_andAnAgentsTabByItsConversation() {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        var agentWorktrees = 0
        var emptyRows: [ContainerID] = []
        for project in session.projects {
            for container in SessionSidebarModel.containers(of: project) {
                let tabs = session.tabs(in: container)
                let first = tabs.first
                let isAgents = first.map { !$0.agentBadges.values.allSatisfy(\.isEmpty) } ?? false
                #expect(tabs.allSatisfy { $0.titleOverride == nil }, "\(container)")
                let name = session.rowName(of: container)
                if let branch = CheckoutName.knownBranch(of: container, in: session) {
                    #expect(name == RowName(text: branch, source: .branch), "\(container)")
                }
                if isAgents {
                    agentWorktrees += 1
                    #expect(first?.conversationName != nil, "\(container)")
                    #expect(first?.displayTitle == first?.conversationName?.name, "\(container)")
                } else {
                    #expect(tabs.allSatisfy { $0.conversationName == nil }, "\(container)")
                    #expect(name?.source != .conversation, "\(container)")
                }
                #expect(session.rowCheckout(of: container) == nil, "\(container)")
                if tabs.isEmpty {
                    emptyRows.append(container)
                }
            }
        }
        #expect(agentWorktrees == 10)
        let folded = [DemoFixture.csvExportWorktreeID] + DemoFixture.agentWorktreeIDs + [DemoFixture.bisectWorktreeID]
        #expect(emptyRows == folded.map { .worktree(projectID: DemoFixture.duesmithProjectID, worktreeID: $0) })
        #expect(session.tabs(in: .loose).count == 1)
    }

    /// Every pane prints its scene with the colors written as text: an
    /// escape character typed into the shell would reach zsh's line editor
    /// as a key. An agent's scene sets the terminal's title to its
    /// conversation's, which the tab shows, and holds the screen with its
    /// cursor hidden.
    @Test func paneCommands_areSingleLine_andIncludeScreenHoldForSelectedScenes() throws {
        let slotsThatHold: Set<DemoFixture.Slot> = [
            .reminders, .remindersCodex, .dev, .prReview, .taxRounding, .proration,
            .docs, .pageBreaks, .batchRender, .embedFonts, .marginOverflow
        ]
        let snapshot = DemoFixture.snapshot
        #expect(Set(snapshot.tabs.flatMap { $0.splitTree.allLeafIDs() }) == Set(DemoFixture.Slot.allCases.map(\.paneID)))
        for slot in DemoFixture.Slot.allCases {
            let tab = try #require(snapshot.tabs.first { $0.id == slot.tabID })
            #expect(Set(tab.initialCommands.keys) == [slot.paneID])
            let command = try #require(tab.initialCommands[slot.paneID])
            #expect(!command.contains("\u{1B}"), "\(slot)")
            #expect(!command.contains("\n"), "\(slot)")
            let holds = slotsThatHold.contains(slot)
            #expect(command.contains("read -r") == holds, "\(slot)")
            #expect(command.contains("printf '\\033[?25l%b'") == holds, "\(slot)")
            #expect(command.hasSuffix("&& read -r; printf '\\033[?25h'") == holds, "\(slot)")
            if let name = tab.conversationName {
                #expect(name.paneID == slot.paneID)
                #expect(DemoFixture.conversationTitle(of: slot) == name.name)
                #expect(command.contains("printf '\\033]2;%s\\007' \(ShellQuote.single(name.name))") == holds, "\(slot)")
            }
        }
        let reminders = DemoFixture.transcript(for: .reminders)
        #expect(reminders.contains("&& clear && printf '\\033]2;%s\\007' 'Send overdue reminders' && "))
        #expect(reminders.contains("\\033[36m"))
    }

    /// The scene's text is typed between single quotes: a quote in it closes
    /// and reopens them rather than ending the argument.
    @Test func aScenesQuote_isClosedEscapedAndReopened() {
        let command = DemoFixture.scene([DemoFixture.Line(.plain, "don't")], prompt: "p", end: .prompt)
        #expect(command.hasPrefix("PS1='p \\$ ' PROMPT='p %% ' && clear && printf '%b\\n' 'don'\\''t' && "))
    }

    /// A demo pane's shell is the demo's own zsh, reading the bundled startup
    /// files and no history file, whatever the app was launched with.
    @Test func aPanesShell_readsTheDemosStartupFiles_andNoHistoryFile() {
        let files = URL(fileURLWithPath: "/Applications/Weir.app/Contents/Resources/demo-shell", isDirectory: true)
        let env = DemoFixture.shellEnvironment(
            over: ["PATH": "/shims:/usr/bin", "ZDOTDIR": "/shim/zdotdir", "HISTFILE": "/Users/me/.zsh_history"],
            startupDirectory: files,
            panesReady: "/tmp/ready"
        )
        #expect(DemoFixture.shellCommand == "/bin/zsh")
        #expect(env["ZDOTDIR"] == files.path)
        #expect(env["HISTFILE"] == "")
        #expect(env["SAVEHIST"] == "0")
        #expect(env["PATH"] == "/shims:/usr/bin")
        #expect(env["USER"] == "demo")
        #expect(env["HOST"] == "localhost")
        #expect(env["WEIR_DEMO_PANES_READY"] == "/tmp/ready")
        // Without the bundled files, a folder that holds none, never the person's.
        let bare = DemoFixture.shellEnvironment(over: [:], startupDirectory: nil, panesReady: "")
        #expect(bare["ZDOTDIR"] == "/var/empty")
    }

    /// Runs the shell as a demo pane does, as a login shell taking a typed
    /// line, in a home whose startup files would keep a history and say so,
    /// and finds neither: the line reached no history file, none of the
    /// home's files ran, and the system's history file was undone. The
    /// prompt is the demo's, and Ghostty's integration, which reports the
    /// pane's folder, is loaded.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no source tree"))
    func aPanesShell_runsNoneOfTheHomesStartupFiles_andKeepsNoHistory() async throws {
        let root = try #require(RepoFixture.weirRoot)
        let files = root.appendingPathComponent("Weir/Resources/demo-shell", isDirectory: true)
        let ghostty = root.appendingPathComponent("Weir/Resources/ghostty", isDirectory: true)
        try await withTempDir { home in
            let rc = "HISTFILE=$HOME/.zsh_history; SAVEHIST=100; setopt inc_append_history; print HOME_RC_RAN\n"
            for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
                try rc.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let environment = DemoFixture.shellEnvironment(
                over: [
                    "HOME": home.path,
                    "PATH": "/usr/bin:/bin",
                    "HISTFILE": home.appendingPathComponent(".zsh_history").path,
                    "GHOSTTY_RESOURCES_DIR": ghostty.path
                ],
                startupDirectory: files,
                panesReady: ""
            )
            let line = #"print -r -- "scene [$HISTFILE] [$SAVEHIST] [$PROMPT] [${precmd_functions[(r)_ghostty_precmd]}]""#
            let result = try #require(await runTool(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["-i"] + environment.map { "\($0.key)=\($0.value)" } + [
                    "/bin/sh", "-c", #"printf '%s\n' "$1" exit | "$2" -il"#, "demo", line, DemoFixture.shellCommand
                ],
                workingDirectory: home,
                timeout: .seconds(10)
            ))
            #expect(result.exitCode == 0, "\(result.stderr)")
            #expect(result.stdout.contains("scene [] [0] [demo@weir %1~ %% ] [_ghostty_precmd]"), "\(result.stdout)")
            #expect(!result.stdout.contains("HOME_RC_RAN"))
            #expect(!result.stderr.contains("HOME_RC_RAN"))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zsh_history").path))
        }
    }

    /// A probe records the capture script's actual launch directory.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no source tree"))
    func theScreenshotScript_launchesFromTheSelectedWorktreesFolder() async throws {
        let root = try #require(RepoFixture.weirRoot)
        let scriptURL = root.appendingPathComponent("scripts/screenshot.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let relative = DemoFixture.selectedWorktreeHomeRelativePath
        #expect(DemoFixture.selectedWorktreeRoot.path == "/Users/demo/\(relative)")
        #expect(script.contains("let expectedPoints = CGSize(width: 1440, height: 900)"))
        try await withTempDir { directory in
            let app = directory.appendingPathComponent("Probe.app")
            let binary = app.appendingPathComponent("Contents/MacOS/probe")
            let stubSwift = directory.appendingPathComponent("bin/swift")
            let record = directory.appendingPathComponent("launch")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stubSwift.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "probe"], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Self.writeExecutable(
                """
                #!/bin/sh
                printf '%s\\n' "$CFFIXED_USER_HOME" "$WEIR_DEMO" > "$DEMO_LAUNCH_RECORD"
                pwd -P >> "$DEMO_LAUNCH_RECORD"
                """,
                at: binary
            )
            // Stop before activation or capture, even if the probe did not launch.
            try Self.writeExecutable("#!/bin/sh\nexit 1\n", at: stubSwift)
            let result = try #require(await runTool(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [
                    "-i", "HOME=\(directory.path)", "TMPDIR=\(directory.path)",
                    "PATH=\(stubSwift.deletingLastPathComponent().path):/usr/bin:/bin",
                    "DEMO_LAUNCH_RECORD=\(record.path)", "WEIR_SCREENSHOT_APP=\(app.path)", "/bin/bash", scriptURL.path
                ],
                workingDirectory: directory,
                timeout: .seconds(15)
            ))
            #expect(result.exitCode == 1)
            #expect(result.stderr.contains("the demo app is not running, so nothing was captured"))
            let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
            try #require(lines.count == 3)
            #expect(lines[1] == "1")
            #expect(lines[2] == "\(lines[0])/\(relative)")
            #expect(!FileManager.default.fileExists(atPath: lines[0]), "the script removed its capture home")
        }
    }

    private static func writeExecutable(_ source: String, at url: URL) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    @Test("snapshot survives a JSON round-trip without losing state")
    func snapshot_jsonRoundTrip() throws {
        let original = DemoFixture.snapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: encoder.encode(original)
        )
        #expect(original.version == SessionSnapshot.currentVersion)
        #expect(restored.version == SessionSnapshot.currentVersion)
        #expect(restored.projects == original.projects)
        #expect(restored.tabs == original.tabs)
        #expect(restored.windows == original.windows)
        #expect(restored.projectViews == original.projectViews)
        #expect(restored.recentProjectPaths == original.recentProjectPaths)
        #expect(restored.conversationTabNames == original.conversationTabNames)
        #expect(restored.unknownFields == original.unknownFields)
    }

    /// Switched to pdf-worker, the window comes back on its waiting agent.
    @Test func pdfWorkersView_opensOnItsWaitingAgent() throws {
        let views = DemoFixture.snapshot.projectViews
        let pdf = try #require(views.first { $0.projectID == DemoFixture.pdfWorkerProjectID })
        #expect(pdf.activeContainerID == DemoFixture.pageBreaksContainer)
        #expect(pdf.activeTabID == DemoFixture.Slot.pageBreaks.tabID)
        let session = WorkspaceSession()
        #expect(session.restore(from: DemoFixture.snapshot) == nil)
        session.showProject(DemoFixture.pdfWorkerProjectID, in: session.primaryWindowID, intent: .person, reason: .person)
        #expect(session.primarySelection.shownProjectID == DemoFixture.pdfWorkerProjectID)
        #expect(session.primarySelection.activeContainerID == DemoFixture.pageBreaksContainer)
        #expect(session.primarySelection.activeTabID == DemoFixture.Slot.pageBreaks.tabID)
        let tab = try #require(session.tab(containing: DemoFixture.Slot.pageBreaks.paneID))
        #expect(tab.id == session.primarySelection.activeTabID)
        let badge = try #require(tab.agentBadges[.codex]?[DemoFixture.Slot.pageBreaks.paneID])
        #expect(badge.state == .needsInput)
        #expect(badge.waitKind == PromptWaitKind.approval.rawValue)
    }

    /// The demo request marks are keyed by hand-written `ContainerID`
    /// values, so nothing but this connects them to the containers in
    /// the snapshot. Change one ID and `make screenshot` silently produces
    /// a hero image with the marks missing — exactly the class of breakage
    /// this suite exists to catch.
    @Test("every demo pull request is keyed to a container in the snapshot")
    func prStatus_keysResolveToSnapshotContainers() throws {
        let snap = DemoFixture.snapshot
        #expect(DemoFixture.prStatus.mapValues(\.number) == [
            DemoFixture.batchRenderContainer: 57,
            DemoFixture.csvExportContainer: 311,
            DemoFixture.closedAgentContainer: 317,
            DemoFixture.docsContainer: 324,
            DemoFixture.prorationContainer: 326
        ])
        for container in DemoFixture.prStatus.keys {
            switch container {
            case let .project(id):
                #expect(snap.projects.contains { $0.id == id })
            case let .worktree(projectID, worktreeID):
                let project = try #require(snap.projects.first { $0.id == projectID })
                #expect(project.worktrees.contains { $0.id == worktreeID })
            case .loose:
                Issue.record("the scratch row has no branch to carry a request")
            }
        }
    }

    @Test func demoWorktrees_doNotStartLiveGitSync() throws {
        let session = WorkspaceSession()
        #expect(session.restore(from: DemoFixture.snapshot) == nil)
        let before = session.projects
        let sync = AppState.makeGitSync(session: session, readsFolders: false)
        // With no coordinator, neither focus nor a manual sync can read
        // the fixture's made-up folders or replace its project state.
        #expect(sync == nil)
        #expect(session.projects == before)
        #expect(session.projects.allSatisfy { $0.trouble == nil })
        let store = GitFactsStore(staged: DemoFixture.gitFacts)
        let reminders = try #require(store.facts(for: DemoFixture.remindersContainer))
        #expect(reminders.proposedCommits == 2)
        #expect(reminders.uncommittedFiles == 5)
    }

    @Test func liveWorktrees_startGitSync() {
        // An empty live session starts no repository reads in this test.
        let session = WorkspaceSession()
        let sync = AppState.makeGitSync(session: session, readsFolders: true)
        #expect(sync != nil)
    }

    @Test func everyStagedGitFact_namesItsSnapshotCheckout() {
        let snap = DemoFixture.snapshot
        let session = WorkspaceSession()
        #expect(session.restore(from: snap) == nil)
        let facts = DemoFixture.gitFacts
        #expect(facts.compactMapValues(\.branch) == [
            .project(DemoFixture.duesmithProjectID): "main",
            DemoFixture.remindersContainer: "feat/overdue-reminders",
            .worktree(projectID: DemoFixture.duesmithProjectID, worktreeID: DemoFixture.taxRoundingWorktreeID): "fix/tax-rounding",
            DemoFixture.prorationContainer: "feat/proration",
            .worktree(projectID: DemoFixture.duesmithProjectID, worktreeID: DemoFixture.webhookWorktreeID): "fix/webhook-timeout",
            DemoFixture.docsContainer: "docs/invoices-api",
            DemoFixture.csvExportContainer: "fix/csv-export",
            DemoFixture.batchRenderContainer: "feat/batch-render",
            DemoFixture.pageBreaksContainer: "fix/page-breaks",
            DemoFixture.embedFontsContainer: "feat/embed-fonts",
            DemoFixture.marginOverflowContainer: "fix/margin-overflow"
        ])
        for (container, fact) in facts {
            #expect(fact.branch != nil)
            #expect(CheckoutName.knownBranch(of: container, in: session) == fact.branch, "\(container)")
        }
        let reminders = facts[DemoFixture.remindersContainer]
        #expect(reminders?.proposedCommits == 2)
        #expect(reminders?.uncommittedFiles == 5, "what Claude's T4 and T5 and Codex's T1 changed")
    }

    /// Demo mode hands the fixture's requests to the syncer at
    /// construction (`PRStatusSource.fixture`), and a completed manual
    /// refresh leaves those fixture rows in place.
    @Test func demoPRStatus_comesFromFixtureSource() async {
        #expect(!DemoFixture.isDemoActive)
        if case .fixture = AppState.prStatusSource {
            Issue.record("a run that is not the demo reads the forge CLIs")
        }
        #expect(AppState.stagedGitFacts == nil)

        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let store = PRStatusStore()
        let syncer = PRStatusSyncer(session: session, store: store, source: .fixture(DemoFixture.prStatus))
        syncer.start()

        #expect(store.perContainer == DemoFixture.prStatus)
        for container in DemoFixture.prStatus.keys {
            #expect(store.forge(for: container) == nil)
            await syncer.refresh(container: container)
        }
        #expect(store.perContainer == DemoFixture.prStatus)
    }

    /// A real `github.com/<name>` is somebody's account, and the demo
    /// hands its link to anyone who clicks. RFC 2606 reserves
    /// `.invalid` so it can never resolve to one.
    @Test("demo request links point at a reserved, non-resolving host")
    func prStatus_urlsUseAReservedHost() {
        #expect(!DemoFixture.prStatus.isEmpty)
        for info in DemoFixture.prStatus.values {
            #expect(info.url.scheme == "https", "PR \(info.number)")
            #expect(info.url.host()?.hasSuffix(".invalid") == true, "PR \(info.number)")
        }
    }

    // MARK: - Staged turns

    /// The selected workspace's conversation: five turns in its worktree,
    /// T3 an answer and the others with changes, T4's check failing and
    /// T5's passing.
    @Test func theRemindersTurns_areOneConversation_inTheSelectedWorktree() throws {
        let turns = try DemoFixture.stagedTurns(of: DemoFixture.remindersConversation)
        #expect(turns.map(\.displayNumber) == [1, 2, 3, 4, 5])
        #expect(turns.allSatisfy { $0.phase == .finished && $0.endTree?.root == DemoFixture.selectedWorktreeRoot.path })
        #expect(turns.allSatisfy { $0.paneID == DemoFixture.Slot.reminders.paneID.uuidString })
        #expect(turns.filter(\.changes.mayHaveChangedFiles).map(\.displayNumber) == [1, 2, 4, 5])
        #expect(turns[3].lastCheck?.exitCode == 1)
        #expect(turns[4].lastCheck == CheckSummary(command: "pnpm test src/reminders", isFiltered: true, exitCode: 0, earlierFailures: 1))
    }

    /// The other staged conversations: the review's two answers, and the
    /// stopped agent's interrupted turn with what it had changed.
    @Test func theOtherConversations_areTheReviewsAnswers_andTheStoppedAgentsTurn() throws {
        let review = try DemoFixture.stagedTurns(of: DemoFixture.prReviewConversation)
        #expect(review.map(\.displayNumber) == [1, 2])
        #expect(review.map(\.phase) == [.finished, .finished])
        #expect(review.map(\.changes) == [.unchanged, .unchanged])
        #expect(review.allSatisfy { $0.conversation == DemoFixture.prReviewConversation })
        #expect(review.allSatisfy { $0.conversation.provider == .codex && $0.paneID == DemoFixture.Slot.prReview.paneID.uuidString })
        #expect(review
            .allSatisfy { $0.beginTree?.root == DemoFixture.duesmithRoot.path && $0.endTree?.root == DemoFixture.duesmithRoot.path })
        let replies = review.compactMap(\.reply)
        #expect(replies.count == 2)
        #expect(replies.first?.hasPrefix("It moves credit notes") == true)
        #expect(replies.last?.hasPrefix("Three problems.") == true)
        let webhook = try DemoFixture.stagedTurns(of: DemoFixture.webhookConversation)
        #expect(webhook.map(\.phase) == [.interrupted])
        let stopped = try #require(webhook.first)
        #expect(stopped.changes == .changed(files: 2, added: 18, removed: 3))
        #expect(stopped.conversation == DemoFixture.webhookConversation)
        #expect(stopped.paneID == DemoFixture.Slot.webhook.paneID.uuidString)
        #expect(stopped.endTree?.root == DemoFixture.folder("duesmith-fix-webhook-timeout").path)
        #expect(stopped.reply == nil)
        #expect(DemoFixture.conversations().count == 4)
    }

    /// Codex's turn in the selected worktree: one turn with changes, begun
    /// after Claude's T4 and before T5, so the timeline reads T4, Codex's
    /// T1, T5.
    @Test func theCodexTurn_isInTheSelectedWorktree_betweenT4AndT5() throws {
        let staged = DemoFixture.stagedProjection
        let codex = try #require(staged.turns.first { $0.key == DemoFixture.remindersCodexConversation }).turns
        let reminders = try #require(staged.turns.first { $0.key == DemoFixture.remindersConversation }).turns
        try #require(reminders.count == 5)
        #expect(codex.map(\.displayNumber) == [1])
        #expect(codex.first?.conversation.provider == .codex)
        #expect(codex.first?.changes == .changed(files: 1, added: 24, removed: 0))
        #expect(codex.first?.endTree?.root == DemoFixture.selectedWorktreeRoot.path)
        #expect(codex.first?.paneID == DemoFixture.Slot.remindersCodex.paneID.uuidString)
        let timeline = ChangesPanelModel.timeline(reminders + codex)
        #expect(timeline.map(\.turnID) == (reminders.prefix(4) + codex + reminders.suffix(1)).map(\.turnID))
        let viewed = ViewedLineStore(writesFiles: false)
        staged.markViewedLines(in: viewed)
        #expect(timeline.filter(viewed.isViewed).map(\.turnID) == reminders.prefix(3).map(\.turnID))
        guard case let .range(range) = ReviewScopeCatalog.unviewedTurns(turns: timeline, isViewed: viewed.isViewed) else {
            Issue.record("expected the worktree's unviewed range")
            return
        }
        #expect(range.turnIDs == (reminders[3...3] + codex + reminders[4...4]).map(\.turnID))
        #expect(ChangesPanelModel.comparison(range).begin == reminders[3].beginTree?.tree)
        #expect(ChangesPanelModel.comparison(range).end == reminders[4].endTree?.tree)
    }

    /// Every staged turn has ended, and each conversation's last one when its
    /// agent's badge says it did.
    @Test func everyConversation_endedBeforeNow_itsLastTurnAsItsBadgeSays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let beforeSnapshot = Date()
        let snapshot = DemoFixture.snapshot
        let afterSnapshot = Date()
        let session = WorkspaceSession()
        _ = session.restore(from: snapshot)
        let format = ISO8601DateFormatter()
        let secondsAgo: [ConversationKey: TimeInterval] = [
            DemoFixture.remindersConversation: 80,
            DemoFixture.remindersCodexConversation: 320,
            DemoFixture.prReviewConversation: 860,
            DemoFixture.webhookConversation: 560
        ]
        for conversation in DemoFixture.conversations(now: now) {
            let ends = conversation.turns.compactMap { $0.finishedAt.flatMap(format.date(from:)) }
            #expect(ends.count == conversation.turns.count)
            #expect(ends.allSatisfy { $0 <= now })
            let pane = try #require(conversation.turns.last.flatMap { UUID(uuidString: $0.paneID) })
            #expect(DemoFixture.conversation(forPane: pane) == conversation.key)
            let badge = try #require(session.tab(containing: pane)?.agentBadges[conversation.key.provider]?[pane])
            let last = try #require(ends.last)
            let offset = try #require(secondsAgo[conversation.key])
            #expect(last == now.addingTimeInterval(-offset))
            // Snapshot badges sample the wall clock internally.
            #expect(badge.updatedAt >= beforeSnapshot.addingTimeInterval(-offset))
            #expect(badge.updatedAt <= afterSnapshot.addingTimeInterval(-offset))
            #expect(badge.lastPrompt == conversation.turns.last?.promptHead)
        }
    }

    /// Each staged conversation is called one name everywhere, as a real
    /// run's is: its tab, its badge's conversation and title as the
    /// provider keeps it, its pane header, every turn's recorded title, and
    /// the changes panel, which names it from those turns.
    @Test func everyStagedConversation_isCalledOneName() throws {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        for conversation in DemoFixture.conversations() {
            let pane = try #require(conversation.turns.last.flatMap { UUID(uuidString: $0.paneID) })
            let tab = try #require(session.tab(containing: pane))
            let badge = try #require(tab.agentBadges[conversation.key.provider]?[pane])
            let name = tab.title

            #expect(tab.displayTitle == name)
            #expect(badge.conversationID == conversation.key.conversationID)
            #expect(PaneHeaderRules.agentTitle(for: badge) == name)
            #expect(tab.conversationName == ConversationName(
                name: name, provider: conversation.key.provider, paneID: pane,
                conversationID: conversation.key.conversationID, startedAt: badge.sessionStartedAt
            ))
            let providerTitle = conversation.key.provider == .claude ? badge.providerGeneratedTitle : badge.providerSessionTitle
            #expect(providerTitle == name)
            #expect(conversation.turns.allSatisfy { $0.conversationTitle == name }, "\(name)")
            let agent = ChangesPanelModel.Agent(conversation: conversation.key, turns: conversation.turns)
            #expect(ChangesPanelModel.title(of: agent, liveTab: nil, rememberedTabName: nil) == name)
        }
    }
}
