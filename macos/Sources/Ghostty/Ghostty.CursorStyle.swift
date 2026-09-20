import GhosttyKit

extension CursorStyle {
    init?(coreShape shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            self = .default

        case GHOSTTY_MOUSE_SHAPE_TEXT:
            self = .horizontalText

        case GHOSTTY_MOUSE_SHAPE_GRAB:
            self = .grabIdle

        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            self = .grabActive

        case GHOSTTY_MOUSE_SHAPE_POINTER:
            self = .link

        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            self = .resizeLeft

        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            self = .resizeRight

        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            self = .resizeUp

        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            self = .resizeDown

        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            self = .resizeUpDown

        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            self = .resizeLeftRight

        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            self = .verticalText

        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            self = .contextMenu

        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            self = .crosshair

        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            self = .operationNotAllowed

        default:
            // We ignore unknown shapes.
            return nil
        }
    }

}
