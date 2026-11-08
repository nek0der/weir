// ReviewFileMenuModel.swift
// Weir — what a reviewed file's path menu offers, for the rail and the diff's header alike.

import Foundation

/// One item of a reviewed file's path menu. `action` is `nil` when the item
/// shows but cannot be chosen.
struct ReviewFileMenuItem {
    /// What an item does. The ones that touch the file hold its path as
    /// Git wrote it and the repository's root, not a URL: the path is
    /// resolved again when the item is chosen (`fileURL()`), so a file
    /// replaced by a link out of the repository after the menu was drawn
    /// is not opened or shown, and its absolute path is not copied.
    enum Action: Equatable {
        case copyRelativePath(String)
        case copyAbsolutePath(String, root: URL)
        case open(String, root: URL)
        case reveal(String, root: URL)

        /// The file the action is about, resolved now: `nil` when its path
        /// no longer leads inside the repository (`ReviewFileAction`).
        func fileURL() -> URL? {
            switch self {
            case .copyRelativePath:
                nil
            case let .copyAbsolutePath(path, root), let .open(path, root), let .reveal(path, root):
                ReviewFileAction.fileURL(for: path, in: root)
            }
        }
    }

    let title: LocalizedStringResource
    let action: Action?
}

/// The items a reviewed file's path menu offers: the file list's row
/// (`ReviewFileActionsMenu`) and the stacked diff's file header both draw
/// these, so the two never offer different things for one file.
enum ReviewFileMenuModel {
    @MainActor
    static func reportOpenFailure(
        _ message: DisplayText,
        from window: ProjectWindowState,
        windows: WindowRegistry,
        session: WorkspaceSession,
        toasts: ToastCenter
    ) {
        let destination = windows.windowForResult(of: window, in: session)
        toasts.show(ToastItem(message: message, undo: nil), in: destination.id)
    }

    /// Copy the relative path, copy the absolute one, open it in the chosen
    /// app, and show it in Finder. A name that is not UTF-8 reaches us only
    /// as an approximation of its path (`ReviewFile.isNameUndecodable`), which
    /// may name no file or a different one: every item then shows, and none
    /// can be chosen.
    /// A path that resolves outside the repository can only be copied as
    /// written, and one that is not on disk cannot be opened.
    static func items(
        for file: ReviewFile,
        in root: URL,
        application: FileApplicationResolution,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [ReviewFileMenuItem] {
        let fileURL = file.isNameUndecodable ? nil : ReviewFileAction.fileURL(for: file.path, in: root)
        let path = file.path
        return [
            ReviewFileMenuItem(
                title: "Copy Relative Path",
                action: file.isNameUndecodable ? nil : .copyRelativePath(path)
            ),
            ReviewFileMenuItem(title: "Copy Absolute Path", action: fileURL.map { _ in .copyAbsolutePath(path, root: root) }),
            ReviewFileMenuItem(
                title: application.openActionTitle,
                action: fileURL.flatMap { exists($0.path) ? .open(path, root: root) : nil }
            ),
            ReviewFileMenuItem(title: MenuItemLabel.showInFinder.title, action: fileURL.map { _ in .reveal(path, root: root) })
        ]
    }

    /// Carries out `action`. Copying the relative path needs no file; every
    /// other action resolves its file first, and one that no longer
    /// resolves inside the repository is left alone. `application` is read
    /// only when the file opens, so a change in Settings since the menu was
    /// drawn applies. A file that fails to open says why through
    /// `onFailure`. Finder never walks above the repository's root.
    @MainActor
    static func perform(
        _ action: ReviewFileMenuItem.Action,
        application: () -> FileApplicationResolution,
        onFailure: @escaping @MainActor (DisplayText) -> Void
    ) {
        if case let .copyRelativePath(path) = action {
            SystemPasteboard.copy(path)
            return
        }
        guard let fileURL = action.fileURL() else { return }
        switch action {
        case .copyRelativePath:
            break
        case .copyAbsolutePath:
            SystemPasteboard.copy(fileURL.path)
        case .open:
            FileOpener.open(fileURL, with: application(), onFailure: onFailure)
        case let .reveal(_, root):
            FinderReveal.select(fileURL, within: root)
        }
    }
}
