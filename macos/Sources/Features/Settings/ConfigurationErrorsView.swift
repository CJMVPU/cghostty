import SwiftUI
import Observation

@MainActor @Observable final class ConfigurationErrorsState {
    var errors: [String] = []
}

/// Reuse the settings controls so startup diagnostics share the same fixed
/// typography, dark appearance and scrolling behavior as the editor.
struct ConfigurationErrorsView: NSViewRepresentable {
    let model: ConfigurationErrorsState
    let dismiss: () -> Void
    let edit: () -> Void

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.addArrangedSubview(settingsLabel("Some settings could not be applied. Open Settings to review them, then restart."))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let editor = SettingsTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        editor.configurePlainText()
        editor.isEditable = false
        editor.isSelectable = true
        editor.font = SettingsTypography.font
        editor.textColor = NSColor(calibratedRed: 1, green: 0.57, blue: 0.5, alpha: 1)
        editor.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        stack.addArrangedSubview(scroll)
        let footer = NSStackView()
        footer.orientation = .horizontal
        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(space)
        footer.addArrangedSubview(SettingsButton("Close", handler: dismiss))
        footer.addArrangedSubview(SettingsButton("Open Settings", handler: edit))
        stack.addArrangedSubview(footer)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        return stack
    }

    func updateNSView(_ view: NSStackView, context: Context) {
        let scroll = view.arrangedSubviews.compactMap { $0 as? NSScrollView }.first
        (scroll?.documentView as? NSTextView)?.string = model.errors.joined(separator: "\n\n")
    }
}
