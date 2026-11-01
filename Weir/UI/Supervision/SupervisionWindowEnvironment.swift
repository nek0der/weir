// SupervisionWindowEnvironment.swift
// Weir — where a supervision window's views read the handlers App gives them.

import SwiftUI

extension EnvironmentValues {
    /// `nil` outside a supervision window, which has no strip or record.
    @Entry var restoreHandler: RestoreHandler?
    /// Nil outside a supervision window, where ⌘⏎ is the terminal's.
    @Entry var primaryActionHandler: PrimaryActionHandler?
    /// `nil` outside a supervision window.
    @Entry var supervisionWindowHandler: SupervisionWindowHandler?
}
