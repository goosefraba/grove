import Foundation
import AppKit

final class FileOperationService {

    static let shared = FileOperationService()
    private let fileManager = FileManager.default
    private let backgroundQueue = DispatchQueue(label: "com.grove.fileops", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    func contentsOfDirectory(at url: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .localizedTypeDescriptionKey, .contentTypeKey, .tagNamesKey
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

    // MARK: - Async Directory Loading

    func contentsOfDirectoryAsync(at url: URL, showHidden: Bool, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let items = try self.contentsOfDirectory(at: url, showHidden: showHidden)
                DispatchQueue.main.async {
                    completion(.success(items))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - File Operations

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

    func rename(_ url: URL, to newName: String) throws -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: url, to: newURL)
        return newURL
    }

    func duplicate(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var counter = 0
        var destURL: URL
        repeat {
            let suffix = counter == 0 ? " copy" : " copy \(counter + 1)"
            let newName = ext.isEmpty ? "\(name)\(suffix)" : "\(name)\(suffix).\(ext)"
            destURL = directory.appendingPathComponent(newName)
            counter += 1
        } while fileManager.fileExists(atPath: destURL.path)

        try fileManager.copyItem(at: url, to: destURL)
        return destURL
    }

    func batchRename(_ urls: [URL], find: String, replace: String, useRegex: Bool) throws -> [(URL, URL)] {
        var results: [(URL, URL)] = []
        for url in urls {
            let original = url.lastPathComponent
            let renamed: String
            if useRegex {
                let regex = try NSRegularExpression(pattern: find)
                let range = NSRange(original.startIndex..., in: original)
                renamed = regex.stringByReplacingMatches(in: original, range: range, withTemplate: replace)
            } else {
                renamed = original.replacingOccurrences(of: find, with: replace)
            }
            if renamed != original && !renamed.isEmpty {
                let newURL = try rename(url, to: renamed)
                results.append((url, newURL))
            }
        }
        return results
    }

    // MARK: - Progress Operations

    func copyWithProgress(_ urls: [URL], to destination: URL, progress: @escaping (Double, String) -> Void, cancelled: @escaping () -> Bool) throws {
        for (index, url) in urls.enumerated() {
            if cancelled() { return }
            let destURL = uniqueDestination(for: url, in: destination)
            progress(Double(index) / Double(urls.count), url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destURL)
        }
        progress(1.0, "")
    }

    func moveWithProgress(_ urls: [URL], to destination: URL, progress: @escaping (Double, String) -> Void, cancelled: @escaping () -> Bool) throws {
        for (index, url) in urls.enumerated() {
            if cancelled() { return }
            let destURL = uniqueDestination(for: url, in: destination)
            progress(Double(index) / Double(urls.count), url.lastPathComponent)
            try fileManager.moveItem(at: url, to: destURL)
        }
        progress(1.0, "")
    }

    // MARK: - Helpers

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
