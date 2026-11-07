import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct MovieExporterTests {
    @Test(arguments: [
        (4.0 / 3.0, ExportPreset.hd1080, 1440, 1080),
        (16.0 / 9.0, ExportPreset.hd1080, 1920, 1080),
        (4.0 / 3.0, ExportPreset.hd720, 960, 720),
        (4.0 / 3.0, ExportPreset.uhd2160, 2880, 2160),
    ])
    func outputSizeMatchesAspect(aspect: Double, preset: ExportPreset, width: Int, height: Int) {
        let size = preset.outputSize(forSourceAspect: aspect)
        #expect(size.width == width)
        #expect(size.height == height)
    }

    @Test func outputSizeIsAlwaysEven() {
        let size = ExportPreset.hd720.outputSize(forSourceAspect: 1.2345)
        #expect(size.width % 2 == 0)
    }

    @Test func outputSizeFallsBackForInvalidAspect() {
        #expect(ExportPreset.hd1080.outputSize(forSourceAspect: 0).width == 1920)
        #expect(ExportPreset.hd1080.outputSize(forSourceAspect: .nan).width == 1920)
    }

    @Test func aspectFitLetterboxes() {
        let rect = ImageLoading.aspectFitRect(
            contentSize: CGSize(width: 400, height: 300),
            in: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(rect == CGRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    @Test func exportsMovieWithExpectedDurationAndSize() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StopThePigeonExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let frames = try (0..<6).map { index in
            try writeSolidJPEG(to: folder.appendingPathComponent("frame-\(index).jpg"), shade: Double(index) / 5)
        }
        let output = folder.appendingPathComponent("movie.mp4")

        try await MovieExporter.export(frameURLs: frames, fps: 12, preset: .hd1080, to: output)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.01)

        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 1440, height: 1080))
    }

    @Test func exportWithNoFramesThrows() async {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        await #expect(throws: MovieExportError.self) {
            try await MovieExporter.export(frameURLs: [], fps: 12, preset: .hd1080, to: output)
        }
    }

    private func writeSolidJPEG(to url: URL, shade: Double) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
