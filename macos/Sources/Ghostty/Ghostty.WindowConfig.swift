import GhosttyKit

extension Ghostty {
    /// Owned native values from one effective config (app or surface scope).
    /// Old snapshots remain valid after reload and after freeing the C handle.
    nonisolated struct WindowConfig: Sendable, Equatable {
        let positionX: Int16?
        let positionY: Int16?
        let stepResize: Bool
        let focusFollowsMouse: Bool
        let maximize: Bool
        let titleFontFamily: String?

        @MainActor
        init(config: ghostty_config_t?) {
            func boolean(_ key: ConfigSchema.Key<Bool>, unloaded: Bool = false) -> Bool {
                guard let config else { return unloaded }
                var value = false
                _ = key.read(from: config, into: &value)
                return value
            }

            func position(_ key: ConfigSchema.Key<Int16>) -> Int16? {
                guard let config else { return nil }
                var value: Int16 = 0
                return key.read(from: config, into: &value) ? value : nil
            }

            func string(_ key: ConfigSchema.Key<UnsafePointer<CChar>?>) -> String? {
                guard let config else { return nil }
                var value: UnsafePointer<CChar>?
                guard key.read(from: config, into: &value),
                      let value else { return nil }
                return String(cString: value)
            }

            positionX = position(ConfigSchema.windowPositionX)
            positionY = position(ConfigSchema.windowPositionY)
            // Preserve the existing unloaded-config fallback, distinct from
            // the finalized configuration's default (false).
            stepResize = boolean(ConfigSchema.windowStepResize, unloaded: true)
            focusFollowsMouse = boolean(ConfigSchema.focusFollowsMouse)
            maximize = boolean(ConfigSchema.maximize, unloaded: true)
            titleFontFamily = string(ConfigSchema.windowTitleFontFamily)
        }
    }
}
