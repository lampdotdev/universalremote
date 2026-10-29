import SwiftUI

/// Ask: the person says or types what they want ("make a Movie Night routine", "volume up five"), and the AI does it
/// with the remote's own tools: it looks up devices, apps and routines, builds a routine draft for the person to
/// review and save, opens a saved routine's Run review, or sends a one-off command through `Commands`. It never saves
/// or runs a routine itself, and what the remote says comes from what the tools did.
@MainActor
final class AskModel: ObservableObject {
    static let shared = AskModel()

    @Published var text = ""
    @Published private(set) var status: LampAIStatus?
    @Published private(set) var working = false
    @Published private(set) var step = ""
    /// The last answer: what was done, or the question back.
    @Published private(set) var said = ""
    @Published private(set) var question: String?
    @Published private(set) var choices: [String] = []
    /// The request kept after a failure, for Try Again.
    @Published private(set) var failedRequest: String?

    private lazy var session = LampActSession(about: Self.about, tools: tools)
    private var turn: LampActTurn?

    func refresh() async { status = await LampAI.status(.act) }

    /// Sends what's typed (or heard). While a question waits, what's typed, said or chosen answers it; a `fresh`
    /// request (from Siri) is always a new one.
    func submit(_ request: String? = nil, fresh: Bool = false) {
        let words = (request ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if request == nil { text = "" }
        if !fresh, question != nil, let answering = session.answer(words, context: context, onStep: show) {
            go(answering, words)
        } else {
            go(session.ask(words, context: context, onStep: show), words)
        }
    }

    func retry() {
        guard let request = failedRequest else { return }
        failedRequest = nil
        go(session.ask(request, context: context, onStep: show), request)
    }

    /// Stops now: the field is free at once. A change already under way still finishes, and what it did is shown
    /// when it does.
    func cancel() {
        turn?.cancel()
        session.cancel()
        question = nil
        choices = []
        working = false
        step = ""
        said = "Stopped."
    }

    private func go(_ turn: LampActTurn, _ words: String) {
        self.turn?.cancel()
        self.turn = turn
        working = true
        question = nil
        choices = []
        said = ""
        failedRequest = nil
        Task {
            let result = await turn.result
            guard self.turn === turn else { return }
            working = false
            step = ""
            question = result.question
            choices = result.choices
            said = result.summary
            // Try Again only when nothing went through: asking again after a change was made would make it twice.
            if [.error, .unreachable, .time].contains(result.stopped), result.done.isEmpty { failedRequest = words }
            if result.stopped == .unreachable { await refresh() }
        }
    }

    private func show(_ step: LampActStep) {
        switch step {
        case .thinking: self.step = "Thinking…"
        case .reading(let name): self.step = "Looking at \(Self.reading[name] ?? name)…"
        case .changing(let name): self.step = Self.changing[name] ?? "Working…"
        case .changed, .failed: break
        }
    }

    private static let reading = ["devices": "your devices", "apps": "the apps", "routines": "your routines", "draft": "the draft"]
    private static let changing = ["nameRoutine": "Naming the routine…", "setStep": "Adding a step…", "removeStep": "Removing a step…",
                                   "reviewRoutine": "Opening the routine…", "press": "Sending…", "openApp": "Opening the app…"]

    /// What the remote shows now, for the AI: the device chosen in it.
    private var context: [String: String] { ["selectedDevice": DeviceHub.shared.selected?.id ?? ""] }

    private static let about = """
    A universal remote for the household's TVs and speakers. Every device has an id; use ids exactly as the tools give them.
    - To make a routine (a named button that does several things), name it with nameRoutine and add its steps in order \
    with setStep. The person reviews the draft and saves it; you never save one. A routine has at most \(Routines.maxSteps) \
    steps and sends at most \(Routines.maxSends) commands; a wait is 0 to \(Int(Routines.maxWait)) seconds.
    - When the person names a device that more than one could be ("the TV" with two TVs), ask which, with the devices' \
    names as choices. Never pick one for them by guessing.
    - To run a saved routine, open its review with reviewRoutine; the person presses Run.
    - For a one-off command now ("volume up five", "open Netflix"), use press or openApp on the device they mean, the \
    selected one when they don't say.
    - You can't turn anything off, type text, or do anything the tools don't offer: say so.
    """

    // MARK: Tools

    private struct DeviceArg: Decodable { let deviceID: String }
    private struct NameArg: Decodable { let name: String }
    private struct IndexArg: Decodable { let index: Int }
    private struct RoutineArg: Decodable { let routineID: String }
    private struct PressArg: Decodable { let deviceID: String; let key: String; let times: Int? }
    private struct OpenArg: Decodable { let deviceID: String; let appID: String }
    private struct StepArg: Decodable {
        let index: Int
        let operation: String
        let deviceID: String?
        let appID: String?
        let key: String?
        let times: Int?
        let seconds: Double?
    }

    private static let keys = VoiceCommands.keyNames.keys.sorted()

    private var tools: [LampActTool] {
        let hub = DeviceHub.shared, routines = Routines.shared
        func device(_ id: String) -> HomeDevice? { hub.known(id) }
        func app(_ id: String, on deviceID: String) async -> TVApp? {
            guard let device = device(deviceID), let controller = hub.controller(for: device) else { return nil }
            return await controller.appList().first { $0.id == id }
        }
        func stepProblem(_ s: StepArg) async -> String? {
            let draft = routines.draft ?? RoutineDraft()
            guard s.index >= 0, s.index <= draft.steps.count else { return "The draft has \(draft.steps.count) steps: use 0 to \(draft.steps.count)." }
            if s.index == draft.steps.count, draft.steps.count >= Routines.maxSteps { return "A routine has at most \(Routines.maxSteps) steps." }
            guard let step = await makeStep(s) else { return "That app isn't on that device: look at its apps first." }
            if let why = Routines.problem(step) { return why }
            var steps = draft.steps
            if s.index == steps.count { steps.append(step) } else { steps[s.index] = step }
            if steps.reduce(0, { $0 + $1.sends }) > Routines.maxSends { return "A routine sends at most \(Routines.maxSends) commands in all." }
            return nil
        }
        func makeStep(_ s: StepArg) async -> RoutineStep? {
            let operation = RoutineStep.Operation(rawValue: s.operation) ?? .wait
            var step = RoutineStep(id: UUID().uuidString, operation: operation, deviceID: s.deviceID)
            switch operation {
            case .wait: step.seconds = s.seconds ?? 0
            case .press: step.key = s.key; step.times = s.times ?? 1
            case .openApp:
                guard let deviceID = s.deviceID, let appID = s.appID else { return step }
                guard let found = await app(appID, on: deviceID) else { return nil }
                step.appID = found.id
                step.appName = found.name
            }
            return step
        }
        func commandProblem(_ command: RemoteCommand?, _ deviceID: String) async -> String? {
            guard let command else { return "That app isn't on that device: look at its apps first." }
            return await CommandSender.shared.problem(command, on: deviceID)
        }
        func send(_ command: RemoteCommand, _ deviceID: String) async throws -> LampActReceipt {
            let outcome = await CommandSender.shared.run(command, on: deviceID)
            let receipt = outcome.receipt(command, on: device(deviceID)?.name ?? deviceID)
            guard outcome.wentThrough else { throw LampAI.Failure(message: receipt) }
            return LampActReceipt(receipt)
        }
        return [
            .read("devices", "Every device: id, name, room, kind, what it can do, and whether it's the one selected in the remote.") {
                hub.choices.map { d -> [String: String] in
                    let can = hub.controller(for: d)?.abilities.map { "\($0)" }.sorted().joined(separator: ", ") ?? ""
                    return ["id": d.id, "name": d.name, "room": d.room ?? "", "kind": d.kindName, "can": can,
                            "selected": d.id == hub.selected?.id ? "yes" : "no"]
                }
            },
            .read("apps", "The apps on one device: id and name.", args: ["deviceID": .text("A device's id")], as: DeviceArg.self) { a, _ in
                guard let d = device(a.deviceID), let controller = hub.controller(for: d) else { throw LampAI.Failure(message: "There's no device with that id.") }
                return await controller.appList().map { ["id": $0.id, "name": $0.name] }
            },
            .read("routines", "The saved routines: id, name and steps.") {
                routines.saved.map { r in ["id": r.id, "name": r.name, "steps": r.steps.map(Routines.words).joined(separator: "; ")] }
            },
            .read("draft", "The routine being made: its name and steps, in order, and what it still needs.") {
                let draft = routines.draft ?? RoutineDraft()
                return ["name": draft.name, "steps": draft.steps.enumerated().map { "\($0.offset): \(Routines.words($0.element))" }.joined(separator: "; "),
                        "needs": routines.unresolved(draft).joined(separator: " ")]
            },
            .write("nameRoutine", "Starts a routine draft with this name, or renames the draft.", args: ["name": .text("The routine's name, a few words")], as: NameArg.self,
                   check: { a, _ in
                       let name = a.name.trimmingCharacters(in: .whitespaces)
                       if name.isEmpty || name.count > 40 { return "A name is 1 to 40 characters." }
                       return nil
                   },
                   run: { a, _ in
                       var draft = routines.draft ?? RoutineDraft()
                       draft.name = a.name.trimmingCharacters(in: .whitespaces)
                       routines.draft = draft
                       let taken = routines.named(draft.name) != nil ? " (a saved routine has this name: the person chooses whether to replace it)" : ""
                       return LampActReceipt("Started the routine draft “\(draft.name)”\(taken)")
                   }),
            .write("setStep", "Puts one step in the draft at `index`: the next one (index = number of steps) to add, or an existing one to replace.",
                   args: ["index": .whole("Where, from 0", min: 0, max: Routines.maxSteps - 1),
                          "operation": .text("openApp, press or wait", oneOf: RoutineStep.Operation.allCases.map(\.rawValue)),
                          "deviceID": .text("For openApp and press: a device's id", optional: true),
                          "appID": .text("For openApp: an app's id from apps", optional: true),
                          "key": .text("For press: which key", oneOf: Self.keys, optional: true),
                          "times": .whole("For press: how many times", min: 1, max: Routines.maxTimes, optional: true),
                          "seconds": .number("For wait: how long", min: 0, max: Routines.maxWait, optional: true)],
                   as: StepArg.self,
                   check: { a, _ in routines.draft == nil ? "Name the routine first." : await stepProblem(a) },
                   run: { a, _ in
                       guard var draft = routines.draft, let step = await makeStep(a) else { throw LampAI.Failure(message: "The draft changed meanwhile.") }
                       if a.index == draft.steps.count { draft.steps.append(step) } else { draft.steps[a.index] = step }
                       routines.draft = draft
                       return LampActReceipt("Step \(a.index + 1): \(Routines.words(step))")
                   }),
            .write("removeStep", "Takes one step out of the draft.", args: ["index": .whole("Which, from 0", min: 0)], as: IndexArg.self,
                   check: { a, _ in (routines.draft?.steps.indices.contains(a.index) ?? false) ? nil : "The draft has no such step." },
                   run: { a, _ in
                       guard var draft = routines.draft, draft.steps.indices.contains(a.index) else { throw LampAI.Failure(message: "The draft changed meanwhile.") }
                       let gone = draft.steps.remove(at: a.index)
                       routines.draft = draft
                       return LampActReceipt("Took out: \(Routines.words(gone))")
                   }),
            .write("reviewRoutine", "Opens a saved routine's review, where the person can press Run. It doesn't run it.",
                   args: ["routineID": .text("A routine's id from routines")], as: RoutineArg.self,
                   check: { a, _ in
                       if routines.routine(a.routineID) == nil { return "There's no saved routine with that id." }
                       if routines.run?.isRunning == true { return "A routine is running: wait for it to finish." }
                       if routines.reviewing != nil { return "A routine's review is open: close it first." }
                       return nil
                   },
                   run: { a, _ in
                       guard let routine = routines.routine(a.routineID) else { throw LampAI.Failure(message: "That routine isn't there any more.") }
                       routines.review(routine)
                       return LampActReceipt("Opened \(routine.name): press Run to start it")
                   }),
            .write("press", "Presses a key on one device now.",
                   args: ["deviceID": .text("A device's id"), "key": .text("Which key", oneOf: Self.keys),
                          "times": .whole("How many times", min: 1, max: Routines.maxTimes, optional: true)], as: PressArg.self,
                   check: { a, _ in
                       guard let key = VoiceCommands.keyNames[a.key] else { return "There's no such key." }
                       return await commandProblem(.press(key, times: a.times ?? 1), a.deviceID)
                   },
                   run: { a, _ in try await send(.press(VoiceCommands.keyNames[a.key]!, times: a.times ?? 1), a.deviceID) }),
            .write("openApp", "Opens an app on one device now.", args: ["deviceID": .text("A device's id"), "appID": .text("An app's id from apps")], as: OpenArg.self,
                   check: { a, _ in await commandProblem(await app(a.appID, on: a.deviceID).map(RemoteCommand.open), a.deviceID) },
                   run: { a, _ in
                       guard let found = await app(a.appID, on: a.deviceID) else { throw LampAI.Failure(message: "That app isn't on that device.") }
                       return try await send(.open(found), a.deviceID)
                   }),
        ]
    }
}

/// Ask under the remote: what answers it and where, the field, and the last answer. Without AI it says why and how to
/// set it up, and the remote and routines work the same.
struct AskBar: View {
    @ObservedObject private var ask = AskModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ask: “Make a Movie Night routine…”", text: $ask.text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(RemoteColors.label)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(RemoteColors.key))
                    .onSubmit { if ready { ask.submit() } }
                    .disabled(ask.working)
                if ask.working {
                    Button("Stop") { ask.cancel() }.buttonStyle(.plain).foregroundStyle(RemoteColors.label)
                } else {
                    Button { ask.submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(ready && !ask.text.isEmpty ? .white : RemoteColors.faint)
                        .disabled(!ready || ask.text.isEmpty)
                        .help("Ask")
                }
            }
            line
            if !ask.choices.isEmpty {
                HStack {
                    ForEach(ask.choices, id: \.self) { choice in
                        Button(choice) { ask.submit(choice) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(RemoteColors.key))
                            .foregroundStyle(RemoteColors.label)
                    }
                }
            }
        }
        .task { await ask.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await ask.refresh() } } }
    }

    private var ready: Bool { ask.status?.available == true }

    @ViewBuilder private var line: some View {
        if ask.working {
            Text(ask.step).font(.caption).foregroundStyle(RemoteColors.faint)
        } else if !ask.said.isEmpty {
            HStack(alignment: .top) {
                Text(ask.said).font(.caption).foregroundStyle(RemoteColors.label).fixedSize(horizontal: false, vertical: true)
                if ask.failedRequest != nil { Button("Try Again") { ask.retry() }.buttonStyle(.plain).font(.caption.weight(.semibold)) }
            }
        } else if let status = ask.status {
            if status.available {
                Text("Ask is ready: \(status.route ?? "AI in Lamp")\(Self.place(status.processing))")
                    .font(.caption).foregroundStyle(RemoteColors.faint)
            } else {
                HStack(alignment: .top) {
                    Text(status.reason ?? "Ask needs AI set up in Lamp.").font(.caption).foregroundStyle(RemoteColors.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(Self.setupTitle(status.setup)) { LampAI.openSetup(for: .act) }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(RemoteColors.label)
                }
            }
        }
    }

    private static func place(_ processing: LampAIStatus.Processing) -> String {
        switch processing {
        case .onDevice: return ", on this Mac"
        case .remote: return ". What you ask and your devices' names are sent to it."
        case .unknown: return ""
        }
    }

    private static func setupTitle(_ setup: LampAIStatus.Setup?) -> String {
        switch setup {
        case .openLamp?: return "Open Lamp"
        case .updateLamp?: return "Update Lamp"
        default: return "Set up in Lamp"
        }
    }
}
