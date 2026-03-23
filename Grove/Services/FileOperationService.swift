import Foundation
import AppKit

final class FileOperationService {

    static let shared = FileOperationService()
    private let fileManager = FileManager.default

    private init() {}

    func contentsOfDirectory(at url: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .localizedTypeDescriptionKey, .contentTypeKey
        ]

        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        )

        return urls.compactMap { FileItem.load(from: $0) }
    }

    func createNewFolder(in directory: URL, name: String = "untitled folder") throws -> URL {
        var folderURL = directory.appendingPathComponent(name)
        var counter = 1

        while fileManager.fileExists(atPath: folderURL.path) {
            folderURL = directory.appendingPathComponent("\(name) \(counter)")
            counter += 1
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
        return folderURL
    }

    func moveToTrash(_ urls: [URL]) throws -> [URL] {
        var resultURLs: [URL] = []
        for url in urls {
            var trashURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashURL)
            if let trashURL = trashURL as URL? {
                resultURLs.append(trashURL)
            }
        }
        return resultURLs
    }

    func copy(_ urls: [URL], to destination: URL) throws {
        for url in urls {
            let destURL = uniqueDestination(for: url, in: destination)
            try fileManager.copyItem(at: url, to: destURL)
        }
    }

    func move(_ urls: [URL], to destination: URL) throws {
        for url in urls {
            let destURL = uniqueDestination(for: url, in: destination)
            try fileManager.moveItem(at: url, to: destURL)
        }
    }

    private func uniqueDestination(for url: URL, in directory: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var destURL = directory.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        while fileManager.fileExists(atPath: destURL.path) {
            let newName = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            destURL = directory.appendingPathComponent(newName)
            counter += 1
        }
        return destURL
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: url, to: newURL)
        return newURL
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func availableDiskSpace(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }
}
