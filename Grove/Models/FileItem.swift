import Foundation
import AppKit
import UniformTypeIdentifiers

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

    var isApplication: Bool {
        contentType?.conforms(to: .application) ?? false ||
        url.pathExtension.lowercased() == "app"
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
            .localizedTypeDescriptionKey, .contentTypeKey
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }

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
            contentType: values.contentType
        )
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
