import Foundation

extension Notification.Name {
    static let addToSidebarFavorites = Notification.Name("com.grove.addToSidebarFavorites")
}

enum PathCopyFormat: CaseIterable {
    case unix
    case hfs
    case windows
    case terminal
    case url
    case name

    var menuTitle: String {
        switch self {
        case .unix:
            return "UNIX"
        case .hfs:
            return "HFS"
        case .windows:
            return "Windows"
        case .terminal:
            return "Terminal"
        case .url:
            return "URL"
        case .name:
            return "Name"
        }
    }
}

enum PathCopyFormatter {
    static func string(for url: URL, format: PathCopyFormat) -> String {
        switch format {
        case .unix:
            return url.path
        case .hfs:
            return hfsPath(for: url)
        case .windows:
            return url.path.replacingOccurrences(of: "/", with: "\\")
        case .terminal:
            return shellQuotedPath(url.path)
        case .url:
            return url.absoluteString
        case .name:
            return url.lastPathComponent
        }
    }

    private static func hfsPath(for url: URL) -> String {
        var components = url.pathComponents.filter { $0 != "/" }
        let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        if let volumeName,
           !volumeName.isEmpty {
            components.insert(volumeName, at: 0)
        }
        return components.joined(separator: ":")
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct MountedVolume: Hashable {
    static let resourceKeys: Set<URLResourceKey> = [
        .localizedNameKey,
        .volumeNameKey,
        .volumeIsEjectableKey,
        .volumeIsRemovableKey,
        .volumeIsInternalKey,
        .volumeIsLocalKey,
        .volumeIsReadOnlyKey,
        .volumeUUIDStringKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
    ]

    let url: URL
    let canonicalURL: URL
    let displayName: String
    let volumeName: String?
    let uuid: String?
    let isEjectable: Bool
    let isRemovable: Bool
    let isInternal: Bool
    let isLocal: Bool
    let isReadOnly: Bool
    let totalCapacity: Int?
    let availableCapacity: Int?

    init?(
        url: URL,
        fileManager: FileManager = .default
    ) {
        let standardizedURL = url.standardizedFileURL
        guard let values = try? standardizedURL.resourceValues(forKeys: Self.resourceKeys) else {
            return nil
        }

        let displayName = values.localizedName ??
            values.volumeName ??
            fileManager.displayName(atPath: standardizedURL.path)
        guard !displayName.isEmpty else { return nil }

        self.init(
            url: standardizedURL,
            canonicalURL: standardizedURL.resolvingSymlinksInPath().standardizedFileURL,
            displayName: displayName,
            volumeName: values.volumeName,
            uuid: values.volumeUUIDString,
            isEjectable: values.volumeIsEjectable ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isInternal: values.volumeIsInternal ?? false,
            isLocal: values.volumeIsLocal ?? true,
            isReadOnly: values.volumeIsReadOnly ?? false,
            totalCapacity: values.volumeTotalCapacity,
            availableCapacity: values.volumeAvailableCapacity
        )
    }

    init(
        url: URL,
        canonicalURL: URL? = nil,
        displayName: String,
        volumeName: String? = nil,
        uuid: String? = nil,
        isEjectable: Bool = false,
        isRemovable: Bool = false,
        isInternal: Bool = false,
        isLocal: Bool = true,
        isReadOnly: Bool = false,
        totalCapacity: Int? = nil,
        availableCapacity: Int? = nil
    ) {
        self.url = url.standardizedFileURL
        self.canonicalURL = (canonicalURL ?? url).resolvingSymlinksInPath().standardizedFileURL
        self.displayName = displayName
        self.volumeName = volumeName
        self.uuid = uuid
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }

    var stableIdentifier: String {
        uuid ?? canonicalURL.path
    }

    var supportsEject: Bool {
        isEjectable || isRemovable
    }

    var systemImage: String {
        if !isLocal {
            return "network"
        }
        if isInternal {
            return "internaldrive"
        }
        return "externaldrive"
    }

    var toolTip: String {
        var details: [String] = [canonicalURL.path]
        if isReadOnly {
            details.append("Read Only")
        }
        if supportsEject {
            details.append("Ejectable")
        }
        return details.joined(separator: "\n")
    }

    func contains(_ candidate: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = canonicalURL.path

        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func mountedVolumes(fileManager: FileManager = .default) -> [MountedVolume] {
        let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return uniqueSorted(volumeURLs.compactMap { MountedVolume(url: $0, fileManager: fileManager) })
    }

    static func uniqueSorted(_ volumes: [MountedVolume]) -> [MountedVolume] {
        var seen = Set<String>()
        return volumes
            .filter { seen.insert($0.stableIdentifier).inserted }
            .sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }
}

enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case locations = "Locations"
    case cloud = "Cloud"
}

struct SidebarItem: Hashable {
    let title: String
    let location: StorageLocation
    let systemImage: String
    let section: SidebarSection
    let isBuiltIn: Bool
    let mountedVolume: MountedVolume?

    var url: URL {
        location.localURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    init(
        title: String,
        url: URL,
        systemImage: String,
        section: SidebarSection,
        isBuiltIn: Bool = true,
        mountedVolume: MountedVolume? = nil
    ) {
        self.title = title
        self.location = .local(url.standardizedFileURL)
        self.systemImage = systemImage
        self.section = section
        self.isBuiltIn = isBuiltIn
        self.mountedVolume = mountedVolume
    }

    init(
        title: String,
        location: StorageLocation,
        systemImage: String,
        section: SidebarSection,
        isBuiltIn: Bool = true,
        mountedVolume: MountedVolume? = nil
    ) {
        self.title = title
        self.location = location
        self.systemImage = systemImage
        self.section = section
        self.isBuiltIn = isBuiltIn
        self.mountedVolume = mountedVolume
    }

    var toolTip: String {
        if let mountedVolume {
            return mountedVolume.toolTip
        }
        if case .local(let url) = location {
            return url.path
        }
        return location.displayName
    }

    func representsProvider(of otherLocation: StorageLocation) -> Bool {
        switch (location, otherLocation) {
        case (.local, .local(let otherURL)):
            return mountedVolume?.contains(otherURL) ?? false
        case (.s3, .s3):
            return true
        default:
            return false
        }
    }

    static let builtInFavorites: [SidebarItem] = [
        SidebarItem(
            title: "Home",
            url: FileManager.default.homeDirectoryForCurrentUser,
            systemImage: "house",
            section: .favorites
        ),
        SidebarItem(
            title: "Desktop",
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
            systemImage: "menubar.dock.rectangle",
            section: .favorites
        ),
        SidebarItem(
            title: "Documents",
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"),
            systemImage: "doc",
            section: .favorites
        ),
        SidebarItem(
            title: "Downloads",
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            systemImage: "arrow.down.circle",
            section: .favorites
        ),
        SidebarItem(
            title: "Applications",
            url: URL(fileURLWithPath: "/Applications"),
            systemImage: "square.grid.2x2",
            section: .favorites
        ),
    ]

    static var favorites: [SidebarItem] {
        builtInFavorites + customFavorites
    }

    static let cloudItems: [SidebarItem] = [
        SidebarItem(
            title: "Amazon S3",
            location: .s3(S3Location()),
            systemImage: "cloud",
            section: .cloud
        )
    ]

    // MARK: - Custom Favorites Persistence

    private static let customFavoritesKey = "customFavorites"

    static var customFavorites: [SidebarItem] {
        guard let dicts = UserDefaults.standard.array(forKey: customFavoritesKey) as? [[String: String]] else {
            return []
        }
        return dicts.compactMap { dict in
            guard let title = dict["title"],
                  let path = dict["path"],
                  let systemImage = dict["systemImage"] else { return nil }
            return SidebarItem(
                title: title,
                url: URL(fileURLWithPath: path),
                systemImage: systemImage,
                section: .favorites,
                isBuiltIn: false
            )
        }
    }

    static func saveCustomFavorites(_ items: [SidebarItem]) {
        let dicts: [[String: String]] = items.map { item in
            [
                "title": item.title,
                "path": item.url.path,
                "systemImage": item.systemImage,
            ]
        }
        UserDefaults.standard.set(dicts, forKey: customFavoritesKey)
    }

    static func volumes() -> [SidebarItem] {
        volumeItems(from: MountedVolume.mountedVolumes())
    }

    static func volumeItems(from volumes: [MountedVolume]) -> [SidebarItem] {
        MountedVolume.uniqueSorted(volumes).map { volume in
            SidebarItem(
                title: volume.displayName,
                url: volume.canonicalURL,
                systemImage: volume.systemImage,
                section: .locations,
                mountedVolume: volume
            )
        }
    }
}
