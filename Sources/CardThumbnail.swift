import ImageIO
import SwiftUI

@MainActor
private final class CardThumbnailImage: ObservableObject {
    private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 300
        return cache
    }()

    @Published private var loaded: (url: URL, image: CGImage)?

    func image(for url: URL?) -> CGImage? {
        guard let url, loaded?.url == url else { return nil }
        return loaded?.image
    }

    func load(_ url: URL?) async {
        guard let url, !Task.isCancelled, loaded?.url != url else { return }
        if let image = Self.cache.object(forKey: url as NSURL) {
            loaded = (url, image)
            return
        }

        let image = await Task.detached(priority: .utility) { Self.read(url) }.value
        guard let image else { return }
        Self.cache.setObject(image, forKey: url as NSURL)
        guard !Task.isCancelled else { return }
        loaded = (url, image)
    }

    private nonisolated static func read(_ url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

@MainActor
struct CardThumbnail: View {
    let url: URL?
    @StateObject private var thumbnail = CardThumbnailImage()

    var body: some View {
        Group {
            if let image = thumbnail.image(for: url) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 40, height: 40)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
        .task(id: url) { await thumbnail.load(url) }
    }
}
