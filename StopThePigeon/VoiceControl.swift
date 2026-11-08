@preconcurrency import AVFoundation
import Observation
import Speech

/// Listens for the user saying "Now" on its own and calls `onCommand`.
///
/// Layers against false triggers:
/// 1. Voice activity detection splits audio into utterances separated by pauses. Only
///    speech-level sound starts recognition, so most knocks and clicks go no further.
/// 2. Each utterance gets its own recognition request, so words either side of a pause
///    can't join up with "now".
/// 3. The whole utterance must be exactly "now" (see `VoiceCommand`).
/// 4. It must be short and, where reported, confidently recognised (`VoiceCommandPolicy`).
/// 5. A cooldown stops one "now", or its echo, capturing twice.
///
/// Recognition runs on the device only; audio never leaves the Mac.
@MainActor
@Observable
final class VoiceControl {
    enum State: Equatable {
        case off
        case starting
        case listening
        case unavailable(String)
    }

    struct Heard: Equatable {
        var text: String
        var accepted: Bool
        var note: String?
    }

    private(set) var state: State = .off
    private(set) var isHearingSpeech = false
    /// Input level from 0 to 1, for a meter.
    private(set) var level: Double = 0
    private(set) var lastHeard: Heard?

    @ObservationIgnored var onCommand: (() -> Void)?

    var isEnabled: Bool { state != .off }

    private static let enabledKey = "voiceControlEnabled"
    private let policy = VoiceCommandPolicy()
    @ObservationIgnored private var lastCapture: Double?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var processor: UtteranceProcessor?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    func setEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { await start() } else { stop() }
    }

    func restoreSavedSetting() async {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { await start() }
    }

    // MARK: Starting and stopping

    private func start() async {
        if case .starting = state { return }
        if case .listening = state { return }
        state = .starting

        guard await Self.requestSpeechAccess() else {
            state = .unavailable("Speech recognition is off for this app. Allow it in System Settings > Privacy & Security > Speech Recognition.")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .unavailable("Microphone access is off for this app. Allow it in System Settings > Privacy & Security > Microphone.")
            return
        }
        guard let recognizer = Self.makeRecognizer() else {
            state = .unavailable("On-device English speech recognition isn't available on this Mac.")
            return
        }
        guard state == .starting else { return } // switched off while asking
        do {
            try startEngine(with: recognizer)
            state = .listening
        } catch {
            state = .unavailable("Couldn't use the microphone: \(error.localizedDescription)")
        }
    }

    private func stop() {
        tearDownEngine()
        state = .off
        isHearingSpeech = false
        level = 0
        lastHeard = nil
    }

    private func startEngine(with recognizer: SFSpeechRecognizer) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceControlError.noMicrophone }

        let processor = UtteranceProcessor(recognizer: recognizer, sampleRate: format.sampleRate)
        processor.onLevel = { [weak self] level, speaking in
            Task { @MainActor in
                self?.level = level
                self?.isHearingSpeech = speaking
            }
        }
        processor.onUtterance = { [weak self] utterance in
            Task { @MainActor in self?.handle(utterance) }
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            processor.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.processor = processor

        // Rebuild when the input device changes (headset plugged in, iPhone mic, ...).
        if configurationObserver == nil {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
            }
        }
    }

    private func tearDownEngine() {
        guard let processor else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processor.cancel()
        self.processor = nil
    }

    private func restartAfterConfigurationChange() {
        guard state == .listening, let recognizer = processor?.recognizer else { return }
        tearDownEngine()
        do {
            try startEngine(with: recognizer)
        } catch {
            state = .unavailable("Couldn't use the microphone: \(error.localizedDescription)")
        }
    }

    // MARK: Decisions

    private func handle(_ utterance: UtteranceProcessor.Utterance) {
        guard state == .listening else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let decision = policy.decide(
            transcript: utterance.transcript,
            confidence: utterance.confidence,
            duration: utterance.duration,
            at: now,
            lastCapture: lastCapture
        )
        switch decision {
        case .capture:
            lastCapture = now
            lastHeard = Heard(text: utterance.transcript, accepted: true)
            onCommand?()
        case .ignore(let reason):
            // Noises that produced no words aren't worth reporting.
            guard !utterance.transcript.isEmpty else { return }
            lastHeard = Heard(text: utterance.transcript, accepted: false, note: reason.explanation)
        }
    }

    // MARK: Setup helpers

    private static func requestSpeechAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    /// An English recogniser that works on the device, preferring the user's own locale.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        var identifiers = ["en-GB", "en-US"]
        if Locale.current.language.languageCode == .english {
            identifiers.insert(Locale.current.identifier, at: 0)
        }
        for identifier in identifiers {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.supportsOnDeviceRecognition {
                return recognizer
            }
        }
        return nil
    }
}

enum VoiceControlError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "No microphone is available." }
}

/// Runs on the audio thread: measures levels, finds utterances and recognises each one
/// with its own on-device request.
final class UtteranceProcessor: @unchecked Sendable {
    struct Utterance {
        var transcript: String
        var confidence: Float?
        var duration: Double
    }

    let recognizer: SFSpeechRecognizer
    var onLevel: ((Double, Bool) -> Void)?
    var onUtterance: ((Utterance) -> Void)?

    /// Audio kept from just before speech is detected, so the start of "now" isn't lost.
    private static let preRollSeconds = 0.35
    /// Stop recognising speech that has clearly gone on too long to be a command.
    private static let maximumListen = 1.6
    private static let levelReportInterval = 1.0 / 15

    private let sampleRate: Double
    private let lock = NSLock()
    private var detector = VoiceActivityDetector()
    private var clock: Double = 0
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollDuration: Double = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pending: PendingUtterance?
    private var utteranceStart: Double = 0
    private var lastLevelReport: Double = 0
    private var cancelled = false

    init(recognizer: SFSpeechRecognizer, sampleRate: Double) {
        self.recognizer = recognizer
        self.sampleRate = sampleRate
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / sampleRate
        let level = Self.decibels(of: buffer)

        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        clock += duration

        switch detector.process(level: level, at: clock) {
        case .speechStarted:
            beginUtterance()
        case .speechEnded(let start, let end):
            finishUtterance(duration: end - start)
        case nil:
            break
        }

        if let request {
            request.append(buffer)
            if clock - utteranceStart > Self.maximumListen {
                // Far too long for "now": stop recognising, and report it when speech ends.
                task?.cancel()
                task = nil
                self.request = nil
            }
        } else if let copy = Self.copy(buffer) {
            preRoll.append(copy)
            preRollDuration += duration
            while preRollDuration > Self.preRollSeconds, let first = preRoll.first {
                preRoll.removeFirst()
                preRollDuration -= Double(first.frameLength) / sampleRate
            }
        }

        if clock - lastLevelReport >= Self.levelReportInterval {
            lastLevelReport = clock
            onLevel?(min(max((level + 60) / 60, 0), 1), detector.isSpeaking)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        task = nil
        request = nil
        lock.unlock()
    }

    private func beginUtterance() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .confirmation
        request.contextualStrings = [VoiceCommand.keyword]
        request.addsPunctuation = false
        for buffer in preRoll { request.append(buffer) }
        preRoll.removeAll()
        preRollDuration = 0

        let pending = PendingUtterance()
        let onUtterance = onUtterance
        task = recognizer.recognitionTask(with: request) { result, error in
            guard let result, result.isFinal, error == nil else {
                if error != nil { pending.complete { _ in } }
                return
            }
            let confidences = result.bestTranscription.segments.map(\.confidence).filter { $0 > 0 }
            let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
            let transcript = result.bestTranscription.formattedString
            pending.complete { duration in
                onUtterance?(Utterance(transcript: transcript, confidence: confidence, duration: duration))
            }
        }
        pending.task = task // keep the task alive until its result is reported
        self.request = request
        self.pending = pending
        utteranceStart = clock
    }

    private func finishUtterance(duration: Double) {
        guard let pending else { return }
        self.pending = nil
        pending.setDuration(duration)
        if let request {
            request.endAudio() // the final result arrives in the task's handler
            self.request = nil
            task = nil
        } else {
            // Recognition was stopped because the speech ran long.
            onUtterance?(Utterance(transcript: "", confidence: nil, duration: duration))
        }
    }

    private static func decibels(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return 20 * log10(Double(max(rms, 1e-7)))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if buffer.format.isInterleaved {
            destination[0].update(from: source[0], count: frames * channels)
        } else {
            for channel in 0..<channels { destination[channel].update(from: source[channel], count: frames) }
        }
        return copy
    }
}

/// Joins the utterance's duration (known when speech ends) with its transcript (known
/// when recognition finishes), and makes sure it's reported once.
private final class PendingUtterance: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: Double?
    private var report: ((Double) -> Void)?
    private var done = false
    var task: SFSpeechRecognitionTask?

    func setDuration(_ value: Double) {
        lock.lock()
        duration = value
        let report = report
        lock.unlock()
        if let report { fire(report, value) }
    }

    func complete(_ report: @escaping (Double) -> Void) {
        lock.lock()
        self.report = report
        let duration = duration
        lock.unlock()
        if let duration { fire(report, duration) }
    }

    private func fire(_ report: (Double) -> Void, _ duration: Double) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        task = nil
        lock.unlock()
        report(duration)
    }
}
