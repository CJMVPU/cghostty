import AppKit
import AppIntents
import Observation
import SwiftUI

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

    var screenshot: NSImage?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    nonisolated var displayRepresentation: DisplayRepresentation {
        var rep = DisplayRepresentation(title: "\(title)")
        if let screenshot,
           let data = screenshot.tiffRepresentation {
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
        if let nsImage = ImageRenderer(content: view.screenshot()).nsImage {
            self.screenshot = nsImage
        }

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
        self.id = view.id
        self.tty = view.surfaceModel?.ttyName

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.waitForMetadata(view) }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
            }
            await group.next()
            group.cancelAll()
        }
        self.title = view.title
        self.workingDirectory = view.pwd ?? ""

        // Wait for the title and pwd then get latest pid and screenshots.
        // This should gave SurfaceView enough time to layout in the window and we can get the most recent process's PID
        // Determine the kind based on the window controller type
        if view.window?.windowController is QuickTerminalController {
            self.kind = .quick
        } else {
            self.kind = .normal
        }

        self.pid = view.surfaceModel?.foregroundPID
        if let nsImage = ImageRenderer(content: view.screenshot()).nsImage {
            self.screenshot = nsImage
        }
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
        let controllers = NSApp.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        // Get all our surfaces
        return controllers.flatMap {
            $0.surfaceTree.root?.leaves() ?? []
        }
    }
}
