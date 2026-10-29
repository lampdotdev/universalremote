import SwiftUI

/// The devices of the house: what's found, looking again, what can't be controlled yet, and the example TV.
struct DevicesSheet: View {
    @ObservedObject private var hub = DeviceHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Form {
                if hub.devices.isEmpty && hub.access != .allowed {
                    Section {
                        Text("Universal Remote looks on your Wi‑Fi for your TV and speakers, so it can control them. It only reads what each one says about itself until you press a key.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(hub.devices) { device in
                        Button { pick(device) } label: { row(device.name, device.model ?? device.kindName, device.symbol, chosen: device.id == hub.selected?.id) }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Forget", role: .destructive) { hub.forget(device) } }
                    }
                    if hub.access == .denied {
                        Label(LampNetwork.allowHint, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else if hub.devices.isEmpty, hub.access == .allowed, !hub.isSearching {
                        Label("Nothing answered. Check your TV and speakers are on and on this Wi‑Fi.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await hub.search() }
                    } label: {
                        Label(hub.isSearching ? "Looking…" : hub.devices.isEmpty && hub.access != .allowed ? "Look Around" : "Look Again",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(hub.isSearching)
                } header: {
                    Text("Your devices")
                } footer: {
                    Text("Samsung TVs, Rokus and Sonos speakers. A Samsung TV asks the first time: choose Allow on it. A Roku needs Settings, System, Advanced system settings, Control by mobile apps set to Enabled.")
                }

                if !hub.unsupported.isEmpty {
                    Section {
                        ForEach(hub.unsupported, id: \.address) { device in
                            HStack {
                                row(device.name, [device.maker, device.model].filter { !$0.isEmpty }.joined(separator: " "), "questionmark.circle", chosen: false)
                                Button(copied == device.address ? "Copied" : "Add with Lamp") {
                                    hub.askLamp(about: device)
                                    copied = device.address
                                }
                                .help("Copies a request for it and opens the chat: paste it there")
                            }
                        }
                    } header: {
                        Text("Not supported yet")
                    } footer: {
                        Text("Lamp can add one: paste the request in the chat.")
                    }
                }

                Section {
                    Button { pick(.example) } label: {
                        row("Example TVs", "Two TVs to try the remote and routines on: nothing is sent", "sparkles.tv", chosen: HomeDevice.examples.contains { $0.id == hub.selectedID })
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Your Devices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func row(_ name: String, _ detail: String, _ symbol: String, chosen: Bool) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }

    private func pick(_ device: HomeDevice) {
        hub.select(device)
        dismiss()
    }
}
