import Foundation
import AppKit
import UniformTypeIdentifiers
import ImageIO
import Darwin

struct FileItem: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64
    let dateModified: Date
    let dateCreated: Date
    let kind: String
    let contentType: UTType?
    let posixPermissions: UInt16
    let tags: [String]

    var isApplication: Bool {
        contentType?.conforms(to: .application) ?? false ||
        url.pathExtension.lowercased() == "app"
    }

    var isImage: Bool {
        contentType?.conforms(to: .image) ?? false
    }

    var formattedPermissions: String {
        let perms = posixPermissions
        let chars: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(chars.map { perms & $0.0 != 0 ? $0.1 : "-" })
    }

    var octalPermissions: String {
        String(format: "%o", posixPermissions)
    }

    var imageDimensions: NSSize? {
        guard isImage else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }

    static func load(from url: URL, includeTags: Bool = true) -> FileItem? {
        if let protectedFolderItem = protectedHomeFolderItem(for: url) {
            return protectedFolderItem
        }

        var keys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .localizedTypeDescriptionKey, .contentTypeKey,
            .fileSecurityKey
        ]
        if includeTags {
            keys.insert(.tagNamesKey)
        }

        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }

        return load(from: url, values: values)
    }

    static func tags(for url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    static func loadForDirectoryListing(from url: URL, name: String, showHidden: Bool) -> FileItem? {
        if !showHidden && name.hasPrefix(".") {
            return nil
        }
        if let protectedFolderItem = protectedHomeFolderItem(for: url) {
            return protectedFolderItem
        }

        var linkInfo = stat()
        guard lstat(url.path, &linkInfo) == 0 else {
            return nil
        }

        let hiddenByFlag = (UInt32(linkInfo.st_flags) & UInt32(UF_HIDDEN)) != 0
        if !showHidden && hiddenByFlag {
            return nil
        }

        var statInfo = stat()
        if stat(url.path, &statInfo) != 0 {
            statInfo = linkInfo
        }

        let mode = statInfo.st_mode
        let isDirectory = (mode & S_IFMT) == S_IFDIR
        let type = contentType(for: url, isDirectory: isDirectory)
        let isPackage = isDirectory && (
            type?.conforms(to: .package) == true ||
            packageExtensions.contains(url.pathExtension.lowercased())
        )

        return FileItem(
            id: url,
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: name.hasPrefix(".") || hiddenByFlag,
            size: Int64(statInfo.st_size),
            dateModified: date(from: statInfo.st_mtimespec),
            dateCreated: date(from: statInfo.st_birthtimespec),
            kind: isDirectory && !isPackage ? "Folder" : type?.localizedDescription ?? "Document",
            contentType: type,
            posixPermissions: UInt16(mode & 0o7777),
            tags: []
        )
    }

    static func load(from url: URL, values: URLResourceValues) -> FileItem? {
        if let protectedFolderItem = protectedHomeFolderItem(for: url) {
            return protectedFolderItem
        }

        let perms: UInt16 = {
            guard let security = values.fileSecurity else { return 0 }
            var mode: mode_t = 0
            guard CFFileSecurityGetMode(security as CFFileSecurity, &mode) else { return 0 }
            return UInt16(mode & 0o7777)
        }()

        return FileItem(
            id: url,
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isHidden: values.isHidden ?? false,
            size: Int64(values.fileSize ?? 0),
            dateModified: values.contentModificationDate ?? Date.distantPast,
            dateCreated: values.creationDate ?? Date.distantPast,
            kind: values.localizedTypeDescription ?? "Document",
            contentType: values.contentType,
            posixPermissions: perms,
            tags: values.tagNames ?? []
        )
    }

    private static func protectedHomeFolderItem(for url: URL) -> FileItem? {
        let protectedFolders = protectedHomeFolderURLs()
        let standardizedURL = url.standardizedFileURL
        guard protectedFolders.contains(standardizedURL) else { return nil }

        return FileItem(
            id: standardizedURL,
            url: standardizedURL,
            name: standardizedURL.lastPathComponent,
            isDirectory: true,
            isPackage: false,
            isHidden: false,
            size: 0,
            dateModified: Date.distantPast,
            dateCreated: Date.distantPast,
            kind: "Folder",
            contentType: .folder,
            posixPermissions: 0,
            tags: []
        )
    }

    private static func protectedHomeFolderURLs() -> Set<URL> {
        let fileManager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .desktopDirectory,
            .documentDirectory,
            .downloadsDirectory,
        ]
        return Set(directories.compactMap { directory in
            fileManager.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL
        })
    }

    static func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    var formattedSize: String {
        if isDirectory && !isPackage {
            return "--"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDateModified: String {
        FileItem.dateFormatter.string(from: dateModified)
    }

    static func sort(_ items: inout [FileItem], key: String, ascending: Bool) {
        items.sort { lhs, rhs in
            compare(lhs, rhs, key: key, ascending: ascending)
        }
    }

    static func sorted(_ items: [FileItem], key: String, ascending: Bool) -> [FileItem] {
        var sortedItems = items
        sort(&sortedItems, key: key, ascending: ascending)
        return sortedItems
    }

    static func compare(_ lhs: FileItem, _ rhs: FileItem, key: String, ascending: Bool) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        let result: ComparisonResult
        switch key {
        case "date":
            result = compare(lhs.dateModified, rhs.dateModified)
        case "size":
            result = compare(lhs.size, rhs.size)
        case "kind":
            result = lhs.kind.localizedCaseInsensitiveCompare(rhs.kind)
        default:
            result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        }

        if result == .orderedSame {
            let tieBreak = lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path)
            return tieBreak == .orderedAscending
        }

        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func contentType(for url: URL, isDirectory: Bool) -> UTType? {
        if isDirectory && url.pathExtension.isEmpty {
            return .folder
        }
        guard !url.pathExtension.isEmpty else {
            return nil
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    private static func date(from timespec: timespec) -> Date {
        let seconds = TimeInterval(timespec.tv_sec)
        let nanoseconds = TimeInterval(timespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "kext", "plugin", "pkg",
        "rtfd", "xcodeproj", "xcworkspace", "playground",
        "photoslibrary", "aplibrary", "pages", "numbers", "key",
        "logicx", "imovielibrary", "band", "gband", "wdgt",
        "qlgenerator", "mdimporter", "saver", "prefpane",
    ]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
