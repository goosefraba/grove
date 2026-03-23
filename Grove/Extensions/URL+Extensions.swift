import Foundation

extension URL {

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var volumeName: String? {
        (try? resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    var displayName: String {
        FileManager.default.displayName(atPath: path)
    }

    var pathComponents_: [URL] {
        var components: [URL] = []
        var current = self.standardizedFileURL
        while current.path != "/" {
            components.append(current)
            current = current.deletingLastPathComponent()
        }
        components.append(URL(fileURLWithPath: "/"))
        return components.reversed()
    }
}
