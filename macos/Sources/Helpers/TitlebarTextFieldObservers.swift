import AppKit

/// Rebind only when AppKit actually replaces a title field. Weak field references
/// avoid keeping detached fullscreen/titlebar views alive through our registry.
@MainActor
final class TitlebarTextFieldObservers {
    private struct Entry {
        weak var field: NSTextField?
        let observer: NSObjectProtocol
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var onChange: ((NSTextField) -> Void)?
    private(set) var registrations = 0
    var count: Int { entries.count }

    func update(_ fields: [NSTextField], onChange: @escaping (NSTextField) -> Void) {
        self.onChange = onChange
        let members = Set(fields.map(ObjectIdentifier.init))
        for (id, entry) in entries where !members.contains(id) || entry.field == nil {
            NotificationCenter.default.removeObserver(entry.observer)
            entries.removeValue(forKey: id)
        }
        for field in fields {
            let id = ObjectIdentifier(field)
            guard entries[id] == nil else { continue }
            field.postsFrameChangedNotifications = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: field, queue: .main
            ) { [weak self, weak field] _ in
                MainActor.assumeIsolated {
                    guard let field else { return }
                    self?.onChange?(field)
                }
            }
            entries[id] = Entry(field: field, observer: observer)
            registrations += 1
        }
    }

    isolated deinit {
        for entry in entries.values { NotificationCenter.default.removeObserver(entry.observer) }
    }
}
