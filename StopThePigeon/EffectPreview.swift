@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

/// Receives live camera frames and, while an effect is active, renders them with the
/// effect applied into a layer. Frames are dropped while the previous one is rendering.
final class EffectPreviewRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let maxPreviewPixels: CGFloat = 1280

    private let lock = NSLock()
    private var effect: FrameEffect?
    private weak var layer: CALayer?

    func update(effect: FrameEffect?) {
        lock.lock()
        self.effect = effect?.isActive == true ? effect : nil
        lock.unlock()
    }

    func attach(_ layer: CALayer?) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let effect = effect
        let layer = layer
        lock.unlock()
        guard let effect, let layer, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let longest = max(image.extent.width, image.extent.height)
        if longest > Self.maxPreviewPixels {
            let scale = Self.maxPreviewPixels / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let renderer = FrameRenderer.shared
        let output = renderer.apply(effect, to: image)
        guard let rendered = renderer.context.createCGImage(output, from: image.extent) else { return }
        DispatchQueue.main.async { layer.contents = rendered }
    }
}

/// Shows the effects preview rendered by `EffectPreviewRenderer`.
struct EffectPreviewView: NSViewRepresentable {
    let renderer: EffectPreviewRenderer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        renderer.attach(layer)
        context.coordinator.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.renderer?.attach(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: EffectPreviewRenderer?
    }
}
