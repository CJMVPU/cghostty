import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor struct ModifierTransitionTests {
    nonisolated struct Modifier: Sendable {
        let keyCode: UInt16
        let aggregate: NSEvent.ModifierFlags
        let ownMask: UInt
        let otherMask: UInt
        let kittyCode: Int
        let kittyMods: Int
    }

    nonisolated static let modifiers: [Modifier] = [
        .init(keyCode: 0x38, aggregate: .shift, ownMask: UInt(NX_DEVICELSHIFTKEYMASK),
              otherMask: UInt(NX_DEVICERSHIFTKEYMASK), kittyCode: 57441, kittyMods: 2),
        .init(keyCode: 0x3C, aggregate: .shift, ownMask: UInt(NX_DEVICERSHIFTKEYMASK),
              otherMask: UInt(NX_DEVICELSHIFTKEYMASK), kittyCode: 57447, kittyMods: 2),
        .init(keyCode: 0x3B, aggregate: .control, ownMask: UInt(NX_DEVICELCTLKEYMASK),
              otherMask: UInt(NX_DEVICERCTLKEYMASK), kittyCode: 57442, kittyMods: 5),
        .init(keyCode: 0x3E, aggregate: .control, ownMask: UInt(NX_DEVICERCTLKEYMASK),
              otherMask: UInt(NX_DEVICELCTLKEYMASK), kittyCode: 57448, kittyMods: 5),
        .init(keyCode: 0x3A, aggregate: .option, ownMask: UInt(NX_DEVICELALTKEYMASK),
              otherMask: UInt(NX_DEVICERALTKEYMASK), kittyCode: 57443, kittyMods: 3),
        .init(keyCode: 0x3D, aggregate: .option, ownMask: UInt(NX_DEVICERALTKEYMASK),
              otherMask: UInt(NX_DEVICELALTKEYMASK), kittyCode: 57449, kittyMods: 3),
        .init(keyCode: 0x37, aggregate: .command, ownMask: UInt(NX_DEVICELCMDKEYMASK),
              otherMask: UInt(NX_DEVICERCMDKEYMASK), kittyCode: 57444, kittyMods: 9),
        .init(keyCode: 0x36, aggregate: .command, ownMask: UInt(NX_DEVICERCMDKEYMASK),
              otherMask: UInt(NX_DEVICELCMDKEYMASK), kittyCode: 57450, kittyMods: 9),
    ]

    private func flags(_ modifier: Modifier, own: Bool, other: Bool) -> NSEvent.ModifierFlags {
        let aggregate = own || other ? modifier.aggregate.rawValue : 0
        return .init(rawValue: aggregate | (own ? modifier.ownMask : 0) | (other ? modifier.otherMask : 0))
    }

    @Test(arguments: modifiers)
    func releaseKeepsOppositeSideHeld(_ modifier: Modifier) {
        #expect(Ghostty.Input.modifierAction(keyCode: modifier.keyCode,
                                            flags: flags(modifier, own: false, other: true), composing: false) == .release)
    }

    @Test(arguments: modifiers, [false, true])
    func pressReportsOwnSide(_ modifier: Modifier, other: Bool) {
        #expect(Ghostty.Input.modifierAction(keyCode: modifier.keyCode,
                                            flags: flags(modifier, own: true, other: other), composing: false) == .press)
    }

    @Test(arguments: modifiers)
    func releaseWithNeitherSideHeld(_ modifier: Modifier) {
        #expect(Ghostty.Input.modifierAction(keyCode: modifier.keyCode, flags: [], composing: false) == .release)
    }

    @Test(arguments: modifiers, [false, true])
    func compositionRetainsModifierTransitions(_ modifier: Modifier, own: Bool) {
        #expect(Ghostty.Input.modifierAction(keyCode: modifier.keyCode,
                                            flags: flags(modifier, own: own, other: true), composing: true) == nil)
    }

    @Test func capsLockUsesToggleStateAndUnknownKeysAreIgnored() {
        #expect(Ghostty.Input.modifierAction(keyCode: 0x39, flags: .capsLock, composing: false) == .press)
        #expect(Ghostty.Input.modifierAction(keyCode: 0x39, flags: [], composing: false) == .release)
        #expect(Ghostty.Input.modifierAction(keyCode: 0x39, flags: .capsLock, composing: true) == nil)
        #expect(Ghostty.Input.modifierAction(keyCode: 0x00, flags: .shift, composing: false) == nil)
        #expect(Ghostty.Input.modifierAction(keyCode: .max, flags: [.control, .option], composing: false) == nil)
    }

    @Test(arguments: modifiers)
    func nativeReleaseReachesRawPTYAsKittyRelease(_ modifier: Modifier) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("capture.py")
        let capture = directory.appendingPathComponent("capture.bin")
        try #"""
        import os, pathlib, sys, tty
        tty.setraw(0)
        os.write(1, b'\x1b[>11u\x1b[5n')
        reply = b''
        while len(reply) < 4:
            reply += os.read(0, 4 - len(reply))
        os.write(1, b'modifier-pty-ready')
        data = b''
        while not data.endswith(b'u'):
            data += os.read(0, 1)
        capture = pathlib.Path(sys.argv[1])
        pending = capture.with_suffix('.pending')
        pending.write_bytes(data)
        pending.replace(capture)
        while True:
            os.read(0, 1024)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let config = try TemporaryConfig("shell-integration = none\nkeybind = clear")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/usr/bin/python3 -u \(script.path) \(capture.path)"
        base.workingDirectory = directory.path
        let view = Ghostty.SurfaceView(app, baseConfig: base)
        let surface = try #require(view.surfaceModel)
        try await NativeTestWait.until("modifier raw PTY and startup resize barrier", timeout: .seconds(5),
                                      polling: .milliseconds(10), diagnostics: {
            NativeTestWait.surfaceState(surface, expectedText: "modifier-pty-ready")
        }, { surface.readContents(viewport: false).contains("modifier-pty-ready") })
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags(modifier, own: false, other: true),
            timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: modifier.keyCode))
        view.flagsChanged(with: event)
        try await NativeTestWait.until("modifier event capture", timeout: .seconds(5), polling: .milliseconds(10),
                                      diagnostics: { NativeTestWait.surfaceState(surface) }, {
            FileManager.default.fileExists(atPath: capture.path)
        })
        let bytes = try Data(contentsOf: capture)
        #expect(bytes == Data("\u{1b}[\(modifier.kittyCode);\(modifier.kittyMods):3u".utf8))
    }
}
