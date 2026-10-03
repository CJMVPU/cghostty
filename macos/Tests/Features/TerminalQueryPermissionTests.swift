import AppKit
import Testing
@testable import Ghostty

@MainActor struct TerminalQueryPermissionTests {
    private class PermissionState {
        var allowed = false
        var checks = 0
    }
    @Test func deniedEnumerationDoesNotReadTerminalMetadata() async throws {
        var permissionChecks = 0
        var applicationReads = 0
        let query = TerminalQuery(permission: {
            permissionChecks += 1
            return false
        }, application: {
            applicationReads += 1
            return nil
        })
        let identified = try await query.entities(for: [UUID()])
        let matching = try await query.entities(matching: "private")
        let all = try await query.allEntities()
        let suggested = try await query.suggestedEntities()
        #expect(identified.isEmpty)
        #expect(matching.isEmpty)
        #expect(all.isEmpty)
        #expect(suggested.isEmpty)
        #expect(permissionChecks == 4)
        #expect(applicationReads == 0)
    }

    @Test func approvedEnumerationAndInternalLookupUseRegisteredSurfaces() async throws {
        let app = Ghostty.App(configPath: "/dev/null")
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/zsh -f"
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        let surface = try #require(controller.surfaceTree.first)
        surface.restoreTitle("private terminal", isUserSet: true)
        defer { window.close() }
        let permission = PermissionState()
        let query = TerminalQuery(permission: {
            permission.checks += 1
            return permission.allowed
        }, application: { app })
        #expect(query.surface(for: surface.id) === surface)
        #expect(permission.checks == 0)
        let denied = try await query.entities(for: [surface.id])
        #expect(denied.isEmpty)
        permission.allowed = true
        let entities = try await query.entities(for: [surface.id])
        let matching = try await query.entities(matching: "private")
        let all = try await query.allEntities()
        let suggested = try await query.suggestedEntities()
        #expect(entities.map(\.id) == [surface.id])
        #expect(entities.first?.title == "private terminal")
        #expect(matching.map(\.id) == [surface.id])
        #expect(all.map(\.id) == [surface.id])
        #expect(suggested.map(\.id) == [surface.id])
        window.close()
        #expect(query.surface(for: surface.id) == nil)
    }
}
