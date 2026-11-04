// AutomationChannelTests.swift
// Weir — the verification channel's folder, refusals, and socket rules.

#if DEBUG && WEIR_AUTOMATION

    import Darwin
    import Foundation
    import Testing
    @testable import Weir
    @testable import WeirDomain

    struct AutomationRunFolderTests {
        @Test func create_makesAPrivateFolderWithTokenAndInfo() throws {
            try withShortTempDir { base in
                let folder = AutomationRunFolder(base: base, pid: 4242)

                let token = try folder.create()

                #expect(token.count == 64)
                #expect(try String(contentsOf: folder.tokenURL, encoding: .utf8) == token)
                #expect(mode(of: folder.folder) == 0o700)
                #expect(mode(of: folder.tokenURL) == 0o600)
                #expect(mode(of: folder.infoURL) == 0o600)
                let info = try #require(AutomationRunFolder.readInfo(at: folder.infoURL))
                #expect(info.pid == 4242)
                #expect(info.socket == folder.socketURL.path)
                #expect(info.protocol == AutomationProtocol.marker)
            }
        }

        @Test func create_refusesABaseOthersCanRead() throws {
            try withShortTempDir { base in
                chmod(base.path, 0o755)
                let folder = AutomationRunFolder(base: base)

                #expect(throws: (any Error).self) { try folder.create() }
            }
        }

        @Test func remove_leavesAFolderAnotherProcessTookOver() throws {
            try withShortTempDir { base in
                let runID = UUID()
                let mine = AutomationRunFolder(base: base, runID: runID, pid: 1)
                _ = try mine.create()
                let later = AutomationRunFolder(base: base, runID: runID, pid: 2)
                try SecureFileWrite.writeAtomic(
                    JSONEncoder().encode(AutomationRunFolder.Info(run: "", pid: 2, socket: "", protocol: "")),
                    to: later.infoURL
                )

                mine.remove()

                #expect(FileManager.default.fileExists(atPath: mine.folder.path))
                later.remove()
                #expect(!FileManager.default.fileExists(atPath: mine.folder.path))
            }
        }

        @Test func removeStale_removesOnlyFoldersWhoseProcessIsGone() throws {
            try withShortTempDir { base in
                let gone = AutomationRunFolder(base: base, pid: 100)
                let alive = AutomationRunFolder(base: base, pid: 200)
                _ = try gone.create()
                _ = try alive.create()

                AutomationRunFolder.removeStale(in: base) { $0 == 200 }

                #expect(!FileManager.default.fileExists(atPath: gone.folder.path))
                #expect(FileManager.default.fileExists(atPath: alive.folder.path))
            }
        }
    }

    @MainActor
    struct AutomationRefusalTests {
        @Test func dataRefusal_allowsTheDemoAndAnotherHome() {
            #expect(AutomationChannel.dataRefusal(environment: [:], isDemoActive: true, realHome: "/Users/a") == nil)
            #expect(AutomationChannel.dataRefusal(
                environment: ["CFFIXED_USER_HOME": "/tmp/somewhere"],
                isDemoActive: false,
                realHome: "/Users/a"
            ) == nil)
        }

        @Test func dataRefusal_refusesThePersonsOwnData() {
            #expect(AutomationChannel.dataRefusal(environment: [:], isDemoActive: false, realHome: "/Users/a") != nil)
            #expect(AutomationChannel.dataRefusal(
                environment: ["CFFIXED_USER_HOME": "/Users/a/"],
                isDemoActive: false,
                realHome: "/Users/a"
            ) != nil)
        }

        @Test func textRefusal_keepsTypeLineToOneLineOfText() {
            #expect(AutomationController.textRefusal(for: .typeLine, text: "echo hi") == nil)
            #expect(AutomationController.textRefusal(for: .typeLine, text: "") != nil)
            #expect(AutomationController.textRefusal(for: .typeLine, text: "a\nb") != nil)
            #expect(AutomationController.textRefusal(for: .typeLine, text: "a\u{7F}") != nil)
            #expect(AutomationController.textRefusal(for: .paste, text: "a\nb") == nil)
            #expect(AutomationController.textRefusal(for: .paste, text: "") != nil)
            #expect(AutomationController.textRefusal(for: .submit, text: "") == nil)
            #expect(AutomationController.textRefusal(for: .submit, text: "x") != nil)
        }
    }

    @MainActor
    struct AutomationTypingRefusalTests {
        private let ref = AutomationPaneRef(run: "R", id: UUID(), generation: 2)
        private let expect = AutomationExpectation(process: "opencode", session: nil)

        private func facts(
            isSameRun: Bool = true,
            hasTerminal: Bool = true,
            generation: Int? = 2,
            isInTmux: Bool = false,
            processNames: [String] = ["opencode"],
            agentSession: String? = "s1",
            hasUnsubmittedInput: Bool = false
        ) -> AutomationController.PaneFacts {
            AutomationController.PaneFacts(
                isSameRun: isSameRun,
                hasTerminal: hasTerminal,
                generation: generation,
                isInTmux: isInTmux,
                processNames: processNames,
                agentSession: agentSession,
                hasUnsubmittedInput: hasUnsubmittedInput
            )
        }

        @Test func aMatchingPane_isTypedInto() {
            #expect(AutomationController.typingRefusal(facts(), ref: ref, expect: expect) == nil)
            #expect(AutomationController.typingRefusal(
                facts(processNames: ["node", "opencode"]),
                ref: ref,
                expect: expect
            ) == nil)
        }

        @Test func eachMismatch_isRefused() {
            let refused: [AutomationController.PaneFacts] = [
                facts(isSameRun: false),
                facts(hasTerminal: false),
                facts(generation: 3),
                facts(generation: nil),
                facts(isInTmux: true),
                facts(processNames: ["zsh"]),
                facts(processNames: []),
                facts(hasUnsubmittedInput: true)
            ]
            for paneFacts in refused {
                #expect(AutomationController.typingRefusal(paneFacts, ref: ref, expect: expect) != nil)
            }
        }

        @Test func theChannelsOwnText_mayBeSubmittedButNotTypedInto() {
            var pasted = facts(hasUnsubmittedInput: true)
            pasted.isChannelDraft = true
            #expect(AutomationController.typingRefusal(pasted, ref: ref, expect: expect, op: .submit) == nil)
            #expect(AutomationController.typingRefusal(pasted, ref: ref, expect: expect, op: .typeLine) != nil)
            #expect(AutomationController.typingRefusal(pasted, ref: ref, expect: expect, op: .paste) != nil)
            #expect(AutomationController.typingRefusal(
                facts(hasUnsubmittedInput: true),
                ref: ref,
                expect: expect,
                op: .submit
            ) != nil)
        }

        @Test func reviewOfAPane_isOpenOnlyWhenItIsThatPanesAndShown() {
            let pane = UUID()
            var review = ReviewTabState(
                root: "/r",
                selection: .uncommitted(includesChangesOutsideTurns: false),
                fixedPoint: ReviewTabFixedPoint(),
                agentPaneID: pane,
                destinationPaneID: nil,
                opening: UUID()
            )
            #expect(AutomationController.isReviewShown(review, for: pane))
            #expect(!AutomationController.isReviewShown(review, for: UUID()))
            review.isShown = false
            #expect(!AutomationController.isReviewShown(review, for: pane))
            #expect(!AutomationController.isReviewShown(nil, for: pane))
        }

        @Test func aNamedSession_mustBeTheOneInThePane() {
            let named = AutomationExpectation(process: "opencode", session: "s1")
            let other = AutomationExpectation(process: "opencode", session: "s2")
            #expect(AutomationController.typingRefusal(facts(), ref: ref, expect: named) == nil)
            #expect(AutomationController.typingRefusal(facts(), ref: ref, expect: other) != nil)
            #expect(AutomationController.typingRefusal(facts(agentSession: nil), ref: ref, expect: named) != nil)
        }
    }

    /// `open` and `command` run a palette row, and refuse at once one the
    /// palette shows off, rather than reply "sent" and leave the client
    /// waiting for a layer that cannot open.
    @MainActor
    struct AutomationPaletteRowTests {
        private func rows(
            _ session: WorkspaceSession,
            facts: SupervisionPaletteFacts = .empty,
            window: WindowID? = nil
        ) throws -> [CommandPaletteItem] {
            try withTempDir { dir in
                CommandPaletteCatalog.buildItems(
                    session: session,
                    settings: SettingsStore(directory: dir),
                    attention: AttentionState(),
                    supervision: facts,
                    window: window ?? session.primaryWindowID,
                    locale: Locale(identifier: "en")
                )
            }
        }

        @Test func eachLayerButReview_opensThroughItsActionsRow() {
            #expect(AutomationController.action(opening: .needsAttention) == .showNeedsAttention)
            #expect(AutomationController.action(opening: .allProjects) == .allProjects)
            #expect(AutomationController.action(opening: .notificationHistory) == .notificationHistory)
            #expect(AutomationController.action(opening: .keyboardShortcuts) == .keyboardShortcuts)
            #expect(AutomationController.action(opening: .planUsage) == .planUsage)
            #expect(AutomationController.action(opening: .review) == nil)
        }

        /// `open planUsage` with the icon bars hidden is refused at once, with
        /// the reason `command` gives, rather than sent to a window that
        /// cannot show the panel.
        @Test func open_refusesALayerWhoseRowIsOff() throws {
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            var facts = SupervisionPaletteFacts.empty
            let shown = try rows(session, facts: facts)
            guard case let .run(item) = AutomationController.openStep(.planUsage, isOpen: false, items: { shown }) else {
                Issue.record("Plan Usage opens with the rail shown")
                return
            }
            #expect(item.action == .shortcutAction(.planUsage))

            facts.areRailsHidden = true
            let hidden = try rows(session, facts: facts)
            #expect(AutomationController.openStep(.planUsage, isOpen: false, items: { hidden })
                == .refused("shortcut.planUsage is disabled now"))
            #expect(AutomationController.row("shortcut.nothing", among: hidden)
                == .refused("no command shortcut.nothing in this window; commands lists them"))
        }

        /// A layer already up is not toggled shut, and the rows are not read.
        @Test func open_leavesALayerThatIsUp() {
            var isRead = false
            let step = AutomationController.openStep(.allProjects, isOpen: true) {
                isRead = true
                return []
            }
            #expect(step == .alreadyOpen)
            #expect(!isRead)
        }

        /// `open` in one window runs its row there, as that window's palette
        /// would: a palette open in another window keeps its query, and the
        /// window's own palette closes.
        @Test func open_inOneWindow_leavesAnotherWindowsPaletteAndItsQuery() throws {
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let other = WorkspaceSessionFixture.addWindow(to: session)
            let window = session.primaryWindowID
            let palette = CommandPaletteState(locale: Locale(identifier: "en"), windowID: other)
            palette.query = ">split"
            session.commandPaletteState = palette

            let items = try rows(session, window: window)
            guard case let .run(item) = AutomationController.openStep(.allProjects, isOpen: false, items: { items }) else {
                Issue.record("All Projects opens in a window with a tab")
                return
            }
            let commands = RecordingWindowCommands()
            try CommandPaletteActions.runRowForTest(item.action, session: session, window: window, commands: commands)

            #expect(session.commandPaletteState === palette)
            #expect(palette.query == ">split")
            #expect(commands.performed.contains { $0.command == .toggleAllProjects && $0.window == window })

            session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window)
            try CommandPaletteActions.runRowForTest(item.action, session: session, window: window, commands: commands)
            #expect(session.commandPaletteState == nil)
        }
    }

    @MainActor
    struct AutomationTurnWatchTests {
        private struct Look {
            var isMidTurn = false
            var isTurnOver = false
            var episode: String?
        }

        /// Feeds `looks` to a watch started at `start` and returns what each
        /// look said. Outside `#expect`, whose expansion cannot call a
        /// mutating method.
        private func ends(from start: Look, _ looks: [Look]) -> [Bool] {
            var watch = AutomationController.TurnWatch(isMidTurn: start.isMidTurn, episode: start.episode)
            return looks.map { watch.observe(isMidTurn: $0.isMidTurn, isTurnOver: $0.isTurnOver, episode: $0.episode) }
        }

        @Test func aTurnSeenRunningThenIdle_hasEnded() {
            let looks = [Look(isMidTurn: true, episode: "e2"), Look(episode: "e2")]
            #expect(ends(from: Look(episode: "e1"), looks) == [false, true])
        }

        @Test func aTurnBetweenTwoLooks_endsByItsFinishedEpisode() {
            #expect(ends(from: Look(episode: "e1"), [Look(isTurnOver: true, episode: "e2")]) == [true])
        }

        @Test func anAgentsFirstIdleReport_isNoEndOfATurn() {
            #expect(ends(from: Look(), [Look(episode: "e1")]) == [false])
            #expect(ends(from: Look(episode: "e1"), [Look(episode: "e2")]) == [false])
        }

        @Test func anAgentsFirstFinishedReport_isNoEndOfATurn() {
            // A restored pane's record, or an agent's first report, arriving as
            // "finished" after the wait began says nothing of a turn it saw.
            #expect(ends(from: Look(), [Look(isTurnOver: true, episode: "e1")]) == [false])
            #expect(ends(from: Look(), [Look(isMidTurn: true, episode: "e1"), Look(isTurnOver: true, episode: "e1")]) == [false, true])
        }

        @Test func anEpisodeThatStays_hasNotEnded() {
            #expect(ends(from: Look(isTurnOver: true, episode: "e1"), [Look(isTurnOver: true, episode: "e1")]) == [false])
        }

        @Test func aTurnRunningWhenTheWaitStarts_endsWhenItStops() {
            let looks = [Look(isMidTurn: true, episode: "e1"), Look(episode: "e1")]
            #expect(ends(from: Look(isMidTurn: true, episode: "e1"), looks) == [false, true])
        }
    }

    struct AutomationSettingsTests {
        @Test func aKnownSetting_isReadAndChanged() throws {
            let settings = WeirSettings()
            #expect(try AutomationSettings.value(at: "font.size", in: settings) == .int(13))

            let changed = try AutomationSettings.setting(.string("dark"), at: "appearance.colorScheme", in: settings)

            #expect(changed.appearance.colorScheme == .dark)
            #expect(try AutomationSettings.value(at: "appearance.colorScheme", in: changed) == .string("dark"))
        }

        @Test func anOptionalSettingLeftUnset_readsAsNullAndCanBeSet() throws {
            let settings = WeirSettings()
            #expect(try AutomationSettings.value(at: "font.family", in: settings) == .null)

            let changed = try AutomationSettings.setting(.string("Menlo"), at: "font.family", in: settings)

            #expect(changed.font.family == "Menlo")
        }

        @Test func aValueTheAppWouldNotRead_isRefused() {
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(.string("big"), at: "font.size", in: WeirSettings())
            }
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(.string("purple"), at: "appearance.colorScheme", in: WeirSettings())
            }
        }

        @Test func aKeyboardOverride_isSetAndAnUnknownKeyInsideItRefused() throws {
            // Keys no action holds by default, which the Keyboard pane takes.
            let shortcut = StoredShortcut(key: "d", modifiers: [.command, .control, .option])
            let value = try JSONDecoder().decode(WeirJSONValue.self, from: JSONEncoder().encode(shortcut))
            let changed = try AutomationSettings.setting(value, at: "keyboard.overrides.splitRight", in: WeirSettings())
            #expect(changed.keyboard.overrides["splitRight"] == shortcut)

            guard case var .object(fields) = value else {
                Issue.record("a shortcut encodes as an object")
                return
            }
            fields["extra"] = .int(1)
            // `StoredShortcut` decodes without keeping unknown fields, so the
            // extra key would be dropped silently; the read-back refuses it.
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(.object(fields), at: "keyboard.overrides.splitRight", in: WeirSettings())
            }
        }

        @Test func aBindingAnotherActionHolds_isRefusedAsTheKeyboardPaneRefusesIt() throws {
            // ⌘T is New Tab's.
            let value = try JSONDecoder().decode(
                WeirJSONValue.self,
                from: JSONEncoder().encode(StoredShortcut(key: "t", modifiers: [.command]))
            )
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(value, at: "keyboard.overrides.splitRight", in: WeirSettings())
            }
        }

        @Test func aQuickTerminalHotKeyWithoutCommandOrControl_isRefused() throws {
            let value = try JSONDecoder().decode(
                WeirJSONValue.self,
                from: JSONEncoder().encode(StoredShortcut(key: "k", modifiers: [.option]))
            )
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(value, at: "quickTerminal.hotKey", in: WeirSettings())
            }
            let taken = try JSONDecoder().decode(
                WeirJSONValue.self,
                from: JSONEncoder().encode(StoredShortcut(key: "k", modifiers: [.command, .control]))
            )
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(taken, at: "quickTerminal.hotKey", in: WeirSettings()) { _ in true }
            }
        }

        @Test func aNarrowerTurnRetention_isRefused_andAWiderOneTaken() throws {
            let settings = WeirSettings()
            let days = settings.advanced.turnRetention.days
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(.int(days - 1), at: "advanced.turnRetention.days", in: settings)
            }
            let wider = try AutomationSettings.setting(.int(days + 1), at: "advanced.turnRetention.days", in: settings)
            #expect(wider.advanced.turnRetention.days == days + 1)
        }

        @Test func anExternalDiffCommand_isKeptWithItsSmartQuotesMadePlain() throws {
            let changed = try AutomationSettings.setting(
                .string("difft \u{201C}a b\u{201D}"),
                at: "review.externalDiffCommand",
                in: WeirSettings()
            )
            #expect(changed.review.externalDiffCommand == "difft \"a b\"")
        }

        @Test func anotherSetting_leavesTheExternalDiffCommandAsTheFileHasIt() throws {
            var settings = WeirSettings()
            settings.review.externalDiffCommand = "difft \u{201C}a\u{201D}"
            let changed = try AutomationSettings.setting(.int(14), at: "font.size", in: settings)
            #expect(changed.review.externalDiffCommand == "difft \u{201C}a\u{201D}")
        }

        @Test func aChoiceThatFallsBackToItsDefault_isReadAndSet() throws {
            // `ConfirmPolicy` reads a value it does not recognize as its
            // default, so a probe there never stays as written.
            #expect(try AutomationSettings.value(at: "confirmations.closePane", in: WeirSettings()) == .string("dirtyOnly"))

            let changed = try AutomationSettings.setting(.string("never"), at: "confirmations.closePane", in: WeirSettings())
            #expect(changed.confirmations.closePane == .never)

            // A value it would fall back from is still refused, by the read-back.
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(.string("nevr"), at: "confirmations.closePane", in: WeirSettings())
            }
        }

        @Test func aDoubleSetting_takesAFractionAndAWholeNumber() throws {
            let half = try AutomationSettings.setting(.double(15.5), at: "font.size", in: WeirSettings())
            #expect(half.font.size == 15.5)
            let whole = try AutomationSettings.setting(.int(16), at: "font.size", in: WeirSettings())
            #expect(whole.font.size == 16)
        }

        @Test func anUnknownFieldAlreadyInTheFile_isNeitherReadNorSet() {
            // A newer build's field, kept as the file carried it.
            var settings = WeirSettings()
            settings.font.unknownFields["futureSize"] = .int(1)
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.value(at: "font.futureSize", in: settings)
            }
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.setting(.int(2), at: "font.futureSize", in: settings)
            }
        }

        @Test func aKeyInsideAnOverrideThatDoesNotExist_isNotRead() throws {
            var settings = WeirSettings()
            settings.keyboard.overrides["splitRight"] = StoredShortcut(key: "d", modifiers: [.command])
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.value(at: "keyboard.overrides.splitRight.typo", in: settings)
            }
            #expect(try AutomationSettings.value(at: "keyboard.overrides.splitRight.key", in: settings) == .string("d"))
        }

        @Test func aKeyThisBuildDoesNotKnow_isRefused() {
            for key in ["font.sise", "nonsense", "font.size.inner", "schemaVersion", "", "font..size"] {
                #expect(throws: AutomationSettings.Failure.self) {
                    try AutomationSettings.setting(.int(1), at: key, in: WeirSettings())
                }
            }
            #expect(throws: AutomationSettings.Failure.self) {
                try AutomationSettings.value(at: "font.sise", in: WeirSettings())
            }
        }
    }

    struct AutomationServerTests {
        private static let token = String(repeating: "ab", count: 32)

        @Test(.timeLimit(.minutes(1)))
        func aRequestBeforeHello_isRefusedAndTheConnectionClosed() throws {
            try withServer { path in
                let client = try LineClient(path: path)
                try client.send(#"{"id":"1","op":"state"}"#)
                #expect(try client.readReply()?.status == .failed)
                #expect(try client.readReply() == nil)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func aLineThatIsNoRequestBeforeHello_closesTheConnection() throws {
            try withServer { path in
                let client = try LineClient(path: path)
                try client.send("not json")
                #expect(try client.readReply()?.status == .failed)
                #expect(try client.readReply() == nil)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func aWrongToken_isRefused() throws {
            try withServer { path in
                let client = try LineClient(path: path)
                try client.send(Self.hello(token: "wrong"))
                #expect(try client.readReply()?.status == .failed)
                #expect(try client.readReply() == nil)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func afterHello_requestsReachTheHandler() throws {
            try withServer { path in
                let client = try LineClient(path: path)
                try client.send(Self.hello(token: Self.token))
                #expect(try client.readReply()?.status == .done)
                try client.send(#"{"id":"7","op":"state"}"#)
                let reply = try #require(try client.readReply())
                #expect(reply.id == "7")
                #expect(reply.reason == "handled state")
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func aLinePastTheLimit_closesTheConnection() throws {
            try withServer { path in
                let client = try LineClient(path: path)
                try client.send(Self.hello(token: Self.token))
                _ = try client.readReply()
                try client.send(String(repeating: "x", count: AutomationProtocol.maxMessageBytes + 1024))
                #expect(try client.readReply() == nil)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func connectionsPastTheLimit_areClosed() throws {
            try withServer { path in
                let open = try (0..<AutomationProtocol.maxConnections).map { _ in try LineClient(path: path) }
                for client in open {
                    try client.send(Self.hello(token: Self.token))
                    #expect(try client.readReply()?.status == .done)
                }
                let extra = try LineClient(path: path)
                #expect(try extra.readReply() == nil)
            }
        }

        @Test func theSocket_isOnlyTheOwners() throws {
            try withServer { path in
                #expect(mode(of: URL(fileURLWithPath: path)) == 0o600)
            }
        }

        private static func hello(token: String) -> String {
            #"{"id":"1","op":"hello","token":"\#(token)","protocol":"\#(AutomationProtocol.marker)"}"#
        }

        private func withServer(_ body: (String) throws -> Void) throws {
            try withShortTempDir { base in
                let path = base.appendingPathComponent("s").path
                let server = AutomationServer(token: Self.token) { request in
                    AutomationReply(id: request.id, status: .done, reason: "handled \(request.op.rawValue)")
                }
                try server.start(at: path)
                defer { server.stop() }
                try body(path)
            }
        }
    }

    /// A blocking client of one line per message, with a read timeout so a test
    /// that expects a reply fails rather than hangs.
    private final class LineClient {
        private let fd: Int32
        private var buffer = Data()

        init(path: String) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: path.utf8)
                raw[path.utf8.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        }

        deinit {
            close(fd)
        }

        func send(_ line: String) throws {
            let data = Array((line + "\n").utf8)
            var offset = 0
            while offset < data.count {
                let written = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                // The server may close a connection mid-line; the read that
                // follows reports it.
                guard written > 0 else { return }
                offset += written
            }
        }

        /// The next reply, or `nil` once the server has closed the connection.
        func readReply() throws -> AutomationReply? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return try JSONDecoder().decode(AutomationReply.self, from: Data(line))
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                if count == 0 || (count < 0 && errno == ECONNRESET) {
                    return nil
                }
                guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
    }

    private func mode(of url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o777
    }

#endif
