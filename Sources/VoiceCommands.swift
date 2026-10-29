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
    /// `fresh`: a request of its own (Siri), never an answer to a question Ask is waiting on.
    static func run(_ said: String, fresh: Bool = false) async {
        let voice = VoiceListener.shared
        voice.isThinking = true
        defer { voice.isThinking = false }

        let hub = DeviceHub.shared
        // The device chosen when it was heard is the one it's for, whatever is chosen by the time it's understood.
        guard let target = hub.selected else { voice.reply = "Choose a device first."; return }
        let apps = await hub.controller(for: target)?.appList() ?? []
        var options = quick.mapValues(\.description)
        for app in apps.prefix(40) { options["open \(app.name)"] = "open the \(app.name) app" }
        for device in hub.choices where device.id != target.id {
            options["switch to \(device.name)"] = "control the \(device.kindName) called \(device.name) instead (only when they name it or say switch)"
        }
        options["other"] = "anything else: pressing something several times or by an amount, several things in a row, a routine, another device named, a channel number, or not a TV command at all"

        if let decision = try? await LampAI.decide(about: said, [
            "command": .choice("Which TV remote command does the person want?", options: options)
        ])["command"], let choice = decision.choice, choice != "other", (decision.confidence ?? 0) > 0.4 {
            if let entry = quick[choice] {
                voice.reply = await perform(choice, on: target, saying: entry.reply)
                return
            }
            if let device = hub.choices.first(where: { "switch to \($0.name)" == choice }) {
                hub.select(device)
                voice.reply = "Now controlling \(device.name)"
                return
            }
            if let app = apps.first(where: { "open \($0.name)" == choice }) {
                hub.pressCount += 1
                let outcome = await CommandSender.shared.run(.open(app), on: target.id)
                voice.reply = outcome.wentThrough ? "Opening \(app.name)" : outcome.receipt(.open(app), on: target.name)
                return
            }
        }
        let ask = AskModel.shared
        guard ask.status?.available == true else {
            voice.reply = ask.status?.reason ?? "That needs Ask, which needs AI set up in Lamp."
            return
        }
        ask.submit(said, fresh: fresh)
        voice.reply = "Asking: “\(said)”"
    }

    // MARK: Helpers

    /// One press on the device it was heard for; the reply is what came of it.
    private static func perform(_ name: String, on target: HomeDevice, saying reply: String) async -> String {
        DeviceHub.shared.pressCount += 1
        let command: RemoteCommand
        switch name {
        case "powerOn": command = .turnOn
        case "powerOff": command = .power
        default:
            guard let key = keyNames[name] else { return "I couldn't do that." }
            command = .press(key, times: 1)
        }
        let outcome = await CommandSender.shared.run(command, on: target.id)
        return outcome.wentThrough ? reply : outcome.receipt(command, on: target.name)
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
