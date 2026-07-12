import Foundation
import AppKit
import CommonCrypto
import Darwin
import OSLog

final class FileOperationService {

    enum ConflictResolution {
        case skip
        case keepBoth
        case replace
        case merge
    }

    struct FileConflict {
        let sourceURL: URL
        let destinationURL: URL
        let canMerge: Bool
    }

    enum TransferUndoBehavior {
        case none
        case trashDestination
        case moveBackToSource
    }

    struct FileTransferRecord {
        let sourceURL: URL
        let destinationURL: URL
        let undoBehavior: TransferUndoBehavior

        var isUndoable: Bool {
            undoBehavior != .none
        }
    }

    enum FileOperationError: LocalizedError {
        case invalidFileName(String)
        case cancelled(records: [FileTransferRecord])
        case partialFailure(records: [FileTransferRecord], underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidFileName(let name):
                return "Invalid file name: \(name)"
            case .cancelled:
                return "File operation cancelled."
            case .partialFailure(_, let underlying):
                return underlying.localizedDescription
            }
        }
    }

    private enum TransferOperation {
        case copy
        case move
    }

    static let shared = FileOperationService()
    private static let logger = Logger(subsystem: "com.goosefraba.grove", category: "FileOperationService")
    private let fileManager = FileManager.default
    private let directoryQueue = DispatchQueue(label: "com.grove.fileops.directory", qos: .userInitiated)
    private let backgroundQueue = DispatchQueue(label: "com.grove.fileops", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    func contentsOfDirectory(at url: URL, showHidden: Bool) throws -> [FileItem] {
        let names = try fileManager.contentsOfDirectory(atPath: url.path)

        return names.compactMap { name in
            let childURL = url.appendingPathComponent(name)
            guard let item = FileItem.loadForDirectoryListing(from: childURL, name: name, showHidden: showHidden) else {
                Self.logger.debug("Skipping unreadable item during directory load: \(childURL.path, privacy: .public)")
                return nil
            }
            return item
        }
    }

    // MARK: - Async Directory Loading

    func contentsOfDirectoryAsync(at url: URL, showHidden: Bool, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        directoryQueue.async { [weak self] in
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
        // Create-and-catch avoids a TOCTOU race between an existence check and createDirectory.
        var counter = 0
        while true {
            let folderName = counter == 0 ? name : "\(name) \(counter)"
            let folderURL = directory.appendingPathComponent(folderName)
            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
                return folderURL
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                counter += 1
            }
        }
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

    func copy(_ urls: [URL], to destination: URL) throws -> [URL] {
        var copiedURLs: [URL] = []
        for url in urls {
            copiedURLs.append(try transfer(url, toUniqueIn: destination, operation: .copy))
        }
        return copiedURLs
    }

    func move(_ urls: [URL], to destination: URL) throws -> [URL] {
        var movedURLs: [URL] = []
        for url in urls {
            movedURLs.append(try transfer(url, toUniqueIn: destination, operation: .move))
        }
        return movedURLs
    }

    func copyResolvingConflicts(
        _ urls: [URL],
        to destination: URL,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [URL] {
        try copyResolvingConflictsWithRecords(urls, to: destination, resolver: resolver).map(\.destinationURL)
    }

    func moveResolvingConflicts(
        _ urls: [URL],
        to destination: URL,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [URL] {
        try moveResolvingConflictsWithRecords(urls, to: destination, resolver: resolver).map(\.destinationURL)
    }

    func copyResolvingConflictsWithRecords(
        _ urls: [URL],
        to destination: URL,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [FileTransferRecord] {
        try transfer(urls, to: destination, operation: .copy, resolver: resolver)
    }

    func moveResolvingConflictsWithRecords(
        _ urls: [URL],
        to destination: URL,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [FileTransferRecord] {
        try transfer(urls, to: destination, operation: .move, resolver: resolver)
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        let validName = try validatedFileName(newName)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(validName)
        try fileManager.moveItem(at: url, to: newURL)
        return newURL
    }

    func duplicate(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let nameParts = fileNameParts(for: url)

        var counter = 0
        var destURL: URL
        repeat {
            let suffix = counter == 0 ? " copy" : " copy \(counter + 1)"
            let newName = fileName(stem: nameParts.stem, suffix: suffix, fileExtension: nameParts.fileExtension)
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

    func copyWithProgress(_ urls: [URL], to destination: URL, progress: @escaping (Double, String) -> Void, cancelled: @escaping () -> Bool) throws -> [URL] {
        var records: [FileTransferRecord] = []
        for (index, url) in urls.enumerated() {
            if cancelled() {
                throw FileOperationError.cancelled(records: records)
            }
            let destURL = uniqueDestination(for: url, in: destination)
            progress(Double(index) / Double(urls.count), url.lastPathComponent)
            do {
                try fileManager.copyItem(at: url, to: destURL)
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
            records.append(FileTransferRecord(sourceURL: url, destinationURL: destURL, undoBehavior: .trashDestination))
        }
        progress(1.0, "")
        return records.map(\.destinationURL)
    }

    func moveWithProgress(_ urls: [URL], to destination: URL, progress: @escaping (Double, String) -> Void, cancelled: @escaping () -> Bool) throws -> [URL] {
        var records: [FileTransferRecord] = []
        for (index, url) in urls.enumerated() {
            if cancelled() {
                throw FileOperationError.cancelled(records: records)
            }
            let destURL = uniqueDestination(for: url, in: destination)
            progress(Double(index) / Double(urls.count), url.lastPathComponent)
            do {
                try fileManager.moveItem(at: url, to: destURL)
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
            records.append(FileTransferRecord(sourceURL: url, destinationURL: destURL, undoBehavior: .moveBackToSource))
        }
        progress(1.0, "")
        return records.map(\.destinationURL)
    }

    // MARK: - Helpers

    func hasNameConflicts(_ urls: [URL], in directory: URL) -> Bool {
        urls.contains { url in
            let destinationURL = directory.appendingPathComponent(url.lastPathComponent)
            return fileManager.fileExists(atPath: destinationURL.path)
        }
    }

    private func transfer(
        _ urls: [URL],
        to destination: URL,
        operation: TransferOperation,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [FileTransferRecord] {
        var records: [FileTransferRecord] = []

        for url in urls {
            do {
                records.append(contentsOf: try transfer(url, to: destination, operation: operation, resolver: resolver))
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
        }

        return records
    }

    private func transfer(
        _ url: URL,
        to directory: URL,
        operation: TransferOperation,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [FileTransferRecord] {
        let destinationURL = directory.appendingPathComponent(url.lastPathComponent)

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try performTransfer(url, to: destinationURL, operation: operation)
            return [transferRecord(sourceURL: url, destinationURL: destinationURL, operation: operation)]
        }

        guard url.standardizedFileURL != destinationURL.standardizedFileURL else {
            guard operation == .copy else {
                return []
            }
            let copyURL = try transfer(url, toCopySuffixIn: directory, operation: operation)
            return [transferRecord(sourceURL: url, destinationURL: copyURL, operation: operation)]
        }

        let conflict = FileConflict(
            sourceURL: url,
            destinationURL: destinationURL,
            canMerge: canMergeDirectories(sourceURL: url, destinationURL: destinationURL)
        )

        switch resolver(conflict) {
        case .skip:
            return []
        case .keepBoth:
            let uniqueURL = try transfer(url, toUniqueIn: directory, operation: operation)
            return [transferRecord(sourceURL: url, destinationURL: uniqueURL, operation: operation)]
        case .replace:
            try performReplacingTransfer(url, to: destinationURL, operation: operation)
            return [
                FileTransferRecord(
                    sourceURL: url,
                    destinationURL: destinationURL,
                    undoBehavior: operation == .move ? .moveBackToSource : .none
                )
            ]
        case .merge:
            guard conflict.canMerge else {
                let uniqueURL = try transfer(url, toUniqueIn: directory, operation: operation)
                return [transferRecord(sourceURL: url, destinationURL: uniqueURL, operation: operation)]
            }
            return try mergeDirectory(sourceURL: url, into: destinationURL, operation: operation, resolver: resolver)
        }
    }

    private func transferRecord(sourceURL: URL, destinationURL: URL, operation: TransferOperation) -> FileTransferRecord {
        FileTransferRecord(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            undoBehavior: operation == .copy ? .trashDestination : .moveBackToSource
        )
    }

    private func performTransfer(_ sourceURL: URL, to destinationURL: URL, operation: TransferOperation) throws {
        switch operation {
        case .copy:
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        case .move:
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private func performReplacingTransfer(_ sourceURL: URL, to destinationURL: URL, operation: TransferOperation) throws {
        let backupURL = replacementBackupURL(for: destinationURL)

        try fileManager.moveItem(at: destinationURL, to: backupURL)
        do {
            try performTransfer(sourceURL, to: destinationURL, operation: operation)
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            try? fileManager.moveItem(at: backupURL, to: destinationURL)
            throw error
        }

        do {
            try fileManager.removeItem(at: backupURL)
        } catch {
            Self.logger.error("Unable to remove replacement backup after successful transfer: \(backupURL.path, privacy: .public)")
        }
    }

    private func replacementBackupURL(for destinationURL: URL) -> URL {
        let directory = destinationURL.deletingLastPathComponent()
        let base = ".\(destinationURL.lastPathComponent).grove-replace"
        var backupURL = directory.appendingPathComponent("\(base)-\(UUID().uuidString)")
        while fileManager.fileExists(atPath: backupURL.path) {
            backupURL = directory.appendingPathComponent("\(base)-\(UUID().uuidString)")
        }
        return backupURL
    }

    private func mergeDirectory(
        sourceURL: URL,
        into destinationURL: URL,
        operation: TransferOperation,
        resolver: (FileConflict) -> ConflictResolution
    ) throws -> [FileTransferRecord] {
        let childURLs = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: []
        )

        var records: [FileTransferRecord] = []
        for childURL in childURLs {
            records.append(contentsOf: try transfer(childURL, to: destinationURL, operation: operation, resolver: resolver))
        }

        if operation == .move,
           (try? fileManager.contentsOfDirectory(atPath: sourceURL.path).isEmpty) == true {
            try fileManager.removeItem(at: sourceURL)
        }
        return records
    }

    private func canMergeDirectories(sourceURL: URL, destinationURL: URL) -> Bool {
        isPlainDirectory(sourceURL) && isPlainDirectory(destinationURL)
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return false
        }
        return values.isDirectory == true && values.isPackage != true
    }

    /// Transfers `url` into `directory` under its own name, appending " N" on collision. The transfer
    /// itself is attempted for each candidate and retried on an existence error, so there is no TOCTOU
    /// window between checking a name and using it.
    private func transfer(_ url: URL, toUniqueIn directory: URL, operation: TransferOperation) throws -> URL {
        try transferRetryingOnCollision(url, in: directory, operation: operation) { counter in
            self.uniqueName(for: url, counter: counter)
        }
    }

    /// Transfers `url` into `directory` using a "_copy"/"_copy_N" suffix, retrying on collision.
    private func transfer(_ url: URL, toCopySuffixIn directory: URL, operation: TransferOperation) throws -> URL {
        try transferRetryingOnCollision(url, in: directory, operation: operation) { counter in
            self.copySuffixName(for: url, counter: counter)
        }
    }

    private func transferRetryingOnCollision(
        _ url: URL,
        in directory: URL,
        operation: TransferOperation,
        name: (Int) -> String
    ) throws -> URL {
        var counter = 0
        while true {
            let destURL = directory.appendingPathComponent(name(counter))
            do {
                try performTransfer(url, to: destURL, operation: operation)
                return destURL
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                counter += 1
            }
        }
    }

    private func uniqueName(for url: URL, counter: Int) -> String {
        guard counter > 0 else { return url.lastPathComponent }
        let parts = fileNameParts(for: url)
        return fileName(stem: parts.stem, suffix: " \(counter)", fileExtension: parts.fileExtension)
    }

    private func copySuffixName(for url: URL, counter: Int) -> String {
        let parts = fileNameParts(for: url)
        let suffix = counter == 0 ? "_copy" : "_copy_\(counter + 1)"
        return fileName(stem: parts.stem, suffix: suffix, fileExtension: parts.fileExtension)
    }

    private func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        let volumeA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let volumeB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let volumeA = volumeA as? NSObject, let volumeB = volumeB as? NSObject else { return false }
        return volumeA.isEqual(volumeB)
    }

    private func fraction(_ done: Int64, _ total: Int64) -> Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    /// Total byte size of the given items, summing regular-file sizes recursively for directories.
    private func byteSize(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + byteSize(of: $1) }
    }

    private func byteSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            var total: Int64 = 0
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                for case let child as URL in enumerator {
                    if let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       childValues.isRegularFile == true {
                        total += Int64(childValues.fileSize ?? 0)
                    }
                }
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    /// Tracks byte-level progress across a `copyfile(3)` operation.
    private final class CopyfileProgress {
        let total: Int64
        let base: Int64
        let isCancelled: () -> Bool
        let report: (Double) -> Void
        var didCancel = false

        init(total: Int64, base: Int64, isCancelled: @escaping () -> Bool, report: @escaping (Double) -> Void) {
            self.total = total
            self.base = base
            self.isCancelled = isCancelled
            self.report = report
        }
    }

    private struct CancellationSentinel: Error {}

    private static let copyfileProgressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
        guard let ctx = ctx else { return COPYFILE_CONTINUE }
        let tracker = Unmanaged<CopyfileProgress>.fromOpaque(ctx).takeUnretainedValue()
        if tracker.isCancelled() {
            tracker.didCancel = true
            return COPYFILE_QUIT
        }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS || stage == COPYFILE_FINISH {
            var copied = off_t(0)
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            let done = min(tracker.base + Int64(copied), tracker.total)
            tracker.report(tracker.total > 0 ? Double(done) / Double(tracker.total) : 0)
        }
        return COPYFILE_CONTINUE
    }

    /// Copies `source` into `directory` (unique name, retrying on collision) using `copyfile(3)` with a
    /// byte-level progress callback so large single-file copies advance smoothly instead of jumping from
    /// 0% to done. Preserves metadata via COPYFILE_ALL. Cleans up a partial destination on cancel/error.
    private func copyItemWithProgress(_ source: URL, toUniqueIn directory: URL, tracker: CopyfileProgress) throws -> URL {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(Self.copyfileProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(tracker).toOpaque())

        let flags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL))
        var counter = 0
        while true {
            let destURL = directory.appendingPathComponent(uniqueName(for: source, counter: counter))
            let result = source.path.withCString { src in
                destURL.path.withCString { dst in
                    copyfile(src, dst, state, flags)
                }
            }
            if result == 0 {
                return destURL
            }
            let err = errno
            if tracker.didCancel {
                try? fileManager.removeItem(at: destURL)
                throw CancellationSentinel()
            }
            if err == EEXIST {
                counter += 1
                continue
            }
            try? fileManager.removeItem(at: destURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))])
        }
    }

    private func fileNameParts(for url: URL) -> (stem: String, fileExtension: String) {
        let filename = url.lastPathComponent
        let ext = url.pathExtension

        guard !ext.isEmpty,
              filename.count > ext.count + 1,
              filename.hasSuffix(".\(ext)") else {
            return (filename, "")
        }

        return (String(filename.dropLast(ext.count + 1)), ext)
    }

    private func fileName(stem: String, suffix: String, fileExtension ext: String) -> String {
        ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
    }

    private func validatedFileName(_ name: String) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw FileOperationError.invalidFileName(name)
        }
        return name
    }

    func undoTransferRecords(_ records: [FileTransferRecord]) throws {
        for record in records.reversed() where record.isUndoable {
            switch record.undoBehavior {
            case .none:
                continue
            case .trashDestination:
                if fileManager.fileExists(atPath: record.destinationURL.path) {
                    _ = try moveToTrash([record.destinationURL])
                }
            case .moveBackToSource:
                guard fileManager.fileExists(atPath: record.destinationURL.path) else { continue }
                let originalDirectory = record.sourceURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: record.sourceURL.path) {
                    _ = try transfer(record.destinationURL, toUniqueIn: originalDirectory, operation: .move)
                } else {
                    try fileManager.moveItem(at: record.destinationURL, to: record.sourceURL)
                }
            }
        }
    }

    private func archiveExtractionFolderName(for archiveURL: URL) -> String {
        let filename = archiveURL.lastPathComponent
        let lowercasedFilename = filename.lowercased()
        let archiveExtensions = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst",
            ".tgz", ".tbz2", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar"
        ]

        for archiveExtension in archiveExtensions where lowercasedFilename.hasSuffix(archiveExtension) {
            let endIndex = filename.index(filename.endIndex, offsetBy: -archiveExtension.count)
            let baseName = String(filename[..<endIndex])
            return baseName.isEmpty ? archiveURL.deletingPathExtension().lastPathComponent : baseName
        }

        return archiveURL.deletingPathExtension().lastPathComponent
    }

    private func createUniqueDirectory(named name: String, in directory: URL) throws -> URL {
        let baseName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Archive" : name
        var counter = 0

        while true {
            let folderName = counter == 0 ? baseName : "\(baseName) \(counter)"
            let folderURL = directory.appendingPathComponent(folderName, isDirectory: true)

            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
                return folderURL
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                counter += 1
            }
        }
    }

    private func extractArchive(_ archiveURL: URL, to destinationDir: URL, password: String?) throws {
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

    func decompressToUniqueFolder(_ archiveURL: URL, password: String? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        backgroundQueue.async {
            var destinationDir: URL?

            do {
                let parentDir = archiveURL.deletingLastPathComponent()
                let folderName = self.archiveExtractionFolderName(for: archiveURL)
                let createdDir = try self.createUniqueDirectory(named: folderName, in: parentDir)
                destinationDir = createdDir

                try self.extractArchive(archiveURL, to: createdDir, password: password)

                DispatchQueue.main.async { completion(.success(createdDir)) }
            } catch {
                if let destinationDir = destinationDir {
                    try? self.fileManager.removeItem(at: destinationDir)
                }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func decompress(_ archiveURL: URL, to destinationDir: URL, password: String? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        backgroundQueue.async {
            do {
                try self.extractArchive(archiveURL, to: destinationDir, password: password)

                DispatchQueue.main.async { completion(.success(destinationDir)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Checksum

    enum ChecksumAlgorithm {
        case md5
        case sha256
    }

    func computeChecksum(for url: URL, algorithm: ChecksumAlgorithm, completion: @escaping (Result<String, Error>) -> Void) {
        backgroundQueue.async {
            do {
                let hex = try Self.streamingChecksum(for: url, algorithm: algorithm)
                DispatchQueue.main.async { completion(.success(hex)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func streamingChecksum(for url: URL, algorithm: ChecksumAlgorithm) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        switch algorithm {
        case .md5:
            var context = CC_MD5_CTX()
            CC_MD5_Init(&context)
            try updateDigest(from: fileHandle) { data in
                data.withUnsafeBytes { buffer in
                    _ = CC_MD5_Update(&context, buffer.baseAddress, CC_LONG(buffer.count))
                }
            }
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            CC_MD5_Final(&digest, &context)
            return digest.map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var context = CC_SHA256_CTX()
            CC_SHA256_Init(&context)
            try updateDigest(from: fileHandle) { data in
                data.withUnsafeBytes { buffer in
                    _ = CC_SHA256_Update(&context, buffer.baseAddress, CC_LONG(buffer.count))
                }
            }
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256_Final(&digest, &context)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func updateDigest(from fileHandle: FileHandle, update: (Data) -> Void) throws {
        while true {
            let data = fileHandle.readData(ofLength: 1_048_576)
            if data.isEmpty {
                return
            }
            update(data)
        }
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func availableDiskCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else {
            return nil
        }
        return Int64(capacity)
    }

    func availableDiskSpace(at url: URL) -> String? {
        guard let capacity = availableDiskCapacity(at: url) else { return nil }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }
}
