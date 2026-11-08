import Foundation

/// Splits a stream of audio levels (dB) into speech segments.
///
/// - Adapts to background noise, so a fan or traffic doesn't count as speech.
/// - Needs a short run of loud audio to start, so clicks and knocks don't.
/// - Uses a lower threshold to stay in speech than to start (hysteresis), so a word
///   doesn't flicker on and off.
/// - Only ends after a pause (`hangover`), so the words of a phrase stay together.
struct VoiceActivityDetector {
    enum Event: Equatable {
        case speechStarted(at: Double)
        case speechEnded(start: Double, end: Double)
    }

    var startMargin: Double = 15
    var endMargin: Double = 9
    /// Never treat audio quieter than this as speech, however quiet the room.
    var absoluteMinimum: Double = -55
    var minimumOnset: Double = 0.05
    var hangover: Double = 0.45
    var floorRisePerSecond: Double = 1.0
    /// Continuous "speech" longer than this is treated as a change in background noise.
    var maximumSpeech: Double = 8

    private(set) var noiseFloor: Double = -60
    private(set) var isSpeaking = false
    private var aboveSince: Double?
    private var speechStart: Double = 0
    private var lastAbove: Double = 0
    private var lastTime: Double?

    mutating func process(level rawLevel: Double, at time: Double) -> Event? {
        let level = rawLevel.isFinite ? max(rawLevel, -120) : -120
        let elapsed = lastTime.map { max(time - $0, 0) } ?? 0
        if lastTime == nil { noiseFloor = level }
        lastTime = time

        if !isSpeaking {
            // Follow the background level: down at once, up slowly.
            noiseFloor = level < noiseFloor ? level : min(noiseFloor + floorRisePerSecond * elapsed, level)
        }
        let startThreshold = max(noiseFloor + startMargin, absoluteMinimum)
        let endThreshold = max(noiseFloor + endMargin, absoluteMinimum - 6)

        if isSpeaking {
            if time - speechStart > maximumSpeech {
                // Steady loud sound, not speech: recalibrate to it.
                noiseFloor = level
                isSpeaking = false
                aboveSince = nil
                return .speechEnded(start: speechStart, end: time)
            }
            if level >= endThreshold {
                lastAbove = time
            } else if time - lastAbove >= hangover {
                isSpeaking = false
                aboveSince = nil
                return .speechEnded(start: speechStart, end: lastAbove)
            }
            return nil
        }

        guard level >= startThreshold else {
            aboveSince = nil
            return nil
        }
        let since = aboveSince ?? time
        aboveSince = since
        guard time - since >= minimumOnset else { return nil }
        isSpeaking = true
        speechStart = since
        lastAbove = time
        return .speechStarted(at: since)
    }
}

enum VoiceCommand {
    static let keyword = "now"

    /// True only when the whole utterance is the keyword ("Now", "now!", " NOW. "),
    /// not when it's part of a phrase ("not now", "now then") or a similar word.
    static func isCommand(_ transcript: String) -> Bool {
        words(in: transcript) == [keyword]
    }

    static func words(in transcript: String) -> [String] {
        transcript.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .map(String.init)
    }
}

/// Decides whether a recognised utterance should capture a frame.
struct VoiceCommandPolicy {
    enum Decision: Equatable {
        case capture
        case ignore(Reason)
    }

    enum Reason: Equatable {
        case notCommand
        case tooShort
        case tooLong
        case unclear
        case tooSoon

        var explanation: String {
            switch self {
            case .notCommand: "not just “now”"
            case .tooShort: "too short"
            case .tooLong: "too long"
            case .unclear: "unclear"
            case .tooSoon: "too soon after the last capture"
            }
        }
    }

    /// A spoken "now" takes roughly 0.2–0.6 s; allow some slack either side.
    var minimumDuration = 0.12
    var maximumDuration = 1.2
    var minimumConfidence: Float = 0.4
    var cooldown = 1.5

    /// `confidence` is nil when the recogniser doesn't report one; the check is then skipped.
    func decide(transcript: String, confidence: Float?, duration: Double, at time: Double, lastCapture: Double?) -> Decision {
        guard VoiceCommand.isCommand(transcript) else { return .ignore(.notCommand) }
        guard duration >= minimumDuration else { return .ignore(.tooShort) }
        guard duration <= maximumDuration else { return .ignore(.tooLong) }
        if let confidence, confidence > 0, confidence < minimumConfidence { return .ignore(.unclear) }
        if let lastCapture, time - lastCapture < cooldown { return .ignore(.tooSoon) }
        return .capture
    }
}
