// RailHighlightTests.swift
// Weir — the left rail lights one button at a time.

import Testing
@testable import Weir

struct RailHighlightTests {
    @Test func highlight_isOneButton_anOpenPanelBeforeScratchBeforeTheSidebar() {
        func of(
            sidebar: Bool = true,
            scratch: Bool = false,
            all: Bool = false,
            history: Bool = false,
            usage: Bool = false,
            update: Bool = false
        ) -> RailHighlight {
            RailHighlight.of(
                isSidebarPresented: sidebar,
                isOnScratch: scratch,
                isAllProjectsPresented: all,
                isHistoryPresented: history,
                isPlanUsagePresented: usage,
                isUpdatePresented: update
            )
        }
        #expect(of() == .sidebar)
        #expect(of(sidebar: false) == .none)
        #expect(of(update: true) == .update)
        #expect(of(scratch: true) == .scratch)
        #expect(of(scratch: true, all: true) == .allProjects)
        #expect(of(scratch: true, history: true) == .history)
        #expect(of(scratch: true, usage: true) == .planUsage)
    }
}
