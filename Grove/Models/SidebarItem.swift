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

    static let favorites: [SidebarItem] = [
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
