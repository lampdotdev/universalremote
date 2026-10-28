import Foundation

/// A TV that isn't there, for trying the remote before any device is found: every key works and says what it would
/// have done, and nothing leaves this device.
@MainActor
final class ExampleTV: DeviceController {
    /// What the last press would have done ("Volume up"), for the line under the remote.
    var said: (String) -> Void = { _ in }

    let abilities: Set<Ability> = [.navigate, .apps, .text, .volume, .channels, .source, .settings, .power]
    var state: DeviceState { .ready("Example: nothing is sent") }

    func send(_ key: TVKey, times: Int) async {
        let name = String(describing: key).replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        said("\(name.prefix(1).uppercased() + name.dropFirst())\(times > 1 ? " ×\(times)" : "")")
    }

    func appList() async -> [TVApp] { TVApp.popular }
    func open(_ app: TVApp) async { said("Open \(app.name)") }
    func send(text: String) async { said("Type “\(text)”") }
    func togglePower() async { said("Power") }
    func turnOn() async { said("Turn on") }
}
