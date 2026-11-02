// ProjectOpeningTests.swift
// Weir — where choosing a row of a project lands, with ⌘ and without, as every entry point reads it.

import Testing
@testable import WeirDomain

/// One project is shown in one window: ⌘ asks for a new window only for a
/// project no window shows, and every other row opens where it would
/// without ⌘.
struct ProjectOpeningTests {
    @Test(arguments: [false, true])
    func thisWindowsProject_opensHere(asksForNewWindow: Bool) {
        #expect(ProjectOpening(isShownHere: true, isShownElsewhere: false, asksForNewWindow: asksForNewWindow) == .here)
    }

    @Test(arguments: [false, true])
    func aProjectAnotherWindowShows_bringsThatWindowForward(asksForNewWindow: Bool) {
        #expect(ProjectOpening(isShownHere: false, isShownElsewhere: true, asksForNewWindow: asksForNewWindow) == .otherWindow)
    }

    @Test func aProjectNoWindowShows_switchesHere_orOpensANewWindowWhenAsked() {
        #expect(ProjectOpening(isShownHere: false, isShownElsewhere: false, asksForNewWindow: false) == .switchHere)
        #expect(ProjectOpening(isShownHere: false, isShownElsewhere: false, asksForNewWindow: true) == .newWindow)
    }

    @Test func onlyAProjectNoWindowShows_offersANewWindow() {
        #expect(ProjectOpening.offersNewWindow(isShownHere: false, isShownElsewhere: false))
        #expect(!ProjectOpening.offersNewWindow(isShownHere: true, isShownElsewhere: false))
        #expect(!ProjectOpening.offersNewWindow(isShownHere: false, isShownElsewhere: true))
    }
}
