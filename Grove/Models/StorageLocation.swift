import Foundation

struct StorageBreadcrumb: Hashable {
    let title: String
    let location: StorageLocation
    let toolTip: String
}

struct StorageCapabilities: OptionSet, Hashable {
    let rawValue: Int

    static let browse = StorageCapabilities(rawValue: 1 << 0)
    static let toolbarSearch = StorageCapabilities(rawValue: 1 << 1)
    static let showHiddenFiles = StorageCapabilities(rawValue: 1 << 2)
    static let createFolder = StorageCapabilities(rawValue: 1 << 3)
    static let openLocalFile = StorageCapabilities(rawValue: 1 << 4)
    static let quickLook = StorageCapabilities(rawValue: 1 << 5)
    static let rename = StorageCapabilities(rawValue: 1 << 6)
    static let trash = StorageCapabilities(rawValue: 1 << 7)
    static let duplicate = StorageCapabilities(rawValue: 1 << 8)
    static let batchRename = StorageCapabilities(rawValue: 1 << 9)
    static let copyMove = StorageCapabilities(rawValue: 1 << 10)
    static let localDragDrop = StorageCapabilities(rawValue: 1 << 11)
    static let finderReveal = StorageCapabilities(rawValue: 1 << 12)
    static let openTerminal = StorageCapabilities(rawValue: 1 << 13)
    static let tags = StorageCapabilities(rawValue: 1 << 14)
    static let compression = StorageCapabilities(rawValue: 1 << 15)
    static let checksum = StorageCapabilities(rawValue: 1 << 16)

    static let localReadWrite: StorageCapabilities = [
        .browse, .toolbarSearch, .showHiddenFiles, .createFolder, .openLocalFile,
        .quickLook, .rename, .trash, .duplicate, .batchRename, .copyMove,
        .localDragDrop, .finderReveal, .openTerminal, .tags, .compression, .checksum,
    ]

    static let s3ReadOnly: StorageCapabilities = [.browse]
}

struct S3Location: Hashable, Codable {
    var profileName: String?
    var regionOverride: String?
    var bucket: String?
    var prefix: String

    init(profileName: String? = nil, regionOverride: String? = nil, bucket: String? = nil, prefix: String = "") {
        self.profileName = Self.clean(profileName)
        self.regionOverride = Self.clean(regionOverride)
        self.bucket = Self.clean(bucket)
        self.prefix = Self.normalizedPrefix(prefix, isFolder: true)
    }

    var effectiveProfileName: String? {
        profileName?.isEmpty == false ? profileName : nil
    }

    var effectiveRegionOverride: String? {
        regionOverride?.isEmpty == false ? regionOverride : nil
    }

    var displayName: String {
        if let bucket, !bucket.isEmpty {
            if prefix.isEmpty {
                return bucket
            }
            return prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/")
                .last
                .map(String.init) ?? bucket
        }
        return "Amazon S3"
    }

    var parent: S3Location? {
        guard bucket?.isEmpty == false else { return nil }
        guard !prefix.isEmpty else {
            return S3Location(profileName: profileName, regionOverride: regionOverride, bucket: nil, prefix: "")
        }

        var parts = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        guard !parts.isEmpty else {
            return S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: "")
        }
        parts.removeLast()
        let parentPrefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        return S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: parentPrefix)
    }

    func with(regionOverride: String?) -> S3Location {
        S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: prefix)
    }

    func with(bucket: String?) -> S3Location {
        S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: "")
    }

    func appendingPrefix(_ childPrefix: String) -> S3Location {
        S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: childPrefix)
    }

    func objectLocation(key: String) -> S3Location {
        S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: Self.normalizedPrefix(key, isFolder: false))
    }

    var breadcrumbs: [StorageBreadcrumb] {
        var result: [StorageBreadcrumb] = [
            StorageBreadcrumb(
                title: "S3",
                location: .s3(S3Location(profileName: profileName, regionOverride: regionOverride, bucket: nil, prefix: "")),
                toolTip: "Amazon S3"
            )
        ]

        if let profileName, !profileName.isEmpty {
            result.append(StorageBreadcrumb(
                title: profileName,
                location: .s3(S3Location(profileName: profileName, regionOverride: regionOverride, bucket: nil, prefix: "")),
                toolTip: "AWS profile \(profileName)"
            ))
        }

        guard let bucket, !bucket.isEmpty else {
            return result
        }

        result.append(StorageBreadcrumb(
            title: bucket,
            location: .s3(S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: "")),
            toolTip: "s3://\(bucket)"
        ))

        var accumulated = ""
        for part in prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init) {
            accumulated += part + "/"
            result.append(StorageBreadcrumb(
                title: part,
                location: .s3(S3Location(profileName: profileName, regionOverride: regionOverride, bucket: bucket, prefix: accumulated)),
                toolTip: "s3://\(bucket)/\(accumulated)"
            ))
        }

        return result
    }

    static func normalizedPrefix(_ value: String, isFolder: Bool) -> String {
        var prefix = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while prefix.hasPrefix("/") {
            prefix.removeFirst()
        }
        while prefix.contains("//") {
            prefix = prefix.replacingOccurrences(of: "//", with: "/")
        }
        if prefix == "." || prefix == ".." {
            prefix = ""
        }
        if isFolder, !prefix.isEmpty, !prefix.hasSuffix("/") {
            prefix += "/"
        }
        return prefix
    }

    private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == true ? nil : cleaned
    }
}

enum StorageLocation: Hashable, Codable {
    case local(URL)
    case s3(S3Location)

    private enum CodingKeys: String, CodingKey {
        case provider
        case path
        case profileName
        case regionOverride
        case bucket
        case prefix
    }

    var displayName: String {
        switch self {
        case .local(let url):
            return url.displayName
        case .s3(let location):
            return location.displayName
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var localURL: URL? {
        guard case .local(let url) = self else { return nil }
        return url
    }

    var parent: StorageLocation? {
        switch self {
        case .local(let url):
            let current = url.standardizedFileURL
            let parent = current.deletingLastPathComponent().standardizedFileURL
            return parent == current ? nil : .local(parent)
        case .s3(let location):
            return location.parent.map(StorageLocation.s3)
        }
    }

    var capabilities: StorageCapabilities {
        switch self {
        case .local:
            return .localReadWrite
        case .s3:
            return .s3ReadOnly
        }
    }

    var breadcrumbs: [StorageBreadcrumb] {
        switch self {
        case .local(let url):
            return url.pathComponents_.map {
                StorageBreadcrumb(title: $0.displayName, location: .local($0), toolTip: $0.path)
            }
        case .s3(let location):
            return location.breadcrumbs
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(String.self, forKey: .provider)
        switch provider {
        case "local":
            let path = try container.decode(String.self, forKey: .path)
            self = .local(URL(fileURLWithPath: path).standardizedFileURL)
        case "s3":
            self = .s3(S3Location(
                profileName: try container.decodeIfPresent(String.self, forKey: .profileName),
                regionOverride: try container.decodeIfPresent(String.self, forKey: .regionOverride),
                bucket: try container.decodeIfPresent(String.self, forKey: .bucket),
                prefix: try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
            ))
        default:
            throw DecodingError.dataCorruptedError(forKey: .provider, in: container, debugDescription: "Unsupported storage provider")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let url):
            try container.encode("local", forKey: .provider)
            try container.encode(url.path, forKey: .path)
        case .s3(let location):
            try container.encode("s3", forKey: .provider)
            try container.encodeIfPresent(location.profileName, forKey: .profileName)
            try container.encodeIfPresent(location.regionOverride, forKey: .regionOverride)
            try container.encodeIfPresent(location.bucket, forKey: .bucket)
            try container.encode(location.prefix, forKey: .prefix)
        }
    }

    var propertyListRepresentation: [String: Any] {
        switch self {
        case .local(let url):
            return ["provider": "local", "path": url.path]
        case .s3(let location):
            var dict: [String: Any] = [
                "provider": "s3",
                "prefix": location.prefix,
            ]
            if let profileName = location.profileName {
                dict["profileName"] = profileName
            }
            if let regionOverride = location.regionOverride {
                dict["regionOverride"] = regionOverride
            }
            if let bucket = location.bucket {
                dict["bucket"] = bucket
            }
            return dict
        }
    }

    static func fromPropertyList(_ value: Any?) -> StorageLocation? {
        guard let dict = value as? [String: Any],
              let provider = dict["provider"] as? String else { return nil }

        switch provider {
        case "local":
            guard let path = dict["path"] as? String else { return nil }
            return .local(URL(fileURLWithPath: path).standardizedFileURL)
        case "s3":
            return .s3(S3Location(
                profileName: dict["profileName"] as? String,
                regionOverride: dict["regionOverride"] as? String,
                bucket: dict["bucket"] as? String,
                prefix: dict["prefix"] as? String ?? ""
            ))
        default:
            return nil
        }
    }
}
