import GhosttyKit

extension QuickTerminalSize {
    init(from cStruct: ghostty_config_quick_terminal_size_s) {
        self.primary = Size(from: cStruct.primary)
        self.secondary = Size(from: cStruct.secondary)
    }

}

extension QuickTerminalSize.Size {
    init?(from cStruct: ghostty_quick_terminal_size_s) {
        switch cStruct.tag {
        case GHOSTTY_QUICK_TERMINAL_SIZE_NONE:
            return nil
        case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
            self = .percentage(cStruct.value.percentage)
        case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
            self = .pixels(cStruct.value.pixels)
        default:
            assertionFailure()
            return nil
        }
    }

}
