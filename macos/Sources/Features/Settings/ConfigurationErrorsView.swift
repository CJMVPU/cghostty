import SwiftUI
import Observation

@MainActor @Observable final class ConfigurationErrorsState {
    var errors: [String] = []
}

struct ConfigurationErrorsView: View {
    let model: ConfigurationErrorsState
    let dismiss: () -> Void
    let reload: () -> Void

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 52))
                    .padding()
                    .frame(alignment: .center)

                Text("""
                    ^[\(model.errors.count) error(s) were](inflect: true) found while loading the configuration. \
                    Please review the errors below and reload your configuration or ignore the erroneous lines.
                    """)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.errors, id: \.self) { error in
                            Text(error)
                                .lineLimit(nil)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        Spacer()
                    }
                    .padding(.all)
                    .frame(minHeight: geo.size.height)
                    .background(Color(.controlBackgroundColor))
                }
            }

            HStack {
                Spacer()
                Button("Ignore", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Reload Configuration", action: reload)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding([.bottom, .trailing])
        }
        .frame(minWidth: 480, maxWidth: 960, minHeight: 270)
    }

}
