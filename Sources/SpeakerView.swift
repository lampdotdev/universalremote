import SwiftUI

/// A speaker's face: what's playing, big transport keys and a volume slider.
struct SpeakerView: View {
    @ObservedObject var speaker: SonosDevice
    @ObservedObject private var hub = DeviceHub.shared
    @ObservedObject private var voice = VoiceListener.shared

    var body: some View {
        VStack(spacing: 22) {
            artwork
            VStack(spacing: 4) {
                Text(speaker.playing.title ?? "Nothing playing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(RemoteColors.label)
                    .lineLimit(1)
                Text(speaker.playing.artist ?? "Start something from the Sonos app, then control it here")
                    .font(.subheadline)
                    .foregroundStyle(RemoteColors.faint)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 0) {
                RoundKey(symbol: "backward.fill", name: "Previous", size: 60) { hub.press(.rewind) }
                Spacer(minLength: 8)
                RoundKey(symbol: speaker.playing.isPlaying ? "pause.fill" : "play.fill",
                         name: speaker.playing.isPlaying ? "Pause" : "Play", size: 76) { Task { await speaker.playOrPause() } }
                Spacer(minLength: 8)
                RoundKey(symbol: "forward.fill", name: "Next", size: 60) { hub.press(.fastForward) }
            }

            HStack(spacing: 14) {
                Button { hub.press(.mute) } label: {
                    Image(systemName: speaker.muted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RemoteColors.label)
                .help(speaker.muted ? "Unmute" : "Mute")
                .accessibilityLabel(speaker.muted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { speaker.volume }, set: { speaker.setVolume($0) }), in: 0...100)
                    .tint(.white)
                    .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(RemoteColors.faint)
                    .frame(width: 28)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(Capsule().fill(RemoteColors.key))

            SiriMicKey(listening: voice.isListening, size: 60) { voice.toggle() }
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)
        }
        .task {
            // Keep what's playing current while the speaker is showing.
            while !Task.isCancelled {
                await speaker.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(RemoteColors.pad)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: speaker.playing.artURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "hifispeaker.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(RemoteColors.faint)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .frame(maxWidth: 300)
    }
}
