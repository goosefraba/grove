import Darwin
import DiskArbitration
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
            return "Windows (UNC)"
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
            return windowsPath(for: url)
        case .terminal:
            return shellQuotedPath(url.path)
        case .url:
            return url.absoluteString
        case .name:
            return url.lastPathComponent
        }
    }

    private static func hfsPath(for url: URL) -> String {
        let bootVolumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        return hfsPath(pathComponents: url.pathComponents, bootVolumeName: bootVolumeName)
    }

    /// Builds a colon-separated HFS path from POSIX path components.
    ///
    /// Non-boot volumes are mounted under `/Volumes/<volumeName>`, so their path
    /// components carry that prefix. The prefix must be treated as the volume
    /// name rather than part of the file hierarchy, otherwise the volume name is
    /// duplicated (e.g. `USB:Volumes:USB:file`). Boot-volume paths have no such
    /// prefix and instead get the volume name prepended.
    static func hfsPath(pathComponents: [String], bootVolumeName: String?) -> String {
        let components = pathComponents.filter { $0 != "/" }
        if components.count >= 2, components[0] == "Volumes" {
            return ([components[1]] + components.dropFirst(2)).joined(separator: ":")
        }
        var result = components
        if let bootVolumeName, !bootVolumeName.isEmpty {
            result.insert(bootVolumeName, at: 0)
        }
        return result.joined(separator: ":")
    }

    /// Produces a Windows-oriented path.
    ///
    /// SMB/CIFS network mounts map to a genuine UNC path (`\\server\share\...`),
    /// which is the only form usable for real Windows interop or SMB access.
    /// Local volumes have no drive letter or UNC form, so they fall back to a
    /// backslash-separated POSIX path — not a valid Windows path, hence the
    /// "Windows (UNC)" menu title reflects that UNC is the meaningful case.
    private static func windowsPath(for url: URL) -> String {
        if let mount = mountInfo(for: url.path),
           let unc = windowsUNCPath(
               mountFromName: mount.from,
               mountPoint: mount.on,
               filePath: url.path
           ) {
            return unc
        }
        return url.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Converts an SMB mount into a UNC path for a file below the mount point.
    ///
    /// Returns `nil` when the mount source is not an SMB/CIFS share.
    static func windowsUNCPath(mountFromName: String, mountPoint: String, filePath: String) -> String? {
        guard let (server, share) = parseSMBMount(mountFromName) else { return nil }
        var unc = "\\\\\(server)\\\(share)"
        let relative = relativePath(filePath, under: mountPoint)
        if !relative.isEmpty {
            unc += "\\" + relative.replacingOccurrences(of: "/", with: "\\")
        }
        return unc
    }

    /// Parses `//[user@]server/share`, `smb://[user@]server/share`, or
    /// `//[user@]server/share/sub` into its server and top-level share.
    private static func parseSMBMount(_ mountFromName: String) -> (server: String, share: String)? {
        var remainder = mountFromName
        var hadScheme = false
        for scheme in ["smb://", "cifs://"] {
            if remainder.lowercased().hasPrefix(scheme) {
                remainder = String(remainder.dropFirst(scheme.count))
                hadScheme = true
                break
            }
        }
        // A stripped scheme leaves "server/share" directly; only genuine "//server/share"
        // sources (no scheme) must still carry the leading "//".
        if remainder.hasPrefix("//") {
            remainder = String(remainder.dropFirst(2))
        } else if !hadScheme {
            return nil
        }

        let segments = remainder.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return nil }

        var host = String(segments[0])
        if let atIndex = host.lastIndex(of: "@") {
            host = String(host[host.index(after: atIndex)...])
        }
        guard !host.isEmpty else { return nil }
        return (host, String(segments[1]))
    }

    /// Returns the portion of `path` that lies below `base`, or "" if `path`
    /// equals `base` or is not contained by it.
    private static func relativePath(_ path: String, under base: String) -> String {
        let base = base == "/" ? "" : base
        guard path.hasPrefix(base) else { return "" }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Looks up the filesystem mount source and mount point for a path.
    private static func mountInfo(for path: String) -> (from: String, on: String)? {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return nil }
        let from = withUnsafeBytes(of: stat.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let on = withUnsafeBytes(of: stat.f_mntonname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return (from, on)
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum MountedVolumeKind: String {
    case internalDisk = "Internal Disk"
    case diskImage = "Disk Image"
    case removable = "Removable"
    case external = "External"
    case network = "Network"
    case localVolume = "Volume"
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
    let deviceProtocol: String?
    let deviceModel: String?
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
        let diskDescription = Self.diskDescription(for: standardizedURL)

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
            deviceProtocol: diskDescription?[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            deviceModel: diskDescription?[kDADiskDescriptionDeviceModelKey as String] as? String,
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
        deviceProtocol: String? = nil,
        deviceModel: String? = nil,
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
        self.deviceProtocol = deviceProtocol
        self.deviceModel = deviceModel
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }

    var stableIdentifier: String {
        uuid ?? canonicalURL.path
    }

    var supportsEject: Bool {
        isEjectable || isRemovable
    }

    var kind: MountedVolumeKind {
        if !isLocal {
            return .network
        }
        if isInternal {
            return .internalDisk
        }
        if isLikelyDiskImage {
            return .diskImage
        }
        if isRemovable {
            return .removable
        }
        if supportsEject {
            return .external
        }
        return .localVolume
    }

    var sidebarDetail: String? {
        kind == .internalDisk ? nil : kind.rawValue
    }

    private var isLikelyDiskImage: Bool {
        if deviceProtocol?.localizedCaseInsensitiveCompare("Disk Image") == .orderedSame {
            return true
        }
        if deviceModel?.localizedCaseInsensitiveCompare("Disk Image") == .orderedSame {
            return true
        }
        return isLocal && !isInternal && isEjectable && !isRemovable
    }

    var systemImage: String {
        switch kind {
        case .network:
            return "network"
        case .internalDisk:
            return "internaldrive"
        case .diskImage:
            return "opticaldiscdrive"
        case .removable, .external, .localVolume:
            return "externaldrive"
        }
    }

    var toolTip: String {
        var details: [String] = [canonicalURL.path, kind.rawValue]
        if isReadOnly {
            details.append("Read Only")
        }
        if supportsEject {
            details.append("Ejectable")
        }
        return details.joined(separator: "\n")
    }

    private static func diskDescription(for url: URL) -> [String: Any]? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return nil
        }
        return description
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

    var sidebarDetail: String? {
        mountedVolume?.sidebarDetail
    }

    var showsInlineEjectButton: Bool {
        mountedVolume?.supportsEject == true
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
