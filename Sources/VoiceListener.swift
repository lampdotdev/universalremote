import SwiftUI
import Speech
import AVFoundation

/// Listens once to what the person says, on the device, then hands it to `VoiceCommands`.
@MainActor
final class VoiceListener: ObservableObject {
    static let shared = VoiceListener()

    @Published var isListening = false
    @Published var isThinking = false
    @Published var transcript = ""
    @Published var reply = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?

    func toggle() {
        if isListening { finish() } else { Task { await start() } }
    }

    func start() async {
        guard !isListening else { return }
        guard await Self.authorize() else {
            reply = "Voice Remote needs the microphone and speech recognition. Turn them on in System Settings › Privacy & Security."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            reply = "Speech recognition isn't available right now."
            return
        }
        transcript = ""
        reply = ""

        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? audio.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = (DeviceHub.shared.tileApps.map(\.name) + TVApp.popular.map(\.name))

        let engine = AVAudioEngine()
        Self.tap(engine.inputNode, into: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            reply = "The microphone didn't start: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler)
        isListening = true
        armSilence(after: 6)
    }

    /// Stops listening and acts on what was heard.
    func finish() {
        guard isListening else { return }
        stopAudio()
        isListening = false
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty {
            reply = "I didn't catch that. Tap the mic and try again."
        } else {
            Task { await VoiceCommands.run(said) }
        }
    }

    func heard(_ text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty {
            transcript = text
            armSilence(after: 1.3)
        }
        if isFinal || failed { finish() }
    }

    private func armSilence(after seconds: Double) {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func stopAudio() {
        silence?.cancel()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Off the main thread

    nonisolated private static func tap(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func handler(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        let text = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let failed = error != nil && result == nil
        Task { @MainActor in
            VoiceListener.shared.heard(text, isFinal: isFinal, failed: failed)
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
