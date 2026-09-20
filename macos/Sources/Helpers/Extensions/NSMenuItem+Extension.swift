import AppKit

extension NSMenuItem {
    /// Sets the image property from a symbol if we want images on our menu items.
    func setImageIfDesired(systemSymbolName symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}
