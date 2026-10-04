import AppKit

/// The representations copied for a clipboard confirmation, ready for display.
struct ClipboardConfirmationPreview {
    struct Item: Identifiable {
        let id: Int
        let mime: String
        let byteCount: Int
        let text: String?
        let image: NSImage?

        var summary: String { "\(mime) (\(byteCount) bytes)" }
    }

    let items: [Item]
    let availableMimes: [String]

    var contents: String {
        items.compactMap(\.text).first ?? items.map(\.summary).joined(separator: "\n")
    }

    init(text: String) {
        items = [.init(id: 0, mime: "text/plain", byteCount: text.utf8.count, text: text, image: nil)]
        availableMimes = []
    }

    init(contents: [Ghostty.ClipboardContent], availableMimes: [String] = []) {
        items = contents.enumerated().map { index, content in
            Item(id: index, mime: content.mime, byteCount: content.data.count,
                 text: content.mime.hasPrefix("text/") ? content.string : nil,
                 image: content.mime.hasPrefix("image/") ? NSImage(data: content.data) : nil)
        }
        self.availableMimes = availableMimes
    }
}
