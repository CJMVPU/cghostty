import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

extension Ghostty.App {
    static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let surface = self.surfaceUserdata(from: userdata) else { return }
        surface.windowRegistry.owner(of: surface)?.closeSurface(surface, withConfirmation: processAlive)
    }

    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surfaceView = self.surfaceUserdata(from: userdata),
              let surface = surfaceView.surfaceModel else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // Get our pasteboard
        guard let pasteboard = NSPasteboard.ghostty(location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // Gather the representation for each requested MIME type that
        // the pasteboard can serve. We only ever read the requested
        // representations so unrelated (potentially large) clipboard
        // contents are never loaded.
        var contents: [Ghostty.ClipboardContent] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<mimesLen {
                guard let ptr = mimes[i] else { continue }
                let mime = String(cString: ptr)
                guard !seen.contains(mime) else { continue }
                seen.insert(mime)
                guard let data = pasteboard.ghosttyData(forMime: mime) else { continue }
                contents.append(.init(mime: mime, data: data))
            }
        }

        // The listing of available types, only gathered when requested.
        let available: [String] = list ? pasteboard.ghosttyAvailableMimes() : []

        // With nothing to serve and no listing requested there is
        // nothing to complete the read with.
        if contents.isEmpty && !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        Ghostty.Surface.ClipboardReadRequest(surface: surface, state: state)
            .complete(contents: contents, available: available)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let context = surfaceContext(from: userdata), let surface = context.surface else { return }
        let pending = Ghostty.Surface.ClipboardReadRequest(surface: surface, state: state)
        guard let surfaceView = context.view else {
            pending.deny()
            return
        }
        guard let confirm,
              let kind = Ghostty.ClipboardRequest.from(request: request) else {
            pending.deny()
            return
        }
        let c = confirm.pointee

        // Copy the borrowed C representations: the confirmation is
        // asynchronous and completes with exactly what the user
        // approved, so the clipboard is never re-read.
        var reps: [Ghostty.ClipboardContent] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let content = contents[i]
                let data: Data = if content.len > 0 {
                    Data(bytes: content.data, count: content.len)
                } else {
                    Data()
                }
                reps.append(.init(mime: String(cString: content.mime), data: data))
            }
        }
        var avail: [String] = []
        if let available = c.available {
            for i in 0..<c.available_len {
                guard let ptr = available[i] else { continue }
                avail.append(String(cString: ptr))
            }
        }

        // The dialog can only display text: show the text
        // representation when there is one and summarize the rest.
        let display = reps.first(where: { $0.mime == "text/plain" })
            .flatMap { String(data: $0.data, encoding: .utf8) }
            ?? reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

        // Decode an image representation so the dialog can preview
        // exactly what would be disclosed rather than a byte count.
        let previewImage: NSImage? = reps.lazy
            .filter { $0.mime.hasPrefix("image/") }
            .compactMap { NSImage(data: $0.data) }
            .first

        // libghostty reaches this callback only when the request attempted
        // by readClipboard requires confirmation. Reads allowed by policy
        // complete immediately and never become pending Swift state.
        let request = Ghostty.ClipboardConfirmationRequest(
            surface: surfaceView,
            contents: display,
            kind: kind,
            programName: c.name.map { String(cString: $0) },
            canRemember: c.can_remember,
            previewImage: previewImage
        ) { _, confirmed, remember in
            if confirmed {
                pending.complete(
                    contents: reps,
                    available: avail,
                    confirmed: true,
                    remember: remember)
            } else {
                pending.deny()
            }
        }
        surfaceView.pendingClipboardConfirmation = request
    }

    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let surfaceView = self.surfaceUserdata(from: userdata) else { return }
        guard let pasteboard = NSPasteboard.ghostty(location) else { return }
        guard let content = content, len > 0 else { return }

        // Convert the C array to Swift array
        let contentArray = (0..<len).compactMap { i in
            Ghostty.ClipboardContent.from(content: content[i])
        }
        guard !contentArray.isEmpty else { return }

        // Assert there is only one text/plain entry. For security reasons we need
        // to guarantee this for now since our confirmation dialog only shows one.
        assert(contentArray.filter({ $0.mime == "text/plain" }).count <= 1,
               "clipboard contents should have at most one text/plain entry")

        if !confirm {
            // Apply writes allowed by policy immediately. Only writes that
            // require confirmation continue to the pending request below.
            let types = contentArray.compactMap { item in
                NSPasteboard.PasteboardType(mimeType: item.mime)
            }
            pasteboard.declareTypes(types, owner: nil)

            // Set data for each type
            for item in contentArray {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setData(item.data, forType: type)
            }
            return
        }

        // For confirmation, use the text/plain content if it exists
        guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }),
              let textPlainString = textPlainContent.string else {
            return
        }

        let request = Ghostty.ClipboardConfirmationRequest(
            surface: surfaceView,
            contents: textPlainString,
            kind: .osc_52_write
        ) { _, confirmed, _ in
            guard confirmed else { return }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(textPlainString, forType: .string)
        }
        surfaceView.pendingClipboardConfirmation = request
    }

}
