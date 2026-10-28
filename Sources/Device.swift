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

    static let example = HomeDevice(id: "example", name: "Example TV", kind: .example, address: "", model: "Nothing is sent", mac: nil)
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
