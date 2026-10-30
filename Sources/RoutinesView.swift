import SwiftUI

/// The saved routines as buttons (each opens its Run review; no AI), and the draft Ask is making, to review and save.
struct RoutinesBar: View {
    @ObservedObject private var routines = Routines.shared
    @State private var reviewingDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ROUTINES").font(.caption2.weight(.bold)).foregroundStyle(RemoteColors.faint)
                Spacer()
            }
            if routines.saved.isEmpty, routines.draft == nil {
                Text("None yet. Ask for one, like “Movie Night: open YouTube on the TV, then pause the speaker.”")
                    .font(.caption).foregroundStyle(RemoteColors.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !routines.saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(routines.saved) { routine in
                            Button { routines.review(routine) } label: {
                                Label(routine.name, systemImage: "play.circle.fill")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(RemoteColors.key))
                                    .foregroundStyle(RemoteColors.label)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete \(routine.name)", role: .destructive) { routines.delete(routine) } }
                        }
                    }
                }
            }
            if let draft = routines.draft {
                Button { reviewingDraft = true } label: {
                    Label("Review “\(draft.name.isEmpty ? "New routine" : draft.name)”: \(draft.steps.count) step\(draft.steps.count == 1 ? "" : "s"), not saved", systemImage: "square.and.pencil")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().strokeBorder(RemoteColors.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .foregroundStyle(RemoteColors.label)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $routines.reviewing, onDismiss: { routines.closeReview() }) { _ in RunReview() }
        .sheet(isPresented: $reviewingDraft) { DraftCard { reviewingDraft = false } }
    }
}

/// The routine Ask is making: its name, each step with the device and app named, what it still needs, and Save.
struct DraftCard: View {
    let close: () -> Void
    @ObservedObject private var routines = Routines.shared
    @State private var problem: String?
    @State private var askingReplace = false

    var body: some View {
        let draft = routines.draft ?? RoutineDraft()
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.name.isEmpty ? "New routine" : draft.name).font(.title3.weight(.semibold))
            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                Text("\(index + 1). \(Routines.words(step))").font(.callout)
            }
            ForEach(routines.unresolved(draft), id: \.self) { need in
                Label(need, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.yellow)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.yellow) }
            Text("Saving sends nothing. Run it from its button.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Discard") { routines.draft = nil; close() }
                Spacer()
                Button("Not Now") { close() }.keyboardShortcut(.cancelAction)
                Button("Save Routine") {
                    if routines.named(draft.name) != nil { askingReplace = true }
                    else { problem = routines.save(draft); if problem == nil { close() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(routines.problem(with: draft) != nil)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .presentationBackground(.black)
        .environment(\.colorScheme, .dark)
        .confirmationDialog("There's already a routine called \(draft.name).", isPresented: $askingReplace) {
            Button("Replace It") {
                problem = routines.save(draft, replacing: routines.named(draft.name))
                if problem == nil { close() }
            }
            Button("Keep Both: Rename This One") { routines.draft?.name = draft.name + " 2" }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A saved routine before and while it runs: its steps, Run, Stop, and what each step did.
struct RunReview: View {
    @ObservedObject private var routines = Routines.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let routine = routines.reviewing {
                Text(routine.name).font(.title3.weight(.semibold))
                if let run = routines.run { RunSteps(run: run) } else {
                    ForEach(Array(routine.steps.enumerated()), id: \.element.id) { index, step in
                        Text("\(index + 1). \(Routines.words(step))").font(.callout)
                    }
                    HStack {
                        Button("Close") { routines.closeReview() }
                        Spacer()
                        Button("Run") { routines.start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .presentationBackground(.black)
        .environment(\.colorScheme, .dark)
    }
}

private struct RunSteps: View {
    @ObservedObject var run: RoutineRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(run.routine.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol(run.states[index])).foregroundStyle(color(run.states[index]))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(index + 1). \(Routines.words(step))").font(.callout)
                        if let words = words(run.states[index]) { Text(words).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let ending = run.ending { Text(ending).font(.callout.weight(.semibold)).padding(.top, 4) }
            if run.routine.steps.contains(where: { $0.deviceID.flatMap(DeviceHub.shared.known)?.kind == .example }) {
                Text("Example TVs got, in order:").font(.caption.weight(.semibold)).padding(.top, 6)
                Text(ExampleTV.log.suffix(6).joined(separator: "\n").ifEmpty("nothing yet")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Close") { Routines.shared.closeReview() }
                Spacer()
                if run.isRunning { Button("Stop", role: .destructive) { run.stop() }.keyboardShortcut(.cancelAction) }
            }
            .padding(.top, 6)
        }
    }

    private func symbol(_ state: RoutineRun.StepState) -> String {
        switch state {
        case .waiting: return "circle"
        case .running: return "arrow.right.circle"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(_ state: RoutineRun.StepState) -> Color {
        switch state {
        case .done: return .green
        case .stopped: return .red
        case .running: return .accentColor
        default: return .secondary
        }
    }

    private func words(_ state: RoutineRun.StepState) -> String? {
        switch state {
        case .waiting: return nil
        case .running: return "Running…"
        case .done(let s), .stopped(let s), .skipped(let s): return s
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
