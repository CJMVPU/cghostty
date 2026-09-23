import AppKit
import AppIntents
import Observation

struct TerminalEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Working Directory")
    var workingDirectory: String?

    @Property(title: "PID")
    var pid: Int?

    @Property(title: "TTY")
    var tty: String?

    @Property(title: "Kind")
    var kind: Kind

    private var screenshotData: Data?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    nonisolated var displayRepresentation: DisplayRepresentation {
        var rep = DisplayRepresentation(title: "\(title)")
        if let data = screenshotData {
            rep.image = .init(data: data)
        }

        return rep
    }

    /// Returns the view associated with this entity. This may no longer exist.
    @MainActor
    var surfaceView: Ghostty.SurfaceView? {
        Self.defaultQuery.all.first { $0.id == self.id }
    }

    @MainActor
    var surfaceModel: Ghostty.Surface? {
        surfaceView?.surfaceModel
    }

    static let defaultQuery = TerminalQuery()

    @MainActor
    init(_ view: Ghostty.SurfaceView) {
        self.id = view.id
        self.title = view.title
        self.workingDirectory = view.pwd
        self.pid = view.surfaceModel?.foregroundPID
        self.tty = view.surfaceModel?.ttyName
        self.screenshotData = view.thumbnailPNG()

        // Determine the kind based on the window controller type
        if view.window?.windowController is QuickTerminalController {
            self.kind = .quick
        } else {
            self.kind = .normal
        }
    }

    /// Wait for initial terminal metadata, bounded by a one-second deadline.
    /// Observation reads both fields together and cancellation ends the loser.
    @MainActor
    init(view: Ghostty.SurfaceView) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.waitForMetadata(view) }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
            }
            await group.next()
            group.cancelAll()
        }
        self.init(view)
        self.workingDirectory = view.pwd ?? ""
    }
    @MainActor private static func waitForMetadata(_ view: Ghostty.SurfaceView) async {
        let metadata = Observations { (view.title, view.pwd) }
        for await (title, pwd) in metadata {
            if Task.isCancelled || (!title.isEmpty && pwd != nil) { return }
        }
    }

}

extension TerminalEntity {
    enum Kind: String, AppEnum {
        case normal
        case quick

        static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Kind")

        static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
            .normal: .init(title: "Normal"),
            .quick: .init(title: "Quick")
        ]
    }
}

struct TerminalQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    func entities(for identifiers: [TerminalEntity.ID]) async throws -> [TerminalEntity] {
        return all.filter {
            identifiers.contains($0.id)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TerminalEntity] {
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(string)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func allEntities() async throws -> [TerminalEntity] {
        return all.map { TerminalEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TerminalEntity] {
        return try await allEntities()
    }

    @MainActor
    var all: [Ghostty.SurfaceView] {
        // Find all of our terminal windows. This will include the quick terminal
        // but only if it was previously opened.
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty else { return [] }
        let controllers = app.windowRegistry.windowControllers

        // Get all our surfaces
        return controllers.flatMap {
            $0.surfaceTree.root?.leaves() ?? []
        }
    }
}
