import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Every device of the house the remote controls, the one chosen now, and what's on the network that it can't
/// control yet. Keys, apps and words go to the chosen device's controller, whatever kind it is.
@MainActor
final class DeviceHub: ObservableObject {
    static let shared = DeviceHub()

    @Published var devices: [HomeDevice] = []
    @Published var selectedID: String?
    @Published var isSearching = false
    /// What answered on the network that the remote has no controller for yet.
    @Published var unsupported: [LampNetwork.Device] = []
    @Published var access: LampNetwork.Access = LampNetwork.access
    @Published var showingDevices = false
    @Published var pressCount = 0
    /// A passing line under the remote: what the example TV would have done.
    @Published var note = ""
    @Published var tileApps: [TVApp] = []
    /// Bumped when a device's state may have changed, so the line under its name is read again.
    @Published private(set) var revision = 0

    private var rokus: [String: LampRoku] = [:]
    private var controllers: [String: DeviceController] = [:]

    init() {
        devices = LampStore.load([HomeDevice].self, from: "devices") ?? []
        rokus = LampStore.load([String: LampRoku].self, from: "rokus") ?? [:]
        selectedID = LampStore.load(String.self, from: "selectedDevice")
        if selectedID == nil { selectedID = devices.first?.id }
    }

    /// The devices to choose from: the ones found, and the example TVs while one is in use or nothing has been found.
    var choices: [HomeDevice] {
        devices.isEmpty || HomeDevice.examples.contains(where: { $0.id == selectedID }) ? devices + HomeDevice.examples : devices
    }

    /// A device the remote can send to, by id: one found, or an example TV.
    func known(_ id: String) -> HomeDevice? {
        devices.first { $0.id == id } ?? HomeDevice.examples.first { $0.id == id }
    }

    /// Something was sent: the line under the device's name is read again.
    func changed() { revision += 1 }

    var selected: HomeDevice? { choices.first { $0.id == selectedID } ?? devices.first }

    var controller: DeviceController? { selected.flatMap(controller(for:)) }

    func can(_ ability: Ability) -> Bool { controller?.abilities.contains(ability) ?? false }

    var state: DeviceState { controller?.state ?? .needs("Find your TV and speakers") }

    func controller(for device: HomeDevice) -> DeviceController? {
        if let known = controllers[device.id] { return known }
        let made: DeviceController?
        switch device.kind {
        case .samsung: made = TVRemote.shared
        case .roku: made = rokus[device.id].map(RokuDevice.init)
        case .sonos: made = SonosDevice(address: device.address)
        case .example:
            let tv = ExampleTV(name: device.name)
            tv.said = { [weak self] words in
                if self?.selectedID == device.id { self?.note = words }
            }
            made = tv
        }
        controllers[device.id] = made
        return made
    }

    func select(_ device: HomeDevice) {
        selectedID = device.id
        LampStore.save(device.id, to: "selectedDevice")
        note = ""
        // One Samsung TV at a time goes through the TV's own channel: the one chosen.
        if device.kind == .samsung, TVRemote.shared.tv?.id != device.id {
            TVRemote.shared.choose(SavedTV(id: device.id, name: device.name, address: device.address, model: device.model, mac: device.mac))
        }
        Task {
            await controller?.wake()
            await refreshApps()
            revision += 1
        }
    }

    func explore() { select(.example) }

    func forget(_ device: HomeDevice) {
        devices.removeAll { $0.id == device.id }
        controllers[device.id] = nil
        if selectedID == device.id { selectedID = devices.first?.id }
        save()
    }

    private func save() {
        LampStore.save(devices, to: "devices")
        LampStore.save(rokus, to: "rokus")
    }

    // MARK: Finding devices

    /// Asks for the local network (the system's question, the first time) and looks for what's there. Only when the
    /// person asks: never at launch.
    func search() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        access = await LampNetwork.requestAccess()
        guard access == .allowed else { return }
        var found: [HomeDevice] = []
        var others: [LampNetwork.Device] = []
        for device in await LampNetwork.find(bonjour: ["_sonos._tcp"]) {
            if device.ssdp.contains("roku:ecp"), let roku = try? await LampRoku.at(device.address) {
                rokus[roku.id] = roku
                found.append(HomeDevice(id: roku.id, name: roku.name, kind: .roku, address: device.address, model: roku.model, mac: nil))
            } else if device.maker.localizedCaseInsensitiveContains("samsung"), let tv = await TVRemote.info(at: device.address) {
                found.append(HomeDevice(id: tv.id, name: tv.name, kind: .samsung, address: tv.address, model: tv.model, mac: tv.mac))
            } else if device.maker.hasPrefix("Sonos") || device.bonjour.contains(where: { $0.type == "_sonos._tcp" }) {
                found.append(HomeDevice(id: "sonos:" + device.name, name: device.name, kind: .sonos, address: device.address, model: device.model, mac: nil))
            } else if !device.maker.isEmpty || !device.model.isEmpty,
                      !device.ssdp.contains(where: { $0.contains("InternetGatewayDevice") }) {
                others.append(device)
            }
        }
        for device in found {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                let before = devices[index]
                devices[index] = device
                controllers[device.id] = nil   // a new address or name: made again when next used
                // The Samsung TV in use goes on at its new address, with its new wake address and its pairing.
                if device.kind == .samsung, device.id == selectedID, device != before {
                    TVRemote.shared.choose(SavedTV(id: device.id, name: device.name, address: device.address, model: device.model, mac: device.mac))
                }
            } else {
                devices.append(device)
            }
        }
        unsupported = others
        save()
        // Nothing chosen yet (or only the example): the first found is, so its connection is made, not only shown.
        let chosen = devices.contains { $0.id == selectedID }
        if !chosen, let first = devices.first { select(first) }
        revision += 1
    }

    /// What to ask Lamp for a device the remote can't control yet.
    func request(for device: LampNetwork.Device) -> String {
        let what = [device.maker, device.model].filter { !$0.isEmpty }.joined(separator: " ")
        return "Add my \(device.name)\(what.isEmpty ? "" : " (\(what))") at \(device.address) to the remote."
    }

    /// Copies that request and opens the app's chat beside it, to paste it there.
    func askLamp(about device: LampNetwork.Device) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request(for: device), forType: .string)
        LampSidebar.openFromMenu()
        #else
        UIPasteboard.general.string = request(for: device)
        #endif
    }

    // MARK: Keys, apps and words

    func press(_ key: TVKey, times: Int = 1) {
        pressCount += 1
        Task { await send(key, times: times) }
    }

    /// Sends a key to the device chosen now: it's named here, so choosing another before it goes changes nothing.
    @discardableResult
    func send(_ key: TVKey, times: Int = 1) async -> CommandOutcome {
        guard let id = selected?.id else { return .notSent("Choose a device first.") }
        return report(await CommandSender.shared.run(.press(key, times: times), on: id))
    }

    /// A key or an app that didn't go says why on the line under the remote.
    private func report(_ outcome: CommandOutcome) -> CommandOutcome {
        switch outcome {
        case .notSent(let why), .failed(let why), .unknown(let why): note = why
        default: break
        }
        return outcome
    }

    func power() {
        pressCount += 1
        guard let id = selected?.id else { return }
        Task { _ = report(await CommandSender.shared.run(.power, on: id)) }
    }

    /// Turns the device chosen now on, through the same checks and queue as its keys.
    @discardableResult
    func turnOn() async -> CommandOutcome {
        guard let id = selected?.id else { return .notSent("Choose a device first.") }
        return report(await CommandSender.shared.run(.turnOn, on: id))
    }

    func type(_ text: String) {
        pressCount += 1
        Task { await send(text: text) }
    }

    @discardableResult
    func send(text: String) async -> CommandOutcome {
        guard let id = selected?.id else { return .notSent("Choose a device first.") }
        return report(await CommandSender.shared.run(.type(text), on: id))
    }

    func launch(_ app: TVApp) {
        pressCount += 1
        Task { await open(app) }
    }

    @discardableResult
    func open(_ app: TVApp) async -> CommandOutcome {
        guard let id = selected?.id else { return .notSent("Choose a device first.") }
        return report(await CommandSender.shared.run(.open(app), on: id))
    }

    /// Every app on the chosen device, for voice.
    func allApps() async -> [TVApp] { await controller?.appList() ?? [] }

    /// The apps worth a key: the popular ones the chosen device has, else its first few.
    func refreshApps() async {
        guard can(.apps), let apps = await controller?.appList() else { tileApps = []; return }
        let popular = TVApp.popular.compactMap { wanted in apps.first { Self.sameApp(wanted.name, $0.name) } }
        tileApps = popular.isEmpty ? Array(apps.prefix(8)) : popular
    }

    func icon(for app: TVApp) -> LampImage? { controller?.icon(for: app) }

    private static func sameApp(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == "youtube" { return y == "youtube" }
        if x == "disney+" { return y.hasPrefix("disney") }
        if x == "max" { return y == "max" || y == "hbo max" }
        return y == x || y.hasPrefix(x + " ")
    }
}
