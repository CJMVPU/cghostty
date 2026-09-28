/// Retained only to decode window restoration archives from older versions.
/// Fixed-size windows do not implement fullscreen transitions.
enum FullscreenMode: String, Codable, Sendable {
    case native
    case nonNative
    case nonNativeVisibleMenu
    case nonNativePaddedNotch
}
