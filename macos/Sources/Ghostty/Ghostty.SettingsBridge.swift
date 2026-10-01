import AppKit
import CoreText
import GhosttyKit

extension Ghostty {
    @MainActor enum SettingsBridge {
        static var catalogData: Data { Data(AllocatedString(ghostty_settings_catalog()).string.utf8) }

        static func font(size: CGFloat) -> NSFont {
            var length = 0
            guard let bytes = ghostty_settings_font_data(&length),
                  let provider = CGDataProvider(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
                                                          count: length, deallocator: .none) as CFData),
                  let face = CGFont(provider) else { preconditionFailure("Missing embedded settings font") }
            return CTFontCreateWithGraphicsFont(face, size, nil, nil) as NSFont
        }
    }
}
