import AVFoundation
import Foundation
import Testing

@Suite struct VoiceCommandTests {
    @Test(arguments: ["now", "Now", "NOW", "now.", "Now!", "  now  ", "Now?"])
    func acceptsTheKeywordOnItsOwn(_ transcript: String) {
        #expect(VoiceCommand.isCommand(transcript))
    }

    @Test(arguments: ["", "not now", "now then", "right now", "now now", "know", "snow", "no", "wow", "nowhere", "now's the time", "and now"])
    func rejectsAnythingElse(_ transcript: String) {
        #expect(!VoiceCommand.isCommand(transcript))
    }
}

@Suite struct VoiceCommandPolicyTests {
    let policy = VoiceCommandPolicy()

    @Test func capturesAShortConfidentNow() {
        #expect(policy.decide(transcript: "Now", confidence: 0.9, duration: 0.35, at: 10, lastCapture: nil) == .capture)
    }

    @Test func checksEachRule() {
        #expect(policy.decide(transcript: "not now", confidence: 0.9, duration: 0.5, at: 10, lastCapture: nil) == .ignore(.notCommand))
        #expect(policy.decide(transcript: "now", confidence: 0.9, duration: 0.05, at: 10, lastCapture: nil) == .ignore(.tooShort))
        #expect(policy.decide(transcript: "now", confidence: 0.9, duration: 2.0, at: 10, lastCapture: nil) == .ignore(.tooLong))
        #expect(policy.decide(transcript: "now", confidence: 0.2, duration: 0.4, at: 10, lastCapture: nil) == .ignore(.unclear))
        #expect(policy.decide(transcript: "now", confidence: 0.9, duration: 0.4, at: 10, lastCapture: 9.2) == .ignore(.tooSoon))
    }

    @Test func skipsConfidenceWhenNotReported() {
        #expect(policy.decide(transcript: "now", confidence: nil, duration: 0.4, at: 10, lastCapture: nil) == .capture)
        #expect(policy.decide(transcript: "now", confidence: 0, duration: 0.4, at: 10, lastCapture: nil) == .capture)
    }

    @Test func allowsCaptureAfterCooldown() {
        #expect(policy.decide(transcript: "now", confidence: 0.9, duration: 0.4, at: 10, lastCapture: 8.4) == .capture)
    }
}

@Suite struct VoiceActivityDetectorTests {
    /// Feeds levels in 20 ms steps: each segment is (dB, seconds).
    private func run(_ segments: [(Double, Double)]) -> [VoiceActivityDetector.Event] {
        var detector = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        var time = 0.0
        for (level, seconds) in segments {
            let end = time + seconds
            while time < end - 1e-9 {
                time += 0.02
                if let event = detector.process(level: level, at: time) { events.append(event) }
            }
        }
        return events
    }

    private func segments(_ events: [VoiceActivityDetector.Event]) -> [(start: Double, end: Double)] {
        events.compactMap {
            if case .speechEnded(let start, let end) = $0 { return (start, end) }
            return nil
        }
    }

    @Test func findsAWordBetweenSilences() {
        let found = segments(run([(-70, 1), (-20, 0.3), (-70, 1)]))
        #expect(found.count == 1)
        #expect(abs(found[0].start - 1.0) < 0.05)
        #expect(abs((found[0].end - found[0].start) - 0.3) < 0.06)
    }

    @Test func ignoresAClick() {
        #expect(run([(-70, 1), (-10, 0.02), (-70, 1)]).isEmpty)
    }

    @Test func shortGapsKeepAPhraseTogether() {
        #expect(segments(run([(-70, 1), (-20, 0.3), (-70, 0.2), (-20, 0.3), (-70, 1)])).count == 1)
    }

    @Test func longGapsSplitUtterances() {
        #expect(segments(run([(-70, 1), (-20, 0.3), (-70, 0.8), (-20, 0.3), (-70, 1)])).count == 2)
    }

    @Test func steadyNoiseDoesNotStaySpeech() {
        // A fan switching on: one long "utterance" at most, then it becomes background.
        let events = run([(-70, 1), (-30, 15)])
        #expect(segments(events).count == 1)
        #expect(events.count == 2)
    }

    @Test func wordEndsPromptlyInFluctuatingRoomNoise() {
        // Real rooms aren't silent: background noise wanders a few dB either side of its
        // average. The word must still end within about the pause length.
        var detector = VoiceActivityDetector()
        var generator = SeededRandom(seed: 42)
        var events: [VoiceActivityDetector.Event] = []
        var time = 0.0
        func feed(seconds: Double, level: () -> Double) {
            let end = time + seconds
            while time < end - 1e-9 {
                time += 0.021
                if let event = detector.process(level: level(), at: time) { events.append(event) }
            }
        }
        let ambient = { -58 + generator.gaussian() * 4 }
        feed(seconds: 3, level: ambient)
        feed(seconds: 0.4) { -25 + generator.gaussian() * 3 }
        feed(seconds: 2, level: ambient)

        let found = segments(events)
        #expect(found.count == 1)
        let duration = (found.first?.end ?? 0) - (found.first?.start ?? 0)
        #expect(abs(duration - 0.4) < 0.15, "duration \(duration)")
    }

    @Test func quietRoomStillNeedsRealVolume() {
        // Even in a silent room, very quiet sounds aren't speech.
        #expect(run([(-110, 1), (-75, 0.4), (-110, 1)]).isEmpty)
    }

    // MARK: Real speech, synthesised with `say`

    private func speechSegments(saying text: String) throws -> [(start: Double, end: Double)] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "[[slnc 800]] \(text) [[slnc 800]]"]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var detector = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        var time = 0.0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 1024)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[0][i] * data[0][i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            time += Double(buffer.frameLength) / format.sampleRate
            if let event = detector.process(level: 20 * log10(Double(max(rms, 1e-7))), at: time) { events.append(event) }
        }
        // Flush with silence so a trailing utterance ends.
        for _ in 0..<50 {
            time += 0.02
            if let event = detector.process(level: -120, at: time) { events.append(event) }
        }
        return segments(events)
    }

    @Test func spokenNowIsOneShortUtterance() throws {
        let found = try speechSegments(saying: "Now")
        #expect(found.count == 1)
        let duration = try #require(found.first).end - found[0].start
        let policy = VoiceCommandPolicy()
        #expect(duration >= policy.minimumDuration && duration <= policy.maximumDuration, "duration \(duration)")
    }

    @Test func spokenSentenceIsTooLongToBeACommand() throws {
        let found = try speechSegments(saying: "Let's move the arm a little bit further over to the left now")
        #expect(found.count == 1)
        let duration = try #require(found.first).end - found[0].start
        #expect(duration > VoiceCommandPolicy().maximumDuration, "duration \(duration)")
    }

    @Test func nowsSeparatedByAPauseAreSeparateUtterances() throws {
        #expect(try speechSegments(saying: "Now. [[slnc 1000]] Now.").count == 2)
    }
}

/// Deterministic noise for tests.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    /// Standard normal sample (Box-Muller).
    mutating func gaussian() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
