// ContainerSymbol.swift
// Weir — shared symbols for containers and their window location.

/// Symbols shared by every surface that names a container or its window
/// location. We share names rather than images because menus and palettes
/// construct their own views.
enum ContainerSymbol {
    static let project = "book.closed"
    static let worktree = "arrow.triangle.branch"
    /// A project shown by another window, independent of where it is named.
    static let otherWindow = "macwindow.on.rectangle"
}
