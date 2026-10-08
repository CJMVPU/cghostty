import Foundation
import GhosttyKit

extension Ghostty {
    /// Sole owner of a core configuration allocation. Native values live in ConfigSnapshot.
    @MainActor final class ConfigHandle {
        let value: ghostty_config_t
        private(set) var settingsDiagnostics: [SettingsDiagnostic]
        var errors: [String] { settingsDiagnostics.map(\.rawMessage) }

        #if CGHOSTTY_TESTING
        static var formattedEntryCallsForTesting = 0
        static var cloneCallsForTesting = 0
        static var settingsLoadCallsForTesting = 0
        #endif

        /// Temporary settings parsers are created, read and freed on the calling
        /// executor. No raw handle leaves settingsProjection or crosses an await.
        private nonisolated static func makeSettingsConfig(data: Data, source: URL, dark: Bool) -> ghostty_config_t? {
            guard let config = ghostty_config_new() else { return nil }
            ghostty_config_set_initial_theme(config, dark)
            let loaded = data.withUnsafeBytes { bytes in
                source.path.withCString { path in
                    ghostty_settings_load(config, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count, path)
                }
            }
            guard loaded else { ghostty_config_free(config); return nil }
            return config
        }

        nonisolated static func settingsProjection(_ data: Data, source: URL, fields: [SettingsField], dark: Bool) throws -> (values: [String: String], diagnostics: [SettingsDiagnostic]) {
            try Task.checkCancellation()
            guard let config = Self.makeSettingsConfig(data: data, source: source, dark: dark) else {
                return ([:], [SettingsDiagnostic(kind: .core, message: "Unable to create the settings parser.")])
            }
            defer { ghostty_config_free(config) }
            ghostty_config_finalize(config)
            var values: [String: String] = [:]
            var errors = (0..<ghostty_config_diagnostics_count(config)).map {
                SettingsDiagnostic(core: ghostty_config_get_diagnostic(config, UInt32($0)))
            }
            for field in fields {
                try Task.checkCancellation()
                let entry = field.key.withCString { ghostty_config_format_entry(config, $0, field.key.utf8.count) }
                guard entry.ptr != nil else {
                    errors.append(SettingsDiagnostic(key: field.key, kind: .core, message: "Unable to read the setting value."))
                    values[field.key] = ""
                    continue
                }
                values[field.key] = SettingsField.values(from: Ghostty.AllocatedString(entry).string).joined(separator: "\n")
            }
            return (values, errors)
        }

        private init(adopting value: ghostty_config_t) {
            self.value = value
            self.settingsDiagnostics = Self.diagnostics(value)
        }

        convenience init?(cloning value: ghostty_config_t) {
            #if CGHOSTTY_TESTING
            Self.cloneCallsForTesting += 1
            #endif
            guard let clone = ghostty_config_clone(value) else { return nil }
            self.init(adopting: clone)
        }

        isolated deinit { ghostty_config_free(value) }

        func keybindTrigger(for action: String) -> ghostty_input_trigger_s {
            ghostty_config_trigger(value, action, UInt(action.utf8.count))
        }

        private static func diagnostics(_ config: ghostty_config_t?) -> [SettingsDiagnostic] {
            guard let config else { return [] }
            return (0..<ghostty_config_diagnostics_count(config)).map { index in
                SettingsDiagnostic(core: ghostty_config_get_diagnostic(config, UInt32(index)))
            }
        }

        func report(_ messages: [String]) {
            settingsDiagnostics.append(contentsOf: messages.map { SettingsDiagnostic(kind: .core, message: $0) })
        }

        func formattedEntry(_ key: String) -> String {
            #if CGHOSTTY_TESTING
            Self.formattedEntryCallsForTesting += 1
            #endif
            let entry = key.withCString { ghostty_config_format_entry(value, $0, key.utf8.count) }
            guard entry.ptr != nil else {
                settingsDiagnostics.append(SettingsDiagnostic(key: key, kind: .core, message: "Unable to read the setting value."))
                return ""
            }
            return Ghostty.AllocatedString(entry).string
        }

        func hasSameSettings(as other: ConfigHandle) -> Bool { ghostty_settings_equal(value, other.value) }

        /// Exact bytes captured by the parser, not paths reconstructed from the
        /// final config-file value or files reopened after validation.
        func sourceFiles() throws -> [SettingsStore.Layer] {
            let json = ghostty_config_source_files(value)
            guard json.ptr != nil else { throw SettingsStore.Failure.unreadable }
            let text = Ghostty.AllocatedString(json).string
            return try JSONDecoder().decode([SettingsStore.Layer].self, from: Data(text.utf8))
        }

        static var defaultPath: String {
            Ghostty.AllocatedString(ghostty_config_default_path()).string
        }

        static var hasCLIOverrides: Bool {
            !isRunningInXcode() && ghostty_config_has_cli_args()
        }

        nonisolated enum SettingsRecoverySource: Sendable { case current, previous, defaults }

        /// Selection consumes existing evaluations instead of reparsing a record.
        static func settingsRecoverySource(currentValid: Bool, previousValid: Bool) -> SettingsRecoverySource {
            let selected = ghostty_settings_select_recovery(currentValid, previousValid)
            switch selected {
            case GHOSTTY_SETTINGS_RECOVERY_CURRENT: return .current
            case GHOSTTY_SETTINGS_RECOVERY_PREVIOUS: return .previous
            case GHOSTTY_SETTINGS_RECOVERY_DEFAULTS: return .defaults
            default: return .defaults
            }
        }

        static func load(settings: SettingsStore.Input, source: URL, cli: Bool = false, dark: Bool = false) -> ConfigHandle? {
            #if CGHOSTTY_TESTING
            settingsLoadCallsForTesting += 1
            #endif
            guard let data = try? JSONEncoder().encode(settings),
                  let cfg = Self.makeSettingsConfig(data: data, source: source, dark: dark) else { return nil }
            if cli && hasCLIOverrides {
                ghostty_config_load_cli_args(cfg)
                ghostty_config_load_recursive_files(cfg)
            }
            ghostty_config_finalize(cfg)
            return ConfigHandle(adopting: cfg)
        }

        /// Startup snapshots contain file input only. CLI overrides are applied
        /// afterward and never written into the shared successful snapshot.
        static func load(data: Data, source: URL, cli: Bool = false, dark: Bool = false) -> ConfigHandle? {
            guard let cfg = ghostty_config_new() else { return nil }
            ghostty_config_set_initial_theme(cfg, dark)
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

nonisolated extension SettingsDiagnostic {
    init(core: ghostty_diagnostic_s) {
        let field = String(cString: core.key)
        key = field.isEmpty ? nil : field
        kind = .core
        message = String(cString: core.detail)
        if let path = core.source, core.source_len > 0 {
            source = String(bytes: UnsafeRawBufferPointer(start: path, count: Int(core.source_len)), encoding: .utf8)
        }
        line = core.line
    }

}
