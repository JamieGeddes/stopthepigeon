import Foundation

/// Chroma-key settings, stored per project.
struct GreenScreenSettings: Codable, Hashable, Sendable {
    enum KeyColour: String, Codable, CaseIterable, Identifiable, Sendable {
        case green
        case blue

        var id: String { rawValue }
        var label: String { self == .green ? "Green" : "Blue" }
    }

    var enabled = false
    var keyColour: KeyColour = .green
    /// 0...1. Higher removes more of the background, at the risk of eating into the subject.
    var tolerance = 0.5
    /// 0...1. Width of the soft edge between keyed and kept pixels.
    var softness = 0.3
    /// 0...1. How much green or blue tint to remove from the subject's edges.
    var spillSuppression = 0.5
    /// Filename of the backdrop image inside the project folder.
    var backdrop: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GreenScreenSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        keyColour = try c.decodeIfPresent(KeyColour.self, forKey: .keyColour) ?? defaults.keyColour
        tolerance = Self.unit(try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? defaults.tolerance)
        softness = Self.unit(try c.decodeIfPresent(Double.self, forKey: .softness) ?? defaults.softness)
        spillSuppression = Self.unit(try c.decodeIfPresent(Double.self, forKey: .spillSuppression) ?? defaults.spillSuppression)
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

/// The colour maths behind the key, kept separate from Core Image so it can be tested.
enum ChromaKey {
    struct Parameters: Hashable {
        var keyColour: GreenScreenSettings.KeyColour
        var tolerance: Double
        var softness: Double
        var spillSuppression: Double

        init(_ settings: GreenScreenSettings) {
            keyColour = settings.keyColour
            tolerance = settings.tolerance
            softness = settings.softness
            spillSuppression = settings.spillSuppression
        }
    }

    /// Keys on colour difference: how far the key channel exceeds the larger of the
    /// other two. Returns the kept alpha and the de-spilled colour (not premultiplied).
    static func apply(r: Double, g: Double, b: Double, _ p: Parameters) -> (r: Double, g: Double, b: Double, alpha: Double) {
        let key = p.keyColour == .green ? g : b
        let other = p.keyColour == .green ? max(r, b) : max(r, g)
        let difference = key - other

        let upper = 0.4 - 0.35 * p.tolerance
        let lower = max(upper - (0.02 + 0.25 * p.softness), 0)
        let alpha = 1 - smoothstep(lower, upper, difference)

        var r = r, g = g, b = b
        if difference > 0 {
            let despilled = key - p.spillSuppression * difference
            if p.keyColour == .green { g = despilled } else { b = despilled }
        }
        return (r, g, b, alpha)
    }

    /// RGBA Float32 colour cube (red varies fastest), premultiplied, for CIColorCube.
    static func cubeData(_ p: Parameters, dimension n: Int = 64) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let scale = 1 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let out = apply(r: Double(ri) * scale, g: Double(gi) * scale, b: Double(bi) * scale, p)
                    values[i] = Float(out.r * out.alpha)
                    values[i + 1] = Float(out.g * out.alpha)
                    values[i + 2] = Float(out.b * out.alpha)
                    values[i + 3] = Float(out.alpha)
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
