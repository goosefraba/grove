import Foundation
import AppKit
import UniformTypeIdentifiers

final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let stateQueue = DispatchQueue(label: "com.grove.thumbnails.state")
    private var pendingCompletions: [String: [(NSImage) -> Void]] = [:]

    private init() {
        cache.countLimit = 500
    }

    func icon(for url: URL, size: NSSize = NSSize(width: 16, height: 16)) -> NSImage {
        let key = cacheKey(for: url, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        guard let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.size = size
        cache.setObject(icon, forKey: key as NSString)
        return icon
    }

    private static let placeholderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .item)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    private let backgroundQueue = DispatchQueue(label: "com.grove.thumbnails", qos: .userInitiated, attributes: .concurrent)

    func iconAsync(for url: URL, size: NSSize = NSSize(width: 16, height: 16), completion: @escaping (NSImage) -> Void) -> NSImage {
        let key = cacheKey(for: url, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        var shouldStartLoad = false
        stateQueue.sync {
            if pendingCompletions[key] == nil {
                pendingCompletions[key] = []
                shouldStartLoad = true
            }
            pendingCompletions[key]?.append(completion)
        }

        guard shouldStartLoad else {
            return ThumbnailCache.placeholderIcon
        }

        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: url.path)
            icon.size = size
            self.cache.setObject(icon, forKey: key as NSString)
            let completions = self.stateQueue.sync { () -> [(NSImage) -> Void] in
                let completions = self.pendingCompletions.removeValue(forKey: key) ?? []
                return completions
            }
            DispatchQueue.main.async {
                completions.forEach { $0(icon) }
            }
        }

        return ThumbnailCache.placeholderIcon
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: cacheKey(for: url, size: NSSize(width: 16, height: 16)) as NSString)
        cache.removeObject(forKey: cacheKey(for: url, size: NSSize(width: 48, height: 48)) as NSString)
        cache.removeObject(forKey: cacheKey(for: url, size: NSSize(width: GroveUI.iconSize, height: GroveUI.iconSize)) as NSString)
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    private func cacheKey(for url: URL, size: NSSize) -> String {
        "\(url.standardizedFileURL.path)#\(Int(size.width))x\(Int(size.height))"
    }
}
