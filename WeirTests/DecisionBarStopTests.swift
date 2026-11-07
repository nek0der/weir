// DecisionBarStopTests.swift
// Weir — what an agent pane's decision bar says of a stopped agent: its menu, its resume, and the line once it is back.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct DecisionBarStopTests {
    private static let pane = UUID()

    @Test func aStoppedBar_offersItsMenu_butNotWhileResuming() {
        let item = AttentionItem.testStop(pane: Self.pane)
        let english = Locale(identifier: "en")
        let menu: [[DecisionBarModel.MoreItem]] = [[.showPartialChanges(item.id), .startNewConversation(item.id)]]
        let available = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .available])), locale: english)
        #expect(available.stopItem == item.id)
        #expect(available.fits(locale: english) == [.full, .folded, .minimal, .wordsOnly])
        for fit in [DecisionBarModel.Fit.full, .folded, .minimal] {
            let shape = available.shape(fit, locale: english)
            #expect(!shape.showsReview)
            #expect(shape.moreSections == menu)
            #expect(shape.usesShortLabels == (fit == .minimal))
        }
        #expect(available.shape(.wordsOnly, locale: english).moreSections.isEmpty)

        let unavailable = DecisionBarModel(content: .make(.init(items: [item])), locale: english)
        #expect(unavailable.stopItem == item.id)
        #expect(unavailable.primaryAction == nil)
        #expect(unavailable.shape(.full, locale: english).moreSections == menu)

        let resuming = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .resuming])), locale: english)
        #expect(resuming.stopItem == nil)
        #expect(resuming.shape(.full, locale: english).moreSections.isEmpty)
    }

    @Test func aPaneKeepsItsBar_whileAStopOfItsAgentWaits() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let window = ProjectWindowState(selection: session.primarySelection)
        let id = AttentionItemID.stop(EpisodeKey(origin: .runtime("stopped-run"), episodeToken: "exit"))
        var queue = AttentionQueue()
        queue.insert(
            id: id, kind: .stop(.processExited),
            subject: .runtime(id: "stopped-run", provider: .claude, paneID: pane, tabID: tab.id, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )

        for hasStop in [true, false] {
            if !hasStop {
                queue.remove(id)
            }
            #expect(DecisionBarModel.stoppedAgent(in: queue.items)?.provider == (hasStop ? .claude : nil))
            #expect(DecisionBarModel.hasBar(in: pane, runtimes: [], session: session, queue: queue) == hasStop)
            let model = DecisionBarModel(
                paneID: pane,
                sources: .init(session: session, window: window, queue: queue, runtimes: [], approvals: ApprovalLedger(), next: nil),
                locale: Locale(identifier: "en")
            )
            if hasStop {
                #expect(model?.stopItem == id)
                #expect(model?.text == "The process exited unexpectedly.")
            } else {
                #expect(model == nil)
            }
        }
    }

    @Test func theBar_offersTheResume_saysItIsResuming_andThatItIsBack() {
        let item = AttentionItem.testStop(pane: Self.pane)
        let english = Locale(identifier: "en")
        let available = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .available])),
            locale: english
        )
        #expect(available.primaryAction == .resume(item.id))
        #expect(available.text == "The process exited unexpectedly. The conversation is saved.")

        let failed = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .failed])), locale: english)
        #expect(failed.primaryAction == .resume(item.id))
        #expect(failed.text == "The process exited unexpectedly. Couldn’t resume the same conversation. Its terminal shows why.")
        let failedInJapanese = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .failed])),
            locale: Locale(identifier: "ja")
        )
        #expect(failedInJapanese.text == "プロセスが異常終了しました。同じ会話を再開できませんでした。理由はターミナルに表示されています。")

        let unavailable = DecisionBarModel(content: .make(.init(items: [item])), locale: english)
        #expect(unavailable.primaryAction == nil)
        #expect(unavailable.text == "The process exited unexpectedly.")

        let resuming = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .resuming])), locale: english)
        #expect(resuming.tag == "Resuming")
        #expect(resuming.text == "Loading the same conversation…")
        #expect(resuming.primaryAction == nil)

        let back = DecisionBarModel(content: .make(.init(done: .init(result: .resumed, next: nil))), locale: Locale(identifier: "ja"))
        #expect(back.text == "同じ会話を再開しました。続きの指示はターミナルで入力してください。")

        let japanese = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .available])),
            locale: Locale(identifier: "ja")
        )
        // Japanese sentences run on with no space, as the restore strip's
        // do; an agent's own words, in English, keep one after them.
        #expect(japanese.text == "プロセスが異常終了しました。会話は保存されています。")
        let agentsError = AttentionItem.testStop(pane: Self.pane, reason: .error("API Error: overloaded"))
        let agentsErrorInJapanese = DecisionBarModel(
            content: .make(.init(items: [agentsError], stopResumes: [agentsError.id: .available])),
            locale: Locale(identifier: "ja")
        )
        #expect(agentsErrorInJapanese.text == "API Error: overloaded 会話は保存されています。")

        let blocked = DecisionBarModel(content: .make(.init(items: [item], stopResumes: [item.id: .blocked(.draft)])), locale: english)
        #expect(blocked.primaryAction == nil)
        #expect(blocked
            .text == "The process exited unexpectedly. The conversation is saved. To resume it, clear the prompt with Control-C.")
    }

    @Test(arguments: [false, true])
    func aPendingResumeLine_showsOverUnreadOrIsDroppedWhenAStopRemains(hasStop: Bool) throws {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let registry = WindowRegistry(primary: session.primarySelection)
        let window = registry.primary
        let stop = AttentionItem.testStop(pane: pane)
        let unread = AttentionItem.testUnread(pane: pane)
        registry.noteRuns(
            [PaneRunLedger.Run.test("resumed", in: [pane], turn: nil, state: .idle)],
            endedStops: StopLedger.Ended(resumed: [.init(paneID: pane, window: window.id)])
        )
        let epoch = try #require(registry.epoch(inPane: pane))
        let shown = ProjectWindowState.ShownItem(item: stop, epoch: epoch)
        #expect(window.pendingDecisionBarDone == [pane: .resumed])
        #expect(window.decisionBarDone.isEmpty)

        let items = hasStop ? [stop, unread] : [unread]
        window.itemsChanged(
            .init(paneID: pane, items: items, lastShown: shown, epoch: epoch),
            isSelectedPane: true, isCurrent: { _ in true }
        )
        #expect(window.pendingDecisionBarDone.isEmpty)
        #expect(window.decisionBarDone == (hasStop ? [:] : [pane: .resumed]))

        if hasStop {
            window.itemsChanged(
                .init(paneID: pane, items: [unread], lastShown: shown, epoch: epoch),
                isSelectedPane: true, isCurrent: { _ in true }
            )
            #expect(window.decisionBarDone.isEmpty)
        }
    }

    /// The resume typed at relaunch failing is said once: what failed and
    /// where to look, not the list's reason followed by the same failure
    /// in other words. Resuming it again from the bar is said as any is.
    @Test func theBar_saysAFailedRelaunchResume_once() {
        let item = AttentionItem.testStop(pane: Self.pane, reason: .notResumedAtLaunch)
        let failed = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .failed])),
            locale: Locale(identifier: "en")
        )
        #expect(failed.text == "Couldn’t resume the same conversation after Weir relaunched. Its terminal shows why.")
        #expect(failed.primaryAction == .resume(item.id))
        let japanese = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .failed])),
            locale: Locale(identifier: "ja")
        )
        #expect(japanese.text == "Weir の再起動後に同じ会話を再開できませんでした。理由はターミナルに表示されています。")
        #expect(japanese.primaryAction == .resume(item.id))
        let resuming = DecisionBarModel(
            content: .make(.init(items: [item], stopResumes: [item.id: .resuming])),
            locale: Locale(identifier: "en")
        )
        #expect(resuming.text == "Loading the same conversation…")
    }
}
