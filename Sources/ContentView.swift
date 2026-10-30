import SwiftUI

struct ContentView: View {
    @ObservedObject private var hub = DeviceHub.shared
    @ObservedObject private var tv = TVRemote.shared   // a Samsung TV's connection, which its state follows
    @ObservedObject private var voice = VoiceListener.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingKeyboard = false

    var body: some View {
        VStack(spacing: 16) {
            header
            if let speaker = hub.controller as? SonosDevice {
                SpeakerView(speaker: speaker)
                    .overlay(alignment: .bottom) { bubbleOverlay }
            } else {
                TouchSurface { hub.press($0) }
                    .overlay(alignment: .bottom) { bubbleOverlay }
                VStack(spacing: 16) {
                    mainKeys
                    if hub.can(.volume) || hub.can(.channels) { rockers }
                    mediaRow
                }
                .padding(.vertical, 12)
                if hub.can(.apps) { appsRow }
            }
            VStack(alignment: .leading, spacing: 12) {
                RoutinesBar()
                AskBar()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .light), trigger: hub.pressCount)
        .sheet(isPresented: $hub.showingDevices) { DevicesSheet() }
        .sheet(isPresented: $showingKeyboard) { KeyboardSheet() }
        .task(id: voice.reply) {
            // A reply is a passing confirmation, not a state: let it go after a few seconds.
            guard !voice.reply.isEmpty else { return }
            let shown = voice.reply
            try? await Task.sleep(for: .seconds(5))
            if voice.reply == shown, !voice.isListening, !voice.isThinking { voice.reply = "" }
        }
        .onAppear {
            tv.loadSavedIcons()
            // The network is looked at only once the person asks (the devices sheet says why first), never at launch:
            // with nothing found yet, that's where the remote starts.
            if let device = hub.selected { hub.select(device) } else { hub.showingDevices = true }
        }
        .task(id: tv.status == .connected) {
            if tv.status == .connected, hub.selected?.kind == .samsung {
                if tv.installedApps.isEmpty || tv.tileApps.contains(where: { tv.icons[$0.id] == nil }) { tv.refreshApps() }
                await hub.refreshApps()
            }
        }
        .onChange(of: tv.installedApps) { _, _ in
            // A Samsung TV's list of apps comes a moment after it connects: its keys follow it.
            if hub.selected?.kind == .samsung { Task { await hub.refreshApps() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let device = hub.selected { hub.select(device) }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 780)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(action: handleKey)
        #endif
    }

    // MARK: Pieces

    private var background: some View {
        Color.black
    }

    /// The chosen device's name centered with a chevron, like the Apple TV remote's device menu.
    private var header: some View {
        ZStack {
            Menu {
                ForEach(hub.choices) { device in
                    Button { hub.select(device) } label: {
                        Label(device.id == hub.selected?.id ? "✓ \(device.name)" : device.name, systemImage: device.symbol)
                    }
                }
                Divider()
                Button { hub.showingDevices = true } label: {
                    Label("Find Devices…", systemImage: "magnifyingglass")
                }
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text(hub.selected?.name ?? "Universal Remote")
                            .font(.headline)
                            .foregroundStyle(RemoteColors.label)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(RemoteColors.faint)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(hub.state.words)
                            .font(.caption)
                            .foregroundStyle(RemoteColors.faint)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 50)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose what to control")
            HStack {
                if hub.can(.text) {
                    RoundKey(symbol: "keyboard", name: "Type on TV", size: 38) {
                        showingKeyboard = true
                    }
                }
                Spacer()
                if hub.can(.power) {
                    RoundKey(symbol: "power", name: "Power", size: 38, tint: .white, fill: RemoteColors.key) {
                        hub.power()
                    }
                }
            }
        }
    }

    private var bubbleOverlay: some View {
        voiceBubble
            .padding(.horizontal, 60)
            .padding(.bottom, 64)
            .allowsHitTesting(false)
    }

    private var voiceBubble: some View {
        Text(bubbleText)
            .font(.footnote)
            .foregroundStyle(voice.isListening || !voice.reply.isEmpty ? RemoteColors.label : RemoteColors.faint)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 20)
            .animation(.easeInOut(duration: 0.2), value: bubbleText)
    }

    private var bubbleText: String {
        if voice.isListening { return voice.transcript.isEmpty ? "Listening…" : "“\(voice.transcript)”" }
        if voice.isThinking { return "“\(voice.transcript)”…" }
        if !voice.reply.isEmpty { return voice.reply }
        return hub.note
    }

    /// Back, TV, Siri and Play/Pause, as on the Apple TV remote.
    private var mainKeys: some View {
        HStack(spacing: 0) {
            RoundKey(symbol: "chevron.left", name: "Back", size: 60) { hub.press(.back) }
            Spacer(minLength: 8)
            RoundKey(symbol: "tv", name: "Home", size: 60) { hub.press(.home) }
            Spacer(minLength: 8)
            SiriMicKey(listening: voice.isListening, size: 60) { voice.toggle() }
            Spacer(minLength: 8)
            RoundKey(symbol: "playpause.fill", name: "Play or Pause", size: 60) { hub.press(.play) }
        }
    }

    private var rockers: some View {
        HStack(spacing: 12) {
            if hub.can(.volume) {
                PillRocker(title: "VOL", lowSymbol: "minus", highSymbol: "plus",
                           lowName: "Volume Down", highName: "Volume Up",
                           low: { hub.press(.volumeDown) }, high: { hub.press(.volumeUp) })
            }
            if hub.can(.channels) {
                PillRocker(title: "CH", lowSymbol: "chevron.down", highSymbol: "chevron.up",
                           lowName: "Channel Down", highName: "Channel Up",
                           low: { hub.press(.channelDown) }, high: { hub.press(.channelUp) })
            }
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 0) {
            RoundKey(symbol: "gobackward.10", name: "Rewind", size: 44) { hub.press(.rewind) }
            Spacer(minLength: 8)
            if hub.can(.volume) {
                RoundKey(symbol: "speaker.slash.fill", name: "Mute", size: 44) { hub.press(.mute) }
                Spacer(minLength: 8)
            }
            if hub.can(.source) {
                RoundKey(symbol: "rectangle.on.rectangle", name: "Source", size: 44) { hub.press(.source) }
                Spacer(minLength: 8)
            }
            if hub.can(.settings) {
                RoundKey(symbol: "gearshape.fill", name: "Settings", size: 44) { hub.press(.menu) }
                Spacer(minLength: 8)
            }
            RoundKey(symbol: "goforward.10", name: "Fast Forward", size: 44) { hub.press(.fastForward) }
        }
    }

    private var appsRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            ForEach(hub.tileApps) { app in
                AppTile(app: app, icon: hub.icon(for: app)) { hub.launch(app) }
            }
        }
    }

    #if os(macOS)
    /// The Mac's keyboard works the remote: arrows, Return for OK, Escape or Delete for Back, Space to play.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]), !AskModel.shared.typing else { return .ignored }
        let keys: [KeyEquivalent: TVKey] = [.upArrow: .up, .downArrow: .down, .leftArrow: .left, .rightArrow: .right,
                                            .return: .ok, .escape: .back, .delete: .back, .space: .play]
        guard let key = keys[press.key] else { return .ignored }
        if let speaker = hub.controller as? SonosDevice, key == .play { Task { await speaker.playOrPause() } } else { hub.press(key) }
        return .handled
    }
    #endif

    // MARK: Status

    private var statusColor: Color {
        _ = hub.revision
        switch hub.state {
        case .ready: return .green
        case .working, .needs: return .yellow
        case .offline: return .red
        }
    }
}
