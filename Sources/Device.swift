import SwiftUI

/// A device of the house the remote knows, as it's remembered between launches.
struct HomeDevice: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case samsung, roku, sonos, example }

    var id: String
    var name: String
    var kind: Kind
    var address: String
    var model: String?
    /// A Samsung TV's Wi-Fi address, for waking it.
    var mac: String?
    /// The room it's in, when the person has said or it's an example; devices saved before rooms have none.
    var room: String? = nil

    var symbol: String {
        switch kind {
        case .samsung, .example: return "tv"
        case .roku: return "appletvremote.gen1"
        case .sonos: return "hifispeaker.fill"
        }
    }

    var kindName: String {
        switch kind {
        case .samsung: return "Samsung TV"
        case .roku: return "Roku"
        case .sonos: return "Sonos speaker"
        case .example: return "example TV"
        }
    }

    /// Two TVs that aren't there, for trying the remote (and routines across two devices) before any is found. They're
    /// never saved among the devices: they're offered while nothing is found or one of them is in use.
    static let example = HomeDevice(id: "example", name: "Living Room TV (example)", kind: .example, address: "", model: "Nothing is sent", mac: nil, room: "Living room")
    static let secondExample = HomeDevice(id: "example-2", name: "Bedroom TV (example)", kind: .example, address: "", model: "Nothing is sent", mac: nil, room: "Bedroom")
    static let examples = [example, secondExample]
}

/// One thing sent to one device: a key (pressed `times` times), an app opened, power (on when it's off, off when it's
/// on, as the remote's key does), turning it on, or words typed into its search box.
enum RemoteCommand: Hashable {
    case press(TVKey, times: Int)
    case open(TVApp)
    case power
    case turnOn
    case type(String)

    var words: String {
        switch self {
        case .press(let key, let times): return key.title + (times > 1 ? " ×\(times)" : "")
        case .open(let app): return "Open \(app.name)"
        case .power: return "Power"
        case .turnOn: return "Turn on"
        case .type(let text): return "Type “\(text)”"
        }
    }
}

/// What came of a command, as far as the remote can know it. A device that took the bytes hasn't said it did what was
/// asked, so `sent` is never read as "it's done".
enum CommandOutcome: Equatable {
    /// Checked and refused: nothing left this Mac.
    case notSent(String)
    /// The device took it; nothing says what it did.
    case sent
    /// The device's own answer shows it happened.
    case confirmed(String)
    /// Tried, and it didn't go.
    case failed(String)
    /// It may have gone or not: the connection went while sending.
    case unknown(String)
    /// An example TV: nothing is sent anywhere.
    case simulated

    /// Whether what comes after it can go on.
    var wentThrough: Bool {
        switch self {
        case .sent, .confirmed, .simulated: return true
        case .notSent, .failed, .unknown: return false
        }
    }

    func receipt(_ command: RemoteCommand, on device: String) -> String {
        switch self {
        case .notSent(let why): return "Not sent: \(command.words) on \(device). \(why)"
        case .sent: return "Sent: \(command.words) to \(device)"
        case .confirmed(let what): return "\(command.words) on \(device): \(what)"
        case .failed(let why): return "Failed: \(command.words) on \(device). \(why)"
        case .unknown(let why): return "Sent, not confirmed: \(command.words) on \(device). \(why)"
        case .simulated: return "Simulated: \(command.words) on \(device)"
        }
    }
}

/// What a device can do. The remote's screen asks for these, never for the kind of device: a TV that can't change
/// its volume over the network shows no volume keys.
enum Ability: Hashable {
    case navigate   // arrows, OK, Back, Home
    case apps       // opens its apps
    case text       // takes typing into its search box
    case volume, channels, source, settings, power
    case speaker    // a speaker's face: what's playing, play and pause, next, a volume slider
}

/// How a device stands right now, for the dot and line under its name.
enum DeviceState: Equatable {
    case ready(String)
    case working(String)
    /// It's there but needs something done first, said plainly.
    case needs(String)
    case offline(String)

    var words: String {
        switch self {
        case .ready(let s), .working(let s), .needs(let s), .offline(let s): s
        }
    }
}

/// One kind of device behind the one face the remote uses. A new kind is one more file like Roku.swift: what it can
/// do, and how.
@MainActor
protocol DeviceController: AnyObject {
    var abilities: Set<Ability> { get }
    var state: DeviceState { get }
    func send(_ key: TVKey, times: Int) async
    func appList() async -> [TVApp]
    func open(_ app: TVApp) async
    func send(text: String) async
    func togglePower() async
    /// Turns it on, and leaves it on when it already is.
    func turnOn() async
    func icon(for app: TVApp) -> LampImage?
    /// Called when it's chosen, to connect or catch up.
    func wake() async
    /// Sends one command and says what came of it, from what the device answered: every kind says it its own way.
    func deliver(_ command: RemoteCommand) async -> CommandOutcome
}

extension DeviceController {
    func appList() async -> [TVApp] { [] }
    func open(_ app: TVApp) async {}
    func send(text: String) async {}
    func togglePower() async {}
    func turnOn() async {}
    func icon(for app: TVApp) -> LampImage? { nil }
    func wake() async {}
}
