// ReviewHunkCommentText.swift
// Weir — the words of a review hunk header's "Comment".

import Foundation

/// The words of a hunk header's "Comment".
enum ReviewHunkCommentText {
    static func comment(locale: Locale) -> String {
        // The gutter's own key: one word for one action.
        LocalizedStringResource("Comment").resolved(in: locale)
    }

    static func commentHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "Comments on this hunk’s change",
            comment: "Review: tooltip of Comment on a hunk header"
        ).resolved(in: locale)
    }

    /// "Comment on the Hunk at Line 3" for VoiceOver, which tells one
    /// hunk's "Comment" from another's in its list of buttons. The hunk is
    /// named by its first line (`ReviewHunkHeader.firstLine`): its
    /// `@@ -3,3 +3,4 @@` line would be read symbol by symbol. A row with no
    /// header gives the button's own word.
    static func commentLabel(header: ReviewHunkHeader?, locale: Locale) -> String {
        guard let header else { return comment(locale: locale) }
        return LocalizedStringResource(
            "Comment on the Hunk at Line \(header.firstLine)",
            comment: "Review, VoiceOver: Comment on a hunk header; argument: the line the hunk's new side starts at"
        ).resolved(in: locale)
    }
}
