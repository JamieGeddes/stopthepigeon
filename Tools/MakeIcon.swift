import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders AppIconArtwork into every size an .appiconset needs.
/// Usage: make-icon <path to AppIcon.appiconset>
@main
struct MakeIcon {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: make-icon <AppIcon.appiconset>")
            exit(1)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let size = CGFloat(pixels)
            let view = Canvas { context, _ in AppIconArtwork.draw(in: &context, pixelSize: size) }
                .frame(width: size, height: size)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let url = output.appendingPathComponent("icon_\(pixels).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            print("wrote \(url.lastPathComponent)")
        }
    }
}
