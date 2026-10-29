import Foundation

/// Turns what the person said into presses on the TV.
@MainActor
enum VoiceCommands {
    /// One-press commands the quick decision model can pick from, each with when it applies.
    private static let quick: [String: (description: String, reply: String)] = [
        "volumeUp": ("turn the volume up a little, louder", "Volume up"),
        "volumeDown": ("turn the volume down a little, quieter", "Volume down"),
        "mute": ("mute or unmute the sound", "Mute"),
        "channelUp": ("next channel, channel up", "Channel up"),
        "channelDown": ("previous channel, channel down", "Channel down"),
        "home": ("go to the home screen", "Home"),
        "back": ("go back", "Back"),
        "exit": ("exit or close what's showing", "Exit"),
        "play": ("play or resume", "Playing"),
        "pause": ("pause", "Paused"),
        "stop": ("stop playback", "Stopped"),
        "fastForward": ("fast forward or skip ahead", "Fast forward"),
        "rewind": ("rewind or go back a bit in the video", "Rewind"),
        "ok": ("select, press OK, enter or choose this", "OK"),
        "up": ("move up once", "Up"),
        "down": ("move down once", "Down"),
        "left": ("move left once", "Left"),
        "right": ("move right once", "Right"),
        "source": ("change the input or source", "Source"),
        "menu": ("open the TV's settings", "Settings"),
        "info": ("show info about what's on", "Info"),
        "guide": ("open the channel guide", "Guide"),
        "captions": ("turn subtitles or captions on or off", "Captions"),
        "powerOff": ("turn the TV off", "Turning off"),
        "powerOn": ("turn the TV on", "Turning on"),
    ]

    /// A one-press command goes straight to the device chosen now, through the same checks as its key, and says what
    /// came of it; anything more is Ask's, with its checked tools.
    static func run(_ said: String) async {
        let voice = VoiceListener.shared
        voice.isThinking = true
        defer { voice.isThinking = false }

        let hub = DeviceHub.shared
        let apps = await DeviceHub.shared.allApps()
        var options = quick.mapValues(\.description)
        for app in apps.prefix(40) { options["open \(app.name)"] = "open the \(app.name) app" }
        for device in hub.choices where device.id != hub.selected?.id {
            options["switch to \(device.name)"] = "control the \(device.kindName) called \(device.name) instead (only when they name it or say switch)"
        }
        options["other"] = "anything else: pressing something several times or by an amount, several things in a row, a routine, another device named, a channel number, or not a TV command at all"

        if let decision = try? await LampAI.decide(about: said, [
            "command": .choice("Which TV remote command does the person want?", options: options)
        ])["command"], let choice = decision.choice, choice != "other", (decision.confidence ?? 0) > 0.4 {
            if let entry = quick[choice] {
                voice.reply = await perform(choice, saying: entry.reply)
                return
            }
            if let device = hub.choices.first(where: { "switch to \($0.name)" == choice }) {
                hub.select(device)
                voice.reply = "Now controlling \(device.name)"
                return
            }
            if let app = apps.first(where: { "open \($0.name)" == choice }) {
                hub.pressCount += 1
                let outcome = await hub.open(app)
                voice.reply = outcome.wentThrough ? "Opening \(app.name)" : outcome.receipt(.open(app), on: hub.selected?.name ?? "the device")
                return
            }
        }
        let ask = AskModel.shared
        guard ask.status?.available == true else {
            voice.reply = ask.status?.reason ?? "That needs Ask, which needs AI set up in Lamp."
            return
        }
        ask.submit(said)
        voice.reply = "Asking: “\(said)”"
    }

    // MARK: Helpers

    /// One press on the device chosen now; the reply is what came of it.
    private static func perform(_ name: String, saying reply: String) async -> String {
        let hub = DeviceHub.shared
        hub.pressCount += 1
        switch name {
        case "powerOn":
            guard hub.can(.power) else { return "This device can't be turned on from here." }
            await hub.controller?.turnOn()
            return reply
        case "powerOff":
            guard hub.can(.power) else { return "This device can't be turned off from here." }
            return words(await hub.send(.power), .press(.power, times: 1), reply)
        default:
            guard let key = keyNames[name] else { return "I couldn't do that." }
            return words(await hub.send(key), .press(key, times: 1), reply)
        }
    }

    private static func words(_ outcome: CommandOutcome, _ command: RemoteCommand, _ reply: String) -> String {
        outcome.wentThrough ? reply : outcome.receipt(command, on: DeviceHub.shared.selected?.name ?? "the device")
    }

    static let keyNames: [String: TVKey] = [
        "home": .home, "back": .back, "exit": .exit,
        "up": .up, "down": .down, "left": .left, "right": .right, "ok": .ok,
        "volumeUp": .volumeUp, "volumeDown": .volumeDown, "mute": .mute,
        "channelUp": .channelUp, "channelDown": .channelDown, "channelList": .channelList, "guide": .guide,
        "play": .play, "pause": .pause, "stop": .stop, "fastForward": .fastForward, "rewind": .rewind,
        "source": .source, "menu": .menu, "info": .info, "captions": .captions,
        "n0": .n0, "n1": .n1, "n2": .n2, "n3": .n3, "n4": .n4,
        "n5": .n5, "n6": .n6, "n7": .n7, "n8": .n8, "n9": .n9,
    ]
}
