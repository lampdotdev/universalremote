import AppIntents

enum TVCommand: String, AppEnum {
    case volumeUp, volumeDown, mute, home, back, play, pause, turnOff, turnOn

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "TV Button"
    static let caseDisplayRepresentations: [TVCommand: DisplayRepresentation] = [
        .volumeUp: "Volume Up",
        .volumeDown: "Volume Down",
        .mute: "Mute",
        .home: "Home",
        .back: "Back",
        .play: "Play",
        .pause: "Pause",
        .turnOff: "Turn Off",
        .turnOn: "Turn On",
    ]
}

struct PressTVButtonIntent: AppIntent {
    static let title: LocalizedStringResource = "Press a TV Button"
    static let description = IntentDescription("Presses a button on the device Universal Remote is controlling.")

    @Parameter(title: "Button") var command: TVCommand

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hub = DeviceHub.shared
        switch command {
        case .turnOn:
            await hub.controller?.turnOn()
            return .result(dialog: "Turning on your TV.")
        case .turnOff: await hub.send(.power)
        case .volumeUp: await hub.send(.volumeUp, times: 2)
        case .volumeDown: await hub.send(.volumeDown, times: 2)
        case .mute: await hub.send(.mute)
        case .home: await hub.send(.home)
        case .back: await hub.send(.back)
        case .play: await hub.send(.play)
        case .pause: await hub.send(.pause)
        }
        if case .offline = hub.state { return .result(dialog: "I couldn't reach your TV.") }
        return .result(dialog: "Done.")
    }
}

struct TellTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell the TV"
    static let description = IntentDescription("Tells your TV, Roku or speaker what to do, like “open Netflix” or “volume up five”.")

    @Parameter(title: "What to do", requestValueDialog: "What should the TV do?") var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await VoiceCommands.run(request)
        let reply = VoiceListener.shared.reply
        return .result(dialog: "\(reply.isEmpty ? "Done." : reply)")
    }
}

struct OpenTVAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open an App on the TV"
    static let description = IntentDescription("Opens an app like Netflix or YouTube on your TV or Roku.")

    @Parameter(title: "App", requestValueDialog: "Which app?") var app: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hub = DeviceHub.shared
        let apps = await hub.allApps()
        guard let match = apps.first(where: { $0.name.localizedCaseInsensitiveContains(app) || app.localizedCaseInsensitiveContains($0.name) }) else {
            return .result(dialog: "I couldn't find \(app) on your TV.")
        }
        await hub.open(match)
        return .result(dialog: "Opening \(match.name).")
    }
}

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TellTVIntent(), phrases: [
            "Tell \(.applicationName)",
            "Talk to my TV with \(.applicationName)",
        ], shortTitle: "Tell the TV", systemImageName: "mic.fill")
        AppShortcut(intent: PressTVButtonIntent(), phrases: [
            "\(\.$command) with \(.applicationName)",
            "Press \(\.$command) on \(.applicationName)",
        ], shortTitle: "Press a Button", systemImageName: "appletvremote.gen4.fill")
        AppShortcut(intent: OpenTVAppIntent(), phrases: [
            "Open an app with \(.applicationName)",
        ], shortTitle: "Open a TV App", systemImageName: "play.tv")
    }
}
