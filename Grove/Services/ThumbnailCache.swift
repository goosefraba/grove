import Foundation
import AppKit

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

    func clearCache() {
        cache.removeAllObjects()
    }
}
