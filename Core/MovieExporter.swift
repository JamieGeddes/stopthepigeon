import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

enum ExportPreset: String, CaseIterable, Identifiable {
    case hd720
    case hd1080
    case uhd2160

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720: "720p (H.264)"
        case .hd1080: "1080p (H.264)"
        case .uhd2160: "4K (HEVC)"
        }
    }

    var height: Int {
        switch self {
        case .hd720: 720
        case .hd1080: 1080
        case .uhd2160: 2160
        }
    }

    var codec: AVVideoCodecType {
        self == .uhd2160 ? .hevc : .h264
    }

    var bitRate: Int {
        switch self {
        case .hd720: 6_000_000
        case .hd1080: 12_000_000
        case .uhd2160: 40_000_000
        }
    }

    /// Output size matching the source aspect ratio, with even dimensions as encoders require.
    func outputSize(forSourceAspect aspect: Double) -> (width: Int, height: Int) {
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
        let width = Int((Double(height) * safeAspect / 2).rounded()) * 2
        return (max(width, 2), height)
    }
}

enum MovieExportError: LocalizedError {
    case noFrames
    case invalidFrameRate(Int)
    case unreadableFrame(URL)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames: "There are no frames to export."
        case .invalidFrameRate(let fps): "\(fps) fps isn't a valid frame rate."
        case .unreadableFrame(let url): "Could not read \(url.lastPathComponent)."
        case .writerFailed(let reason): "Export failed: \(reason)"
        }
    }
}

enum MovieExporter {
    /// Encodes the frames, in order, into an MP4 at `fps` frames per second,
    /// applying `effect` to each frame if it's active.
    static func export(
        frameURLs: [URL],
        fps: Int,
        preset: ExportPreset,
        effect: FrameEffect? = nil,
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let first = frameURLs.first else { throw MovieExportError.noFrames }
        guard fps > 0 else { throw MovieExportError.invalidFrameRate(fps) }
        guard let sourceSize = ImageLoading.orientedPixelSize(at: first) else {
            throw MovieExportError.unreadableFrame(first)
        }
        let (width, height) = preset.outputSize(forSourceAspect: sourceSize.width / sourceSize.height)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: preset.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: preset.bitRate],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { throw MovieExportError.writerFailed("Unsupported output settings.") }
        writer.add(input)

        guard writer.startWriting() else {
            throw MovieExportError.writerFailed(writer.error?.localizedDescription ?? "Could not start writing.")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale = CMTimeScale(fps)
        let maxPixelSize = max(width, height)

        for (index, url) in frameURLs.enumerated() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw MovieExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let image = FrameRenderer.shared.renderFrame(at: url, maxPixelSize: maxPixelSize, effect: effect) else {
                writer.cancelWriting()
                throw MovieExportError.unreadableFrame(url)
            }
            guard let buffer = makePixelBuffer(from: image, width: width, height: height, pool: adaptor.pixelBufferPool) else {
                writer.cancelWriting()
                throw MovieExportError.writerFailed("Could not allocate a video frame.")
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: timescale)) else {
                throw MovieExportError.writerFailed(writer.error?.localizedDescription ?? "Could not append frame.")
            }
            progress?(Double(index + 1) / Double(frameURLs.count))
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameURLs.count), timescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MovieExportError.writerFailed(writer.error?.localizedDescription ?? "Could not finish writing.")
        }
    }

    /// Draws the image aspect-fitted onto a black frame.
    private static func makePixelBuffer(from image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        let imageSize = CGSize(width: image.width, height: image.height)
        context.draw(image, in: ImageLoading.aspectFitRect(contentSize: imageSize, in: bounds))
        return buffer
    }
}
