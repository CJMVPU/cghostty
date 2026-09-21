import Foundation
import Testing
@testable import Ghostty

@MainActor struct ShortcutsPermissionTests {
    @Test func existingApprovalSurvivesAndExpiredApprovalIsCleared() throws {
        let defaults = UserDefaults.ghostty
        let key = "com.cjmvpu.cghostty.shortcutsPermission"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // Archives created by the previous StoredPermission implementation:
        // an approval expiring in 2100 and one that expired in 1970.
        let valid = """
        YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZl
        ctEICVRyb290gAGlCwwTFx1VJG51bGzTDQ4PEBESVnJlc3VsdFYkY2xhc3NWZXhwaXJ5CYAEgALSFA4VFldOUy50aW1lI0Hn
        RtHQAAAAgAPSGBkaG1okY2xhc3NuYW1lWCRjbGFzc2VzVk5TRGF0ZaIaHFhOU09iamVjdNIYGR4fXxAQU3RvcmVkUGVybWlz
        c2lvbqIgHF8QEFN0b3JlZFBlcm1pc3Npb24IERokKTI3SUxRU1lfZm10e3x+gIWNlpidqLG4u8TJ3N8AAAAAAAABAQAAAAAA
        AAAhAAAAAAAAAAAAAAAAAAAA8g==
        """
        let expired = """
        YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZl
        ctEICVRyb290gAGlCwwTFx1VJG51bGzTDQ4PEBESVnJlc3VsdFYkY2xhc3NWZXhwaXJ5CYAEgALSFA4VFldOUy50aW1lI8HN
        J+RAAAAAgAPSGBkaG1okY2xhc3NuYW1lWCRjbGFzc2VzVk5TRGF0ZaIaHFhOU09iamVjdNIYGR4fXxAQU3RvcmVkUGVybWlz
        c2lvbqIgHF8QEFN0b3JlZFBlcm1pc3Npb24IERokKTI3SUxRU1lfZm10e3x+gIWNlpidqLG4u8TJ3N8AAAAAAAABAQAAAAAA
        AAAhAAAAAAAAAAAAAAAAAAAA8g==
        """
        let validData: Data = try #require(Data(base64Encoded: valid, options: .ignoreUnknownCharacters))
        defaults.set(validData, forKey: key)
        #expect(ShortcutsPermission.storedDecision() == true)
        let expiredData: Data = try #require(Data(base64Encoded: expired, options: .ignoreUnknownCharacters))
        defaults.set(expiredData, forKey: key)
        #expect(ShortcutsPermission.storedDecision() == nil)
        #expect(defaults.object(forKey: key) == nil)
    }
}
