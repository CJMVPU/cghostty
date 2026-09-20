import GhosttyKit

extension Ghostty {
    enum TabDestination: Equatable {
        case previous, next, last
        case index(Int)

        init?(coreValue: ghostty_action_goto_tab_e) {
            switch coreValue {
            case GHOSTTY_GOTO_TAB_PREVIOUS: self = .previous
            case GHOSTTY_GOTO_TAB_NEXT: self = .next
            case GHOSTTY_GOTO_TAB_LAST: self = .last
            default:
                guard coreValue.rawValue > 0 else { return nil }
                self = .index(Int(coreValue.rawValue))
            }
        }
    }
}
