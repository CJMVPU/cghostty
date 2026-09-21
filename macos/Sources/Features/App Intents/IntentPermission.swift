import AppKit

/// Checks the configured Shortcuts policy, remembering approval across launches.
@MainActor
func requestIntentPermission() async -> Bool {
    if let delegate = NSApp.delegate as? AppDelegate {
        switch delegate.ghostty.config.macosShortcuts {
        case .allow: return true
        case .deny: return false
        case .ask: break
        }
    }
    return ShortcutsPermission.request()
}

@MainActor
enum ShortcutsPermission {
    private static let key = "com.cjmvpu.cghostty.shortcutsPermission"

    static func request() -> Bool {
        if let decision = storedDecision() { return decision }

        let alert = NSAlert()
        alert.messageText = "Allow Shortcuts to interact with cghostty?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed { rememberAllowance() }
        return allowed
    }

    /// Retrieves a cached permission decision if it hasn't expired
    /// - Returns: The cached decision, or nil if no valid cached decision exists
    static func storedDecision() -> Bool? {
        let userDefaults = UserDefaults.ghostty
        guard let data = userDefaults.data(forKey: key),
              let storedPermission = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: StoredPermission.self, from: data) else {
            return nil
        }

        if Date() > storedPermission.expiry {
            // Decision has expired, remove stored value
            userDefaults.removeObject(forKey: key)
            return nil
        }

        return storedPermission.result
    }

    /// Keep the existing archive format and long-lived approval expiration.
    private static func rememberAllowance() {
        let expiryDate = Date().addingTimeInterval(3153600000)
        let storedPermission = StoredPermission(result: true, expiry: expiryDate)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: storedPermission, requiringSecureCoding: true) {
            let userDefaults = UserDefaults.ghostty
            userDefaults.set(data, forKey: key)
        }
    }

    /// Internal class for storing permission decisions with expiration dates in UserDefaults
    /// Conforms to NSSecureCoding for safe archiving/unarchiving
    @objc(StoredPermission)
    private class StoredPermission: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool = true

        let result: Bool
        let expiry: Date

        init(result: Bool, expiry: Date) {
            self.result = result
            self.expiry = expiry
            super.init()
        }

        required init?(coder: NSCoder) {
            self.result = coder.decodeBool(forKey: "result")
            guard let expiry = coder.decodeObject(of: NSDate.self, forKey: "expiry") as? Date else {
                return nil
            }
            self.expiry = expiry
            super.init()
        }

        func encode(with coder: NSCoder) {
            coder.encode(result, forKey: "result")
            coder.encode(expiry, forKey: "expiry")
        }
    }
}
