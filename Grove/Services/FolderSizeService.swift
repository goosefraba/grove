import Foundation

final class FolderSizeService {

    static let shared = FolderSizeService()

    private let queue = DispatchQueue(label: "com.grove.foldersize", attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "com.grove.foldersize.state")
    private let cache = NSCache<NSURL, NSNumber>()
    private var pendingCompletions: [NSURL: [(Int64) -> Void]] = [:]

    private init() {
        cache.countLimit = 1000
    }

    func calculateSize(for url: URL, completion: @escaping (Int64) -> Void) {
        let key = url.standardizedFileURL as NSURL
        if let cached = cache.object(forKey: key) {
            completion(cached.int64Value)
            return
        }

        var shouldStartScan = false
        stateQueue.sync {
            if pendingCompletions[key] == nil {
                pendingCompletions[key] = []
                shouldStartScan = true
            }
            pendingCompletions[key]?.append(completion)
        }

        guard shouldStartScan else { return }

        queue.async { [weak self] in
            let size = self?.computeSize(at: url) ?? 0
            self?.cache.setObject(NSNumber(value: size), forKey: key)
            let completions = self?.stateQueue.sync { () -> [(Int64) -> Void] in
                self?.pendingCompletions.removeValue(forKey: key) ?? []
            } ?? []
            DispatchQueue.main.async {
                completions.forEach { $0(size) }
            }
        }
    }

    private func computeSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  !(values.isDirectory ?? false) else { continue }
            totalSize += Int64(values.fileSize ?? 0)
        }
        return totalSize
    }

    func invalidateCache(for url: URL) {
        // Walk up the full path invalidating every ancestor: a change deep in
        // A/b/c makes the cached size of A, A/b, ... all stale, not just the
        // exact URL and its direct parent. removeObject on an absent key is a
        // no-op, so this stays cheap.
        var current = url.standardizedFileURL
        while true {
            cache.removeObject(forKey: current as NSURL)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break } // reached filesystem root
            current = parent
        }
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
