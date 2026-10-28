import SwiftUI

/// The remote is a physical-looking object, so its colors are its own and stay the same in light and dark.
enum RemoteColors {
    // Apple TV remote: pure black, flat graphite keys, white symbols.
    static let body = Color.black
    static let bodyTop = Color(white: 0.11)
    static let key = Color(white: 0.17)
    static let keyPressed = Color(white: 0.30)
    static let pad = Color(white: 0.13)
    static let glow = Color.white
    static let accent2 = Color(white: 0.6)
    static let power = Color(white: 0.17)
    static let label = Color.white
    static let faint = Color.white.opacity(0.4)
}

/// A flat Apple-style key that brightens while pressed.
struct RemoteKeyStyle: ButtonStyle {
    var shape = AnyShape(Circle())
    var fill = RemoteColors.key

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(RemoteColors.label)
            .background(shape.fill(fill).overlay(shape.fill(Color.white.opacity(pressed ? 0.14 : 0))))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(shape)
    }
}

struct RoundKey: View {
    let symbol: String
    let name: String
    var size: CGFloat = 56
    var tint: Color = RemoteColors.label
    var fill: Color = RemoteColors.key
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
        .buttonStyle(RemoteKeyStyle(fill: fill))
        .help(name)
        .accessibilityLabel(name)
    }
}

struct AppTile: View {
    let app: TVApp
    var icon: LampImage? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                self.logo(icon)
            } else {
                nameLabel
            }
        }
        .buttonStyle(RemoteKeyStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)),
                                    fill: hasLogo ? .clear : style.fill))
        .help("Open \(shortName)")
        .accessibilityLabel("Open \(shortName)")
    }

    private var hasLogo: Bool { icon != nil }

    /// The app's icon as the device shares it, as a small square key.
    private func logo(_ image: LampImage) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                #if os(macOS)
                Image(nsImage: image).resizable().scaledToFill().scaleEffect(1.08)
                #else
                Image(uiImage: image).resizable().scaledToFill().scaleEffect(1.08)
                #endif
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var nameLabel: some View {
            Text(shortName)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(style.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
    }

    /// "Spotify - Music and Podcasts" reads as "Spotify" on a tile.
    private var shortName: String {
        app.name.components(separatedBy: " - ").first ?? app.name
    }

    private var style: (fill: Color, text: Color) {
        switch shortName.lowercased() {
        case "netflix": return (Color(red: 0.08, green: 0.08, blue: 0.08), Color(red: 0.90, green: 0.04, blue: 0.08))
        case "youtube": return (Color(red: 0.95, green: 0.0, blue: 0.0), .white)
        case "prime video": return (Color(red: 0.0, green: 0.48, blue: 0.85), .white)
        case "disney+": return (Color(red: 0.04, green: 0.12, blue: 0.33), .white)
        case "apple tv": return (RemoteColors.key, .white)
        case "hulu": return (Color(red: 0.11, green: 0.91, blue: 0.51), .black)
        case "max", "hbo max": return (Color(red: 0.0, green: 0.16, blue: 0.85), .white)
        case "spotify": return (Color(red: 0.11, green: 0.73, blue: 0.33), .black)
        default: return (RemoteColors.key, RemoteColors.label)
        }
    }
}

/// The big touch surface of an Apple TV remote: swipe to move, tap to select, or click its edges.
struct TouchSurface: View {
    let press: (TVKey) -> Void
    @State private var flash: TVKey?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(RemoteColors.pad)
            highlight
            // The clickpad ring, as on the Siri Remote, with its four arrows just inside it.
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                VStack {
                    edge(.up, "chevron.up", "Up")
                    Spacer()
                    edge(.down, "chevron.down", "Down")
                }
                HStack {
                    edge(.left, "chevron.left", "Left")
                    Spacer()
                    edge(.right, "chevron.right", "Right")
                }
                Button { fire(.ok) } label: {
                    Circle().fill(Color.white.opacity(0.001)).frame(width: 96, height: 96)
                }
                .buttonStyle(.plain)
                .help("Select")
                .accessibilityLabel("OK")
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .highPriorityGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                fire(abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up))
            }
        )
        .onTapGesture { fire(.ok) }
    }

    /// A soft light where the surface was pressed, fading out.
    private var highlight: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, r = min(w, h)
            let point: CGPoint = switch flash {
            case .up: CGPoint(x: w / 2, y: h * 0.15)
            case .down: CGPoint(x: w / 2, y: h * 0.85)
            case .left: CGPoint(x: w * 0.15, y: h / 2)
            case .right: CGPoint(x: w * 0.85, y: h / 2)
            default: CGPoint(x: w / 2, y: h / 2)
            }
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: r * 0.35)
                .frame(width: r * 0.7, height: r * 0.7)
                .position(point)
                .opacity(flash == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.35), value: flash)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .allowsHitTesting(false)
    }

    private func edge(_ key: TVKey, _ symbol: String, _ name: String) -> some View {
        Button { fire(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RemoteColors.faint)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .help(name)
        .accessibilityLabel(name)
    }

    private func fire(_ key: TVKey) {
        press(key)
        flash = key
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if flash == key { flash = nil }
        }
    }
}

/// A wide pill with a key at each end, for volume and channel.
struct PillRocker: View {
    let title: String
    let lowSymbol: String
    let highSymbol: String
    let lowName: String
    let highName: String
    let low: () -> Void
    let high: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            half(lowSymbol, lowName, low)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RemoteColors.faint)
                .fixedSize()
            half(highSymbol, highName, high)
        }
        .background(Capsule().fill(RemoteColors.key))
        .clipShape(Capsule())
    }

    private func half(_ symbol: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(PillHalfStyle())
        .buttonRepeatBehavior(.enabled)
        .help(name)
        .accessibilityLabel(name)
    }
}

struct PillHalfStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(RemoteColors.label)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The voice key: graphite at rest, and Siri's colors swirling while it listens.
struct SiriMicKey: View {
    let listening: Bool
    var size: CGFloat = 60
    let action: () -> Void
    @State private var turn = false

    var body: some View {
        Button(action: action) {
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background {
                    if listening {
                        Circle()
                            .fill(AngularGradient(colors: [.pink, .purple, .blue, .cyan, .orange, .pink], center: .center))
                            .rotationEffect(.degrees(turn ? 360 : 0))
                            .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: turn)
                            .onAppear { turn = true }
                            .onDisappear { turn = false }
                            .shadow(color: .purple.opacity(0.6), radius: 14)
                    }
                }
        }
        .buttonStyle(RemoteKeyStyle(fill: RemoteColors.key))
        .help("Talk to your TV")
        .accessibilityLabel(listening ? "Stop listening" : "Talk to your TV")
    }
}
