import SwiftUI

/// Types into the search box that's open on the TV, with this device's own keyboard.
struct KeyboardSheet: View {
    @ObservedObject private var hub = DeviceHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Type on TV")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack(spacing: 10) {
                TextField("Search or type…", text: $text)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Capsule().fill(RemoteColors.key))
                    .focused($focused)
                    .submitLabel(.send)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(RemoteKeyStyle(fill: text.isEmpty ? RemoteColors.key : .blue))
                .disabled(text.isEmpty)
                .help("Send to TV")
                .accessibilityLabel("Send to TV")
            }
            Text("Open a search box on the TV first. Some apps use their own keyboard and ignore this.")
                .font(.caption)
                .foregroundStyle(RemoteColors.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 380)
        #endif
        .presentationDetents([.height(190)])
        .presentationBackground(.black)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    private func send() {
        guard !text.isEmpty else { return }
        hub.type(text)
        text = ""
        dismiss()
    }
}
