import Foundation

/// A TV that isn't there, for trying the remote before any device is found: every key works and says what it would
/// have done, and nothing leaves this device. What each one was sent goes in `ExampleTV.log`, in order, so a routine
/// across two of them can be checked against what each got.
@MainActor
final class ExampleTV: DeviceController {
    /// Every command the example TVs were sent, oldest first: "Bedroom TV (example): Home".
    static var log: [String] = [] { didSet { if log.count > 50 { log.removeFirst(log.count - 50) } } }

    let name: String
    /// What the last press would have done ("Volume up"), for the line under the remote.
    var said: (String) -> Void = { _ in }

    init(name: String) { self.name = name }

    let abilities: Set<Ability> = [.navigate, .apps, .text, .volume, .channels, .source, .settings, .power]
    var state: DeviceState { .ready("Example: nothing is sent") }

    private func record(_ words: String) {
        Self.log.append("\(name): \(words)")
        said(words)
    }

    func send(_ key: TVKey, times: Int) async { record(RemoteCommand.press(key, times: times).words) }
    func appList() async -> [TVApp] { TVApp.popular }
    func open(_ app: TVApp) async { record("Open \(app.name)") }
    func send(text: String) async { record("Type “\(text)”") }
    func togglePower() async { record("Power") }
    func turnOn() async { record("Turn on") }

    func deliver(_ command: RemoteCommand) async -> CommandOutcome {
        record(command.words)
        return .simulated
    }
}
