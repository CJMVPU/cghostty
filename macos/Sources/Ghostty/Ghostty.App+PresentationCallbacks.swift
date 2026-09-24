import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

extension Ghostty.App {
    static func setTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_set_title_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let title = String(cString: v.title!, encoding: .utf8) else { return }
        surfaceView.setTitle(title)
    }

    static func setTabTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_set_title_s
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            Ghostty.logger.warning("set tab title does nothing with an app target")
            return false

        case GHOSTTY_TARGET_SURFACE:
            guard let title = String(cString: v.title!, encoding: .utf8) else { return false }
            let titleOverride = title.isEmpty ? nil : title
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }
            controller.titleOverride = titleOverride
            return true

        default:
            assertionFailure()
            return false
        }
    }

    static func showSurfaceFault(
        target: ghostty_target_s,
        value: ghostty_surface_fault_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = surfaceView(from: surface) else { return false }
        // Publish synchronously on the app thread, even before window attachment.
        // Returning true means the native view owns a visible, durable explanation.
        view.state.fault = Ghostty.SurfaceFault(value)
        view.state.childExitedMessage = nil
        return true
    }

    static func showChildExited(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_surface_message_childexited_s,
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            // We handle this when the window is visible and timetime_ms is greater than 0,
            // which will rule out exit codes on launch
            guard surfaceView.window != nil, v.timetime_ms > 0 else { return false }
            guard let config = appState(from: app)?.config else { return false }
            surfaceView.setChildExitedMessage(.init(v, threshold: config.abnormalCommandExitRuntime))
            return true
        default:
            return false
        }
    }

    static func copyTitleToClipboard(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            guard let surfaceView = self.surfaceView(from: surface) else { return false }
            let title = surfaceView.title
            if title.isEmpty { return false }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(title, forType: .string)
            return true

        default:
            return false
        }
    }

    static func promptTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_prompt_title_e) -> Bool {
        let promptTitle = Ghostty.Action.PromptTitle(v)
        switch promptTitle {
        case .surface:
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set title prompt does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                surfaceView.promptTitle()
                return true

            default:
                assertionFailure()
                return false
            }

        case .tab:
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                guard let registry = appState(from: app)?.windowRegistry,
                      let controller = registry.windowControllers.first(where: { $0.window?.isMainWindow == true })
                        ?? registry.windowControllers.first(where: { $0.window?.isKeyWindow == true })
                else { return false }
                controller.promptTabTitle()
                return true

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.windowRegistry.owner(of: surfaceView) else { return false }
                controller.promptTabTitle()
                return true

            default:
                assertionFailure()
                return false
            }
        }
    }

    static func pwdChanged(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_pwd_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let pwd = String(cString: v.pwd!, encoding: .utf8) else { return }
        surfaceView.pwd = pwd
    }

    static func setMouseShape(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        shape: ghostty_action_mouse_shape_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        if let style = CursorStyle(coreShape: shape) { surfaceView.setCursorShape(style) }
    }

    static func setMouseVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_mouse_visibility_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        switch v {
        case GHOSTTY_MOUSE_VISIBLE:
            surfaceView.setCursorVisibility(true)

        case GHOSTTY_MOUSE_HIDDEN:
            surfaceView.setCursorVisibility(false)

        default:
            return
        }
    }

    static func setMouseOverLink(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_mouse_over_link_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard v.len > 0 else {
            surfaceView.hoverUrl = nil
            return
        }

        let buffer = Data(bytes: v.url!, count: v.len)
        surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)
    }

    static func setInitialSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_initial_size_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.initialSize = NSSize(width: Double(v.width), height: Double(v.height))
    }

    static func resetWindowSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        (surfaceView.windowRegistry.owner(of: surfaceView) as? TerminalController)?.returnToDefaultSize(nil)
    }

    static func setCellSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_cell_size_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
        DispatchQueue.main.async { [weak surfaceView] in
            guard let surfaceView else { return }
            surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
        }
    }

    static func rendererHealth(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_renderer_health_e) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        surfaceView.updateRendererHealth(v == GHOSTTY_RENDERER_HEALTH_HEALTHY)
    }

    static func keySequence(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_key_sequence_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        if v.active {
            guard let key = Ghostty.keyboardShortcut(for: v.trigger) else { return }
            surfaceView.continueKeySequence(key)
        } else {
            surfaceView.endKeySequence()
        }
    }

    static func keyTable(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_key_table_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let action = Ghostty.Action.KeyTable(c: v) else { return }

        surfaceView.updateKeyTable(action)
    }

    static func progressReport(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_progress_report_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }
        guard let config = appState(from: app)?.config else { return }

        guard config.progressStyle else {
            Ghostty.logger.debug("progress_report action blocked by config")
            DispatchQueue.main.async {
                surfaceView.progressReport = nil
            }
            return
        }

        let progressReport = Ghostty.Action.ProgressReport(c: v)
        DispatchQueue.main.async {
            if progressReport.state == .remove {
                surfaceView.progressReport = nil
            } else {
                surfaceView.progressReport = progressReport
            }
        }
    }

    static func scrollbar(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_scrollbar_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let scrollbar = Ghostty.Action.Scrollbar(c: v)
        surfaceView.updateScrollbar(scrollbar)
    }

    static func startSearch(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_start_search_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let startSearch = Ghostty.Action.StartSearch(c: v)
        DispatchQueue.main.async {
            if let searchState = surfaceView.searchState {
                if let needle = startSearch.needle, !needle.isEmpty {
                    searchState.setNeedle(needle)
                }
            } else {
                surfaceView.searchState = Ghostty.SearchState(from: startSearch)
            }

            surfaceView.searchState?.requestFocus()
        }
    }

    static func endSearch(
        _ app: ghostty_app_t,
        target: ghostty_target_s) -> Bool {
        guard let surfaceView = self.surfaceView(for: target) else { return false }

        DispatchQueue.main.async {
            surfaceView.endSearch()
        }
        return true
    }

    static func searchTotal(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_search_total_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let total: UInt? = v.total >= 0 ? UInt(v.total) : nil
        DispatchQueue.main.async {
            surfaceView.searchState?.total = total
        }
    }

    static func searchSelected(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_search_selected_s) {
        guard let surfaceView = self.surfaceView(for: target) else { return }

        let selected: UInt? = v.selected >= 0 ? UInt(v.selected) : nil
        DispatchQueue.main.async {
            surfaceView.searchState?.selected = selected
        }
    }

    static func applyTheme(
        _ app: ghostty_app_t,
        target: ghostty_target_s) {
        Ghostty.logger.info("apply theme notification")

        guard let app_ud = ghostty_app_userdata(app) else { return }
        let ghostty = Unmanaged<Ghostty.App>.fromOpaque(app_ud).takeUnretainedValue()

        switch target.tag {
        case GHOSTTY_TARGET_APP:
            ghostty.applyTheme()
            return

        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            if let model = surfaceView(from: surface)?.surfaceModel {
                ghostty.applyTheme(surface: model)
            }

        default:
            assertionFailure()
        }
    }

    static func configChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        v: ghostty_action_config_change_s) {
            Ghostty.logger.info("config change notification")

            // Clone the config so we own the memory. It'd be nicer to not have to do
            // this but since we async send the config out below we have to own the lifetime.
            // A future improvement might be to add reference counting to config or
            // something so apprt's do not have to do this.
            let config = Ghostty.Config(clone: v.config)

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                // We also REPLACE our app-level config when this happens. This lets
                // all the various things that depend on this but are still theme specific
                // such as split border color work.
                guard let app_ud = ghostty_app_userdata(app) else { return }
                let ghostty = Unmanaged<Ghostty.App>.fromOpaque(app_ud).takeUnretainedValue()
                ghostty.acceptConfiguration(config)

                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.acceptConfiguration(config)

            default:
                assertionFailure()
            }
        }

    static func colorChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        change: ghostty_action_color_change_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("color change does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.acceptColorChange(Ghostty.Action.ColorChange(c: change))

            default:
                assertionFailure()
            }
    }
}
