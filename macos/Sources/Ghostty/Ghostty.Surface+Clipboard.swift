import Foundation
import GhosttyKit

extension Ghostty.Surface {
    /// Owns a pending core request, whose pointer is invalidated by its first resolution.
    /// Retaining the surface keeps the core alive until native cancellation or completion.
    @MainActor final class ClipboardReadRequest {
        private let surface: Ghostty.Surface
        private var state: UnsafeMutableRawPointer?

        init(surface: Ghostty.Surface, state: UnsafeMutableRawPointer?) {
            self.surface = surface
            self.state = state
        }

        func deny() {
            guard let state else { return }
            self.state = nil
            ghostty_surface_deny_clipboard_request(surface.unsafeCValue, state)
        }

        func complete(contents: [Ghostty.ClipboardContent], available: [String],
                      confirmed: Bool = false, remember: Bool = false) {
            guard let state else { return }
            self.state = nil
            // Copy everything into C memory for the duration of the call.
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            var cDatas: [UnsafeMutableRawPointer] = []
            defer {
                cStrings.forEach { free($0) }
                cDatas.forEach { $0.deallocate() }
            }

            var cContents: [ghostty_clipboard_content_s] = []
            for entry in contents {
                guard let mime = strdup(entry.mime) else { continue }
                cStrings.append(mime)
                let buf = UnsafeMutableRawPointer.allocate(
                    byteCount: max(entry.data.count, 1),
                    alignment: 1)
                cDatas.append(buf)
                entry.data.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        buf.copyMemory(from: base, byteCount: src.count)
                    }
                }
                cContents.append(ghostty_clipboard_content_s(
                    mime: mime,
                    data: buf.assumingMemoryBound(to: CChar.self),
                    len: entry.data.count))
            }

            var cAvailable: [UnsafePointer<CChar>?] = []
            for mime in available {
                guard let str = strdup(mime) else { continue }
                cStrings.append(str)
                cAvailable.append(UnsafePointer(str))
            }

            cContents.withUnsafeBufferPointer { contentsBuf in
                cAvailable.withUnsafeBufferPointer { availableBuf in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availableBuf.baseAddress,
                        available_len: availableBuf.count,
                        confirmed: confirmed,
                        remember: remember)
                    ghostty_surface_complete_clipboard_request(surface.unsafeCValue, &complete, state)
                }
            }
        }
    }
}
