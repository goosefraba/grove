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

    // MARK: - Compression

    enum CompressionLevel: Int, CaseIterable {
        case store = 0
        case fast = 1
        case normal = 5
        case maximum = 9

        var label: String {
            switch self {
            case .store: return "Store (no compression)"
            case .fast: return "Fast"
            case .normal: return "Normal"
            case .maximum: return "Maximum"
            }
        }
    }

    func compress(_ urls: [URL], to archiveURL: URL, level: CompressionLevel = .normal, password: String? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        backgroundQueue.async {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                // Stage files into temp directory so ditto archives them by name
                for url in urls {
                    let dest = tempDir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: dest)
                }

                var args = ["-c", "-k"]
                if let password = password, !password.isEmpty {
                    args += ["--password", password]
                }
                args += ["--zlibCompressionLevel", "\(level.rawValue)"]
                args += [tempDir.path, archiveURL.path]

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = args
                let errorPipe = Pipe()
                process.standardError = errorPipe
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8) ?? "Compression failed"
                    throw NSError(domain: "com.grove.compress", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
                }

                DispatchQueue.main.async { completion(.success(archiveURL)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func decompress(_ archiveURL: URL, to destinationDir: URL, password: String? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        backgroundQueue.async {
            do {
                var args = ["-x", "-k"]
                if let password = password, !password.isEmpty {
                    args += ["--password", password]
                }
                args += [archiveURL.path, destinationDir.path]

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = args
                let errorPipe = Pipe()
                process.standardError = errorPipe
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8) ?? "Decompression failed"
                    throw NSError(domain: "com.grove.decompress", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
                }

                DispatchQueue.main.async { completion(.success(destinationDir)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
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
