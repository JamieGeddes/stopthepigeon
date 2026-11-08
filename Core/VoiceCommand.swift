import Foundation

/// Splits a stream of audio levels (dB) into speech segments.
///
/// - Adapts to background noise, so a fan or traffic doesn't count as speech. The level
///   is smoothed first: real rooms fluctuate, and following the quietest instants would
///   put the floor below the typical background, so the background would never let a
///   word end.
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
    var endMargin: Double = 10
    /// Never treat audio quieter than this as speech, however quiet the room.
    var absoluteMinimum: Double = -55
    var minimumOnset: Double = 0.05
    var hangover: Double = 0.45
    /// Time constant for the smoothed level used for the noise floor and end of speech.
    var smoothing: Double = 0.12
    /// How quickly the floor follows the background down, and how fast it may rise.
    var floorFallTime: Double = 0.4
    var floorRisePerSecond: Double = 1.5
    /// Continuous "speech" longer than this is treated as a change in background noise.
    var maximumSpeech: Double = 8

    private(set) var noiseFloor: Double = -60
    private(set) var smoothedLevel: Double = -60
    private(set) var isSpeaking = false
    private(set) var peakLevel: Double = -120
    private var aboveSince: Double?
    private var speechStart: Double = 0
    private var lastAbove: Double = 0
    private var lastTime: Double?

    mutating func process(level rawLevel: Double, at time: Double) -> Event? {
        let level = rawLevel.isFinite ? max(rawLevel, -120) : -120
        guard let previous = lastTime else {
            lastTime = time
            noiseFloor = level
            smoothedLevel = level
            return nil
        }
        let elapsed = max(time - previous, 0)
        lastTime = time
        smoothedLevel += (level - smoothedLevel) * min(elapsed / smoothing, 1)

        if !isSpeaking {
            if smoothedLevel < noiseFloor {
                noiseFloor += (smoothedLevel - noiseFloor) * min(elapsed / floorFallTime, 1)
            } else {
                noiseFloor = min(noiseFloor + floorRisePerSecond * elapsed, smoothedLevel)
            }
        }
        let startThreshold = max(noiseFloor + startMargin, absoluteMinimum)
        let endThreshold = max(noiseFloor + endMargin, absoluteMinimum - 6)

        if isSpeaking {
            peakLevel = max(peakLevel, level)
            if time - speechStart > maximumSpeech {
                // Steady loud sound, not speech: recalibrate to it.
                noiseFloor = smoothedLevel
                isSpeaking = false
                aboveSince = nil
                return .speechEnded(start: speechStart, end: time)
            }
            // Raw level keeps speech going (words are bursty); the smoothed level must
            // also have dropped before the pause counts, so background spikes don't.
            if level >= endThreshold && smoothedLevel >= endThreshold {
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
        peakLevel = level
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
