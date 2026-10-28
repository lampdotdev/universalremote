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

    static func run(_ said: String) async {
        let voice = VoiceListener.shared
        voice.isThinking = true
        defer { voice.isThinking = false }

        let hub = DeviceHub.shared
        let apps = await DeviceHub.shared.allApps()
        var options = quick.mapValues(\.description)
        for app in apps.prefix(40) { options["open \(app.name)"] = "open the \(app.name) app" }
        for device in hub.devices where device.id != hub.selected?.id {
            options["switch to \(device.name)"] = "control the \(device.kindName) called \(device.name) instead (only when they name it or say switch)"
        }
        options["other"] = "anything else: pressing something several times or by an amount, several things in a row, a channel number, typing or searching for words, or not a TV command at all"

        if let decision = try? await LampAI.decide(about: said, [
            "command": .choice("Which TV remote command does the person want?", options: options)
        ])["command"], let choice = decision.choice, choice != "other", (decision.confidence ?? 0) > 0.4 {
            if let entry = quick[choice] {
                perform(choice)
                voice.reply = entry.reply
                return
            }
            if let device = hub.devices.first(where: { "switch to \($0.name)" == choice }) {
                hub.select(device)
                voice.reply = "Now controlling \(device.name)"
                return
            }
            if let app = apps.first(where: { "open \($0.name)" == choice }) {
                hub.launch(app)
                voice.reply = "Opening \(app.name)"
                return
            }
        }
        await plan(said, apps: apps)
    }

    // MARK: Several steps

    private struct Plan: Decodable {
        var steps: [Step]
        var reply: String
    }

    private struct Step: Decodable {
        var key: String?
        var times: Int?
        var app: String?
        var type: String?
        var wait: Double?
        var device: String?
    }

    private static func plan(_ said: String, apps: [TVApp]) async {
        let voice = VoiceListener.shared
        let keys = keyNames.keys.sorted().joined(separator: ", ")
        let hub = DeviceHub.shared
        let devices = hub.devices.map { "\($0.name) (\($0.kindName))" }.joined(separator: ", ")
        let prompt = """
        You are a universal remote. Right now it controls \(hub.selected.map { "\($0.name), a \($0.kindName)" } ?? "nothing").
        Other devices: \(devices). The person said what's in the data. Turn it into steps.
        Remote keys you can press: \(keys), powerOn, powerOff.
        Apps on the TV: \(apps.map(\.name).joined(separator: ", ")).
        Reply with JSON only, in this shape:
        {"steps": [{"device": "Living Room"}, {"key": "volumeUp", "times": 5}, {"app": "YouTube"}, {"wait": 3}, {"type": "words to type"}], "reply": "Turning it up 5"}
        Each step has exactly one of device (switch to that device by name, only when they name another device), key (with optional times, 1 to 50), app (a name from the list), wait (seconds), or type (text for the TV's on-screen keyboard).
        On a Sonos speaker: play, pause, fastForward is next track, rewind is previous track, volumeUp and volumeDown change volume by 3 each.
        A channel number is its digit keys (n1, n2, ...) then ok. To search an app, open it, wait about 4 seconds, and only then type.
        "A bit" or "a little" is 3 presses, "a lot" is 10. reply is a short, friendly confirmation under 8 words.
        If it isn't something a TV remote can do, return no steps and a short reply saying so.
        """
        do {
            let plan = try await LampAI.ask(prompt, data: said, as: Plan.self)
            voice.reply = plan.reply
            await execute(plan.steps, apps: apps)
        } catch {
            voice.reply = "I couldn't work that out: \(error.localizedDescription)"
        }
    }

    private static func execute(_ steps: [Step], apps: [TVApp]) async {
        let hub = DeviceHub.shared
        var apps = apps
        for step in steps.prefix(30) {
            if let name = step.device {
                if let device = hub.devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }) {
                    hub.select(device)
                    await hub.controller?.wake()
                    apps = await hub.allApps()
                }
            } else if let name = step.key {
                if name == "powerOn" || name == "powerOff" {
                    perform(name)
                } else if let key = keyNames[name] {
                    hub.pressCount += 1
                    await hub.send(key, times: step.times ?? 1)
                }
                try? await Task.sleep(for: .milliseconds(250))
            } else if let name = step.app {
                let app = apps.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    ?? apps.first { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }
                if let app { await hub.open(app) }
            } else if let seconds = step.wait {
                try? await Task.sleep(for: .seconds(min(max(seconds, 0), 10)))
            } else if let text = step.type, !text.isEmpty {
                await hub.send(text: text)
            }
        }
    }

    // MARK: Helpers

    private static func perform(_ name: String) {
        let hub = DeviceHub.shared
        switch name {
        case "powerOn":
            if hub.can(.power) { Task { await hub.controller?.turnOn() } }
        case "powerOff":
            if hub.can(.power) { hub.press(.power) }
        default:
            if let key = keyNames[name] { hub.press(key) }
        }
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
