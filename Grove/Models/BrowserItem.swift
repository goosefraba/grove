import AppKit
import Foundation
import UniformTypeIdentifiers

enum BrowserItemKind: String, Codable {
    case folder
    case file
    case s3Prefix
    case s3Object
}

struct S3ObjectMetadata: Equatable {
    var contentLength: Int64?
    var contentType: String?
    var eTag: String?
    var lastModified: Date?
    var storageClass: String?
    var userMetadata: [String: String]
    var warning: String?
}

struct S3Item: Identifiable, Hashable {
    let bucket: String
    let key: String
    let name: String
    let isPrefix: Bool
    let size: Int64?
    let lastModified: Date?
    let eTag: String?
    let storageClass: String?
    let location: S3Location
    var metadata: S3ObjectMetadata?

    var id: String {
        "s3:\(location.profileName ?? ""):\(location.regionOverride ?? ""):\(bucket):\(key):\(isPrefix ? "prefix" : "object")"
    }

    var isBucket: Bool {
        isPrefix && key.isEmpty && location.bucket == bucket && location.prefix.isEmpty
    }

    var kind: String {
        if isBucket { return "S3 Bucket" }
        return isPrefix ? "S3 Prefix" : "S3 Object"
    }

    var formattedSize: String {
        guard !isPrefix, let size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: S3Item, rhs: S3Item) -> Bool {
        lhs.id == rhs.id && lhs.metadata == rhs.metadata
    }
}

enum BrowserItem: Identifiable, Hashable {
    case local(FileItem)
    case s3(S3Item)

    var id: String {
        switch self {
        case .local(let item):
            return "local:\(item.url.path)"
        case .s3(let item):
            return item.id
        }
    }

    var name: String {
        switch self {
        case .local(let item):
            return item.name
        case .s3(let item):
            return item.name
        }
    }

    var kind: String {
        switch self {
        case .local(let item):
            return item.kind
        case .s3(let item):
            return item.kind
        }
    }

    var isContainer: Bool {
        switch self {
        case .local(let item):
            return item.isDirectory && !item.isPackage
        case .s3(let item):
            return item.isPrefix
        }
    }

    var formattedSize: String {
        switch self {
        case .local(let item):
            return item.formattedSize
        case .s3(let item):
            return item.formattedSize
        }
    }

    var dateModified: Date? {
        switch self {
        case .local(let item):
            return item.dateModified
        case .s3(let item):
            return item.metadata?.lastModified ?? item.lastModified
        }
    }

    var storageLocation: StorageLocation {
        switch self {
        case .local(let item):
            return .local(item.url)
        case .s3(let item):
            return .s3(item.location)
        }
    }

    var fileItem: FileItem? {
        guard case .local(let item) = self else { return nil }
        return item
    }

    var s3Item: S3Item? {
        guard case .s3(let item) = self else { return nil }
        return item
    }

    var icon: NSImage {
        switch self {
        case .local(let item):
            let icon = NSWorkspace.shared.icon(forFile: item.url.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        case .s3(let item):
            let symbol = item.isBucket ? "externaldrive.connected.to.line.below" : (item.isPrefix ? "folder" : "doc")
            return NSImage(systemSymbolName: symbol, accessibilityDescription: item.name) ?? NSImage()
        }
    }
}
