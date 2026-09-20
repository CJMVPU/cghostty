import SwiftUI

/// The current cghostty application icon.
struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(height: 128)
            .accessibilityLabel("cghostty Application Icon")
    }
}
