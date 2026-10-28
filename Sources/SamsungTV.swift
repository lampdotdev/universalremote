import SwiftUI
import Darwin

/// A key on a Samsung remote, by the code the TV understands.
enum TVKey: String, CaseIterable {
    case power = "KEY_POWER", home = "KEY_HOME", back = "KEY_RETURN", exit = "KEY_EXIT"
    case up = "KEY_UP", down = "KEY_DOWN", left = "KEY_LEFT", right = "KEY_RIGHT", ok = "KEY_ENTER"
    case volumeUp = "KEY_VOLUP", volumeDown = "KEY_VOLDOWN", mute = "KEY_MUTE"
    case channelUp = "KEY_CHUP", channelDown = "KEY_CHDOWN", channelList = "KEY_CH_LIST", guide = "KEY_GUIDE"
    case play = "KEY_PLAY", pause = "KEY_PAUSE", stop = "KEY_STOP", fastForward = "KEY_FF", rewind = "KEY_REWIND"
    case source = "KEY_SOURCE", menu = "KEY_MENU", info = "KEY_INFO", captions = "KEY_CAPTION"
    case n0 = "KEY_0", n1 = "KEY_1", n2 = "KEY_2", n3 = "KEY_3", n4 = "KEY_4"
    case n5 = "KEY_5", n6 = "KEY_6", n7 = "KEY_7", n8 = "KEY_8", n9 = "KEY_9"

    static func digit(_ d: Int) -> TVKey? { TVKey(rawValue: "KEY_\(d)") }
}

/// An app on the TV.
struct TVApp: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var appType: Int? = nil
    /// Where the TV keeps this app's icon, for asking it for the picture.
    var iconPath: String? = nil

    static let popular: [TVApp] = [
        TVApp(id: "3201907018807", name: "Netflix"),
        TVApp(id: "111299001912", name: "YouTube"),
        TVApp(id: "3201910019365", name: "Prime Video"),
        TVApp(id: "3201901017640", name: "Disney+"),
        TVApp(id: "3201807016597", name: "Apple TV"),
        TVApp(id: "3201601007625", name: "Hulu"),
        TVApp(id: "3202301029760", name: "Max"),
        TVApp(id: "3201606009684", name: "Spotify"),
    ]
}

/// The TV this remote talks to, as it's remembered between launches.
struct SavedTV: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var address: String
    var model: String?
    var mac: String?
    var token: String?
}

@MainActor
final class TVRemote: ObservableObject {
    static let shared = TVRemote()

    enum Status: Equatable {
        case notSetUp, connecting, waitingForAllow, connected, offline(String)
    }

    @Published var status: Status = .notSetUp
    @Published var tvName: String = "Samsung TV"
    @Published var tv: SavedTV?
    @Published var installedApps: [TVApp] = []

    private var socket: URLSessionWebSocketTask?
    private var connecting: Task<Bool, Never>?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }()
    private let trust = LocalTrust()
    private let remoteName = "Universal Remote"

    /// Each paired TV's token by its id, so switching between TVs never asks one to Allow again.
    private var tokens: [String: String] = LampStore.load([String: String].self, from: "tokens") ?? [:]
    /// Bumped when another TV is chosen: a connection still being made for the one before is dropped, never used.
    private var generation = 0

    init() {
        tv = LampStore.load(SavedTV.self, from: "tv")
        installedApps = LampStore.load([TVApp].self, from: "apps") ?? []
        if let tv {
            tvName = tv.name
            Task { _ = await self.ensureConnected() }
        }
    }

    /// The apps worth a tile: the popular ones, in that order, that are on this TV (or all of them before we know).
    var tileApps: [TVApp] {
        guard !installedApps.isEmpty else { return TVApp.popular }
        let installedIDs = Set(installedApps.map(\.id))
        let shown = TVApp.popular.compactMap { app in
            installedApps.first { $0.id == app.id }
                ?? installedApps.first { $0.name.lowercased() == app.name.lowercased() }
        }
        return shown.isEmpty ? TVApp.popular : shown.filter { installedIDs.contains($0.id) }
    }

    // MARK: Sending

    /// Turns the TV on (over the network) when it's off, or off when it's on.
    func togglePower() async {
        if status == .connected, socket != nil {
            await send(.power)
        } else {
            await turnOn()
        }
    }

    func send(_ key: TVKey, times: Int = 1) async {
        for i in 0..<max(1, min(times, 50)) {
            if i > 0 { try? await Task.sleep(for: .milliseconds(160)) }
            await emit(["method": "ms.remote.control",
                        "params": ["Cmd": "Click", "DataOfCmd": key.rawValue,
                                   "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
        }
    }

    func send(text: String) async {
        let encoded = Data(text.utf8).base64EncodedString()
        await emit(["method": "ms.remote.control",
                    "params": ["Cmd": encoded, "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"]])
        await emit(["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
    }

    /// Asks the TV to bring the app to the front. The TV's own launch address does that reliably;
    /// launching over the remote channel can leave an app running out of sight, so it's only the fallback.
    func open(_ app: TVApp) async {
        if let tv, let url = URL(string: "http://\(tv.address):8001/api/v2/applications/\(app.id)") {
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.httpMethod = "POST"
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                print("Opened \(app.name): \(String(decoding: data, as: UTF8.self))")
                return
            }
        }
        await emit(["method": "ms.channel.emit",
                    "params": ["event": "ed.apps.launch", "to": "host",
                               "data": ["appId": app.id, "action_type": "NATIVE_LAUNCH"]]])
    }

    func turnOn() async {
        guard let tv else { return }
        if let mac = tv.mac { WakeOnLAN.send(to: mac) }
        status = .connecting
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            if await ensureConnected() { return }
        }
        status = .offline(tv.mac == nil ? "Can't turn it on from here" : "Didn't wake up")
    }

    /// Sends one message, connecting first when needed. Says whether it went.
    @discardableResult
    private func emit(_ message: [String: Any]) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return false }
        for attempt in 0..<2 {
            guard await ensureConnected(), let socket else { return false }
            do {
                try await socket.send(.string(text))
                return true
            } catch {
                print("Send failed (\(attempt)): \(error.localizedDescription)")
                closed(socket)
            }
        }
        return false
    }

    // MARK: Connecting

    func ensureConnected() async -> Bool {
        if status == .connected, socket != nil { return true }
        if let connecting { return await connecting.value }
        let generation = generation
        let task = Task { await self.openConnection(generation) }
        connecting = task
        let ok = await task.value
        if generation == self.generation { connecting = nil }
        return ok && generation == self.generation
    }

    /// The token the TV handed back, kept with it and by its id.
    private func keep(token: String?) {
        tv?.token = token
        if let id = tv?.id { tokens[id] = token }
        if let saved = tv { LampStore.save(saved, to: "tv") }
        LampStore.save(tokens, to: "tokens")
    }

    private enum Attempt { case connected, denied, unreachable, gaveUp }

    private func openConnection(_ generation: Int) async -> Bool {
        guard let tv else { status = .notSetUp; return false }
        trust.host = tv.address
        status = .connecting
        // Newer TVs talk on 8002 (secure, with a token); older ones on 8001.
        // Right after launch the network can say it's offline for a moment, so try a few rounds.
        for round in 0..<3 {
            if round > 0 { try? await Task.sleep(for: .seconds(Double(round) * 1.5)) }
            for secure in [true, false] {
            let result = await attempt(self.tv ?? tv, secure: secure, generation: generation)
            // Another TV was chosen meanwhile: this one's answer is no longer the remote's.
            guard generation == self.generation else { return false }
            switch result {
            case .connected:
                status = .connected
                requestApps()
                return true
            case .denied:
                // An old pairing the TV no longer accepts: forget it and ask the TV afresh.
                if self.tv?.token != nil {
                    keep(token: nil)
                    continue
                }
                status = .offline("Choose Allow on the TV, then press any key")
                return false
            case .gaveUp:
                status = .offline("No answer yet: press any key to ask again")
                return false
            case .unreachable:
                continue
            }
            }
        }
        status = .offline("Can't reach the TV")
        return false
    }

    private func attempt(_ tv: SavedTV, secure: Bool, generation: Int) async -> Attempt {
        let name = Data(remoteName.utf8).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var path = secure ? "wss://\(tv.address):8002" : "ws://\(tv.address):8001"
        path += "/api/v2/channels/samsung.remote.control?name=\(name)"
        if secure, let token = tv.token { path += "&token=\(token)" }
        guard let url = URL(string: path) else { return .unreachable }

        let task = session.webSocketTask(with: url)
        task.resume()
        let started = Date()
        // When the TV is quiet for a moment, it's showing its Allow question.
        let waiting = Task { @MainActor in
            try await Task.sleep(for: .seconds(2.5))
            if self.status == .connecting { self.status = .waitingForAllow }
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(45))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { waiting.cancel(); timeout.cancel() }

        do {
            let message = try await task.receive()
            let json = Self.json(message)
            switch json?["event"] as? String {
            case "ms.channel.connect":
                guard generation == self.generation else {
                    task.cancel()
                    return .unreachable
                }
                if let token = (json?["data"] as? [String: Any])?["token"] as? String { keep(token: token) }
                socket = task
                listen(task)
                return .connected
            case "ms.channel.unauthorized":
                task.cancel()
                return .denied
            default:
                task.cancel()
                return .unreachable
            }
        } catch {
            task.cancel()
            let ns = error as NSError
            print("Connect on \(secure ? 8002 : 8001) failed: \(ns.domain) \(ns.code) \(ns.userInfo)")
            return Date().timeIntervalSince(started) > 8 ? .gaveUp : .unreachable
        }
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            while true {
                do {
                    let message = try await task.receive()
                    self?.handle(message)
                } catch {
                    self?.closed(task)
                    return
                }
            }
        }
    }

    private func closed(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        task.cancel()
        socket = nil
        guard status == .connected else { return }
        // The TV closes quiet connections now and then: reconnect right away instead of showing it as lost.
        status = .connecting
        Task {
            try? await Task.sleep(for: .seconds(1))
            if !(await self.ensureConnected()) { self.status = .offline("Disconnected") }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let json = Self.json(message), let event = json["event"] as? String else { return }
        if event == "ed.installedApp.get",
           let list = ((json["data"] as? [String: Any])?["data"]) as? [[String: Any]] {
            installedApps = list.compactMap { item in
                guard let id = item["appId"] as? String, let name = item["name"] as? String else { return nil }
                return TVApp(id: id, name: name, appType: item["app_type"] as? Int, iconPath: item["icon"] as? String)
            }
            LampStore.save(installedApps, to: "apps")
            fetchIcons()
        } else if event == "ed.apps.icon" {
            gotIcon(json["data"] as? [String: Any] ?? [:])
        }
    }

    // MARK: App icons, straight from the TV

    @Published var icons: [String: LampImage] = [:]
    private var iconQueue: [TVApp] = []

    /// Asks the TV for its list of apps again (with their icons).
    func refreshApps() {
        Task {
            await emit(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
        }
    }

    func loadSavedIcons() {
        for app in installedApps where icons[app.id] == nil {
            let url = LampStore.folder.appendingPathComponent("icon-\(app.id).png")
            if let data = try? Data(contentsOf: url), let image = LampImage(data: data) { icons[app.id] = image }
        }
    }

    func fetchIcons() {
        loadSavedIcons()
        iconQueue = tileApps.filter { icons[$0.id] == nil && $0.iconPath != nil }
        askNextIcon()
    }

    func askNextIcon() {
        guard let app = iconQueue.first, let path = app.iconPath else { return }
        Task {
            await emit(["method": "ms.channel.emit",
                        "params": ["event": "ed.apps.icon", "to": "host", "data": ["iconPath": path]]])
        }
    }

    func gotIcon(_ data: [String: Any]) {
        guard !iconQueue.isEmpty else { return }
        let path = data["iconPath"] as? String
        let index = iconQueue.firstIndex { $0.iconPath == path } ?? 0
        let app = iconQueue.remove(at: index)
        if let base64 = data["imageBase64"] as? String,
           let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let image = LampImage(data: bytes) {
            icons[app.id] = image
            try? bytes.write(to: LampStore.folder.appendingPathComponent("icon-\(app.id).png"))
        } else {
            print("No icon for \(app.name): \(data.keys.sorted())")
        }
        askNextIcon()
    }

    private func requestApps() {
        Task {
            await emit(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
        }
    }

    private static func json(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let d): data = d
        @unknown default: return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Choosing a TV

    func choose(_ newTV: SavedTV) {
        generation += 1
        connecting = nil
        if let socket { socket.cancel() }
        socket = nil
        var chosen = newTV
        chosen.token = (newTV.id == tv?.id ? tv?.token : nil) ?? tokens[newTV.id]
        if chosen.mac == nil, newTV.id == tv?.id { chosen.mac = tv?.mac }
        if newTV.id != tv?.id {
            installedApps = []
            LampStore.save(installedApps, to: "apps")
        }
        tv = chosen
        tvName = chosen.name
        status = .connecting
        LampStore.save(chosen, to: "tv")
        Task { _ = await ensureConnected() }
    }

    /// Adds a TV by the address the person typed, even when it doesn't describe itself.
    func add(address: String) async {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        let info = await Self.info(at: address)
        choose(info ?? SavedTV(id: address, name: "Samsung TV", address: address))
    }

    // MARK: Finding TVs

    /// The Samsung TV at an address, as it describes itself, or nil when it isn't one.
    nonisolated static func info(at address: String, timeout: TimeInterval = 4) async -> SavedTV? {
        guard let url = URL(string: "http://\(address):8001/api/v2/") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, _) = try? await session.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let device = json["device"] as? [String: Any] ?? [:]
        let kind = (device["type"] as? String ?? "") + (json["type"] as? String ?? "") + (json["name"] as? String ?? "")
        guard kind.localizedCaseInsensitiveContains("samsung") || kind.localizedCaseInsensitiveContains("tv") else { return nil }
        var name = (device["name"] as? String) ?? (json["name"] as? String) ?? "Samsung TV"
        if name.hasPrefix("[TV] ") { name.removeFirst(5) }
        let id = (device["id"] as? String) ?? (json["id"] as? String) ?? address
        let mac = (device["wifiMac"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SavedTV(id: id, name: name, address: address, model: device["modelName"] as? String, mac: mac)
    }
}

/// Samsung TVs use their own certificate on the local network: trust it for the TV's address only.
final class LocalTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    var host: String?

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Where a wake packet goes: every network this device is on.
enum LocalNetwork {
    /// Broadcast addresses of this device's networks.
    static func broadcasts() -> [String] {
        var result = ["255.255.255.255"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name).hasPrefix("en"),
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let maskPointer = entry.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let b = ip | ~mask
            result.append("\(b >> 24).\((b >> 16) & 255).\((b >> 8) & 255).\(b & 255)")
        }
        return result
    }
}

/// Wakes a sleeping TV with a "magic packet" (the TV's Power On with Mobile setting must be on).
enum WakeOnLAN {
    static func send(to mac: String) {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        for address in LocalNetwork.broadcasts() {
            for port: UInt16 in [9, 7] {
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = port.bigEndian
                inet_pton(AF_INET, address, &target.sin_addr)
                let sent = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent < 0 { print("Wake packet to \(address) didn't go: \(String(cString: strerror(errno)))") }
            }
        }
    }
}

/// A Samsung TV as one of the remote's devices: its own remote channel, over the network.
extension TVRemote: DeviceController {
    var abilities: Set<Ability> { [.navigate, .apps, .text, .volume, .channels, .source, .settings, .power] }

    var state: DeviceState {
        switch status {
        case .connected: return .ready("Connected")
        case .connecting: return .working("Connecting…")
        case .waitingForAllow: return .needs("Choose Allow on the TV")
        case .notSetUp: return .needs("Not set up")
        case .offline(let why): return .offline(why)
        }
    }

    func wake() async { _ = await ensureConnected() }

    func appList() async -> [TVApp] { installedApps.isEmpty ? TVApp.popular : installedApps }

    func icon(for app: TVApp) -> LampImage? { icons[app.id] }
}
