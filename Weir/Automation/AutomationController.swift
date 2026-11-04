// AutomationController.swift
// Weir — answers the verification channel's requests on the main actor.

#if DEBUG && WEIR_AUTOMATION

    import AppKit
    import Foundation
    import WeirDomain

    /// Resolves each request's target, checks it, and acts through the code the
    /// app's own controls call. Everything here runs on the main actor; the
    /// socket side hands over values and gets values back.
    @MainActor
    final class AutomationController {
        private weak var state: AppState?
        let runID: String
        private var revision = 0
        /// The pane's last typing request, which the next one waits behind, so
        /// two requests never interleave their text and their Returns.
        private var paneTails: [UUID: Task<Void, Never>] = [:]
        /// The unsent text the channel itself left in a pane, which only its
        /// `submit` may send. Kept with the pane's generation and its last
        /// input from outside the channel, so the record lapses as soon as
        /// the person types, sends, or drops anything there, or the view is
        /// made again.
        private var channelDrafts: [UUID: ChannelDraft] = [:]
        /// Set by `quit`, and read by the quit confirmation
        /// (`AppState.shouldAllowQuit`), which then asks nothing: the caller
        /// already decided, and the alert would come up above the person's
        /// other apps in a run that is meant to stay behind them.
        private(set) var isQuitting = false

        /// Whether a paste request still waits for its paste to land.
        @MainActor
        private final class PasteWait {
            var isOpen = true
        }

        struct ChannelDraft: Equatable {
            let generation: Int
            let lastKeyInputAt: Date?
        }

        init(state: AppState, runID: String) {
            self.state = state
            self.runID = runID
        }

        func handle(_ request: AutomationRequest) async -> AutomationReply {
            guard let state else { return .failed(request.id, "the app is shutting down") }
            // A request reaches the main actor after the socket queue took it;
            // a caller that left in between has it dropped before it acts.
            // Operations that wait look again before each change they make.
            if Task.isCancelled {
                return AutomationReply(id: request.id, status: .cancelled)
            }
            var reply: AutomationReply
            switch request.op {
            case .hello:
                reply = AutomationReply(id: request.id, status: .done)
            case .state:
                reply = AutomationReply(id: request.id, status: .done)
                reply.state = snapshot(of: state)
            case .open:
                reply = await open(request, in: state)
            case .typeLine, .paste, .submit:
                reply = await type(request, in: state)
            case .wait:
                reply = await wait(request, in: state)
            case .capture:
                reply = await capture(request, in: state)
            case .commands, .command:
                reply = command(request, in: state)
            case .setting:
                reply = setting(request, in: state)
            case .quit:
                reply = quit(request, in: state)
            case .focus:
                reply = focus(request, in: state)
            }
            reply.revision = revision
            return reply
        }

        // MARK: - state

        func snapshot(of state: AppState) -> AutomationSnapshot {
            let session = state.session
            let registry = state.windowRegistry
            let projects = session.projects.map {
                AutomationSnapshot.Project(id: $0.id, name: $0.name, path: $0.rootURL.path)
            }
            let windows = registry.windows.map { window -> AutomationSnapshot.Window in
                let selection = window.selection
                let tabs = session.tabs
                    .filter { $0.container == selection.activeContainerID }
                    .map { tab in
                        AutomationSnapshot.Tab(
                            id: tab.id,
                            title: tab.title,
                            isSelected: tab.id == selection.activeTabID,
                            panes: tab.splitTree.allLeafIDs().map { pane(of: $0, in: state) }
                        )
                    }
                return AutomationSnapshot.Window(
                    id: window.id.rawValue,
                    project: selection.shownProjectID,
                    isKey: registry.keyWindowID == window.id,
                    isOnScreen: registry.presenter?.isOnScreen(window.id) ?? false,
                    openLayers: openLayers(of: window, in: state),
                    dropdown: window.titleBarMenu.map { Self.name(of: $0.menu) },
                    hasSheet: window.hasAttachedSheet,
                    isSidebarShown: window.isSidebarShown,
                    areIconBarsHidden: window.areRailsHidden,
                    isChangesPanelShown: selection.showsChangesPanel,
                    review: window.review.map {
                        AutomationSnapshot.Review(pane: $0.agentPaneID, scope: Self.name(of: $0.selection), isShown: $0.isShown)
                    },
                    keyboard: keyboard(of: window, in: state),
                    tabs: tabs
                )
            }
            return AutomationSnapshot(run: runID, projects: projects, windows: windows, settings: settingsSnapshot())
        }

        private func pane(of id: UUID, in state: AppState) -> AutomationSnapshot.Pane {
            let view = state.registry.view(for: id)
            let runtime = state.attention.headerRuntime(inPane: id)
            return AutomationSnapshot.Pane(
                ref: AutomationPaneRef(run: runID, id: id, generation: state.registry.generations[id] ?? 0),
                foregroundProcess: view?.foregroundProcessName,
                agent: runtime?.kind.rawValue,
                agentState: runtime.map { String(describing: $0.badge.state) },
                agentSession: runtime?.sessionID,
                isMidTurn: runtime?.badge.state.isMidTurn ?? false,
                hasUnsubmittedInput: view?.hasUnsubmittedInput ?? false,
                isInTmux: Self.isInTmux(id, view: view, in: state),
                hasKeyboard: view.map { $0.window?.firstResponder === $0 } ?? false
            )
        }

        // MARK: - open

        /// Opens a layer other than the review through the palette row of the
        /// action that opens it, as `command` runs a row: a layer whose row is
        /// off now (the plan usage panel with the icon bars hidden) is refused
        /// at once, rather than sent to a window that cannot show it.
        private func open(_ request: AutomationRequest, in state: AppState) async -> AutomationReply {
            guard let layer = request.layer else { return .failed(request.id, "open needs a layer") }
            guard let action = Self.action(opening: layer) else { return openReview(request, state: state) }
            guard let window = resolveWindow(request.window, in: state) else {
                return .failed(request.id, "no such window")
            }
            let step = Self.openStep(
                action,
                isOpen: openLayers(of: window, in: state).contains(layer),
                items: { state.paletteItems(in: window) }
            )
            switch step {
            case .alreadyOpen:
                return AutomationReply(id: request.id, status: .done, reason: "already open")
            case let .refused(reason):
                return .failed(request.id, reason)
            case let .run(item):
                if let failure = send(item, request: request, in: window) {
                    return failure
                }
                return AutomationReply(id: request.id, status: .done, reason: "sent; wait for layerOpen")
            }
        }

        /// Review of the named pane's uncommitted changes, opened for that pane
        /// rather than for whatever the window has selected, so no other
        /// selection can come between. Another pane's review already up is not
        /// this one. Opened in the window that shows the pane: review opens in
        /// a window's selected tab, so another window would get a review of a
        /// pane it does not show.
        private func openReview(_ request: AutomationRequest, state: AppState) -> AutomationReply {
            guard let ref = request.pane else { return .failed(request.id, "review needs a pane") }
            if let refusal = refusal(for: ref, in: state) {
                return .failed(request.id, refusal)
            }
            guard let window = reviewWindow(for: request, paneID: ref.id, in: state) else {
                return .failed(request.id, "the pane is not shown in that window")
            }
            if Self.isReviewShown(window.review, for: ref.id) {
                return AutomationReply(id: request.id, status: .done, reason: "already open")
            }
            revision += 1
            Task {
                await ReviewTabActions.open(.uncommitted, agentPaneID: ref.id, window: window, stores: state.reviewTabStores)
            }
            return AutomationReply(id: request.id, status: .done, reason: "started; wait for layerOpen")
        }

        /// The window to open or watch a pane's review in: the one the caller
        /// named, if it shows the pane, or else the one that shows it.
        private func reviewWindow(for request: AutomationRequest, paneID: UUID, in state: AppState) -> ProjectWindowState? {
            let showing = state.session.window(showingPane: paneID)
            guard let named = request.window else {
                return showing.flatMap { state.windowRegistry.window($0) }
            }
            let window = state.windowRegistry.window(WindowID(named))
            let isShown = window.map { state.session.drawnTab(in: $0.id)?.splitTree.allLeafIDs().contains(paneID) == true } ?? false
            return isShown ? window : nil
        }

        /// Whether `review` is shown and is the one for `paneID`.
        static func isReviewShown(_ review: ReviewTabState?, for paneID: UUID) -> Bool {
            review?.isShown == true && review?.agentPaneID == paneID
        }

        // MARK: - typing

        private func type(_ request: AutomationRequest, in state: AppState) async -> AutomationReply {
            guard let ref = request.pane else { return .failed(request.id, "\(request.op.rawValue) needs a pane") }
            guard let expect = request.expect else {
                return .failed(request.id, "\(request.op.rawValue) needs expect.process: typing into a pane is running code")
            }
            let text = request.text ?? ""
            if let refusal = Self.textRefusal(for: request.op, text: text) {
                return .failed(request.id, refusal)
            }
            let previous = paneTails[ref.id]
            let work = Task { @MainActor [weak self] () -> AutomationReply in
                await previous?.value
                guard let self else { return .failed(request.id, "the channel stopped") }
                return await self.performTyping(request, ref: ref, expect: expect, text: text, in: state)
            }
            paneTails[ref.id] = Task { _ = await work.value }
            return await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
        }

        private func performTyping(
            _ request: AutomationRequest,
            ref: AutomationPaneRef,
            expect: AutomationExpectation,
            text: String,
            in state: AppState
        ) async -> AutomationReply {
            if Task.isCancelled {
                return AutomationReply(id: request.id, status: .cancelled)
            }
            // A Return the app scheduled for its own command lands first, so
            // ours never arrives in the middle of it.
            await state.registry.view(for: ref.id)?.commandSubmit.settled()
            // Looked at again after the wait: a caller that went away while
            // it waited has its request dropped before anything is written.
            if Task.isCancelled {
                return AutomationReply(id: request.id, status: .cancelled)
            }
            if let refusal = typingRefusal(for: ref, expect: expect, op: request.op, in: state) {
                return .failed(request.id, refusal)
            }
            guard let view = state.registry.view(for: ref.id) else { return .failed(request.id, "the pane has no terminal") }
            switch request.op {
            case .paste:
                return await paste(text, into: view, ref: ref, request: request)
            case .submit:
                guard sendReturn(to: view, ref: ref) else { return .failed(request.id, "the pane has no terminal") }
                return AutomationReply(id: request.id, status: .done, submitted: true)
            default:
                break
            }
            view.noteTypedOwnCommand(text)
            guard view.commitText(text) else { return .failed(request.id, "the pane has no terminal") }
            // Marked as a draft, as the person's typing is, so the app's own
            // commands (the prompt cache panel's) see unsent text and do not
            // type into it while the Return waits or after a `--no-submit`.
            view.noteDraft(true)
            channelDrafts[ref.id] = ChannelDraft(generation: ref.generation, lastKeyInputAt: view.lastKeyInputAt)
            revision += 1
            guard request.submit ?? true else {
                return AutomationReply(id: request.id, status: .done, submitted: false)
            }
            // Apart from the text, as `typeAgentCommand(_:)` sends it, so the
            // agent reads typed input rather than one pasted burst.
            do {
                try await Task.sleep(for: SurfaceView.commandSubmitDelay)
            } catch {
                return AutomationReply(id: request.id, status: .cancelled, reason: "typed, not submitted", submitted: false)
            }
            // Checked again: the agent can exit, or the person can start typing,
            // while the Return waits. A process that exits after this check can
            // still get the Return; the reply says what was checked, not more.
            if let refusal = typingRefusal(for: ref, expect: expect, op: .submit, in: state) {
                return AutomationReply(id: request.id, status: .failed, reason: "typed, not submitted: \(refusal)", submitted: false)
            }
            // The person's own Return or ⌃C since then sent or dropped the line;
            // a second Return would send an empty one.
            guard let current = state.registry.view(for: ref.id), isChannelDraft(in: current, ref: ref) else {
                return AutomationReply(
                    id: request.id,
                    status: .failed,
                    reason: "typed, not submitted: the line was sent or changed from the keyboard",
                    submitted: false
                )
            }
            let isSent = state.registry.view(for: ref.id).map { sendReturn(to: $0, ref: ref) } ?? false
            return AutomationReply(id: request.id, status: isSent ? .done : .failed, submitted: isSent)
        }

        /// Sends Return, and with it the channel's own unsent text, as a
        /// Return the person presses does: the draft mark and the record go.
        private func sendReturn(to view: SurfaceView, ref: AutomationPaneRef) -> Bool {
            guard view.automationSendReturn() else { return false }
            if channelDrafts.removeValue(forKey: ref.id) != nil {
                view.noteDraft(false)
            }
            revision += 1
            return true
        }

        /// Pastes through the path review uses, Ghostty's own paste action, so a
        /// program that did not ask for bracketed paste meets the paste
        /// confirmation instead of running each line. `ghostty_surface_text`
        /// would skip that confirmation (`SurfaceView+Review.swift`).
        ///
        /// The paste carries a receipt, as a review insert's does, whose
        /// settlement says what became of it: it reached the terminal, it was
        /// refused, or it waits at the paste confirmation for an answer. Only
        /// text that reached the terminal is recorded as the channel's, and
        /// only then is the reply `done`.
        private func paste(
            _ text: String,
            into view: SurfaceView,
            ref: AutomationPaneRef,
            request: AutomationRequest
        ) async -> AutomationReply {
            // The text is recorded as the channel's as it lands, inside the
            // clipboard read that delivers it, so no key of the person's can be
            // taken for part of it. Only while this request waits: a paste the
            // person lets through at the confirmation later is theirs to send.
            let waiting = PasteWait()
            let generation = ref.generation
            let settlement = ReviewPasteSettlement { [weak self, weak view] wasDelivered in
                guard wasDelivered, waiting.isOpen, let self, let view else { return }
                channelDrafts[ref.id] = ChannelDraft(generation: generation, lastKeyInputAt: view.lastKeyInputAt)
            }
            defer { waiting.isOpen = false }
            // The root and comments name what a review insert marks once its
            // paste lands; the channel's paste marks nothing.
            let receipt = ReviewPasteReceipt(root: URL(fileURLWithPath: "/"), commentIDs: [], settlement: settlement)
            do {
                try view.deliverReviewText(ReviewPrompt(validating: text), receipt: receipt)
            } catch {
                return .failed(request.id, "the paste was refused: \(error.localizedDescription)")
            }
            revision += 1
            let deadline = ContinuousClock.now + .seconds(1)
            while settlement.wasDelivered == nil, ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return AutomationReply(id: request.id, status: .cancelled, reason: "pasted, not recorded as the channel's")
                }
            }
            switch settlement.wasDelivered {
            case nil:
                return AutomationReply(
                    id: request.id,
                    status: .notObservable,
                    reason: "held by the paste confirmation, which waits for the person; submit will refuse it"
                )
            case false?:
                return .failed(request.id, "the paste did not reach the terminal")
            case true?:
                return AutomationReply(id: request.id, status: .done, reason: "pasted")
            }
        }

        static func textRefusal(for op: AutomationRequest.Operation, text: String) -> String? {
            switch op {
            case .submit:
                return text.isEmpty ? nil : "submit takes no text"
            case .typeLine:
                if text.isEmpty {
                    return "typeLine needs text"
                }
                if text.unicodeScalars.contains(where: \.isTypedControl) {
                    return "typeLine takes one line without control characters; use paste for several lines"
                }
                return nil
            case .paste:
                return text.isEmpty ? "paste needs text" : nil
            default:
                return nil
            }
        }

        /// What the channel reads of a pane before typing into it, as values,
        /// so the rules can be tested without a terminal.
        struct PaneFacts: Equatable {
            var isSameRun: Bool
            var hasTerminal: Bool
            var generation: Int?
            var isInTmux: Bool
            var processNames: [String]
            var agentSession: String?
            var hasUnsubmittedInput: Bool
            /// The unsent text is the channel's own, typed or pasted.
            var isChannelDraft = false
        }

        static func typingRefusal(
            _ facts: PaneFacts,
            ref: AutomationPaneRef,
            expect: AutomationExpectation,
            op: AutomationRequest.Operation = .typeLine
        ) -> String? {
            if let refusal = refusal(facts, ref: ref) {
                return refusal
            }
            if facts.isInTmux {
                return "the pane runs tmux, whose client the channel does not resolve"
            }
            guard facts.processNames.contains(expect.process) else {
                return "the process in front is \(facts.processNames.first ?? "unknown"), not \(expect.process)"
            }
            if let session = expect.session, facts.agentSession != session {
                return "the pane's agent session is not \(session)"
            }
            // Only `submit` may send the channel's own paste; anything else
            // would type into it.
            if facts.hasUnsubmittedInput, facts.isChannelDraft, op != .submit {
                return "the channel's own unsent text is there; submit it first"
            }
            if facts.hasUnsubmittedInput, !(op == .submit && facts.isChannelDraft) {
                return "the pane holds text the person has not sent"
            }
            return nil
        }

        static func refusal(_ facts: PaneFacts, ref: AutomationPaneRef) -> String? {
            guard facts.isSameRun else { return "the pane was read in another run" }
            guard facts.hasTerminal else { return "no such pane" }
            guard facts.generation == ref.generation else {
                return "the pane's terminal was made again since it was read"
            }
            return nil
        }

        private func facts(of ref: AutomationPaneRef, in state: AppState) -> PaneFacts {
            let view = state.registry.view(for: ref.id)
            return PaneFacts(
                isSameRun: ref.run == runID,
                hasTerminal: view != nil,
                generation: state.registry.generations[ref.id],
                isInTmux: Self.isInTmux(ref.id, view: view, in: state),
                processNames: [view?.foregroundProcessName].compactMap(\.self) + (view?.foregroundGroupProcessNames ?? []),
                agentSession: state.attention.headerRuntime(inPane: ref.id)?.sessionID,
                hasUnsubmittedInput: view?.hasUnsubmittedInput ?? false,
                isChannelDraft: view.map { isChannelDraft(in: $0, ref: ref) } ?? false
            )
        }

        /// Whether the pane runs tmux. The process in front says so at once;
        /// the tmux probe matches a client to the pane only on its next pass,
        /// so a tmux just started would read as a plain shell until then.
        private static func isInTmux(_ paneID: UUID, view: SurfaceView?, in state: AppState) -> Bool {
            if state.tmuxPresence.client(inPane: paneID) != nil {
                return true
            }
            let names = [view?.foregroundProcessName].compactMap(\.self) + (view?.foregroundGroupProcessNames ?? [])
            return names.contains("tmux")
        }

        private func isChannelDraft(in view: SurfaceView, ref: AutomationPaneRef) -> Bool {
            guard let draft = channelDrafts[ref.id] else { return false }
            return draft.generation == ref.generation && draft.lastKeyInputAt == view.lastKeyInputAt
        }

        private func typingRefusal(
            for ref: AutomationPaneRef,
            expect: AutomationExpectation,
            op: AutomationRequest.Operation = .typeLine,
            in state: AppState
        ) -> String? {
            Self.typingRefusal(facts(of: ref, in: state), ref: ref, expect: expect, op: op)
        }

        private func refusal(for ref: AutomationPaneRef, in state: AppState) -> String? {
            Self.refusal(facts(of: ref, in: state), ref: ref)
        }

        // MARK: - wait

        private func wait(_ request: AutomationRequest, in state: AppState) async -> AutomationReply {
            guard let outcome = request.until else { return .failed(request.id, "wait needs until") }
            // Clamped before the conversion: a huge or negative number from the
            // caller would otherwise trap in `Int(_:)`.
            let seconds = min(max(request.timeout ?? 10, 0), 30)
            let deadline = ContinuousClock.now + min(.milliseconds(Int(seconds * 1000)), AutomationProtocol.maxWait)
            var turn: TurnWatch?
            while true {
                if Task.isCancelled {
                    return AutomationReply(id: request.id, status: .cancelled)
                }
                if let reply = look(for: outcome, of: request, turn: &turn, in: state) {
                    return reply
                }
                guard ContinuousClock.now < deadline else { return AutomationReply(id: request.id, status: .timedOut) }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return AutomationReply(id: request.id, status: .cancelled)
                }
            }
        }

        /// What a `turnEnded` wait has seen of the pane's agent. A turn counts
        /// once it was seen running and is no longer, or once the agent's state
        /// episode changed to one that ends a turn (finished, or an error): a
        /// turn that started and ended between two looks still leaves such an
        /// episode. An agent's first report, idle as it starts or as Codex's
        /// first hook says, changes the episode without ending anything, so it
        /// does not count. A run waiting on an answer is mid-turn, so a wait
        /// over an approval times out.
        struct TurnWatch: Equatable {
            let startEpisode: String?
            var hasSeenMidTurn = false

            init(isMidTurn: Bool, episode: String?) {
                startEpisode = episode
                hasSeenMidTurn = isMidTurn
            }

            /// Records a look and says whether the turn has ended.
            mutating func observe(isMidTurn: Bool, isTurnOver: Bool, episode: String?) -> Bool {
                hasSeenMidTurn = hasSeenMidTurn || isMidTurn
                guard !isMidTurn else { return false }
                // The episode rule needs one known at the start: an agent's
                // first report after the wait began, a restored pane's
                // "finished" among them, says nothing about a turn the wait saw
                // start.
                guard let startEpisode else { return hasSeenMidTurn }
                return hasSeenMidTurn || (isTurnOver && episode != nil && episode != startEpisode)
            }
        }

        /// The reply `outcome` has now, or `nil` while it has not come.
        private func look(
            for outcome: AutomationOutcome,
            of request: AutomationRequest,
            turn: inout TurnWatch?,
            in state: AppState
        ) -> AutomationReply? {
            switch outcome {
            case .layerOpen:
                guard let layer = request.layer else { return .failed(request.id, "layerOpen needs a layer") }
                // Review of a named pane is open only when it is that pane's:
                // another pane's review, already up, is not what was asked.
                if layer == .review {
                    guard let ref = request.pane else { return .failed(request.id, "review needs a pane") }
                    if let refusal = refusal(for: ref, in: state) {
                        return AutomationReply(id: request.id, status: .notObservable, reason: refusal)
                    }
                    guard let window = reviewWindow(for: request, paneID: ref.id, in: state) else {
                        return AutomationReply(id: request.id, status: .notObservable, reason: "the pane is not shown in that window")
                    }
                    return Self.isReviewShown(window.review, for: ref.id) ? AutomationReply(id: request.id, status: .done) : nil
                }
                guard let window = resolveWindow(request.window, in: state) else {
                    return AutomationReply(id: request.id, status: .notObservable, reason: "the window is gone")
                }
                return openLayers(of: window, in: state).contains(layer) ? AutomationReply(id: request.id, status: .done) : nil
            case .turnEnded:
                guard let ref = request.pane else { return .failed(request.id, "turnEnded needs a pane") }
                if let refusal = refusal(for: ref, in: state) {
                    return AutomationReply(id: request.id, status: .notObservable, reason: refusal)
                }
                let runtime = state.attention.headerRuntime(inPane: ref.id)
                let isMidTurn = runtime?.badge.state.isMidTurn ?? false
                let episode = runtime?.stateEpisodeToken
                guard var watch = turn else {
                    turn = TurnWatch(isMidTurn: isMidTurn, episode: episode)
                    return nil
                }
                let isTurnOver = runtime.map { $0.badge.state == .finished || $0.badge.state == .error } ?? false
                let hasEnded = watch.observe(isMidTurn: isMidTurn, isTurnOver: isTurnOver, episode: episode)
                turn = watch
                return hasEnded ? AutomationReply(id: request.id, status: .done) : nil
            }
        }

        // MARK: - commands and settings

        /// Runs a command palette row, the way the palette runs it, in place of
        /// the menu item or shortcut that runs the same action: a standard menu
        /// opens only in front, and the palette's rows are the app's commands.
        /// A row the palette shows disabled is refused, as its menu item would
        /// be, but for the actions `ShortcutAvailability` splits by surface.
        /// `commands` lists the rows with their enabled state.
        private func command(_ request: AutomationRequest, in state: AppState) -> AutomationReply {
            guard let window = resolveWindow(request.window, in: state) else { return .failed(request.id, "no such window") }
            let items = state.paletteItems(in: window)
            if request.op == .commands {
                var reply = AutomationReply(id: request.id, status: .done)
                reply.commands = items.map { AutomationCommandInfo(id: $0.id, title: $0.title, isEnabled: $0.isEnabled) }
                return reply
            }
            guard let name = request.name, !name.isEmpty else { return .failed(request.id, "command needs a name") }
            let id = name.contains(".") ? name : "shortcut.\(name)"
            switch Self.row(id, among: items) {
            case let .refused(reason):
                return .failed(request.id, reason)
            case let .runnable(item):
                if let failure = send(item, request: request, in: window) {
                    return failure
                }
                return AutomationReply(id: request.id, status: .done, reason: "ran \(id)")
            }
        }

        /// Runs the palette row `item` in `window`, as the palette runs a
        /// committed row. The reply when it did not run: a canceled request,
        /// or no view that took it; `nil` when it ran.
        private func send(_ item: CommandPaletteItem, request: AutomationRequest, in window: ProjectWindowState) -> AutomationReply? {
            if Task.isCancelled {
                return AutomationReply(id: request.id, status: .cancelled)
            }
            let execution = CommandPaletteExecution(action: item.action, windowID: window.id, opensInNewWindow: request.newWindow == true)
            guard window.commands.send(.runPaletteRow(execution)) else {
                return .failed(request.id, "no view of the window took the command")
            }
            revision += 1
            return nil
        }

        /// Reads or changes one setting by its key, through the settings store,
        /// as the Settings window's controls change it.
        private func setting(_ request: AutomationRequest, in state: AppState) -> AutomationReply {
            guard let key = request.key else { return .failed(request.id, "setting needs a key") }
            let store = state.settingsStore
            // JSON null and a missing value decode alike, so clearing an
            // optional setting is asked with `unset`.
            let value = request.unset == true ? .null : request.value
            do {
                if let value {
                    // Checked and normalized in full before the one assignment,
                    // so a refused value is never saved.
                    let hotKeyCenter = state.quickTerminalHotKeyCenter
                    store.settings = try AutomationSettings.setting(value, at: key, in: store.settings) { hotKeyCenter.isTakenBySystem($0) }
                    revision += 1
                }
                var reply = AutomationReply(id: request.id, status: .done)
                reply.value = try AutomationSettings.value(at: key, in: store.settings)
                return reply
            } catch {
                return .failed(request.id, error.localizedDescription)
            }
        }

        // MARK: - focus

        /// Gives the pane the keyboard within its window, as a click on it
        /// does, without bringing the app to the front. Keys that come from
        /// outside the channel, a person's or a test's, land in the pane that
        /// has it; the channel's own typing names its pane and needs none.
        ///
        /// It goes through the model, as ⌘J focuses a pane, so the selected tab,
        /// the tab's focused pane, and its zoom can change; that counts as a
        /// change the channel made. It never brings the window or the app
        /// forward.
        private func focus(_ request: AutomationRequest, in state: AppState) -> AutomationReply {
            guard let ref = request.pane else { return .failed(request.id, "focus needs a pane") }
            if let refusal = refusal(for: ref, in: state) {
                return .failed(request.id, refusal)
            }
            guard let view = state.registry.view(for: ref.id), let window = view.window,
                  let tabID = state.session.tabID(forPane: ref.id),
                  let windowID = state.session.window(showingPane: ref.id)
            else {
                return AutomationReply(id: request.id, status: .notObservable, reason: "the pane is not in a window")
            }
            // Through the model, as ⌘J focuses a pane: the window puts the
            // keyboard back on its tab's focused pane whenever it draws, so
            // a focus set on the view alone is taken back at once. `.repair`
            // keeps the window where it is, behind the person's.
            PaneActions.activateAndFocus(
                state.session,
                registry: state.registry,
                tabID: tabID,
                paneID: ref.id,
                in: windowID,
                intent: .repair
            )
            // Another view can refuse to give the keyboard up, or take it back
            // at once; the reply names it rather than claim a focus that did
            // not happen.
            guard window.firstResponder === view else {
                let holder = window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nothing"
                revision += 1
                return .failed(request.id, "the keyboard stayed with \(holder)")
            }
            revision += 1
            return AutomationReply(id: request.id, status: .done)
        }

        // MARK: - quit

        /// Ends the run the way Quit does, with the scrollback saved and the
        /// run folder removed, but without the confirmation, which is a native
        /// alert the channel cannot answer. Agents running in the run's panes
        /// would be ended with it, so that takes `force`; without it the reply
        /// says so and nothing quits.
        private func quit(_ request: AutomationRequest, in state: AppState) -> AutomationReply {
            if state.hasAgentAQuitWouldEnd(), request.force != true {
                return .failed(request.id, "agents are running in this run's panes; quit with force to end them")
            }
            isQuitting = true
            // A paste confirmation left up is a sheet on a window, and AppKit
            // does not finish quitting while it shows. Refusing it is the safe
            // answer: nothing is pasted, as when its pane closes.
            state.clipboardConfirmation.deny()
            // After the reply has gone out: the socket closes with the app.
            // Not tied to the request: once asked, the quit goes ahead even
            // if the caller leaves, so the pause's cancellation is ignored.
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.terminate(nil)
            }
            return AutomationReply(id: request.id, status: .done, reason: "quitting")
        }

        // MARK: - capture

        /// Hands back the window's number for `screencapture -l`, which the
        /// client runs: the client's terminal holds the Screen Recording grant,
        /// and Weir asking for its own would put a prompt in front of the
        /// person. The panes keep drawing while covered
        /// (`WindowRegistry.keepsOffScreenPanesDrawing`); the pause lets the
        /// last change reach the screen's copy of the window.
        private func capture(_ request: AutomationRequest, in state: AppState) async -> AutomationReply {
            if request.settings == true {
                guard let nsWindow = Self.settingsWindow() else {
                    return AutomationReply(id: request.id, status: .notObservable, reason: "Settings is not open")
                }
                return await capture(nsWindow, request: request) { Self.settingsWindow() }
            }
            guard let window = resolveWindow(request.window, in: state) else { return .failed(request.id, "no such window") }
            let registry = state.windowRegistry
            guard let nsWindow = registry.nsWindow(for: window.id) else {
                return AutomationReply(id: request.id, status: .notObservable, reason: "the window is not shown")
            }
            return await capture(nsWindow, request: request) { registry.nsWindow(for: window.id) }
        }

        /// `nsWindow`'s number once the last change has had time to reach the
        /// window server. `current` finds the window again after the pause.
        private func capture(
            _ nsWindow: NSWindow,
            request: AutomationRequest,
            current: () -> NSWindow?
        ) async -> AutomationReply {
            guard nsWindow.isVisible, !nsWindow.isMiniaturized else {
                return AutomationReply(id: request.id, status: .notObservable, reason: "the window is hidden or minimized")
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return AutomationReply(id: request.id, status: .cancelled)
            }
            // Looked at again: the window can close, hide, or be minimized
            // during the pause, and its number would then capture nothing.
            guard current() === nsWindow, nsWindow.isVisible, !nsWindow.isMiniaturized else {
                return AutomationReply(id: request.id, status: .notObservable, reason: "the window went away during the capture")
            }
            var reply = AutomationReply(id: request.id, status: .done)
            reply.windowNumber = nsWindow.windowNumber
            return reply
        }

        // MARK: - targets

        /// The window named by `id`, or the one commands act on when `id` is
        /// nil.
        private func resolveWindow(_ id: UUID?, in state: AppState) -> ProjectWindowState? {
            let registry = state.windowRegistry
            guard let id else { return registry.lastUsedWindow }
            return registry.window(WindowID(id))
        }
    }

#endif
