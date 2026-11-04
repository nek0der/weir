// AgentIntegrationServiceAlert.swift
// Weir — actionable failure UI for native approval service activation.

import SwiftUI

/// What one presentation of the alert stands for: the reason it was keyed
/// to. An alert keeps the text and buttons it was presented with, and the
/// issue can change while it shows: the backoff's failure becomes the disk
/// image's once a replacement is refused there. So each reason gets an
/// alert of its own, and an alert answers only for its own reason.
struct AgentIntegrationServiceAlertSlot: Equatable {
    /// `nil` while there is no issue, when the slot presents nothing.
    let reason: AgentIntegrationServiceIssue.Reason?

    /// Whether this slot's alert shows while `issue` is current.
    func isPresented(for issue: AgentIntegrationServiceIssue?, isShown: Bool) -> Bool {
        isShown && reason != nil && issue?.reason == reason
    }

    /// Whether this slot's alert closing dismisses `issue`: only when it
    /// is still the issue this slot shows. A slot closing because the
    /// reason changed, or one left for another window, is not an answer.
    func dismisses(_ issue: AgentIntegrationServiceIssue?, isShown: Bool) -> Bool {
        isPresented(for: issue, isShown: isShown)
    }

    /// The buttons besides **Not Now**, in order.
    static func actions(for reason: AgentIntegrationServiceIssue.Reason) -> [Action] {
        var actions: [Action] = []
        if reason == .requiresApproval {
            actions.append(.openLoginItems)
        }
        // Where the app runs from cannot change while it runs, so a retry
        // would only show the same alert.
        if reason != .temporaryLocation {
            actions.append(.retry)
        }
        return actions
    }

    enum Action: Hashable {
        case openLoginItems
        case retry
    }
}

private struct AgentIntegrationServiceAlertModifier: ViewModifier {
    let registrar: AgentIntegrationServiceRegistrar
    /// Whether this window shows the alert: one window does, not every one.
    let isShown: Bool

    func body(content: Content) -> some View {
        // Keyed by the reason, so a new reason replaces the alert on screen
        // instead of leaving the one presented before it.
        content.background {
            AgentIntegrationServiceAlertAnchor(
                registrar: registrar,
                slot: AgentIntegrationServiceAlertSlot(reason: registrar.issue?.reason),
                isShown: isShown
            )
            .id(registrar.issue?.reason)
        }
    }
}

private struct AgentIntegrationServiceAlertAnchor: View {
    let registrar: AgentIntegrationServiceRegistrar
    let slot: AgentIntegrationServiceAlertSlot
    let isShown: Bool

    var body: some View {
        Color.clear.alert(
            Text(registrar.issue?.title ?? ""),
            isPresented: Binding(
                get: { slot.isPresented(for: registrar.issue, isShown: isShown) },
                set: {
                    if !$0, slot.dismisses(registrar.issue, isShown: isShown) {
                        registrar.dismissIssue()
                    }
                }
            ),
            presenting: registrar.issue
        ) { issue in
            ForEach(AgentIntegrationServiceAlertSlot.actions(for: issue.reason), id: \.self) { action in
                switch action {
                case .openLoginItems:
                    Button("Open Login Items") {
                        registrar.openLoginItemsSettings()
                    }
                case .retry:
                    Button("Retry") {
                        registrar.retry()
                    }
                }
            }
            Button("Not Now", role: .cancel) {
                registrar.dismissIssue()
            }
        } message: { issue in
            Text(issue.detail)
        }
    }
}

extension View {
    func agentIntegrationServiceAlert(
        _ registrar: AgentIntegrationServiceRegistrar,
        isShown: Bool
    ) -> some View {
        modifier(AgentIntegrationServiceAlertModifier(registrar: registrar, isShown: isShown))
    }
}
