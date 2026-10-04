import SwiftUI

/// This delegate is notified of the completion result of the clipboard confirmation dialog.
protocol ClipboardConfirmationViewDelegate: AnyObject {
    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, remember: Bool)
}

/// The SwiftUI view for showing a clipboard confirmation dialog.
struct ClipboardConfirmationView: View {
    enum Action: String {
        case cancel
        case confirm

        static func text(_ action: Action, _ reason: Ghostty.ClipboardRequest) -> String {
            switch (action, reason) {
            case (.cancel, .paste):
                return "Cancel"
            case (.cancel, .osc_52_read), (.cancel, .osc_52_write),
                 (.cancel, .kitty_read), (.cancel, .kitty_write):
                return "Deny"
            case (.confirm, .paste):
                return "Paste"
            case (.confirm, .osc_52_read), (.confirm, .osc_52_write),
                 (.confirm, .kitty_read), (.confirm, .kitty_write):
                return "Allow"
            }
        }
    }

    /// The contents of the paste.
    let preview: ClipboardConfirmationPreview

    var contents: String { preview.contents }

    /// The type of the clipboard request
    let request: Ghostty.ClipboardRequest

    /// The human friendly name of the requesting program, when the
    /// protocol carries one.
    var programName: String?

    /// True when the user's decision may be remembered as a session
    /// grant, showing the remember toggle.
    var canRemember: Bool = false

    /// Optional delegate to get results. If this is nil, then this view will never close on its own.
    weak var delegate: ClipboardConfirmationViewDelegate?

    /// Whether the user's decision should be remembered for the session.
    @State private var remember: Bool = false

    /// Used to track if we should rehide on disappear
    @State private var cursorHiddenCount: UInt = 0

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 42))
                    .padding()
                    .frame(alignment: .center)

                Text(request.text(name: programName))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let text = item.text {
                                TextEditor(text: .constant(text))
                                    .focusable(false)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(height: 120)
                            }
                            if let image = item.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 160)
                            }
                        }
                    }
                    if !preview.availableMimes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available types")
                                .font(.caption.bold())
                            Text(preview.availableMimes.joined(separator: "\n"))
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if canRemember {
                Toggle("Remember this choice for the session", isOn: $remember)
                    .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button(Action.text(.cancel, request)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(Action.text(.confirm, request)) { onPaste() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.bottom)
        }
        .onAppear {
            // I can't find a better way to handle this. There is no API to detect
            // if the cursor is hidden and OTHER THINGS do unhide the cursor. So we
            // try to unhide it completely here and hope for the best. Issue #1516.
            cursorHiddenCount = Cursor.unhideCompletely()

            // If we didn't unhide anything, we just send an unhide to be safe.
            // I don't think the count can go negative on NSCursor so this handles
            // scenarios cursor is hidden outside of our own NSCursor usage.
            if cursorHiddenCount == 0 {
                _ = Cursor.unhide()
            }
        }
        .onDisappear {
            // Rehide if we unhid
            for _ in 0..<cursorHiddenCount {
                Cursor.hide()
            }
        }
    }

    private func onCancel() {
        delegate?.clipboardConfirmationComplete(.cancel, remember: false)
    }

    private func onPaste() {
        delegate?.clipboardConfirmationComplete(.confirm, remember: remember)
    }
}
