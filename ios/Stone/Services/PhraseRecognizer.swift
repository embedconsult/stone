import AVFoundation
import Speech

/// Push-to-talk dictation for the gpcr edit phrase field, using iOS's
/// on-device Speech framework (`SFSpeechRecognizer`) per decision S2.1 in the
/// "Stone Remote Operations and Speech Design" wiki page: the OS-provided
/// framework, no external service, no on-device grammar parsing (gp-crystal
/// parses server-side).
///
/// This is Stage 1 of the interaction roadmap (S2.2): a mic button, live
/// partial transcription, and an explicit stop to submit — the plumbing
/// baseline before grammar-based auto-endpointing.
@MainActor
final class PhraseRecognizer: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var partialText = ""
    @Published var errorText: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Ask for microphone + speech-recognition permission. Call before the
    /// first `start()`; iOS shows the system prompts on first ask and
    /// remembers the answer afterward.
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start listening. `partialText` updates live; call `stop()` to end the
    /// utterance (Stage 1 is push-to-talk, not auto-endpointed).
    func start() {
        guard !isRecording, let recognizer, recognizer.isAvailable else {
            errorText = "Speech recognition is not available right now."
            return
        }
        errorText = nil
        partialText = ""

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorText = "Couldn't start the audio session: \(error.localizedDescription)"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // The decisive alignment: bias toward exactly the grammar's vocabulary.
        req.contextualStrings = GpcrGrammar.contextualStrings
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            inputNode.removeTap(onBus: 0)
            request = nil
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    /// End the utterance. Idempotent — safe to call after the task already
    /// finished on its own (e.g. on a recognition error).
    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
