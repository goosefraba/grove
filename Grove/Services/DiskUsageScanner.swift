import Foundation
import Darwin

// Independently implemented for Grove. See docs/storage-dashboard.md for Mole research.
enum DiskUsageCategory: String, CaseIterable, Identifiable {
    case applications = "Applications", developer = "Developer", media = "Media"
    case documents = "Documents", archives = "Archives", other = "Other"
    var id: String { rawValue }

    static func classify(_ url: URL) -> Self {
        let path = url.path.lowercased()
        if path.contains(".app/") || url.pathExtension.lowercased() == "app" { return .applications }
        if ["/node_modules/", "/.git/", "/deriveddata/", "/.build/", "/.npm/", "/.cargo/"].contains(where: path.contains) { return .developer }
        switch url.pathExtension.lowercased() {
        case "swift", "m", "h", "c", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "json", "yaml", "yml", "toml", "sh", "html", "css": return .developer
        case "jpg", "jpeg", "png", "gif", "heic", "raw", "tiff", "webp", "svg", "mp4", "mov", "mkv", "avi", "mp3", "m4a", "wav", "flac", "aiff": return .media
        case "pdf", "txt", "md", "rtf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv", "epub": return .documents
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg": return .archives
        default: return .other
        }
    }
}

struct DiskUsageEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var fileCount = 0
    var issueCount = 0
    var isExcluded = false
    var name: String { url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
}

struct DiskUsageIssue: Identifiable {
    let id = UUID()
    let url: URL
    let message: String
}

struct DiskUsageSnapshot {
    let root: URL
    let entries: [DiskUsageEntry]
    let largestFiles: [DiskUsageEntry]
    let categories: [DiskUsageCategory: Int64]
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int
    let folderCount: Int
    let skippedLinks: Int
    let skippedVolumes: Int
    let duplicateHardlinks: Int
    let issueCount: Int
    let issues: [DiskUsageIssue]
    let startedAt: Date
    let finishedAt: Date
    var isPartial: Bool { issueCount > 0 || skippedVolumes > 0 }
}

struct DiskUsageProgress {
    let fileCount: Int
    let allocatedBytes: Int64
    let currentPath: String
}

// All mutable state is protected by lock; shared only for cooperative cancellation.
final class DiskUsageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class DiskUsageScanner {
    private let deviceIdentifier: (URL, dev_t) -> dev_t
    private let resourceValues: (URL, Set<URLResourceKey>) throws -> URLResourceValues

    init(deviceIdentifier: @escaping (URL, dev_t) -> dev_t = { _, device in device },
         resourceValues: @escaping (URL, Set<URLResourceKey>) throws -> URLResourceValues = { try $0.resourceValues(forKeys: $1) }) {
        self.deviceIdentifier = deviceIdentifier
        self.resourceValues = resourceValues
    }

    static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]

    // Foundation can preserve /var while its enumerator emits /private/var.
    // Use the filesystem's canonical spelling consistently for ownership and cache keys.
    static func canonicalURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    // One traversal; retain immediate children and only the 32 largest descendant files.
    // Metadata only: never open file contents or invoke a shell/du command.
    func scan(_ root: URL, cancellation: DiskUsageCancellation,
              progress: (DiskUsageProgress) -> Void = { _ in }) throws -> DiskUsageSnapshot {
        try checkCancellation(cancellation)
        let root = try Self.canonicalURL(root)
        let started = Date()
        var rootStat = stat()
        guard root.withUnsafeFileSystemRepresentation({ lstat($0!, &rootStat) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: root.path])
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Choose a folder to scan."])
        }
        try checkCancellation(cancellation)
        // Unlike enumerator creation, this reports an unreadable root as a failure.
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(Self.keys))
        var entries: [String: DiskUsageEntry] = [:]
        var issues: [DiskUsageIssue] = []
        var issueCount = 0
        var allocated: Int64 = 0, logical: Int64 = 0
        var files = 0, folders = 0, links = 0, mounts = 0, duplicates = 0
        var categories: [DiskUsageCategory: Int64] = [:]
        var largest: [DiskUsageEntry] = []
        var seen = Set<FileIdentity>()
        var lastProgress = Date.distantPast
        let prefix = root.path == "/" ? "/" : root.path + "/"

        func ownerName(_ url: URL) -> String? {
            guard url.path.hasPrefix(prefix) else { return nil }
            return url.path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init)
        }
        func recordIssue(_ url: URL, _ error: Error) {
            issueCount += 1
            if issues.count < 40 { issues.append(DiskUsageIssue(url: url, message: error.localizedDescription)) }
            if let owner = ownerName(url) { entries[owner]?.issueCount += 1 }
        }
        for child in children {
            try checkCancellation(cancellation)
            var info = stat()
            if child.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 {
                entries[child.lastPathComponent] = DiskUsageEntry(url: child,
                    isDirectory: info.st_mode & S_IFMT == S_IFDIR, isSymbolicLink: info.st_mode & S_IFMT == S_IFLNK)
            } else {
                entries[child.lastPathComponent] = DiskUsageEntry(url: child, isDirectory: false, isSymbolicLink: false)
                recordIssue(child, NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(Self.keys),
            options: [], errorHandler: { url, error in recordIssue(url, error); return !cancellation.isCancelled }) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = enumerator.nextObject() as? URL {
            try checkCancellation(cancellation)
            autoreleasepool {
                guard let owner = ownerName(url) else { return }
                var info = stat()
                guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
                    recordIssue(url, NSError(domain: NSPOSIXErrorDomain, code: Int(errno))); return
                }
                // Files can appear between the initial listing and traversal.
                if entries[owner] == nil {
                    entries[owner] = DiskUsageEntry(url: root.appendingPathComponent(owner),
                        isDirectory: info.st_mode & S_IFMT == S_IFDIR, isSymbolicLink: info.st_mode & S_IFMT == S_IFLNK)
                }
                // lstat protects against following symbolic links, including links to ancestors.
                if info.st_mode & S_IFMT == S_IFLNK {
                    // DirectoryEnumerator does not follow symlinks. Calling
                    // skipDescendants on a non-directory can skip the next folder.
                    links += 1
                    if url.deletingLastPathComponent() == root { entries[owner]?.isExcluded = true }
                    return
                }
                if deviceIdentifier(url, info.st_dev) != deviceIdentifier(root, rootStat.st_dev) {
                    if info.st_mode & S_IFMT == S_IFDIR { enumerator.skipDescendants() }
                    mounts += 1
                    if url.deletingLastPathComponent() == root { entries[owner]?.isExcluded = true }
                    else { entries[owner]?.issueCount += 1 }
                    return
                }
                if info.st_mode & S_IFMT == S_IFDIR { folders += 1; return }
                guard info.st_mode & S_IFMT == S_IFREG else { return }
                do {
                    let values = try resourceValues(url, Self.keys)
                    let fileLogical = max(0, Int64(values.fileSize ?? Int(info.st_size)))
                    // Zero is a valid allocation for a sparse file / cloud placeholder.
                    let fileAllocated = max(0, Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(info.st_blocks) * 512))
                    let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
                    let duplicate = info.st_nlink > 1 && !seen.insert(identity).inserted
                    let counted = duplicate ? 0 : fileAllocated
                    if duplicate { duplicates += 1 }
                    files += 1; logical = Self.adding(logical, fileLogical); allocated = Self.adding(allocated, counted)
                    if let value = entries[owner]?.logicalBytes { entries[owner]?.logicalBytes = Self.adding(value, fileLogical) }
                    if let value = entries[owner]?.allocatedBytes { entries[owner]?.allocatedBytes = Self.adding(value, counted) }
                    entries[owner]?.fileCount += 1
                    let category = DiskUsageCategory.classify(url)
                    categories[category] = Self.adding(categories[category, default: 0], counted)
                    if !duplicate && counted > 0 {
                        let file = DiskUsageEntry(url: url, isDirectory: false, isSymbolicLink: false,
                                                  allocatedBytes: counted, logicalBytes: fileLogical, fileCount: 1)
                        if largest.count < 32 || largest.last.map({ Self.largestFirst(file, $0) }) == true {
                            largest.append(file); largest.sort(by: Self.largestFirst)
                            if largest.count > 32 { largest.removeLast() }
                        }
                    }
                    if Date().timeIntervalSince(lastProgress) >= 0.15 {
                        progress(DiskUsageProgress(fileCount: files, allocatedBytes: allocated, currentPath: url.path))
                        lastProgress = Date()
                    }
                } catch { recordIssue(url, error) }
            }
        }
        try checkCancellation(cancellation)
        return DiskUsageSnapshot(root: root, entries: entries.values.sorted(by: Self.largestFirst), largestFiles: largest,
            categories: categories, allocatedBytes: allocated, logicalBytes: logical, fileCount: files, folderCount: folders,
            skippedLinks: links, skippedVolumes: mounts, duplicateHardlinks: duplicates, issueCount: issueCount, issues: issues,
            startedAt: started, finishedAt: Date())
    }

    private func checkCancellation(_ cancellation: DiskUsageCancellation) throws {
        if cancellation.isCancelled { throw CancellationError() }
    }

    static func largestFirst(_ lhs: DiskUsageEntry, _ rhs: DiskUsageEntry) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
    }
}
