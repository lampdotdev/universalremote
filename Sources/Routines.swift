import SwiftUI

/// One step of a routine, by the ids of what it uses, so a renamed device or a different one chosen in the remote
/// never changes where it goes.
struct RoutineStep: Codable, Identifiable, Hashable {
    enum Operation: String, Codable, CaseIterable { case openApp, press, wait }

    var id: String
    var operation: Operation
    var deviceID: String?
    var appID: String?
    /// The app's name as it was when the step was made, for showing it; the app itself is found by `appID`.
    var appName: String?
    /// A key, by its name in `VoiceCommands.keyNames`.
    var key: String?
    var times: Int?
    var seconds: Double?

    /// How many commands it sends when it runs.
    var sends: Int {
        switch operation {
        case .openApp: return 1
        case .press: return times ?? 1
        case .wait: return 0
        }
    }
}

/// A routine the person saved: run from its button, with no AI. `revision` goes up every time it's replaced, so a run
/// reviewed before a change can't run the changed one.
struct Routine: Codable, Identifiable, Hashable {
    var id: String
    var revision: Int
    var name: String
    var steps: [RoutineStep]
}

/// What's saved: versioned, so a later shape can be read alongside this one.
private struct SavedRoutines: Codable {
    var version = 1
    var routines: [Routine]
}

/// A routine being made (by Ask, or changed by the person) before it's saved. Saving it never sends anything.
struct RoutineDraft: Equatable {
    var name = ""
    var steps: [RoutineStep] = []
}

/// The household's routines, the draft being made, and the run going on.
@MainActor
final class Routines: ObservableObject {
    static let shared = Routines()

    /// What a routine may be, said to the person and the AI the same way: these are deliberate limits.
    static let maxSteps = 6
    static let maxSends = 10
    static let maxWait: Double = 5
    static let maxTimes = 10
    static let runSeconds: Double = 30

    @Published private(set) var saved: [Routine] = []
    @Published var draft: RoutineDraft?
    /// The routine waiting on its Run review, as it was when the review opened.
    @Published var reviewing: Routine?
    @Published private(set) var run: RoutineRun?

    private static let key = "routines"

    init() {
        saved = LampStore.load(SavedRoutines.self, from: Self.key)?.routines ?? []
    }

    func routine(_ id: String) -> Routine? { saved.first { $0.id == id } }
    func named(_ name: String) -> Routine? { saved.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame } }

    // MARK: Saving

    /// Why the draft can't be saved as it is, or nil.
    func problem(with draft: RoutineDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give it a name." }
        if draft.steps.isEmpty { return "It has no steps yet." }
        if let unresolved = unresolved(draft).first { return unresolved }
        return nil
    }

    /// What a draft still needs before it can be saved: a device or an app that isn't there, a value out of range.
    func unresolved(_ draft: RoutineDraft) -> [String] {
        var needs: [String] = []
        if draft.steps.count > Self.maxSteps { needs.append("A routine has at most \(Self.maxSteps) steps.") }
        if draft.steps.reduce(0, { $0 + $1.sends }) > Self.maxSends { needs.append("A routine sends at most \(Self.maxSends) commands.") }
        for (index, step) in draft.steps.enumerated() {
            if let why = Self.problem(step) { needs.append("Step \(index + 1): \(why)") }
        }
        return needs
    }

    /// Why a step can't be what it says, from what the remote knows now (device and app availability are checked
    /// again, live, when it runs).
    static func problem(_ step: RoutineStep) -> String? {
        let hub = DeviceHub.shared
        switch step.operation {
        case .wait:
            guard let seconds = step.seconds, (0...maxWait).contains(seconds) else { return "A wait is 0 to \(Int(maxWait)) seconds." }
            return nil
        case .openApp, .press:
            guard let id = step.deviceID, let device = hub.known(id) else { return "Which device?" }
            guard let controller = hub.controller(for: device) else { return "\(device.name) can't be controlled yet." }
            if step.operation == .openApp {
                guard controller.abilities.contains(.apps) else { return "\(device.name) doesn't open apps." }
                guard step.appID != nil else { return "Which app?" }
            } else {
                guard let name = step.key, let key = VoiceCommands.keyNames[name] else { return "Which key?" }
                guard CommandSender.can(controller.abilities, key) else { return "\(device.name) has no \(key.title) key." }
                guard (1...maxTimes).contains(step.times ?? 1) else { return "A key is pressed 1 to \(maxTimes) times." }
            }
            return nil
        }
    }

    /// Saves the draft as a new routine, or in place of `replacing` (whose revision must still be `revision`, so a
    /// routine changed meanwhile isn't overwritten). Returns why it couldn't, or nil.
    @discardableResult
    func save(_ draft: RoutineDraft, replacing: Routine? = nil) -> String? {
        if let problem = problem(with: draft) { return problem }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if let replacing {
            guard let index = saved.firstIndex(where: { $0.id == replacing.id }) else { return "That routine isn't there any more." }
            guard saved[index].revision == replacing.revision else { return "\(replacing.name) changed meanwhile. Look at it again first." }
            saved[index] = Routine(id: replacing.id, revision: replacing.revision + 1, name: name, steps: draft.steps)
        } else {
            if named(name) != nil { return "There's already a routine called \(name)." }
            saved.append(Routine(id: UUID().uuidString, revision: 1, name: name, steps: draft.steps))
        }
        LampStore.save(SavedRoutines(routines: saved), to: Self.key)
        self.draft = nil
        return nil
    }

    func delete(_ routine: Routine) {
        saved.removeAll { $0.id == routine.id }
        LampStore.save(SavedRoutines(routines: saved), to: Self.key)
    }

    // MARK: Running

    /// Opens the Run review of a saved routine: what it will do, and Run. Nothing is sent until Run is pressed.
    func review(_ routine: Routine) {
        guard run?.isRunning != true else { return }
        run = nil
        reviewing = routine
    }

    /// Runs the routine under review, as it was reviewed.
    func start() {
        guard let routine = reviewing, run?.isRunning != true else { return }
        let run = RoutineRun(routine)
        self.run = run
        run.task = Task { await run.go() }
    }

    func closeReview() {
        run?.stop()
        run = nil
        reviewing = nil
    }

    /// Words for one step, with the device and app named.
    static func words(_ step: RoutineStep) -> String {
        let hub = DeviceHub.shared
        let device = step.deviceID.flatMap(hub.known)?.name ?? "a device to choose"
        switch step.operation {
        case .wait: return "Wait \(LampFormat.seconds(step.seconds ?? 0))"
        case .openApp: return "Open \(step.appName ?? "an app to choose") on \(device)"
        case .press:
            let key = step.key.flatMap { VoiceCommands.keyNames[$0] }?.title ?? "a key to choose"
            return "Press \(key)\((step.times ?? 1) > 1 ? " ×\(step.times!)" : "") on \(device)"
        }
    }
}

enum LampFormat {
    static func seconds(_ value: Double) -> String {
        let whole = value.rounded() == value
        let n = whole ? String(Int(value)) : String(format: "%.1f", value)
        return "\(n) second\(value == 1 ? "" : "s")"
    }
}

/// One run of a saved routine: its steps in order, each to the device it names, each checked right before it goes.
/// It stops at the first step that doesn't go through, or when the person presses Stop, and says what each step did.
@MainActor
final class RoutineRun: ObservableObject {
    enum StepState: Equatable {
        case waiting
        case running
        case done(String)
        case stopped(String)
        case skipped(String)
    }

    let routine: Routine
    @Published private(set) var states: [StepState]
    @Published private(set) var isRunning = false
    @Published private(set) var ending: String?
    private var stopping = false

    init(_ routine: Routine) {
        self.routine = routine
        states = routine.steps.map { _ in .waiting }
    }

    /// The run's task, cancelled by Stop: a command still waiting its turn isn't sent, nor is anything after it.
    var task: Task<Void, Never>?

    func stop() {
        stopping = true
        task?.cancel()
    }

    func go() async {
        isRunning = true
        defer { isRunning = false }
        let started = Date()
        // The routine as it was reviewed: a version saved since then doesn't run in its place.
        guard Routines.shared.routine(routine.id)?.revision == routine.revision else {
            ending = "\(routine.name) changed after you looked at it. Close this and look again."
            return
        }
        for (index, step) in routine.steps.enumerated() {
            if stopping { skipRest(from: index, "Not run: stopped."); ending = "Stopped."; return }
            if Date().timeIntervalSince(started) > Routines.runSeconds {
                skipRest(from: index, "Not run: out of time."); ending = "Ran out of time."; return
            }
            states[index] = .running
            switch step.operation {
            case .wait:
                let until = Date().addingTimeInterval(min(max(step.seconds ?? 0, 0), Routines.maxWait))
                while Date() < until, !stopping { try? await Task.sleep(for: .milliseconds(100)) }
                if stopping {
                    states[index] = .stopped("Stopped while waiting.")
                    skipRest(from: index + 1, "Not run: stopped.")
                    ending = "Stopped."
                    return
                }
                states[index] = .done("Waited \(LampFormat.seconds(step.seconds ?? 0))")
            case .press, .openApp:
                guard let deviceID = step.deviceID, let command = await command(for: step, on: deviceID) else {
                    states[index] = .stopped("Not sent: \(Routines.problem(step) ?? "its app isn't on that device now.")")
                    skipRest(from: index + 1, "Not run: an earlier step didn't go through.")
                    ending = "Stopped at step \(index + 1)."
                    return
                }
                let device = DeviceHub.shared.known(deviceID)?.name ?? "that device"
                if stopping {
                    states[index] = .stopped("Not sent: stopped.")
                    skipRest(from: index + 1, "Not run: stopped.")
                    ending = "Stopped."
                    return
                }
                let outcome = await CommandSender.shared.run(command, on: deviceID, unless: { [weak self] in self?.stopping ?? true })
                states[index] = outcome.wentThrough ? .done(outcome.receipt(command, on: device)) : .stopped(outcome.receipt(command, on: device))
                // A step that didn't go, or might not have, stops the rest: the person sees what's left rather than
                // have it sent again by itself.
                if !outcome.wentThrough {
                    skipRest(from: index + 1, "Not run: an earlier step didn't go through.")
                    ending = "Stopped at step \(index + 1)."
                    return
                }
            }
        }
        ending = "Done."
    }

    private func command(for step: RoutineStep, on deviceID: String) async -> RemoteCommand? {
        switch step.operation {
        case .press:
            guard let key = step.key.flatMap({ VoiceCommands.keyNames[$0] }) else { return nil }
            return .press(key, times: min(max(step.times ?? 1, 1), Routines.maxTimes))
        case .openApp:
            guard let device = DeviceHub.shared.known(deviceID), let controller = DeviceHub.shared.controller(for: device),
                  let app = await controller.appList().first(where: { $0.id == step.appID }) else { return nil }
            return .open(app)
        case .wait: return nil
        }
    }

    private func skipRest(from index: Int, _ why: String) {
        for i in index..<states.count where states[i] == .waiting || states[i] == .running { states[i] = .skipped(why) }
    }
}
