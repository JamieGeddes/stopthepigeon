import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Everything needed to render a frame with effects applied.
struct FrameEffect: Hashable, Sendable {
    var greenScreen: GreenScreenSettings
    var backdropURL: URL?

    var isActive: Bool { greenScreen.enabled }
}

/// Applies effects with Core Image. Thread-safe; share one instance.
final class FrameRenderer: @unchecked Sendable {
    static let shared = FrameRenderer()

    let context = CIContext(options: [.cacheIntermediates: false])

    private let lock = NSLock()
    private var cube: (parameters: ChromaKey.Parameters, data: Data)?
    private var backdrop: (url: URL, image: CIImage)?

    /// Loads a frame at up to `maxPixelSize`, applying `effect` if it's active.
    func renderFrame(at url: URL, maxPixelSize: Int, effect: FrameEffect?) -> CGImage? {
        guard let source = ImageLoading.cgImage(at: url, maxPixelSize: maxPixelSize) else { return nil }
        guard let effect, effect.isActive else { return source }
        let input = CIImage(cgImage: source)
        let output = apply(effect, to: input)
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Keys out the background and composites the result over the backdrop, or over a
    /// checkerboard when no backdrop is set. The output is cropped to the input's extent.
    func apply(_ effect: FrameEffect, to image: CIImage) -> CIImage {
        guard effect.isActive else { return image }
        let extent = image.extent

        let key = CIFilter.colorCubeWithColorSpace()
        key.inputImage = image
        key.cubeDimension = 64
        key.cubeData = cubeData(for: ChromaKey.Parameters(effect.greenScreen))
        key.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let keyed = key.outputImage else { return image }

        let background = effect.backdropURL.flatMap { backdropImage(at: $0) }
            .map { Self.aspectFill($0, to: extent) }
            ?? Self.checkerboard(in: extent)
        return keyed.composited(over: background).cropped(to: extent)
    }

    // MARK: Caches

    private func cubeData(for parameters: ChromaKey.Parameters) -> Data {
        lock.lock()
        if let cube, cube.parameters == parameters {
            lock.unlock()
            return cube.data
        }
        lock.unlock()

        let data = ChromaKey.cubeData(parameters)
        lock.lock()
        cube = (parameters, data)
        lock.unlock()
        return data
    }

    private func backdropImage(at url: URL) -> CIImage? {
        lock.lock()
        if let backdrop, backdrop.url == url {
            lock.unlock()
            return backdrop.image
        }
        lock.unlock()

        // Decode once at a size large enough for 4K export.
        guard let cgImage = ImageLoading.cgImage(at: url, maxPixelSize: 4096) else { return nil }
        let image = CIImage(cgImage: cgImage)
        lock.lock()
        backdrop = (url, image)
        lock.unlock()
        return image
    }

    // MARK: Helpers

    private static func aspectFill(_ image: CIImage, to extent: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        let scale = max(extent.width / source.width, extent.height / source.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = extent.midX - scaled.extent.midX
        let dy = extent.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: extent)
    }

    private static func checkerboard(in extent: CGRect) -> CIImage {
        let filter = CIFilter.checkerboardGenerator()
        filter.color0 = CIColor(red: 0.75, green: 0.75, blue: 0.75)
        filter.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55)
        filter.width = Float(max(extent.width, extent.height) / 32)
        filter.center = CGPoint(x: extent.minX, y: extent.minY)
        return filter.outputImage?.cropped(to: extent) ?? CIImage(color: .gray).cropped(to: extent)
    }
}
