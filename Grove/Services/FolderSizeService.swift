import Foundation

final class FolderSizeService {

    static let shared = FolderSizeService()

    private let queue = DispatchQueue(label: "com.grove.foldersize", attributes: .concurrent)
    private let cache = NSCache<NSURL, NSNumber>()

    private init() {
        cache.countLimit = 1000
    }

    func calculateSize(for url: URL, completion: @escaping (Int64) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached.int64Value)
            return
        }

        queue.async { [weak self] in
            let size = self?.computeSize(at: url) ?? 0
            self?.cache.setObject(NSNumber(value: size), forKey: url as NSURL)
            DispatchQueue.main.async {
                completion(size)
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
        cache.removeObject(forKey: url as NSURL)
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
