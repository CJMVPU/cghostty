import SwiftUI

struct SurfaceFaultView: View {
    let fault: Ghostty.SurfaceFault
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Terminal IO failed", systemImage: "exclamationmark.triangle")
                    .font(.title2)
                Text(fault.explanation)
                Text("Error: \(fault.errorCode)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("Close this terminal and open a new one after correcting the problem.")
                    .foregroundStyle(.secondary)
                Button("Close Terminal", action: onClose)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("SurfaceFault")
    }
}
