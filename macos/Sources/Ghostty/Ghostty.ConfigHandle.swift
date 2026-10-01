import Foundation
import GhosttyKit

extension Ghostty {
    /// Sole owner of a core configuration allocation. Native values live in ConfigSnapshot.
    @MainActor final class ConfigHandle {
        let value: ghostty_config_t
        private(set) var errors: [String]

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

        func report(_ messages: [String]) {
            errors.append(contentsOf: messages)
        }

        func formattedEntry(_ key: String) -> String {
            key.withCString { Ghostty.AllocatedString(ghostty_config_format_entry(value, $0, key.utf8.count)).string }
        }

        func hasSameSettings(as other: ConfigHandle) -> Bool { ghostty_settings_equal(value, other.value) }

        static var defaultPath: String {
            Ghostty.AllocatedString(ghostty_config_default_path()).string
        }

        static var hasCLIOverrides: Bool {
            !isRunningInXcode() && ghostty_config_has_cli_args()
        }

        static func load(settings: SettingsStore.Input, source: URL, cli: Bool = false) -> ConfigHandle? {
            guard let data = try? JSONEncoder().encode(settings), let cfg = ghostty_config_new() else { return nil }
            let loaded = data.withUnsafeBytes { bytes in
                source.path.withCString { path in
                    ghostty_settings_load(cfg, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count, path)
                }
            }
            guard loaded else { ghostty_config_free(cfg); return nil }
            if cli && hasCLIOverrides {
                ghostty_config_load_cli_args(cfg)
                ghostty_config_load_recursive_files(cfg)
            }
            ghostty_config_finalize(cfg)
            return ConfigHandle(adopting: cfg)
        }

        /// Startup snapshots contain file input only. CLI overrides are applied
        /// afterward and never written into the shared successful snapshot.
        static func load(data: Data, source: URL, cli: Bool = false) -> ConfigHandle? {
            guard let cfg = ghostty_config_new() else { return nil }
            if !data.isEmpty {
                data.withUnsafeBytes { bytes in
                    source.path.withCString { path in
                        ghostty_config_load_data(cfg, bytes.bindMemory(to: UInt8.self).baseAddress!, data.count, path)
                    }
                }
            }
            if cli && !isRunningInXcode() { ghostty_config_load_cli_args(cfg) }
            ghostty_config_load_recursive_files(cfg)
            ghostty_config_finalize(cfg)
            return ConfigHandle(adopting: cfg)
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
