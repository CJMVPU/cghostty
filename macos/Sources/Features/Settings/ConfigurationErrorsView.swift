import SwiftUI
import Observation

@MainActor @Observable final class ConfigurationErrorsState {
    var errors: [String] = []
}

struct ConfigurationErrorsView: View {
    let model: ConfigurationErrorsState
    let dismiss: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 52))
                    .padding()
                    .frame(alignment: .center)

                Text("""
                    配置未完全应用，请查看下面的原因。修改配置后重启应用生效。\n\nConfiguration could not be fully applied. Review the messages below, edit the file, and restart the application.
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
                Button("关闭 / Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("打开配置 / Open Configuration", action: edit)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding([.bottom, .trailing])
        }
        .frame(minWidth: 480, maxWidth: 960, minHeight: 270)
    }

}
