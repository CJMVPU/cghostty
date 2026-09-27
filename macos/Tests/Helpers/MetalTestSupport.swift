import Metal

nonisolated enum MetalTestSupport {
    // Hosted macOS runners may expose only a paravirtual GPU. Skip GPU tests
    // only when Metal 4 is unsupported; compiler failures on capable hardware
    // must propagate as test failures.
    static func metal4Available() throws -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        print("GPU frame tests: device=\(device.name), Metal4=\(device.supportsFamily(.metal4))")
        guard device.supportsFamily(.metal4) else { return false }
        _ = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        return true
    }
}
