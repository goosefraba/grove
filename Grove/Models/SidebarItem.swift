import Foundation

enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case locations = "Locations"
}

struct SidebarItem: Hashable {
    let title: String
    let url: URL
    let systemImage: String
    let section: SidebarSection
    let isBuiltIn: Bool

    init(title: String, url: URL, systemImage: String, section: SidebarSection, isBuiltIn: Bool = true) {
        self.title = title
        self.url = url
        self.systemImage = systemImage
        self.section = section
        self.isBuiltIn = isBuiltIn
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
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.volumeNameKey],
            options: []
        ) else {
            return []
        }

        return contents.compactMap { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return SidebarItem(
                title: name,
                url: url,
                systemImage: "externaldrive",
                section: .locations
            )
        }
    }
}
