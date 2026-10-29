import SwiftUI

@main
struct MainApp: SwiftUI.App {
    var body: some SwiftUI.Scene {
        WindowGroup("Universal Remote") {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 380, height: 1000)
        .windowResizability(.contentMinSize)
        .commands {
            LampCommands()
            RemoteCommands()
        }
        #endif
    }
}

#if os(macOS)
struct RemoteCommands: Commands {
    var body: some Commands {
        CommandMenu("Remote") {
            Button("Talk to Remote") { VoiceListener.shared.toggle() }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button("Volume Up") { DeviceHub.shared.press(.volumeUp) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { DeviceHub.shared.press(.volumeDown) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Mute") { DeviceHub.shared.press(.mute) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Home") { DeviceHub.shared.press(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Back") { DeviceHub.shared.press(.back) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Play") { DeviceHub.shared.press(.play) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Pause") { DeviceHub.shared.press(.pause) }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Your Devices…") { DeviceHub.shared.showingDevices = true }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}
#endif
