import Foundation

/// The one way a command reaches a device, for the keys, voice, Siri, Ask and routines alike: to a device named by its
/// id when the command is made, never "whichever is chosen" when it's sent, checked right before it goes, one at a
/// time. Choosing another device meanwhile can't send a command somewhere else.
@MainActor
final class CommandSender {
    static let shared = CommandSender()

    /// The command before this one, which this one waits for: two commands never interleave on one connection.
    private var last: Task<CommandOutcome, Never>?

    /// Sends `command` to the device with this id, after every command asked for before it.
    func run(_ command: RemoteCommand, on deviceID: String) async -> CommandOutcome {
        let before = last
        let task = Task { @MainActor in
            _ = await before?.value
            return await self.dispatch(command, on: deviceID)
        }
        last = task
        return await task.value
    }

    /// Why this command can't go to this device now, or nil. Asked again right before it's sent.
    func problem(_ command: RemoteCommand, on deviceID: String) async -> String? {
        let hub = DeviceHub.shared
        guard let device = hub.known(deviceID) else { return "That device isn't one of the remote's any more." }
        guard let controller = hub.controller(for: device) else { return "\(device.name) can't be controlled yet." }
        switch command {
        case .press(let key, let times):
            guard (1...10).contains(times) else { return "A key is pressed 1 to 10 times." }
            guard Self.can(controller.abilities, key) else { return "\(device.name) has no \(key.title) key." }
        case .open(let app):
            guard controller.abilities.contains(.apps) else { return "\(device.name) doesn't open apps." }
            guard await controller.appList().contains(where: { $0.id == app.id }) else { return "\(device.name) doesn't have \(app.name)." }
        }
        if case .needs(let what) = controller.state { return "\(device.name): \(what)." }
        // One Samsung TV at a time goes through the TV's own channel: the one it's connected to.
        if device.kind == .samsung, TVRemote.shared.tv?.id != device.id { return "Choose \(device.name) in the remote first." }
        return nil
    }

    private func dispatch(_ command: RemoteCommand, on deviceID: String) async -> CommandOutcome {
        if Task.isCancelled { return .notSent("Stopped.") }
        if let problem = await problem(command, on: deviceID) { return .notSent(problem) }
        guard let device = DeviceHub.shared.known(deviceID), let controller = DeviceHub.shared.controller(for: device) else {
            return .notSent("That device isn't one of the remote's any more.")
        }
        let outcome = await controller.deliver(command)
        DeviceHub.shared.changed()
        return outcome
    }

    /// Whether a device with these abilities has this key.
    static func can(_ abilities: Set<Ability>, _ key: TVKey) -> Bool {
        switch key {
        case .volumeUp, .volumeDown, .mute: return abilities.contains(.volume)
        case .channelUp, .channelDown, .channelList, .guide, .n0, .n1, .n2, .n3, .n4, .n5, .n6, .n7, .n8, .n9:
            return abilities.contains(.channels) || (abilities.contains(.speaker) && [.channelUp, .channelDown].contains(key))
        case .source: return abilities.contains(.source)
        case .menu: return abilities.contains(.settings) || abilities.contains(.navigate)
        case .power: return abilities.contains(.power)
        case .play, .pause, .stop, .fastForward, .rewind: return abilities.contains(.navigate) || abilities.contains(.speaker)
        case .home, .back, .exit, .up, .down, .left, .right, .ok, .info, .captions: return abilities.contains(.navigate)
        }
    }
}
