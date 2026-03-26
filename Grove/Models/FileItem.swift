import Foundation
import AppKit
import UniformTypeIdentifiers
import ImageIO

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

    static func load(from url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .localizedTypeDescriptionKey, .contentTypeKey, .tagNamesKey,
            .fileSecurityKey
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
