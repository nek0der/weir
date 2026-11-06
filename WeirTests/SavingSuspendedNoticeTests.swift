// SavingSuspendedNoticeTests.swift
// Weir — what Weir says while it has stopped saving the person's files, or a save fails.

import Foundation
import Testing
@testable import Weir

struct SavingSuspendedNoticeTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let folder = URL(fileURLWithPath: "/tmp/weir-notice")
    private static let sessionFile = folder.appendingPathComponent("state.json")
    private static let settingsFile = folder.appendingPathComponent("settings.json")

    /// Nothing is shown while every file is saved, in Settings or in the alert.
    @Test func everyFileSaved_showsNothing() {
        #expect(SavingSuspendedNotice.make(
            status: SavingStatus(), settings: nil, isSettingsSaveFailing: false, settingsFile: Self.settingsFile, locale: Self.english
        ) == nil)
        #expect(SavingSuspendedNotice.alert(
            launchSettings: nil,
            failedSessionFile: nil,
            isSettingsSaveFailing: false,
            settingsFile: Self.settingsFile,
            locale: Self.english
        ) == nil)
    }

    /// Settings → General names each file whose saving stopped, the
    /// sessions first, with what to do; they are the files Show in Finder
    /// selects.
    @Test func eachSuspendedFile_isNamed_sessionsFirst() throws {
        let notice = try #require(SavingSuspendedNotice.make(
            status: SavingStatus(suspendedSessionFile: Self.sessionFile),
            settings: .unreadable,
            isSettingsSaveFailing: false,
            settingsFile: Self.settingsFile,
            locale: Self.japanese
        ))
        #expect(notice.files == [Self.sessionFile, Self.settingsFile])
        #expect(notice.sentences == [
            "セッションを保存していません。このバージョンでは state.json を読み込めず、退避もできませんでした。state.json をフォルダーの外に移動してから、Weir を終了して再度開いてください。",
            "設定を保存していません。このバージョンでは settings.json を読み込めず、退避もできませんでした。settings.json をフォルダーの外に移動してから、Weir を終了して再度開いてください。"
        ])
    }

    /// An older settings file read as it was is not called unreadable.
    @Test func anOlderSettingsFileNotMoved_isToldApart() throws {
        let notice = try #require(SavingSuspendedNotice.make(
            status: SavingStatus(),
            settings: .notMoved,
            isSettingsSaveFailing: false,
            settingsFile: Self.settingsFile,
            locale: Self.english
        ))
        #expect(notice.files == [Self.settingsFile])
        #expect(notice.sentences.count == 1)
        #expect(notice.sentences[0].hasPrefix("Your settings aren’t being saved: settings.json couldn’t be updated"))
        #expect(notice.sentences[0].hasSuffix("so it is read as it was. Quit and reopen Weir to try again."))
    }

    /// A file a newer build wrote is told apart, and says where to change
    /// the settings.
    @Test func aNewerSettingsFile_isToldApart() {
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersion, locale: Self.japanese)
            == "設定を保存していません。settings.json は新しいバージョンの Weir が書き込んだため、このバージョンは読み込むだけで上書きしません。設定を変更するには、そのバージョンの Weir を開いてください。")
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersion, locale: Self.english)
            .hasPrefix("Your settings aren’t being saved: settings.json was written by a newer version of Weir"))
    }

    /// One this build cannot decode says the defaults are in use, not the
    /// file.
    @Test func aNewerSettingsFileThatDoesNotDecode_saysTheDefaultsAreInUse() {
        // swiftlint:disable:next line_length
        let japanese = "設定を保存していません。settings.json は新しいバージョンの Weir がこのバージョンでは読めない形で書き込んだため、このバージョンはデフォルトの設定を使い、ファイルはそのまま残します。設定を変更するには、そのバージョンの Weir を開いてください。"
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersionUnreadable, locale: Self.japanese) == japanese)
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersionUnreadable, locale: Self.english)
            .contains("this version uses its defaults and leaves the file as it is"))
    }

    /// A file that stopped decoding while the app ran says fixing it is enough.
    @Test func aFileThatStoppedDecoding_saysFixingItIsEnough() {
        #expect(SavingSuspendedText.settingsNotSaved(.doesNotDecode, locale: Self.japanese)
            .contains("ファイルを修正すると保存を再開します"))
        #expect(SavingSuspendedText.settingsNotSaved(.doesNotDecode, locale: Self.english)
            .contains("Correct the file and saving starts again"))
    }

    /// The launch alert tells the settings alone.
    @Test func theLaunchAlert_tellsTheSettings() throws {
        let alert = try #require(SavingSuspendedNotice.alert(
            launchSettings: .unreadable,
            failedSessionFile: nil,
            isSettingsSaveFailing: false,
            settingsFile: Self.settingsFile,
            locale: Self.japanese
        ))
        #expect(alert.files == [Self.settingsFile])
        #expect(alert.sentences == [SavingSuspendedText.settingsNotSaved(.unreadable, locale: Self.japanese)])
    }

    /// A save that fails is told apart from saving that stopped: it says
    /// what to check, and that the next change saves again.
    @Test func aFailingSave_isTold_inSettingsAndTheAlert() throws {
        let status = SavingStatus(failedSessionFile: Self.sessionFile)
        let notice = try #require(SavingSuspendedNotice.make(
            status: status, settings: nil, isSettingsSaveFailing: true, settingsFile: Self.settingsFile, locale: Self.japanese
        ))
        let sentences = [
            "セッションを保存できませんでした。state.json に書き込めませんでした。ディスクの空き容量と、フォルダーに書き込めるかを確認してください。次に変更したときにもう一度保存します。",
            "設定を保存できませんでした。settings.json に書き込めませんでした。ディスクの空き容量と、フォルダーに書き込めるかを確認してください。次に変更したときにもう一度保存します。"
        ]
        #expect(notice.sentences == sentences)
        #expect(notice.files == [Self.sessionFile, Self.settingsFile])
        let alert = try #require(SavingSuspendedNotice.alert(
            launchSettings: nil,
            failedSessionFile: Self.sessionFile,
            isSettingsSaveFailing: true,
            settingsFile: Self.settingsFile,
            locale: Self.japanese
        ))
        #expect(alert == notice)
        #expect(SavingSuspendedText.sessionSaveFailed(locale: Self.english)
            .hasPrefix("Your sessions couldn’t be saved: writing state.json failed."))
        #expect(SavingSuspendedText.saveFailedTitle(locale: Self.japanese) == "変更を保存できませんでした")
    }

    /// The smaller stores are named in Settings, after the sessions and the
    /// settings, each with its own file; the alert leaves them out, as what
    /// they hold is not lost work.
    @Test func theSmallerStores_areNamedInSettingsOnly() throws {
        let history = Self.folder.appendingPathComponent("notifications.json")
        let ranking = Self.folder.appendingPathComponent("frecency.json")
        let viewed = Self.folder.appendingPathComponent("viewed-lines.json")
        let status = SavingStatus(
            suspendedSessionFile: Self.sessionFile,
            suspendedStores: [
                .init(kind: .notificationHistory, file: history),
                .init(kind: .paletteRanking, file: ranking),
                .init(kind: .viewedTurns, file: viewed)
            ]
        )
        let notice = try #require(SavingSuspendedNotice.make(
            status: status, settings: nil, isSettingsSaveFailing: false, settingsFile: Self.settingsFile, locale: Self.japanese
        ))
        #expect(notice.files == [Self.sessionFile, history, ranking, viewed])
        #expect(Array(notice.sentences.dropFirst()) == [
            "通知履歴を保存していません。notifications.json を使用できず、退避もできませんでした。フォルダーのアクセス権を確認するか、ファイルをフォルダーの外に移動してから、Weir を終了して再度開いてください。",
            "コマンドパレットの並び順を保存していません。frecency.json を使用できず、退避もできませんでした。フォルダーのアクセス権を確認するか、ファイルをフォルダーの外に移動してから、Weir を終了して再度開いてください。",
            "確認済みのターンを保存していません。viewed-lines.json を使用できず、退避もできませんでした。フォルダーのアクセス権を確認するか、ファイルをフォルダーの外に移動してから、Weir を終了して再度開いてください。"
        ])
    }

    /// The alert that the session was not restored also says it is not
    /// being saved, and only then.
    @Test func theRestoreAlert_saysTheSessionIsNotSaved_whenItIsNot() {
        let detail = "A fresh window was opened instead."
        #expect(SavingSuspendedText.loadIssueMessage(detail: detail, isSessionSavingSuspended: false, locale: Self.english)
            == detail)
        #expect(SavingSuspendedText.loadIssueMessage(detail: detail, isSessionSavingSuspended: true, locale: Self.english)
            == detail + "\n\n" + SavingSuspendedText.sessionNotSaved(locale: Self.english))
    }

    /// The alert names the stores whose loss is work to do again, and
    /// leaves the ones that rebuild themselves to Settings; a file of work
    /// still to finish is named by its file.
    @Test func theAlert_namesOnlyTheStoresWhoseLossIsWork() throws {
        let stores: [SuspendedStore] = [
            .init(kind: .notificationHistory, file: Self.folder.appendingPathComponent("notifications.json")),
            .init(kind: .stops, file: Self.folder.appendingPathComponent("stops.json")),
            .init(kind: .turnReads, file: Self.folder.appendingPathComponent("turn-reads.json")),
            .init(kind: .pendingWork, file: Self.folder.appendingPathComponent("turn-deletions.json"))
        ]
        let alert = try #require(SavingSuspendedNotice.alert(
            launchSettings: nil,
            launchStores: stores,
            failedSessionFile: nil,
            isSettingsSaveFailing: false,
            settingsFile: Self.settingsFile,
            locale: Self.english
        ))
        #expect(alert.files.map(\.lastPathComponent) == ["stops.json", "turn-deletions.json"])
        #expect(alert.sentences[1]
            == "Weir isn’t saving turn-deletions.json: it can’t be used and couldn’t be set aside. "
            + "Check the permissions of its folder or move it out, then quit and reopen Weir.")
        #expect(SavingSuspendedText.storesTitle(locale: Self.japanese) == "一部のファイルを保存していません")
    }
}
