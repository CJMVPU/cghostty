import AppKit

/// Owns only the constraints used to place AppKit's tab accessory in our toolbar.
/// AppKit continues to own the tab bar, its buttons and their internal layout.
@MainActor final class NativeTitlebarTabLayout {
    private let tabBar: NSView
    private let container: NSView
    private let clipView: NSView
    private let accessoryView: NSView
    private let originalClipAutoresizing: Bool
    private let originalAccessoryAutoresizing: Bool
    private let leadingConstraint: NSLayoutConstraint
    private let constraints: [NSLayoutConstraint]

    init(tabBar: NSView, clipView: NSView, accessoryView: NSView, container: NSView) {
        self.tabBar = tabBar
        self.clipView = clipView
        self.accessoryView = accessoryView
        self.container = container
        originalClipAutoresizing = clipView.translatesAutoresizingMaskIntoConstraints
        originalAccessoryAutoresizing = accessoryView.translatesAutoresizingMaskIntoConstraints
        leadingConstraint = clipView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        constraints = [
            leadingConstraint,
            clipView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            clipView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            clipView.heightAnchor.constraint(equalTo: container.heightAnchor),
            accessoryView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            accessoryView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            accessoryView.topAnchor.constraint(equalTo: clipView.topAnchor),
            accessoryView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ]
        for constraint in constraints { constraint.identifier = "cghostty.titlebar-tabs" }
    }

    isolated deinit { deactivate() }

    func matches(tabBar: NSView, clipView: NSView, accessoryView: NSView, container: NSView) -> Bool {
        self.tabBar === tabBar && self.clipView === clipView
            && self.accessoryView === accessoryView && self.container === container
    }

    /// Resize events reuse the same constraints. A detached or zero-sized toolbar
    /// is an AppKit transition, not a new layout to constrain.
    @discardableResult
    func update(leadingInset: CGFloat) -> Bool {
        guard container.bounds.width > leadingInset,
              container.bounds.height > 2,
              container.window != nil,
              clipView.window === container.window,
              tabBar.isDescendant(of: accessoryView),
              accessoryView.isDescendant(of: clipView) else {
            deactivate()
            return false
        }
        leadingConstraint.constant = leadingInset
        guard !leadingConstraint.isActive else { return true }
        clipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(constraints)
        return true
    }

    func deactivate() {
        NSLayoutConstraint.deactivate(constraints)
        clipView.translatesAutoresizingMaskIntoConstraints = originalClipAutoresizing
        accessoryView.translatesAutoresizingMaskIntoConstraints = originalAccessoryAutoresizing
    }
}
