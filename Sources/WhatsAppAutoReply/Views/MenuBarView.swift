import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhatsApp Auto-Reply")
                .font(.headline)

            Divider()

            Text("No contacts imported")
                .foregroundColor(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280, height: 380)
    }
}
