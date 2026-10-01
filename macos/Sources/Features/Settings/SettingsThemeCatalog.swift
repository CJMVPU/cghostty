import AppKit

@MainActor final class SettingsThemeCatalog {
    static let shared = SettingsThemeCatalog(directories: defaultDirectories)
    private let directories: [URL]
    private var signatures: [URL: Date]?
    private var cached: [String] = []

    init(directories: [URL]) { self.directories = Array(Set(directories)) }

    func load() -> [String] {
        let current = Dictionary(uniqueKeysWithValues: directories.map { directory in
            let date = (try? FileManager.default.attributesOfItem(atPath: directory.resolvingSymlinksInPath().path)[.modificationDate]) as? Date ?? .distantPast
            return (directory, date)
        })
        guard current != signatures else { return cached }
        signatures = current
        cached = Set(directories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? [])
                .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.lastPathComponent)
        }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return cached
    }

    private static var defaultDirectories: [URL] {
        var directories: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cjmvpu.cghostty").appendingPathComponent("themes"))
        }
        if let resources = Bundle.main.resourceURL { directories.append(resources.appendingPathComponent("cghostty/themes")) }
        #if !DEBUG
        if let resources = ProcessInfo.processInfo.environment["CGHOSTTY_RESOURCES_DIR"], !resources.isEmpty {
            directories.append(URL(fileURLWithPath: resources).appendingPathComponent("themes"))
        }
        #endif
        return Array(Set(directories))
    }
}
