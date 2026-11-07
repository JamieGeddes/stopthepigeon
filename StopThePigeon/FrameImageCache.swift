import CoreGraphics
import Foundation
import SwiftUI

/// Decodes frames off the main thread and keeps recently used sizes in memory.
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

    func cached(_ url: URL, maxPixelSize: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixelSize))?.image
    }

    func image(for url: URL, maxPixelSize: Int) async -> CGImage? {
        if let hit = cached(url, maxPixelSize: maxPixelSize) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoading.cgImage(at: url, maxPixelSize: maxPixelSize)
        }.value
        if let image { cache.setObject(Entry(image), forKey: key(url, maxPixelSize)) }
        return image
    }

    private func key(_ url: URL, _ size: Int) -> NSString {
        "\(size)|\(url.path)" as NSString
    }
}

/// Shows a frame image, keeping the previous image on screen while the next one
/// decodes so playback doesn't flash.
struct FrameImageView: View {
    let url: URL?
    let maxPixelSize: Int
    let cache: FrameImageCache
    var contentMode: ContentMode = .fit

    @State private var image: CGImage?

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
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = cache.cached(url, maxPixelSize: maxPixelSize) {
                image = hit
            } else {
                image = await cache.image(for: url, maxPixelSize: maxPixelSize)
            }
        }
    }
}
