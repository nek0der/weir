// SavingSuspendedNotice.swift
// Weir — what Weir says while it has stopped saving the person's files, or a save fails.

import Foundation

/// What the app knows about saving its files, apart from the settings,
/// which `SettingsStore` reports itself: what `SavingSuspendedNotice` is
/// made from. A plain value read off the stores, so a view can be handed it.
struct SavingStatus: Equatable {
    /// `state.json` while this launch has stopped saving it.
    var suspendedSessionFile: URL?
    /// `state.json` while its last save did not reach disk.
    var failedSessionFile: URL?
    /// The smaller stores whose file could neither be read nor be moved
    /// aside, so this launch does not save them.
    var suspendedStores: [SuspendedStore] = []
}

/// One of the smaller stores whose saving stopped (`SavingStatus`).
struct SuspendedStore: Equatable {
    enum Kind: Equatable {
        case notificationHistory
        case paletteRanking
        case viewedTurns
        case turnReads
        case stops
        /// A file of work still to finish (`VersionedListFile`): the turns
        /// on their way to deletion, the notices of undos cut short, the
        /// sessions the person ended. Named by its file, which is all the
        /// person can act on.
        case pendingWork

        /// Whether the alert tells it, and not only Settings: what this
        /// launch cannot save there is work the person or Weir would have
        /// to do again, or cannot (a deleted turn's span, a stop, a
        /// discard's way back). The history, the palette's ranking, and the
        /// read marks rebuild themselves as Weir is used.
        var isToldInAlert: Bool {
            switch self {
            case .viewedTurns, .stops, .pendingWork: true
            case .notificationHistory, .paletteRanking, .turnReads: false
            }
        }
    }

    var kind: Kind
    var file: URL
}

/// What Weir tells while a file this launch could not take in has
/// stopped saving, or while a save fails: which file, why, and what to
/// do. Without it the person would go on changing sessions or settings
/// that are lost when Weir quits. Settings → General shows it at its top;
/// the settings' suspension and a failing save are also an alert
/// (`alert`).
struct SavingSuspendedNotice: Equatable {
    /// One sentence per file: the sessions first, then the settings, then
    /// the smaller stores.
    let sentences: [String]
    /// The files the sentences name, for Show in Finder to select.
    let files: [URL]

    /// `nil` while every file is being saved.
    static func make(
        status: SavingStatus,
        settings: SettingsSavingSuspension?,
        isSettingsSaveFailing: Bool,
        settingsFile: URL,
        locale: Locale
    ) -> Self? {
        var notice = Builder()
        if let file = status.suspendedSessionFile {
            notice.add(SavingSuspendedText.sessionNotSaved(locale: locale), file)
        }
        if let file = status.failedSessionFile {
            notice.add(SavingSuspendedText.sessionSaveFailed(locale: locale), file)
        }
        if let settings {
            notice.add(SavingSuspendedText.settingsNotSaved(settings, locale: locale), settingsFile)
        }
        if isSettingsSaveFailing {
            notice.add(SavingSuspendedText.settingsSaveFailed(locale: locale), settingsFile)
        }
        for store in status.suspendedStores {
            notice.add(SavingSuspendedText.storeNotSaved(store, locale: locale), store.file)
        }
        return notice.built
    }

    /// The alert, shown once in one window: the settings' suspension and
    /// the smaller stores' as the launch found them, and any save of the
    /// sessions or settings that is failing. The session's own suspension
    /// is told by the alert that it was not restored (`SessionLoadIssue`),
    /// which every suspension of its saving comes with. Of the smaller
    /// stores, only those whose loss is work to do again
    /// (`SuspendedStore.Kind.isToldInAlert`). `nil` while there is nothing
    /// to tell.
    static func alert(
        launchSettings: SettingsSavingSuspension?,
        launchStores: [SuspendedStore] = [],
        failedSessionFile: URL?,
        isSettingsSaveFailing: Bool,
        settingsFile: URL,
        locale: Locale
    ) -> Self? {
        make(
            status: SavingStatus(
                failedSessionFile: failedSessionFile,
                suspendedStores: launchStores.filter(\.kind.isToldInAlert)
            ),
            settings: launchSettings,
            isSettingsSaveFailing: isSettingsSaveFailing,
            settingsFile: settingsFile,
            locale: locale
        )
    }

    /// Collects the sentences, and each file once.
    private struct Builder {
        var sentences: [String] = []
        var files: [URL] = []

        mutating func add(_ sentence: String, _ file: URL) {
            sentences.append(sentence)
            if !files.contains(file) {
                files.append(file)
            }
        }

        var built: SavingSuspendedNotice? {
            sentences.isEmpty ? nil : SavingSuspendedNotice(sentences: sentences, files: files)
        }
    }
}

/// The words of `SavingSuspendedNotice`.
enum SavingSuspendedText {
    static func sessionNotSaved(locale: Locale) -> String {
        LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Your sessions aren’t being saved: state.json can’t be read by this version and couldn’t be set aside. Move it out of the folder, then quit and reopen Weir.",
            comment: "Settings, General, and the alert that the session was not restored: saving sessions is suspended"
        ).resolved(in: locale)
    }

    /// The text of the alert that the session was not restored: its own
    /// `detail`, then, while the session is not being saved, that too, so
    /// the person learns it at launch and not only in Settings.
    static func loadIssueMessage(detail: String, isSessionSavingSuspended: Bool, locale: Locale) -> String {
        guard isSessionSavingSuspended else { return detail }
        return detail + "\n\n" + sessionNotSaved(locale: locale)
    }

    static func settingsNotSaved(_ suspension: SettingsSavingSuspension, locale: Locale) -> String {
        switch suspension {
        case .unreadable:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json can’t be read by this version and couldn’t be set aside. Move it out of the folder, then quit and reopen Weir.",
                comment: "Settings, General, and an alert at launch: saving settings is suspended, as the file cannot be read"
            ).resolved(in: locale)
        case .notMoved:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json couldn’t be updated to this version’s format, so it is read as it was. Quit and reopen Weir to try again.",
                comment: "Settings, General, and an alert at launch: saving settings is suspended, as the older file could not be migrated"
            ).resolved(in: locale)
        case .newerVersion:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json was written by a newer version of Weir, so this version reads it but doesn’t write over it. Open that version to change your settings.",
                comment: "Settings, General, and an alert at launch: saving settings is suspended, as a newer version wrote the file"
            ).resolved(in: locale)
        case .newerVersionUnreadable:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json was written by a newer version of Weir in a form this version can’t read, so this version uses its defaults and leaves the file as it is. Open that version to change your settings.",
                comment: "Settings, General, and a launch alert: saving settings is suspended, as a newer version wrote an unreadable file"
            ).resolved(in: locale)
        case .doesNotDecode:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json can’t be read as it stands, so Weir keeps using the settings it had. Correct the file and saving starts again.",
                comment: "Settings, General: saving settings is suspended, as the file stopped being readable while Weir ran"
            ).resolved(in: locale)
        }
    }

    static func sessionSaveFailed(locale: Locale) -> String {
        LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Your sessions couldn’t be saved: writing state.json failed. Check that the disk has free space and that its folder can be written to. Weir saves again with the next change.",
            comment: "Settings, General, and an alert: the last save of the sessions did not reach disk"
        ).resolved(in: locale)
    }

    static func settingsSaveFailed(locale: Locale) -> String {
        LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Your settings couldn’t be saved: writing settings.json failed. Check that the disk has free space and that its folder can be written to. Weir saves again with the next change.",
            comment: "Settings, General, and an alert: the last save of the settings did not reach disk"
        ).resolved(in: locale)
    }

    static func storeNotSaved(_ store: SuspendedStore, locale: Locale) -> String {
        switch store.kind {
        case .notificationHistory:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your notification history isn’t being saved: notifications.json can’t be used and couldn’t be set aside. Check the permissions of its folder or move it out, then quit and reopen Weir.",
                comment: "Settings, General: saving the notification history is suspended, as its file cannot be read"
            ).resolved(in: locale)
        case .paletteRanking:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "The command palette’s ranking isn’t being saved: frecency.json can’t be used and couldn’t be set aside. Check the permissions of its folder or move it out, then quit and reopen Weir.",
                comment: "Settings, General: saving how the command palette ranks its rows is suspended, as its file cannot be read"
            ).resolved(in: locale)
        case .viewedTurns:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "The turns you’ve viewed aren’t being saved: viewed-lines.json can’t be used and couldn’t be set aside. Check the permissions of its folder or move it out, then quit and reopen Weir.",
                comment: "Settings, General, and an alert: saving which turns are viewed is suspended, as its file cannot be read"
            ).resolved(in: locale)
        case .turnReads:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "The turns you’ve read aren’t being saved: turn-reads.json can’t be used and couldn’t be set aside. Check the permissions of its folder or move it out, then quit and reopen Weir.",
                comment: "Settings, General: saving which turns are read is suspended, as its file cannot be read"
            ).resolved(in: locale)
        case .stops:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "The agents that stopped aren’t being saved: stops.json can’t be used and couldn’t be set aside. Check the permissions of its folder or move it out, then quit and reopen Weir.",
                comment: "Settings, General, and an alert: saving the agents that stopped is suspended, as its file cannot be read"
            ).resolved(in: locale)
        case .pendingWork:
            pendingWorkNotSaved(fileName: store.file.lastPathComponent, locale: locale)
        }
    }

    private static func pendingWorkNotSaved(fileName: String, locale: Locale) -> String {
        LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Weir isn’t saving \(fileName): it can’t be used and couldn’t be set aside. Check the permissions of its folder or move it out, then quit and reopen Weir.",
            comment: "Settings, General, and an alert: a file of work still to finish cannot be read or saved; the argument is its name"
        ).resolved(in: locale)
    }

    static func launchTitle(locale: Locale) -> String {
        LocalizedStringResource("Settings Aren’t Being Saved", comment: "The alert at launch while saving settings is suspended: its title")
            .resolved(in: locale)
    }

    static func storesTitle(locale: Locale) -> String {
        LocalizedStringResource(
            "Weir Isn’t Saving Some Files",
            comment: "The alert at launch while saving some of Weir's own files is suspended: its title"
        )
        .resolved(in: locale)
    }

    static func saveFailedTitle(locale: Locale) -> String {
        LocalizedStringResource(
            "Weir Couldn’t Save Your Changes",
            comment: "The alert while a save of the sessions or the settings fails: its title"
        )
        .resolved(in: locale)
    }

    static func openSettings(locale: Locale) -> String {
        SettingsCommand.openTitle.resolved(in: locale)
    }

    static func showFiles(locale: Locale) -> String {
        MenuItemLabel.showInFinder.title.resolved(in: locale)
    }
}
