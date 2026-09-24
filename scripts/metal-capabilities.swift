// Report runtime GPU capability separately from the installed Metal toolchain.
import Foundation
import Metal

let devices = MTLCopyAllDevices()
let report: [[String: Any]] = devices.map { device in
    var result: [String: Any] = [
        "name": device.name,
        "metal4": device.supportsFamily(.metal4)
    ]
    do {
        _ = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        result["compilerAvailable"] = true
    } catch {
        result["compilerAvailable"] = false
        result["compilerError"] = String(describing: error)
    }
    return result
}
let data = try JSONSerialization.data(withJSONObject: ["devices": report], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
