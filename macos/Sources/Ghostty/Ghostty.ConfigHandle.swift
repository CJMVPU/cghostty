import GhosttyKit

extension Ghostty {
    /// Sole owner of a core configuration allocation. Native values live in ConfigSnapshot.
    @MainActor final class ConfigHandle {
        let value: ghostty_config_t
        let errors: [String]

        private init(adopting value: ghostty_config_t) {
            self.value = value
            self.errors = Self.diagnostics(value)
        }

        convenience init?(cloning value: ghostty_config_t) {
            guard let clone = ghostty_config_clone(value) else { return nil }
            self.init(adopting: clone)
        }

        isolated deinit { ghostty_config_free(value) }

        func keybindTrigger(for action: String) -> ghostty_input_trigger_s {
            ghostty_config_trigger(value, action, UInt(action.utf8.count))
        }

        private static func diagnostics(_ config: ghostty_config_t?) -> [String] {
            guard let config else { return [] }
            return (0..<ghostty_config_diagnostics_count(config)).map { index in
                String(cString: ghostty_config_get_diagnostic(config, UInt32(index)).message)
            }
        }

        static func load(at path: String?, finalize: Bool) -> ConfigHandle? {
            // Initialize the global configuration.
            guard let cfg = ghostty_config_new() else {
                logger.critical("ghostty_config_new failed")
                return nil
            }

            // Load our configuration from files, CLI args, and then any referenced files.
            if let path {
                ghostty_config_load_file(cfg, path)
            } else {
                ghostty_config_load_default_files(cfg)
            }

            // We only load CLI args when not running in Xcode because in Xcode we
            // pass some special parameters to control the debugger.
            if !isRunningInXcode() {
                ghostty_config_load_cli_args(cfg)
            }

            ghostty_config_load_recursive_files(cfg)

            if finalize {
                // Finalize will make our defaults available.
                ghostty_config_finalize(cfg)
            }
            // Log any configuration errors. These will be automatically shown in a
            // pop-up window too.
            let result = ConfigHandle(adopting: cfg)
            let errors = result.errors
            if !errors.isEmpty {
                logger.warning("config error: \(errors.count, privacy: .public) configuration errors on reload")
                for message in errors {
                    logger.warning("config error: \(message, privacy: .public)")
                }
            }

            return result
        }

    }
}
