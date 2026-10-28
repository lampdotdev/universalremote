import Foundation

/// A Roku, through Lamp's `LampRoku` block (its External Control Protocol on port 8060).
@MainActor
final class RokuDevice: DeviceController {
    private(set) var roku: LampRoku
    private var apps: [TVApp] = []

    init(_ roku: LampRoku) { self.roku = roku }

    var abilities: Set<Ability> {
        var can: Set<Ability> = [.navigate, .apps, .text]
        // A Roku player has no power, volume or channels of its own; a Roku TV does.
        if roku.isTV { can.formUnion([.volume, .channels, .power]) }
        return can
    }

    var state: DeviceState {
        roku.canBeControlled ? .ready(roku.model) : .needs("Turn on control: Settings, System, Advanced system settings, Control by mobile apps")
    }

    func wake() async {
        if let fresh = try? await LampRoku.at(roku.address) { roku = fresh }
    }

    func send(_ key: TVKey, times: Int) async {
        guard let key = Self.keys[key] else { return }
        for i in 0..<max(1, min(times, 50)) {
            if i > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            do { try await roku.press(key) } catch { return }
        }
    }

    func appList() async -> [TVApp] {
        if apps.isEmpty, let list = try? await roku.apps() { apps = list.map { TVApp(id: $0.id, name: $0.name) } }
        return apps
    }

    func open(_ app: TVApp) async { try? await roku.launch(appID: app.id) }

    func send(text: String) async { try? await roku.type(text) }

    func turnOn() async { try? await roku.power(on: true) }

    func togglePower() async {
        let on = ((try? await roku.info())?["power-mode"]) == "PowerOn"
        try? await roku.power(on: !on)
    }

    private static let keys: [TVKey: LampRoku.Key] = [
        .home: .home, .exit: .home, .back: .back, .up: .up, .down: .down, .left: .left, .right: .right, .ok: .select,
        .play: .play, .pause: .play, .stop: .play, .rewind: .rewind, .fastForward: .fastForward,
        .info: .info, .menu: .info, .guide: .info,
        .volumeUp: .volumeUp, .volumeDown: .volumeDown, .mute: .mute, .channelUp: .channelUp, .channelDown: .channelDown,
        .power: .powerOff,
    ]
}
