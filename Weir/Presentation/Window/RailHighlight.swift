// RailHighlight.swift
// Weir — which one left rail button is lit.

/// The one left rail button lit at a time: an open panel, else the scratch
/// tabs the window is on, else the sidebar. Two lit at once read as two places.
enum RailHighlight: Equatable {
    case sidebar
    case scratch
    case allProjects
    case history
    case planUsage
    case update
    case none

    static func of( // swiftlint:disable:this function_parameter_count
        isSidebarPresented: Bool,
        isOnScratch: Bool,
        isAllProjectsPresented: Bool,
        isHistoryPresented: Bool,
        isPlanUsagePresented: Bool,
        isUpdatePresented: Bool
    ) -> Self {
        if isAllProjectsPresented {
            return .allProjects
        }
        if isHistoryPresented {
            return .history
        }
        if isPlanUsagePresented {
            return .planUsage
        }
        if isUpdatePresented {
            return .update
        }
        if isOnScratch {
            return .scratch
        }
        return isSidebarPresented ? .sidebar : .none
    }
}
