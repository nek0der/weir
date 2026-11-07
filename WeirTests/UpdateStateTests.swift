// UpdateStateTests.swift
// Weir — the update interface's state: the item it shows, a download's progress, and how progress is read out.

import Foundation
import Testing
@testable import Weir

@MainActor
struct UpdateStateTests {
    @Test func aDownload_isZeroWhileItsSizeIsUnknown_andStopsAtTheEnd() {
        #expect(UpdateState.downloadProgress(received: 500, expected: nil) == 0)
        #expect(UpdateState.downloadProgress(received: 500, expected: 0) == 0)
        #expect(UpdateState.downloadProgress(received: 250, expected: 1000) == 0.25)
        #expect(UpdateState.downloadProgress(received: 1500, expected: 1000) == 1)
    }

    @Test func progress_isReadAsAPercentage_inTheWindowsLanguage() {
        #expect(UpdateState.progressText(0.42, locale: Locale(identifier: "en")) == "42%")
        #expect(UpdateState.progressText(0.42, locale: Locale(identifier: "ja")) == "42%")
        #expect(UpdateState.progressText(0.42, locale: Locale(identifier: "fr")) == "42\u{00A0}%")
        #expect(UpdateState.extracting(progress: 0.5).progressValueText(locale: Locale(identifier: "en")) == "50%")
        #expect(UpdateState.idle.progressValueText(locale: Locale(identifier: "en")).isEmpty)
    }

    @Test func showingAState_recordsTheSessionItBelongsTo() {
        let model = UpdateStateModel()
        let session = UpdateSessionID(rawValue: 7)

        model.show(.extracting(progress: 0.5), for: session)
        #expect(model.sessionID == session)
        #expect(model.state.progress == 0.5)

        model.show(.idle)
        #expect(model.sessionID == nil)
        #expect(model.state.progress == nil)
    }
}
