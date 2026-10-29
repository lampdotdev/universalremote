import Foundation

/// A Sonos speaker, talked to over its own local control (port 1400). No account or app needed.
struct Sonos {
    let address: String

    struct NowPlaying: Equatable {
        var title: String?
        var artist: String?
        var artURL: URL?
        var isPlaying = false
    }

    func play() async throws { _ = try await soap("AVTransport", "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>") }
    func pause() async throws { _ = try await soap("AVTransport", "Pause", "<InstanceID>0</InstanceID>") }
    func next() async throws { _ = try await soap("AVTransport", "Next", "<InstanceID>0</InstanceID>") }
    func previous() async throws { _ = try await soap("AVTransport", "Previous", "<InstanceID>0</InstanceID>") }

    func volume() async throws -> Int {
        let xml = try await soap("RenderingControl", "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        return Int(Self.tag("CurrentVolume", in: xml) ?? "") ?? 0
    }

    func setVolume(_ value: Int) async throws {
        let v = max(0, min(100, value))
        _ = try await soap("RenderingControl", "SetVolume",
                           "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(v)</DesiredVolume>")
    }

    func isMuted() async throws -> Bool {
        let xml = try await soap("RenderingControl", "GetMute", "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        return Self.tag("CurrentMute", in: xml) == "1"
    }

    func setMuted(_ muted: Bool) async throws {
        _ = try await soap("RenderingControl", "SetMute",
                           "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(muted ? 1 : 0)</DesiredMute>")
    }

    func nowPlaying() async throws -> NowPlaying {
        let state = try await soap("AVTransport", "GetTransportInfo", "<InstanceID>0</InstanceID>")
        let position = try await soap("AVTransport", "GetPositionInfo", "<InstanceID>0</InstanceID>")
        var now = NowPlaying()
        now.isPlaying = Self.tag("CurrentTransportState", in: state) == "PLAYING"
        // The track's details come as escaped XML inside the answer.
        if let meta = Self.tag("TrackMetaData", in: position).map(Self.unescape) {
            now.title = Self.tag("dc:title", in: meta).map(Self.unescape)
            now.artist = Self.tag("dc:creator", in: meta).map(Self.unescape)
            if let art = Self.tag("upnp:albumArtURI", in: meta).map(Self.unescape), !art.isEmpty {
                now.artURL = art.hasPrefix("http") ? URL(string: art) : URL(string: "http://\(address):1400\(art)")
            }
        }
        return now
    }

    // MARK: Talking to it

    private func soap(_ service: String, _ action: String, _ arguments: String) async throws -> String {
        let urn = "urn:schemas-upnp-org:service:\(service):1"
        guard let url = URL(string: "http://\(address):1400/MediaRenderer/\(service)/Control") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(urn)">\
        \(arguments)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>") ?? xml.range(of: "<\(name) ", options: []).flatMap({ r in
                  xml.range(of: ">", range: r.upperBound..<xml.endIndex) }),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A Sonos speaker as one of the remote's devices: its face is the speaker's, with what's playing and a volume slider.
@MainActor
final class SonosDevice: ObservableObject, DeviceController {
    let sonos: Sonos
    @Published private(set) var playing = Sonos.NowPlaying()
    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var answered = true

    init(address: String) { sonos = Sonos(address: address) }

    let abilities: Set<Ability> = [.speaker, .volume]

    var state: DeviceState {
        guard answered else { return .offline("Not answering") }
        return .ready(playing.isPlaying ? "Playing" : "Sonos")
    }

    /// What's playing and how loud, read again.
    func refresh() async {
        do {
            playing = try await sonos.nowPlaying()
            volume = Double(try await sonos.volume())
            muted = try await sonos.isMuted()
            answered = true
        } catch {
            answered = false
        }
    }

    func wake() async { await refresh() }

    func setVolume(_ value: Double) {
        volume = value
        Task { try? await sonos.setVolume(Int(value.rounded())) }
    }

    func playOrPause() async {
        try? await (playing.isPlaying ? sonos.pause() : sonos.play())
        await settle()
    }

    func send(_ key: TVKey, times: Int) async {
        do {
            switch key {
            case .play: try await sonos.play()
            case .pause, .stop: try await sonos.pause()
            case .ok: try await (playing.isPlaying ? sonos.pause() : sonos.play())
            case .fastForward, .right, .channelUp: try await sonos.next()
            case .rewind, .left, .channelDown: try await sonos.previous()
            case .volumeUp, .up: try await sonos.setVolume(Int(volume) + 3 * times)
            case .volumeDown, .down: try await sonos.setVolume(Int(volume) - 3 * times)
            case .mute: try await sonos.setMuted(!muted)
            case .power: try await sonos.pause()
            default: return
            }
        } catch {
            answered = false
            return
        }
        await settle()
    }

    /// Play and pause are confirmed by what the speaker says it's doing afterwards; the rest it only takes.
    func deliver(_ command: RemoteCommand) async -> CommandOutcome {
        guard case .press(let key, let times) = command else { return .notSent("A speaker has no apps.") }
        do {
            switch key {
            case .play: try await sonos.play()
            case .pause, .stop: try await sonos.pause()
            case .fastForward, .right, .channelUp: try await sonos.next()
            case .rewind, .left, .channelDown: try await sonos.previous()
            case .volumeUp, .up: try await sonos.setVolume(Int(volume) + 3 * times)
            case .volumeDown, .down: try await sonos.setVolume(Int(volume) - 3 * times)
            case .mute: try await sonos.setMuted(!muted)
            default: return .notSent("A speaker has no \(key.title) key.")
            }
        } catch {
            answered = false
            return .failed(error.localizedDescription)
        }
        await settle()
        switch key {
        case .play: return playing.isPlaying ? .confirmed("Playing") : .unknown("The speaker doesn't say it's playing.")
        case .pause, .stop: return playing.isPlaying ? .unknown("The speaker still says it's playing.") : .confirmed("Paused")
        default: return .sent
        }
    }

    /// A moment for the speaker to take the change, then what it's doing now.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
    }
}
