import Foundation
import AppKit
import UniformTypeIdentifiers

final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        guard let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: url as NSURL)
        return icon
    }

    private static let placeholderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .item)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    private let backgroundQueue = DispatchQueue(label: "com.grove.thumbnails", qos: .userInitiated, attributes: .concurrent)

    func iconAsync(for url: URL, completion: @escaping (NSImage) -> Void) -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            guard let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else { return }
            icon.size = NSSize(width: 16, height: 16)
            self.cache.setObject(icon, forKey: url as NSURL)
            DispatchQueue.main.async {
                completion(icon)
            }
        }

        return ThumbnailCache.placeholderIcon
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
