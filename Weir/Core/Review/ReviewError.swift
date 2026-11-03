// ReviewError.swift
// Weir — what can go wrong in a review, in the words the banner shows.

import Foundation

enum ReviewError: WeirLocalizedError {
    case invalidDiff, unsupported, tooLarge, gitFailed, changed, targetUnavailable, invalidText, storageFailed
    /// A draft on disk that could not be read. Separate from `storageFailed`:
    /// nothing was being saved, and there is nothing for the reader to retry.
    case resolvedBacklogTooLarge, baseUnavailable
    case draftUnreadable
    /// The draft on disk could not be updated safely, so the review is kept
    /// in memory only, until it closes.
    case draftNotSaved
    /// The draft on disk could not be read, nor moved aside: the review
    /// starts empty and must not save over it.
    case draftUnreadableNotSaved
    /// The review or the worktree moved while Git was answering. Separate from
    /// `changed`, which is about comments that no longer describe the diff.
    case checkInterrupted
    case commentLimitReached, commentTooLong, nothingToInsert, promptTooLong, timedOut
    case instructionsInvalid, instructionsTooLong
    /// A fixed range lost a snapshot (the retention sweep, a pruned ref):
    /// its record is incomplete, and nothing is guessed in its place.
    case rangeSnapshotsMissing
    /// A fixed range was recorded in another work tree of the repository.
    case rangeInAnotherWorktree
    case unsavedComment
    /// A comment is being written, and another was asked for: the first is
    /// not dropped for it.
    case commentInProgress
    /// A comment from before scopes could not be moved into the scope on
    /// screen: its file is not in it, the lines it quotes are not, or
    /// they are there more than once, or (a fixed range) the code is no
    /// longer where the comment says. Each says what the reader can do.
    case legacyFileNotInScope, legacyCodeNotFound, legacyCodeRepeated, legacyCodeMoved
    /// The comment being edited was deleted in another window; the text
    /// written stays in the composer.
    case commentDeletedElsewhere
    /// The review's banner holds the text of a comment that could not stay
    /// where it was written (`ReviewSession.unplacedComment`), which has to
    /// be copied or discarded first.
    case unplacedCommentHeld
    /// The review tab's worktree no longer resolves to the review the tab
    /// keeps (`ReviewPaneOpening`).
    case worktreeMoved
    /// The pane's terminal did not start, or did not finish typing the
    /// command it was restored with, in the time an insert waits for it.
    case paneDidNotStart
    /// The paste was started and the terminal did not take it: refused at
    /// the confirmation sheet, or dropped with its pane. Nothing was marked.
    case pasteRefused
    /// The pane shows several sessions, and the one the review is about did not come
    /// to the front in time. A paste would have gone to another conversation.
    case sessionNotShown
    /// Another review of the worktree, in another window, is inserting some
    /// of the same comments and has not heard back from its paste yet.
    case insertInProgress
    /// The program in the pane has exited. Its terminal is still on screen,
    /// saying so, but nothing reads what a paste writes there.
    case paneExited

    var message: DisplayText {
        .localized(text)
    }

    private var text: LocalizedStringResource {
        switch self {
        case .unsavedComment:
            "Save or cancel the comment before changing the review scope."
        case .commentInProgress:
            "Save or cancel the comment you’re writing first."
        case .legacyFileNotInScope:
            "This comment’s file isn’t in this scope."
        case .legacyCodeNotFound:
            "The code this comment quotes isn’t in this scope’s changes."
        case .legacyCodeRepeated:
            "The code this comment quotes appears more than once in this scope, so it can’t be placed."
        case .legacyCodeMoved:
            "The code this comment quotes has changed since. Write the comment again."
        case .commentDeletedElsewhere:
            "This comment was deleted in another window. Copy what you wrote before closing."
        case .unplacedCommentHeld:
            "First, copy or discard the comment that couldn’t be put back."
        case .worktreeMoved:
            "This review’s worktree is no longer where it was. Close the review and open it again."
        case .paneDidNotStart:
            "The pane’s terminal didn’t start. Try again."
        case .sessionNotShown:
            "This review’s conversation didn’t come to the front of its pane, so the comments weren’t inserted. They stay in this review."
        case .insertInProgress:
            "These comments are being inserted from another window. Wait for that insert to finish."
        case .paneExited:
            "The program in this pane has exited, so the comments weren’t inserted. They stay in this review."
        case .pasteRefused:
            // The comments are what Insert puts in the pane, not
            // the review, which stays open around them.
            "The comments weren’t inserted. They stay in this review."
        case .rangeSnapshotsMissing:
            "The snapshots of these turns are gone, so their record is incomplete and their changes can’t be shown."
        case .rangeInAnotherWorktree:
            "These turns were recorded in another worktree."
        case .invalidDiff: "This diff couldn’t be parsed."
        case .unsupported: "This file can’t be reviewed as text."
        case .tooLarge: "This diff exceeds the review size limit."
        case .gitFailed: "Git couldn’t load the changes. Try again."
        case .changed: "Changes have moved since these comments were written. Reopen the file and recreate affected comments."
        // Not "there is no terminal": the same error answers a terminal that
        // took the paste as a request for the clipboard's types, and a pane
        // the reader switched away from while Git was running.
        case .targetUnavailable: "The terminal below the review didn’t accept the insert. Try again."
        case .invalidText: "The review text contains unsupported control characters."
        case .commentLimitReached: "This review has as many comments as it can hold. Resolve or delete some before adding more."
        case .commentTooLong: "This comment is too long to send. Shorten it and try again."
        case .nothingToInsert: "Every comment in this review is resolved. Unresolve a comment to include it."
        case .timedOut: "Git didn’t respond in time. Try again."
        case .instructionsInvalid: "The review instructions in Settings contain characters that can’t be sent to a terminal."
        case .instructionsTooLong: "The review instructions in Settings are too long to send. Shorten them and try again."
        case .promptTooLong: "These comments are too long to send together. Resolve or delete some and try again."
        case .storageFailed: "Review comments couldn’t be saved. Keep Review open and try the change again."
        case .resolvedBacklogTooLarge:
            "The review draft is full. Delete resolved comments from the preview and try again."
        case .baseUnavailable:
            "Git couldn’t determine the comparison branch. Check the repository and try again."
        case .draftUnreadable: "Saved review comments couldn’t be loaded. This review starts empty."
        case .draftNotSaved:
            "Saved review comments couldn’t be updated safely, so changes to this review aren’t saved and are lost when it closes."
        case .draftUnreadableNotSaved:
            "Saved review comments couldn’t be loaded or moved aside. This review starts empty, and changes to it aren’t saved."
        case .checkInterrupted: "The comments or the checked-out commit changed while Git was checking them. Insert again."
        }
    }
}
