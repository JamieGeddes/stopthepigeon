import CoreGraphics
import Foundation
import SwiftUI

/// Decodes (and applies effects to) frames off the main thread, keeping recent
/// results in memory.
final class FrameImageCache: @unchecked Sendable {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        return cache
    }()

    func cached(_ url: URL, maxPixelSize: Int, effect: FrameEffect?) -> CGImage? {
        cache.object(forKey: key(url, maxPixelSize, effect))?.image
    }

    func image(for url: URL, maxPixelSize: Int, effect: FrameEffect?) async -> CGImage? {
        if let hit = cached(url, maxPixelSize: maxPixelSize, effect: effect) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            FrameRenderer.shared.renderFrame(at: url, maxPixelSize: maxPixelSize, effect: effect)
        }.value
        if let image { cache.setObject(Entry(image), forKey: key(url, maxPixelSize, effect)) }
        return image
    }

    private func key(_ url: URL, _ size: Int, _ effect: FrameEffect?) -> NSString {
        let effectKey = effect?.isActive == true ? String(effect.hashValue) : "none"
        return "\(size)|\(effectKey)|\(url.path)" as NSString
    }
}

/// Shows a frame image, keeping the previous image on screen while the next one
/// renders so playback and slider changes don't flash.
struct FrameImageView: View {
    let url: URL?
    let maxPixelSize: Int
    let cache: FrameImageCache
    var effect: FrameEffect?
    var contentMode: ContentMode = .fit

    @State private var image: CGImage?

    private struct LoadKey: Equatable {
        let url: URL?
        let effect: FrameEffect?
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: LoadKey(url: url, effect: effect?.isActive == true ? effect : nil)) {
            guard let url else { image = nil; return }
            if let hit = cache.cached(url, maxPixelSize: maxPixelSize, effect: effect) {
                image = hit
            } else if let rendered = await cache.image(for: url, maxPixelSize: maxPixelSize, effect: effect),
                      !Task.isCancelled {
                image = rendered
            }
        }
    }
}
