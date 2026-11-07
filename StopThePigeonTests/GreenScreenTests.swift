import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct ChromaKeyTests {
    let green = ChromaKey.Parameters(GreenScreenSettings())
    var blue: ChromaKey.Parameters {
        var settings = GreenScreenSettings()
        settings.keyColour = .blue
        return ChromaKey.Parameters(settings)
    }

    @Test func greenKeyRemovesGreenScreen() {
        #expect(ChromaKey.apply(r: 0, g: 1, b: 0, green).alpha == 0)
        #expect(ChromaKey.apply(r: 0.2, g: 0.7, b: 0.25, green).alpha == 0)
    }

    @Test func greenKeyKeepsSubjectColours() {
        for (r, g, b) in [(0.9, 0.7, 0.6), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.5, 0.5, 0.5), (1.0, 1.0, 1.0)] {
            #expect(ChromaKey.apply(r: r, g: g, b: b, green).alpha == 1, "(\(r), \(g), \(b))")
        }
    }

    @Test func blueKeySwapsChannels() {
        #expect(ChromaKey.apply(r: 0, g: 0, b: 1, blue).alpha == 0)
        #expect(ChromaKey.apply(r: 0, g: 1, b: 0, blue).alpha == 1)
    }

    @Test func higherToleranceRemovesMore() {
        var strict = GreenScreenSettings(); strict.tolerance = 0
        var loose = GreenScreenSettings(); loose.tolerance = 1
        let pale = (r: 0.5, g: 0.65, b: 0.5)
        let strictAlpha = ChromaKey.apply(r: pale.r, g: pale.g, b: pale.b, .init(strict)).alpha
        let looseAlpha = ChromaKey.apply(r: pale.r, g: pale.g, b: pale.b, .init(loose)).alpha
        #expect(looseAlpha < strictAlpha)
    }

    @Test func spillSuppressionReducesGreenTint() {
        var full = GreenScreenSettings(); full.spillSuppression = 1
        var none = GreenScreenSettings(); none.spillSuppression = 0
        #expect(ChromaKey.apply(r: 0.6, g: 0.7, b: 0.5, .init(full)).g == 0.6)
        #expect(ChromaKey.apply(r: 0.6, g: 0.7, b: 0.5, .init(none)).g == 0.7)
    }

    @Test func cubeHasExpectedSizeAndPremultipliedCorners() {
        let n = 16
        let data = ChromaKey.cubeData(green, dimension: n)
        #expect(data.count == n * n * n * 4 * MemoryLayout<Float>.size)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Index of pure green: r = 0, g = n-1, b = 0.
        let greenIndex = ((0 * n + (n - 1)) * n + 0) * 4
        #expect(floats[greenIndex + 3] == 0)
        #expect(floats[greenIndex + 1] == 0)
        // Pure white is kept.
        let whiteIndex = (((n - 1) * n + (n - 1)) * n + (n - 1)) * 4
        #expect(floats[whiteIndex + 3] == 1)
    }

    @Test func settingsDecodeWithDefaultsAndClamping() throws {
        let json = #"{"enabled": true, "tolerance": 7, "softness": -1}"#
        let settings = try JSONDecoder().decode(GreenScreenSettings.self, from: Data(json.utf8))
        #expect(settings.enabled)
        #expect(settings.keyColour == .green)
        #expect(settings.tolerance == 1)
        #expect(settings.softness == 0)
        #expect(settings.spillSuppression == 0.5)
    }
}

@Suite struct FrameRendererTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StopThePigeonFX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func replacesGreenWithBackdropAndKeepsSubject() throws {
        // Left half green screen, right half red "character".
        let frame = try TestImages.write(to: folder.appendingPathComponent("frame.png"), width: 200, height: 100) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        let backdrop = try TestImages.write(to: folder.appendingPathComponent("backdrop.png"), width: 50, height: 50) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }

        var settings = GreenScreenSettings()
        settings.enabled = true
        let effect = FrameEffect(greenScreen: settings, backdropURL: backdrop)
        let image = try #require(FrameRenderer.shared.renderFrame(at: frame, maxPixelSize: 200, effect: effect))
        #expect(image.width == 200 && image.height == 100)

        // Compare against the colours as decoded, since PNG colour handling shifts them slightly.
        let backdropColour = try TestImages.pixel(of: #require(ImageLoading.cgImage(at: backdrop, maxPixelSize: 50)), x: 25, y: 25)
        let subjectColour = try TestImages.pixel(of: #require(ImageLoading.cgImage(at: frame, maxPixelSize: 200)), x: 150, y: 50)
        let left = try TestImages.pixel(of: image, x: 50, y: 50)
        let right = try TestImages.pixel(of: image, x: 150, y: 50)
        #expect(TestImages.close(left, backdropColour), "left \(left) vs backdrop \(backdropColour)")
        #expect(TestImages.close(right, subjectColour), "right \(right) vs subject \(subjectColour)")
    }

    @Test func inactiveEffectLeavesFrameUnchanged() throws {
        let frame = try TestImages.write(to: folder.appendingPathComponent("frame.png"), width: 20, height: 20) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let effect = FrameEffect(greenScreen: GreenScreenSettings(), backdropURL: nil)
        let image = try #require(FrameRenderer.shared.renderFrame(at: frame, maxPixelSize: 20, effect: effect))
        let pixel = try TestImages.pixel(of: image, x: 10, y: 10)
        #expect(pixel.g > 240 && pixel.r < 20)
    }
}

@Suite struct ProjectBackdropTests {
    let folder: URL
    let source: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StopThePigeonBD-\(UUID().uuidString)")
        folder = root.appendingPathComponent("Project")
        source = root.appendingPathComponent("sky.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: source)
    }

    @Test func setBackdropCopiesIntoProjectAndPersists() throws {
        var project = try StopMotionProject.create(at: folder)
        project.greenScreen.enabled = true
        project.greenScreen.keyColour = .blue
        try project.setBackdrop(copying: source)

        let name = try #require(project.greenScreen.backdrop)
        #expect(name.hasPrefix("backdrop-") && name.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        #expect(FileManager.default.fileExists(atPath: source.path), "original is left in place")

        let reopened = try StopMotionProject.open(at: folder)
        #expect(reopened.greenScreen == project.greenScreen)
    }

    @Test func replacingBackdropRemovesOldCopy() throws {
        var project = try StopMotionProject.create(at: folder)
        try project.setBackdrop(copying: source)
        let first = try #require(project.greenScreen.backdrop)
        try project.setBackdrop(copying: source)
        #expect(project.greenScreen.backdrop != first)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(first).path))

        try project.removeBackdrop()
        #expect(project.greenScreen.backdrop == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("backdrop-") }
        #expect(leftovers.isEmpty)
    }

    @Test func rejectsUnsupportedBackdropType() throws {
        var project = try StopMotionProject.create(at: folder)
        let gif = source.deletingLastPathComponent().appendingPathComponent("anim.gif")
        try Data([0]).write(to: gif)
        #expect(throws: ProjectError.self) { try project.setBackdrop(copying: gif) }
    }

    @Test func openDropsBackdropOutsideFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"version": 1, "fps": 12, "frames": [], "greenScreen": {"enabled": true, "backdrop": "../sky.png"}}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
        let project = try StopMotionProject.open(at: folder)
        #expect(project.greenScreen.enabled)
        #expect(project.greenScreen.backdrop == nil)
    }

    @Test func oldManifestWithoutEffectsOpens() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "fps": 12, "frames": []}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        #expect(try StopMotionProject.open(at: folder).greenScreen == GreenScreenSettings())
    }

    @Test func adoptingFolderIgnoresBackdropFiles() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent("shot1.jpg"))
        try Data([0]).write(to: folder.appendingPathComponent("backdrop-1234abcd.jpg"))
        #expect(try StopMotionProject.open(at: folder).frames == ["shot1.jpg"])
    }
}

enum TestImages {
    static func write(to url: URL, width: Int, height: Int, draw: (CGContext) -> Void) throws -> URL {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(ctx)
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    static func close(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), tolerance: Int = 6) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    /// RGBA8 sRGB value at (x, y), with y measured from the top.
    static func pixel(of image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
