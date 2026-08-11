import Foundation
import AppKit
import CommonCrypto
import Darwin
import OSLog

@_silgen_name("acl_delete_fd_np")
private func groveACLDeleteFD(_ descriptor: Int32, _ type: acl_type_t) -> Int32

final class FileOperationService {

    enum ArchiveSanitationFailureStage {
        case directory
        case regular
        case symbolicLink
    }

    enum ArchiveQuarantineSanitationStatus: String, Codable {
        case intent
        case registered
        case sanitized
        case failed
    }

    struct ArchiveQuarantineRecord: Codable, Equatable {
        let id: UUID
        let transactionID: UUID
        var path: String
        var sourceParentPath: String?
        var sourceName: String?
        let device: UInt64
        let inode: UInt64
        let registeredAt: Date
        var sanitationStatus: ArchiveQuarantineSanitationStatus
        var sanitationUpdatedAt: Date
        var sanitationError: String?
    }

    private final class ArchivePipeCollector {
        private let lock = NSLock()
        private var data = Data()

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    struct PasswordProtectedArchiveInvocation {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let standardInput: Data
        let archiveToolPath: String
        let archiveToolArguments: [String]
    }

    enum ArchiveControlRecord: Equatable {
        case childPID(pid_t)
        case authenticated
    }

    enum ArchiveControlRecordError: LocalizedError {
        case malformed
        case oversized

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "Archive control channel sent a malformed record."
            case .oversized:
                return "Archive control channel exceeded its size limit."
            }
        }
    }

    /// Incrementally parses the private Expect-to-Swift control channel. Records are emitted only after
    /// a newline, so a fragmented PID can never be mistaken for a shorter, valid process identifier.
    struct ArchiveControlRecordParser {
        private var buffer = Data()
        private let maximumRecordBytes: Int
        private var didEmitChildPID = false
        private var didEmitAuthentication = false

        init(maximumRecordBytes: Int = 256) {
            self.maximumRecordBytes = maximumRecordBytes
        }

        mutating func append(_ data: Data) throws -> [ArchiveControlRecord] {
            buffer.append(data)
            var records: [ArchiveControlRecord] = []

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                var lineData = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if lineData.last == 0x0D { lineData.removeLast() }
                guard !lineData.isEmpty, lineData.count <= maximumRecordBytes,
                      let line = String(data: lineData, encoding: .utf8) else {
                    throw ArchiveControlRecordError.malformed
                }

                if line == "GROVE_ARCHIVE_AUTHENTICATED" {
                    guard didEmitChildPID, !didEmitAuthentication else {
                        throw ArchiveControlRecordError.malformed
                    }
                    didEmitAuthentication = true
                    records.append(.authenticated)
                    continue
                }

                let pidPrefix = "GROVE_ARCHIVE_CHILD_PID:"
                guard line.hasPrefix(pidPrefix) else {
                    throw ArchiveControlRecordError.malformed
                }
                let pidText = line.dropFirst(pidPrefix.count)
                guard !pidText.isEmpty,
                      pidText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                      let pid = pid_t(pidText), pid > 0,
                      !didEmitChildPID, !didEmitAuthentication else {
                    throw ArchiveControlRecordError.malformed
                }
                didEmitChildPID = true
                records.append(.childPID(pid))
            }

            guard buffer.count <= maximumRecordBytes else {
                throw ArchiveControlRecordError.oversized
            }
            return records
        }

        mutating func finish() throws {
            guard buffer.isEmpty else {
                throw ArchiveControlRecordError.malformed
            }
        }
    }

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
        case invalidDestination(operationIsMove: Bool)
        case nameCollision(String)
        case cancelled(records: [FileTransferRecord])
        case partialFailure(records: [FileTransferRecord], underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidFileName(let name):
                return "Invalid file name: \(name)"
            case .invalidDestination(let operationIsMove):
                return operationIsMove
                    ? "You can't move an item into itself."
                    : "You can't copy an item into itself."
            case .nameCollision(let name):
                return "The name \"\(name)\" would be used by more than one item."
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
    static let archiveQuarantineNeedsAttentionNotification = Notification.Name(
        "com.goosefraba.grove.archiveQuarantineNeedsAttention"
    )
    private let retainedCleanupLock = NSLock()
    private var retainedArchiveCleanupTrees: [URL] = []
    private static let maximumResolvedArchiveQuarantineAuditRecords = 8
    private var quarantineRegistryURLOverride: URL?
    private var archiveQuarantineMaintenanceTimer: DispatchSourceTimer?
    private var archiveRetirementDirectoriesByDevice: [UInt64: URL] = [:]
    private var forceArchiveQuarantineSiblingFallbackForTesting = false
    private var forceArchiveCleanupDescriptorPathFailureForTesting = false
    private var archiveSanitationFailureStageForTesting: ArchiveSanitationFailureStage?
    private var archiveAfterSanitationInventoryForTesting: ((URL) throws -> Void)?
    private var archiveSymlinkBeforeSwapForTesting: ((URL) throws -> Void)?
    private var archiveSymlinkBeforeSensitiveRelocationForTesting: ((URL) throws -> Void)?
    private var forceArchiveSymlinkSwapFailureForTesting = false
    private let fileManager = FileManager.default
    private let directoryQueue = DispatchQueue(label: "com.grove.fileops.directory", qos: .userInitiated)
    private let backgroundQueue = DispatchQueue(label: "com.grove.fileops", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    private var archiveQuarantineRegistryURL: URL {
        if let quarantineRegistryURLOverride { return quarantineRegistryURLOverride }
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("Grove", isDirectory: true)
            .appendingPathComponent("archive-quarantines.plist")
    }

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
        try moveToTrashRecords(urls).map(\.destinationURL)
    }

    /// Trashes each URL, returning a record per successfully-trashed item. On a mid-loop
    /// failure it throws `.partialFailure` carrying the records completed so far, so the
    /// caller can register undo for them instead of silently losing the completed work.
    /// Items whose trash location is unknown (nil `resultingItemURL`) are skipped rather
    /// than paired positionally, avoiding restore-to-wrong-location misalignment.
    func moveToTrashRecords(_ urls: [URL]) throws -> [FileTransferRecord] {
        var records: [FileTransferRecord] = []
        for url in urls {
            var trashURL: NSURL?
            do {
                try fileManager.trashItem(at: url, resultingItemURL: &trashURL)
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
            if let trashURL = trashURL as URL? {
                records.append(FileTransferRecord(sourceURL: url, destinationURL: trashURL, undoBehavior: .moveBackToSource))
            }
        }
        return records
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

    struct BatchRenameEntry {
        let url: URL
        let originalName: String
        let newName: String
        let isCollision: Bool

        var isChanged: Bool { newName != originalName }
    }

    /// Computes the target name for each URL and flags collisions: two or more items that
    /// would end up with the same name, or a changed name that would clash with an existing
    /// sibling not itself being renamed. Comparison is case-insensitive to match the default
    /// (case-insensitive) macOS filesystem. Shared by the preview UI and `batchRename`.
    func batchRenamePreview(_ urls: [URL], find: String, replace: String, useRegex: Bool) throws -> [BatchRenameEntry] {
        let regex = useRegex ? try NSRegularExpression(pattern: find) : nil
        let targets: [(url: URL, original: String, new: String)] = urls.map { url in
            let original = url.lastPathComponent
            let renamed = renamedString(for: original, find: find, replace: replace, useRegex: useRegex, regex: regex)
            let new = (renamed.isEmpty || find.isEmpty) ? original : renamed
            return (url, original, new)
        }

        // Count final names (unchanged items keep their original name).
        var nameCounts: [String: Int] = [:]
        for target in targets {
            nameCounts[target.new.lowercased(), default: 0] += 1
        }
        // Lowercased to match the case-insensitive fileExists check below, so a pure
        // case-only rename (readme.txt -> README.txt) isn't flagged as a self-collision.
        let renameSet = Set(targets.map { $0.url.standardizedFileURL.path.lowercased() })

        return targets.map { target in
            var collides = nameCounts[target.new.lowercased(), default: 0] > 1
            if !collides, target.new != target.original {
                let destURL = target.url.deletingLastPathComponent().appendingPathComponent(target.new)
                if fileManager.fileExists(atPath: destURL.path),
                   !renameSet.contains(destURL.standardizedFileURL.path.lowercased()) {
                    collides = true
                }
            }
            return BatchRenameEntry(url: target.url, originalName: target.original, newName: target.new, isCollision: collides)
        }
    }

    private func renamedString(for original: String, find: String, replace: String, useRegex: Bool, regex: NSRegularExpression?) -> String {
        guard !find.isEmpty else { return original }
        if useRegex {
            guard let regex else { return original }
            let range = NSRange(original.startIndex..., in: original)
            return regex.stringByReplacingMatches(in: original, range: range, withTemplate: replace)
        }
        return original.replacingOccurrences(of: find, with: replace)
    }

    func batchRename(_ urls: [URL], find: String, replace: String, useRegex: Bool) throws -> [FileTransferRecord] {
        let entries = try batchRenamePreview(urls, find: find, replace: replace, useRegex: useRegex)
        if let collision = entries.first(where: \.isCollision) {
            throw FileOperationError.nameCollision(collision.newName)
        }

        var records: [FileTransferRecord] = []
        for entry in entries where entry.isChanged {
            do {
                let newURL = try rename(entry.url, to: entry.newName)
                records.append(FileTransferRecord(sourceURL: entry.url, destinationURL: newURL, undoBehavior: .moveBackToSource))
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
        }
        return records
    }

    // MARK: - Progress Operations

    func copyWithProgress(_ urls: [URL], to destination: URL, progress: @escaping (Double, String) -> Void, cancelled: @escaping () -> Bool) throws -> [URL] {
        try validateTransferDestination(urls, to: destination, operationIsMove: false)
        var records: [FileTransferRecord] = []
        let totalBytes = byteSize(of: urls)
        var completedBytes: Int64 = 0
        for url in urls {
            if cancelled() {
                throw FileOperationError.cancelled(records: records)
            }
            let sourceBytes = byteSize(of: url)
            progress(fraction(completedBytes, totalBytes), url.lastPathComponent)
            let tracker = CopyfileProgress(total: totalBytes, base: completedBytes, isCancelled: cancelled) {
                progress($0, url.lastPathComponent)
            }
            do {
                let destURL = try copyItemWithProgress(url, toUniqueIn: destination, tracker: tracker)
                records.append(FileTransferRecord(sourceURL: url, destinationURL: destURL, undoBehavior: .trashDestination))
            } catch is CancellationSentinel {
                throw FileOperationError.cancelled(records: records)
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
            completedBytes += sourceBytes
        }
        progress(1.0, "")
        return records.map(\.destinationURL)
    }

    func moveWithProgress(_ urls: [URL], to destination: URL, progress: @escaping (Double, String) -> Void, cancelled: @escaping () -> Bool) throws -> [URL] {
        try validateTransferDestination(urls, to: destination, operationIsMove: true)
        var records: [FileTransferRecord] = []
        let totalBytes = byteSize(of: urls)
        var completedBytes: Int64 = 0
        for url in urls {
            if cancelled() {
                throw FileOperationError.cancelled(records: records)
            }
            let sourceBytes = byteSize(of: url)
            progress(fraction(completedBytes, totalBytes), url.lastPathComponent)
            do {
                let destURL: URL
                if onSameVolume(url, destination) {
                    // Same volume: moveItem is an instant rename, no byte progress needed.
                    destURL = try transfer(url, toUniqueIn: destination, operation: .move)
                } else {
                    // Cross volume move is a copy + delete; stream byte progress then remove the source.
                    let tracker = CopyfileProgress(total: totalBytes, base: completedBytes, isCancelled: cancelled) {
                        progress($0, url.lastPathComponent)
                    }
                    destURL = try copyItemWithProgress(url, toUniqueIn: destination, tracker: tracker)
                    try fileManager.removeItem(at: url)
                }
                records.append(FileTransferRecord(sourceURL: url, destinationURL: destURL, undoBehavior: .moveBackToSource))
            } catch is CancellationSentinel {
                throw FileOperationError.cancelled(records: records)
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
            completedBytes += sourceBytes
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

    /// True when `destinationPath` is `sourcePath` itself or lives inside its subtree.
    /// Uses path-component boundaries so `/foo` is not treated as an ancestor of `/foobar`.
    static func destination(_ destinationPath: String, isWithin sourcePath: String) -> Bool {
        let dest = (destinationPath as NSString).standardizingPath
        let source = (sourcePath as NSString).standardizingPath
        if dest == source { return true }
        return dest.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    /// Rejects transfers where the destination is one of the sources or nested inside it
    /// (Finder-style guard). Sibling copies into the same parent remain allowed.
    private func validateTransferDestination(_ urls: [URL], to destination: URL, operationIsMove: Bool) throws {
        let destPath = destination.standardizedFileURL.path
        for url in urls where Self.destination(destPath, isWithin: url.standardizedFileURL.path) {
            throw FileOperationError.invalidDestination(operationIsMove: operationIsMove)
        }
    }

    /// Conflict-aware copy/move that also reports progress and honours cancellation, so it
    /// can run on a background queue behind a progress sheet. On cancel it throws
    /// `.cancelled` carrying the records completed so far (partial-undo).
    func transferResolvingConflictsWithProgress(
        _ urls: [URL],
        to destination: URL,
        isMove: Bool,
        resolver: (FileConflict) -> ConflictResolution,
        progress: @escaping (Double, String) -> Void,
        cancelled: @escaping () -> Bool
    ) throws -> [FileTransferRecord] {
        try transfer(
            urls,
            to: destination,
            operation: isMove ? .move : .copy,
            resolver: resolver,
            progress: progress,
            cancelled: cancelled
        )
    }

    /// Byte-progress context threaded through the conflict-aware transfer so single-file copies
    /// advance smoothly (via `copyfile(3)`) instead of jumping per item. `base` is the number of
    /// bytes already fully transferred before the current item.
    private struct TransferByteProgress {
        let total: Int64
        let base: Int64
        let report: (Double, String) -> Void
        let cancelled: () -> Bool
    }

    private func copyTracker(_ byteProgress: TransferByteProgress?, name: String) -> CopyfileProgress? {
        guard let byteProgress else { return nil }
        return CopyfileProgress(total: byteProgress.total, base: byteProgress.base, isCancelled: byteProgress.cancelled) {
            byteProgress.report($0, name)
        }
    }

    private func transfer(
        _ urls: [URL],
        to destination: URL,
        operation: TransferOperation,
        resolver: (FileConflict) -> ConflictResolution,
        progress: ((Double, String) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) throws -> [FileTransferRecord] {
        try validateTransferDestination(urls, to: destination, operationIsMove: operation == .move)
        var records: [FileTransferRecord] = []
        let totalBytes = byteSize(of: urls)
        var completedBytes: Int64 = 0

        for url in urls {
            if cancelled?() == true {
                throw FileOperationError.cancelled(records: records)
            }
            let sourceBytes = byteSize(of: url)
            progress?(fraction(completedBytes, totalBytes), url.lastPathComponent)
            // Only route through the byte-level copy path when a caller is actually consuming
            // progress; the plain conflict-resolving copy/move APIs keep FileManager semantics.
            let byteProgress = progress.map { report in
                TransferByteProgress(
                    total: totalBytes,
                    base: completedBytes,
                    report: report,
                    cancelled: cancelled ?? { false }
                )
            }
            do {
                records.append(contentsOf: try transfer(url, to: destination, operation: operation, resolver: resolver, byteProgress: byteProgress))
            } catch is CancellationSentinel {
                throw FileOperationError.cancelled(records: records)
            } catch {
                throw FileOperationError.partialFailure(records: records, underlying: error)
            }
            completedBytes += sourceBytes
        }
        progress?(1.0, "")

        return records
    }

    private func transfer(
        _ url: URL,
        to directory: URL,
        operation: TransferOperation,
        resolver: (FileConflict) -> ConflictResolution,
        byteProgress: TransferByteProgress? = nil
    ) throws -> [FileTransferRecord] {
        let destinationURL = directory.appendingPathComponent(url.lastPathComponent)

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            // Route plain copies through the byte-progress copy path; moves are an instant rename
            // on the same volume (and FileManager handles cross-volume) so item granularity suffices.
            if operation == .copy, let tracker = copyTracker(byteProgress, name: url.lastPathComponent) {
                let destURL = try copyItemWithProgress(url, toUniqueIn: directory, tracker: tracker)
                return [transferRecord(sourceURL: url, destinationURL: destURL, operation: operation)]
            }
            try performTransfer(url, to: destinationURL, operation: operation)
            return [transferRecord(sourceURL: url, destinationURL: destinationURL, operation: operation)]
        }

        guard url.standardizedFileURL != destinationURL.standardizedFileURL else {
            guard operation == .copy else {
                return []
            }
            let copyURL = try transfer(url, toCopySuffixIn: directory, operation: operation, tracker: copyTracker(byteProgress, name: url.lastPathComponent))
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
            let uniqueURL = try transfer(url, toUniqueIn: directory, operation: operation, tracker: copyTracker(byteProgress, name: url.lastPathComponent))
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
                let uniqueURL = try transfer(url, toUniqueIn: directory, operation: operation, tracker: copyTracker(byteProgress, name: url.lastPathComponent))
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
        // Same-volume moves can be replaced atomically without staging a copy.
        if operation == .move, onSameVolume(sourceURL, destinationURL) {
            try fileManager.replaceItem(at: destinationURL, withItemAt: sourceURL, backupItemName: nil, options: [], resultingItemURL: nil)
            return
        }

        // Otherwise stage the incoming item in a system-managed replacement directory (same volume as
        // the destination) and swap it in atomically. FileManager.replaceItem restores the original on
        // failure and never leaves a user-visible backup file stranded on a crash.
        let stagingDir = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
        defer { try? fileManager.removeItem(at: stagingDir) }

        let stagedURL = stagingDir.appendingPathComponent(destinationURL.lastPathComponent)
        try performTransfer(sourceURL, to: stagedURL, operation: operation)
        do {
            try fileManager.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: nil, options: [], resultingItemURL: nil)
        } catch {
            // A failed move already relocated the source into staging; the defer would delete it with the
            // rest of the staging dir, destroying the user's only copy. Restore it before rethrowing.
            if operation == .move {
                try? fileManager.moveItem(at: stagedURL, to: sourceURL)
            }
            throw error
        }
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
    private func transfer(_ url: URL, toUniqueIn directory: URL, operation: TransferOperation, tracker: CopyfileProgress? = nil) throws -> URL {
        if operation == .copy, let tracker {
            return try copyItemWithProgress(url, toUniqueIn: directory, tracker: tracker)
        }
        return try transferRetryingOnCollision(url, in: directory, operation: operation) { counter in
            self.uniqueName(for: url, counter: counter)
        }
    }

    /// Transfers `url` into `directory` using a "_copy"/"_copy_N" suffix, retrying on collision.
    private func transfer(_ url: URL, toCopySuffixIn directory: URL, operation: TransferOperation, tracker: CopyfileProgress? = nil) throws -> URL {
        if operation == .copy, let tracker {
            return try copyItemWithProgress(url, toCopySuffixIn: directory, tracker: tracker)
        }
        return try transferRetryingOnCollision(url, in: directory, operation: operation) { counter in
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
        let status: (() -> Void)?
        var didCancel = false

        init(
            total: Int64,
            base: Int64,
            isCancelled: @escaping () -> Bool,
            report: @escaping (Double) -> Void,
            status: (() -> Void)? = nil
        ) {
            self.total = total
            self.base = base
            self.isCancelled = isCancelled
            self.report = report
            self.status = status
        }
    }

    private struct CancellationSentinel: Error {}

    private static let copyfileProgressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
        guard let ctx = ctx else { return COPYFILE_CONTINUE }
        let tracker = Unmanaged<CopyfileProgress>.fromOpaque(ctx).takeUnretainedValue()
        tracker.status?()
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
        try copyItemWithProgress(source, in: directory, tracker: tracker) { counter in
            self.uniqueName(for: source, counter: counter)
        }
    }

    /// Byte-progress copy that names the destination with a "_copy"/"_copy_N" suffix, retrying on collision.
    private func copyItemWithProgress(_ source: URL, toCopySuffixIn directory: URL, tracker: CopyfileProgress) throws -> URL {
        try copyItemWithProgress(source, in: directory, tracker: tracker) { counter in
            self.copySuffixName(for: source, counter: counter)
        }
    }

    private func copyItemWithProgress(_ source: URL, in directory: URL, tracker: CopyfileProgress, name: (Int) -> String) throws -> URL {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(Self.copyfileProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(tracker).toOpaque())

        let flags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL))
        var counter = 0
        while true {
            let destURL = directory.appendingPathComponent(name(counter))
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

    /// Re-applies the original operation captured by `records` — the inverse of
    /// `undoTransferRecords` — so NSUndoManager's redo step round-trips copy/move/rename/trash.
    func redoTransferRecords(_ records: [FileTransferRecord]) throws {
        for record in records where record.isUndoable {
            switch record.undoBehavior {
            case .none:
                continue
            case .trashDestination:
                // Original op was a copy/duplicate: recreate the destination from the source.
                guard fileManager.fileExists(atPath: record.sourceURL.path),
                      !fileManager.fileExists(atPath: record.destinationURL.path) else { continue }
                try fileManager.copyItem(at: record.sourceURL, to: record.destinationURL)
            case .moveBackToSource:
                // Original op was a move/rename/trash: move the item from source to destination again.
                guard fileManager.fileExists(atPath: record.sourceURL.path) else { continue }
                try fileManager.createDirectory(at: record.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: record.sourceURL, to: record.destinationURL)
            }
        }
    }

    private func archiveExtractionFolderName(for archiveURL: URL) -> String {
        let filename = archiveURL.lastPathComponent
        let lowercasedFilename = filename.lowercased()
        // ditto -x -k only extracts ZIP archives; advertising other formats is dead capability.
        let archiveExtensions = [".zip"]

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

    private func extractArchive(
        _ archiveURL: URL,
        to destinationDir: URL,
        password: String?,
        operationTimeout: TimeInterval?,
        cancellationRequested: @escaping () -> Bool,
        hooks: ArchiveExtractionHooks
    ) throws {
        let archiveMetadataDirectoryName = try encryptedArchiveMetadataLocator(in: archiveURL)
        if (password?.isEmpty == false) || archiveMetadataDirectoryName != nil {
            // Grove ZIP metadata is untrusted until the whole private tree has been extracted and
            // validated. Never apply it in the caller's destination: a crafted manifest could otherwise
            // target a pre-existing item that was not a member of this archive. Item-replacement storage
            // keeps the transaction on the destination volume in the common case.
            // Keep external unzip entirely outside the mutable destination namespace. The resulting
            // tree is later merged only through retained directory descriptors.
            let transactionParent = fileManager.temporaryDirectory
            let transactionParentDescriptor = open(
                transactionParent.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC
            )
            guard transactionParentDescriptor >= 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            let transaction: (url: URL, identity: ArchiveTreeIdentity)
            do {
                transaction = try createSiblingArchiveTransaction(
                    in: transactionParent,
                    parentDescriptor: transactionParentDescriptor,
                    prefix: ".grove-extract"
                )
            } catch {
                close(transactionParentDescriptor)
                throw error
            }
            let transactionDirectory = transaction.url
            let transactionHandle = ArchivePrivateTreeHandle(
                parentDescriptor: transactionParentDescriptor,
                name: transaction.url.lastPathComponent,
                identity: transaction.identity
            )
            defer { close(transactionHandle.parentDescriptor) }
            var shouldRemoveTransaction = true
            defer {
                if shouldRemoveTransaction {
                    try? identityBoundRemoveArchiveTree(
                        named: transactionHandle.name,
                        in: transactionHandle.parentDescriptor,
                        expected: transactionHandle.identity,
                        displayURL: transactionDirectory,
                        treeRetained: hooks.cleanupTreeRetained
                    )
                }
            }
            hooks.extractionDirectoryCreated?(transactionDirectory)
            let boundTransactionDirectory = try descriptorRelativeURL(
                parentDescriptor: transactionHandle.parentDescriptor,
                name: transactionHandle.name
            )
            if let password, !password.isEmpty {
                try runPasswordProtectedArchiveTool(
                    "/usr/bin/unzip",
                    arguments: ["-o", archiveURL.path, "-d", boundTransactionDirectory.path],
                    password: password,
                    errorDomain: "com.grove.decompress",
                    fallbackMessage: "Decompression failed",
                    operationTimeout: operationTimeout,
                    expectedPasswordPrompts: 1,
                    cancellationRequested: cancellationRequested
                )
            } else {
                try runArchiveTool(
                    "/usr/bin/ditto",
                    arguments: ["-x", "-k", archiveURL.path, boundTransactionDirectory.path],
                    errorDomain: "com.grove.decompress",
                    fallbackMessage: "Decompression failed",
                    cancellationRequested: cancellationRequested
                )
            }
            if let metadataDirectoryName = archiveMetadataDirectoryName {
                try rehydrateEncryptedArchiveMetadata(
                    in: boundTransactionDirectory,
                    metadataDirectoryName: metadataDirectoryName,
                    cancellationRequested: cancellationRequested
                )
            }
            guard !cancellationRequested() else {
                throw archiveCancellationError(domain: "com.grove.decompress")
            }
            try transactionallyMergeExtractedArchive(
                boundTransactionDirectory,
                into: destinationDir,
                cancellationRequested: cancellationRequested,
                hooks: hooks
            )
            shouldRemoveTransaction = false
            do {
                try identityBoundRemoveArchiveTree(
                    named: transactionHandle.name,
                    in: transactionHandle.parentDescriptor,
                    expected: transactionHandle.identity,
                    displayURL: transactionDirectory,
                    treeRetained: hooks.cleanupTreeRetained
                )
            } catch {
                // Publishing already completed. Cleanup is durably accounted separately and must
                // never turn a committed extraction into an API failure (or invite a caller to erase
                // the newly-published destination while trying to roll back).
                reportPostCommitArchiveCleanupWarning(error, hooks: hooks)
            }
        } else {
            try runArchiveTool(
                "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, destinationDir.path],
                errorDomain: "com.grove.decompress",
                fallbackMessage: "Decompression failed",
                cancellationRequested: cancellationRequested
            )
        }
    }

    private func transactionallyMergeExtractedArchive(
        _ extractedDirectory: URL,
        into destination: URL,
        cancellationRequested: @escaping () -> Bool,
        hooks: ArchiveExtractionHooks
    ) throws {
        let parent = destination.deletingLastPathComponent()
        guard parent.standardizedFileURL.path != destination.standardizedFileURL.path else {
            throw NSError(
                domain: "com.grove.decompress",
                code: Int(ENOTSUP),
                userInfo: [NSLocalizedDescriptionKey: "Transactional extraction directly into a filesystem root is unsupported."]
            )
        }
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        defer { close(parentDescriptor) }
        var parentInfo = stat()
        guard fstat(parentDescriptor, &parentInfo) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        let initialParentIdentity = ArchiveTreeIdentity(device: parentInfo.st_dev, inode: parentInfo.st_ino)
        let destinationName = destination.lastPathComponent

        var initialDestinationInfo = stat()
        let destinationStatus = destinationName.withCString {
            fstatat(parentDescriptor, $0, &initialDestinationInfo, AT_SYMLINK_NOFOLLOW)
        }
        let initialDestinationIdentity: ArchiveTreeIdentity?
        if destinationStatus == 0 {
            guard initialDestinationInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw NSError(
                    domain: "com.grove.decompress",
                    code: Int(ENOTDIR),
                    userInfo: [NSLocalizedDescriptionKey: "The archive destination must be a directory."]
                )
            }
            initialDestinationIdentity = ArchiveTreeIdentity(
                device: initialDestinationInfo.st_dev,
                inode: initialDestinationInfo.st_ino
            )
        } else {
            let errorCode = errno
            guard errorCode == ENOENT else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
                )
            }
            initialDestinationIdentity = nil
        }

        let replacement = try createSiblingArchiveTransaction(
            in: parent,
            parentDescriptor: parentDescriptor,
            prefix: ".grove-extract-replacement"
        )
        let replacementName = replacement.url.lastPathComponent
        let preparedReplacementIdentity = replacement.identity
        var expectedCleanupIdentity = preparedReplacementIdentity
        var shouldRemoveReplacement = true
        defer {
            if shouldRemoveReplacement {
                try? identityBoundRemoveArchiveTree(
                    named: replacementName,
                    in: parentDescriptor,
                    expected: expectedCleanupIdentity,
                    displayURL: replacement.url,
                    treeRetained: hooks.cleanupTreeRetained
                )
            }
        }
        hooks.replacementDirectoryCreated?(replacement.url)
        let boundReplacement = try descriptorRelativeURL(
            parentDescriptor: parentDescriptor,
            name: replacementName
        )
        let replacementDescriptor = replacementName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard replacementDescriptor >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        defer { close(replacementDescriptor) }

        try hooks.destinationPreparationStarted?()
        var destinationDescriptor: Int32?
        if initialDestinationIdentity != nil {
            let openedDestination = destinationName.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard openedDestination >= 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            destinationDescriptor = openedDestination
        }
        defer {
            if let destinationDescriptor { close(destinationDescriptor) }
        }
        guard !cancellationRequested() else {
            throw archiveCancellationError(domain: "com.grove.decompress")
        }
        var destinationRootInfo: stat?
        if let destinationDescriptor {
            var info = stat()
            guard fstat(destinationDescriptor, &info) == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            destinationRootInfo = info
            let metadataFlags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_METADATA))
            guard fcopyfile(destinationDescriptor, replacementDescriptor, nil, metadataFlags) == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
        }

        var extractedDescriptorForFinalMetadata: Int32?
        defer {
            if let extractedDescriptorForFinalMetadata { close(extractedDescriptorForFinalMetadata) }
        }
        if let finalMerge = hooks.finalMerge {
            if let destinationDescriptor {
                let copyContext = ArchiveCopyContext(
                    cancellationRequested: cancellationRequested,
                    status: hooks.internalCopyStatus
                )
                try copyArchiveDirectoryContents(
                    from: destinationDescriptor,
                    to: replacementDescriptor,
                    context: copyContext,
                    overwriteExisting: true
                )
            }
            try finalMerge(extractedDirectory, boundReplacement, cancellationRequested)
        } else {
            let extractedDescriptor = open(
                extractedDirectory.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard extractedDescriptor >= 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            extractedDescriptorForFinalMetadata = extractedDescriptor
            let copyContext = ArchiveCopyContext(
                cancellationRequested: cancellationRequested,
                status: hooks.internalCopyStatus
            )
            try copyArchiveDirectoryContents(
                from: extractedDescriptor,
                to: replacementDescriptor,
                context: copyContext,
                overwriteExisting: true
            )
            // Overlay the archive onto the old destination without deleting names: archive members
            // were copied first, then destination-only members fill the remaining gaps.
            if let destinationDescriptor {
                let destinationCopyContext = ArchiveCopyContext(
                    cancellationRequested: cancellationRequested,
                    status: hooks.internalCopyStatus
                )
                try copyArchiveDirectoryContents(
                    from: destinationDescriptor,
                    to: replacementDescriptor,
                    context: destinationCopyContext,
                    overwriteExisting: false
                )
                try reapplyArchiveDirectoryMetadata(
                    from: extractedDescriptor,
                    to: replacementDescriptor,
                    cancellationRequested: cancellationRequested
                )
            }
        }
        if let destinationRootInfo {
            guard fchmod(replacementDescriptor, destinationRootInfo.st_mode & 0o7777) == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            let times = [destinationRootInfo.st_atimespec, destinationRootInfo.st_mtimespec]
            let timeResult = times.withUnsafeBufferPointer {
                futimens(replacementDescriptor, $0.baseAddress)
            }
            guard timeResult == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
        }
        if let extractedDescriptorForFinalMetadata, destinationDescriptor != nil {
            try reapplyArchiveDirectoryMetadata(
                from: extractedDescriptorForFinalMetadata,
                to: replacementDescriptor,
                cancellationRequested: cancellationRequested
            )
        }
        try hooks.destinationPreparationFinished?()
        guard !cancellationRequested() else {
            throw archiveCancellationError(domain: "com.grove.decompress")
        }

        try hooks.immediatelyBeforeCommit?(replacement.url, destination)
        guard !cancellationRequested() else {
            throw archiveCancellationError(domain: "com.grove.decompress")
        }
        try verifyArchiveParentNamespace(
            parent,
            expected: initialParentIdentity
        )
        try verifyArchiveTreeIdentity(
            named: replacementName,
            in: parentDescriptor,
            expected: preparedReplacementIdentity,
            displayURL: replacement.url
        )

        if let initialDestinationIdentity {
            let swapResult = replacementName.withCString { replacementName in
                destinationName.withCString { destinationName in
                    renameatx_np(
                        parentDescriptor,
                        replacementName,
                        parentDescriptor,
                        destinationName,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapResult == 0 else {
                let errorCode = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
                )
            }

            var swappedOutInfo = stat()
            let identityStatus = replacementName.withCString { replacementName in
                fstatat(parentDescriptor, replacementName, &swappedOutInfo, AT_SYMLINK_NOFOLLOW)
            }
            let identityMatches = identityStatus == 0
                && ArchiveTreeIdentity(device: swappedOutInfo.st_dev, inode: swappedOutInfo.st_ino)
                    == initialDestinationIdentity
            guard identityMatches else {
                let identityErrorCode = identityStatus == 0 ? ESTALE : errno
                let rollbackResult = replacementName.withCString { replacementName in
                    destinationName.withCString { destinationName in
                        renameatx_np(
                            parentDescriptor,
                            replacementName,
                            parentDescriptor,
                            destinationName,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard rollbackResult == 0 else {
                    let rollbackErrorCode = errno
                    // The identity of `replacement` is unverified. Retain it and the caller-visible tree
                    // so recovery is possible; never delete either after a failed rollback.
                    shouldRemoveReplacement = false
                    throw NSError(
                        domain: "com.grove.decompress.commit",
                        code: Int(rollbackErrorCode),
                        userInfo: [
                            NSLocalizedDescriptionKey: "The archive destination changed during commit, and rollback failed (identity error \(identityErrorCode): \(String(cString: strerror(identityErrorCode))); rollback error \(rollbackErrorCode): \(String(cString: strerror(rollbackErrorCode))). Both trees were retained at \(destination.path) and \(replacement.url.path)."
                        ]
                    )
                }
                throw NSError(
                    domain: "com.grove.decompress.commit",
                    code: Int(identityErrorCode),
                    userInfo: [
                        NSLocalizedDescriptionKey: "The archive destination changed during commit. The competing destination was restored and the archive was not published."
                    ]
                )
            }
            // Only the verified original destination is now at `replacement`. Reverify its identity
            // descriptor-relative immediately before cleanup; a substituted name is retained.
            expectedCleanupIdentity = initialDestinationIdentity
            shouldRemoveReplacement = false
            do {
                try hooks.immediatelyBeforeCleanup?(replacement.url)
                try identityBoundRemoveArchiveTree(
                    named: replacementName,
                    in: parentDescriptor,
                    expected: initialDestinationIdentity,
                    displayURL: replacement.url,
                    afterIntentPersisted: hooks.immediatelyAfterQuarantineIntentPersisted,
                    afterQuarantineVerification: hooks.immediatelyAfterQuarantineVerification,
                    immediatelyBeforeRootRemoval: hooks.immediatelyBeforeQuarantineRootRemoval,
                    immediatelyBeforeChildRetention: hooks.immediatelyBeforeCleanupChildRetention,
                    treeRetained: hooks.cleanupTreeRetained
                )
            } catch {
                // RENAME_SWAP has committed the replacement. Cleanup warnings are post-commit state,
                // not rollback failures; preserve the published tree and surface the retained evidence.
                reportPostCommitArchiveCleanupWarning(error, hooks: hooks)
            }
        } else {
            let result = replacementName.withCString { replacementName in
                destinationName.withCString { destinationName in
                    renameatx_np(
                        parentDescriptor,
                        replacementName,
                        parentDescriptor,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                let errorCode = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
                )
            }
            shouldRemoveReplacement = false
        }
    }

    private struct ArchiveTreeIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private func reportPostCommitArchiveCleanupWarning(
        _ error: Error,
        hooks: ArchiveExtractionHooks
    ) {
        Self.logger.error(
            "Archive extraction committed with cleanup warning: \(error.localizedDescription, privacy: .public)"
        )
        hooks.postCommitCleanupWarning?(error)
        NotificationCenter.default.post(
            name: Self.archiveQuarantineNeedsAttentionNotification,
            object: self,
            userInfo: [NSUnderlyingErrorKey: error]
        )
    }

    private struct ArchivePrivateTreeHandle {
        let parentDescriptor: Int32
        let name: String
        let identity: ArchiveTreeIdentity
    }

    private func createSiblingArchiveTransaction(
        in parent: URL,
        parentDescriptor: Int32,
        prefix: String
    ) throws -> (url: URL, identity: ArchiveTreeIdentity) {
        for _ in 0..<100 {
            let name = "\(prefix)-\(UUID().uuidString)"
            let result = name.withCString { mkdirat(parentDescriptor, $0, 0o700) }
            if result == 0 {
                var info = stat()
                guard name.withCString({ fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                return (
                    parent.appendingPathComponent(name, isDirectory: true),
                    ArchiveTreeIdentity(device: info.st_dev, inode: info.st_ino)
                )
            }
            let errorCode = errno
            guard errorCode == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
        }
        throw NSError(domain: "com.grove.decompress", code: Int(EEXIST))
    }

    private func descriptorRelativeURL(parentDescriptor: Int32, name: String) throws -> URL {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parentDescriptor, F_GETPATH, &pathBuffer) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        return URL(fileURLWithPath: String(cString: pathBuffer), isDirectory: true)
            .appendingPathComponent(name)
    }

    private final class ArchiveCopyContext {
        struct HardLinkTarget {
            let parentDescriptor: Int32
            let name: String
        }

        let cancellationRequested: () -> Bool
        let status: ((Int64) -> Void)?
        var hardLinkTargets: [ArchiveTreeIdentity: HardLinkTarget] = [:]

        init(cancellationRequested: @escaping () -> Bool, status: ((Int64) -> Void)?) {
            self.cancellationRequested = cancellationRequested
            self.status = status
        }

        deinit {
            for target in hardLinkTargets.values {
                close(target.parentDescriptor)
            }
        }
    }

    private func copyArchiveDirectoryMetadataDescriptor(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32
    ) throws {
        try replaceArchiveExtendedAttributesDescriptor(
            from: sourceDescriptor,
            to: destinationDescriptor
        )
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard fchmod(destinationDescriptor, sourceInfo.st_mode & 0o7777) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        let times = [sourceInfo.st_atimespec, sourceInfo.st_mtimespec]
        let timeResult = times.withUnsafeBufferPointer {
            futimens(destinationDescriptor, $0.baseAddress)
        }
        guard timeResult == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var verifiedInfo = stat()
        guard fstat(destinationDescriptor, &verifiedInfo) == 0,
              verifiedInfo.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec,
              verifiedInfo.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec else {
            throw NSError(
                domain: "com.grove.decompress.metadata",
                code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "Directory metadata time verification failed (source \(sourceInfo.st_mtimespec.tv_sec), destination \(verifiedInfo.st_mtimespec.tv_sec))."]
            )
        }
    }

    private func archiveExtendedAttributeNames(from descriptor: Int32) throws -> [String] {
        let byteCount = flistxattr(descriptor, nil, 0, 0)
        guard byteCount >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard byteCount > 0 else { return [] }
        var names = [CChar](repeating: 0, count: byteCount)
        let readCount = flistxattr(descriptor, &names, names.count, 0)
        guard readCount == byteCount else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var result: [String] = []
        var start = 0
        while start < readCount {
            let end = names[start...].firstIndex(of: 0) ?? readCount
            if end > start { result.append(String(cString: Array(names[start...end]))) }
            start = end + 1
        }
        return result
    }

    private func replaceArchiveExtendedAttributesDescriptor(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32
    ) throws {
        let sourceNames = try archiveExtendedAttributeNames(from: sourceDescriptor)
        for name in try archiveExtendedAttributeNames(from: destinationDescriptor) where !sourceNames.contains(name) {
            if name.withCString({ fremovexattr(destinationDescriptor, $0, 0) }) != 0, errno != ENOATTR {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
        }
        for name in sourceNames {
            let size = name.withCString { fgetxattr(sourceDescriptor, $0, nil, 0, 0, 0) }
            guard size >= 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            var value = Data(count: size)
            let readCount = value.withUnsafeMutableBytes { bytes in
                name.withCString {
                    fgetxattr(sourceDescriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
            guard readCount == size else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            let writeResult = value.withUnsafeBytes { bytes in
                name.withCString {
                    fsetxattr(destinationDescriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
            guard writeResult == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
        }
    }

    private func reapplyArchiveDirectoryMetadata(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        cancellationRequested: @escaping () -> Bool
    ) throws {
        // `dup` shares the directory stream offset with `sourceDescriptor`. This tree is
        // intentionally enumerated more than once (copy, fill-only merge, then bottom-up
        // metadata), so open `.` to obtain an independent open-file description each time.
        let enumerationDescriptor = openat(
            sourceDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            guard !cancellationRequested() else {
                throw archiveCancellationError(domain: "com.grove.decompress")
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var sourceInfo = stat()
            guard name.withCString({ fstatat(sourceDescriptor, $0, &sourceInfo, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            guard sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
            let sourceChild = name.withCString {
                openat(sourceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let destinationChild = name.withCString {
                openat(destinationDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard sourceChild >= 0, destinationChild >= 0 else {
                if sourceChild >= 0 { close(sourceChild) }
                if destinationChild >= 0 { close(destinationChild) }
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            do {
                try reapplyArchiveDirectoryMetadata(
                    from: sourceChild,
                    to: destinationChild,
                    cancellationRequested: cancellationRequested
                )
                try copyArchiveDirectoryMetadataDescriptor(from: sourceChild, to: destinationChild)
                close(sourceChild)
                close(destinationChild)
            } catch {
                close(sourceChild)
                close(destinationChild)
                throw error
            }
        }
    }

    private func copyArchiveDirectoryContents(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        context: ArchiveCopyContext,
        overwriteExisting: Bool
    ) throws {
        // Use an independent directory offset. A duplicated descriptor would inherit and
        // advance the caller's stream position, making later metadata passes see an empty tree.
        let enumerationDescriptor = openat(
            sourceDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            guard !context.cancellationRequested() else {
                throw archiveCancellationError(domain: "com.grove.decompress")
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var sourceInfo = stat()
            guard name.withCString({ fstatat(sourceDescriptor, $0, &sourceInfo, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            var destinationInfo = stat()
            let destinationExists = name.withCString {
                fstatat(destinationDescriptor, $0, &destinationInfo, AT_SYMLINK_NOFOLLOW)
            } == 0
            let sourceType = sourceInfo.st_mode & mode_t(S_IFMT)
            if sourceType == mode_t(S_IFDIR) {
                var createdDestinationDirectory = false
                if destinationExists,
                   destinationInfo.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
                    guard overwriteExisting else { continue }
                    throw NSError(domain: "com.grove.decompress", code: Int(EEXIST))
                }
                if !destinationExists || destinationInfo.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
                    guard name.withCString({ mkdirat(destinationDescriptor, $0, 0o700) }) == 0 else {
                        let errorCode = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                    }
                    createdDestinationDirectory = true
                }
                let sourceChild = name.withCString {
                    openat(sourceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                let destinationChild = name.withCString {
                    openat(destinationDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard sourceChild >= 0, destinationChild >= 0 else {
                    if sourceChild >= 0 { close(sourceChild) }
                    if destinationChild >= 0 { close(destinationChild) }
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                do {
                    try copyArchiveDirectoryContents(
                        from: sourceChild,
                        to: destinationChild,
                        context: context,
                        overwriteExisting: overwriteExisting
                    )
                    if overwriteExisting || createdDestinationDirectory {
                        try copyArchiveDirectoryMetadataDescriptor(
                            from: sourceChild,
                            to: destinationChild
                        )
                    }
                    close(sourceChild)
                    close(destinationChild)
                } catch {
                    close(sourceChild)
                    close(destinationChild)
                    throw error
                }
            } else if sourceType == mode_t(S_IFREG) {
                guard !destinationExists else {
                    if overwriteExisting {
                        throw NSError(domain: "com.grove.decompress", code: Int(EEXIST))
                    }
                    continue
                }
                let sourceIdentity = ArchiveTreeIdentity(device: sourceInfo.st_dev, inode: sourceInfo.st_ino)
                if sourceInfo.st_nlink > 1,
                   let firstDestination = context.hardLinkTargets[sourceIdentity] {
                    let linkResult = firstDestination.name.withCString { firstName in
                        name.withCString { destinationName in
                            linkat(
                                firstDestination.parentDescriptor,
                                firstName,
                                destinationDescriptor,
                                destinationName,
                                0
                            )
                        }
                    }
                    guard linkResult == 0 else {
                        let errorCode = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                    }
                    continue
                }
                let sourceFile = name.withCString {
                    openat(sourceDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
                let destinationFile = name.withCString {
                    openat(destinationDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                }
                guard sourceFile >= 0, destinationFile >= 0 else {
                    if sourceFile >= 0 { close(sourceFile) }
                    if destinationFile >= 0 { close(destinationFile) }
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                let tracker = CopyfileProgress(
                    total: Int64(sourceInfo.st_size),
                    base: 0,
                    isCancelled: context.cancellationRequested,
                    report: { _ in },
                    status: context.status.map { status in
                        { status(Int64(sourceInfo.st_size)) }
                    }
                )
                let state = copyfile_state_alloc()
                copyfile_state_set(
                    state,
                    UInt32(COPYFILE_STATE_STATUS_CB),
                    unsafeBitCast(Self.copyfileProgressCallback, to: UnsafeRawPointer.self)
                )
                copyfile_state_set(
                    state,
                    UInt32(COPYFILE_STATE_STATUS_CTX),
                    Unmanaged.passUnretained(tracker).toOpaque()
                )
                let flags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_ALL))
                let result = fcopyfile(sourceFile, destinationFile, state, flags)
                let errorCode = errno
                copyfile_state_free(state)
                var partialScrubError: NSError?
                if result != 0 {
                    if ftruncate(destinationFile, 0) != 0 {
                        let scrubErrorCode = errno
                        partialScrubError = NSError(
                            domain: "com.grove.decompress.quarantine",
                            code: Int(scrubErrorCode),
                            userInfo: [NSLocalizedDescriptionKey: "Could not scrub a partial replacement file: \(String(cString: strerror(scrubErrorCode)))"]
                        )
                    }
                }
                close(sourceFile)
                close(destinationFile)
                guard result == 0 else {
                    if let partialScrubError { throw partialScrubError }
                    if tracker.didCancel || context.cancellationRequested() {
                        throw archiveCancellationError(domain: "com.grove.decompress")
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                if sourceInfo.st_nlink > 1 {
                    let retainedParentDescriptor = dup(destinationDescriptor)
                    guard retainedParentDescriptor >= 0 else {
                        let errorCode = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                    }
                    context.hardLinkTargets[sourceIdentity] = .init(
                        parentDescriptor: retainedParentDescriptor,
                        name: name
                    )
                }
            } else if sourceType == mode_t(S_IFLNK) {
                guard !destinationExists else {
                    if overwriteExisting {
                        throw NSError(domain: "com.grove.decompress", code: Int(EEXIST))
                    }
                    continue
                }
                var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = name.withCString {
                    readlinkat(sourceDescriptor, $0, &target, Int(PATH_MAX))
                }
                guard length >= 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                target[Int(length)] = 0
                guard name.withCString({ symlinkat(target, destinationDescriptor, $0) }) == 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                let sourceLink = name.withCString {
                    openat(sourceDescriptor, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
                }
                let destinationLink = name.withCString {
                    openat(destinationDescriptor, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
                }
                guard sourceLink >= 0, destinationLink >= 0 else {
                    if sourceLink >= 0 { close(sourceLink) }
                    if destinationLink >= 0 { close(destinationLink) }
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                let metadataFlags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_METADATA))
                let metadataResult = fcopyfile(sourceLink, destinationLink, nil, metadataFlags)
                let metadataError = errno
                close(sourceLink)
                close(destinationLink)
                guard metadataResult == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(metadataError))
                }
            } else {
                throw NSError(domain: "com.grove.decompress", code: Int(ENOTSUP))
            }
        }
    }

    private func verifyArchiveTreeIdentity(
        named name: String,
        in parentDescriptor: Int32,
        expected: ArchiveTreeIdentity,
        displayURL: URL
    ) throws {
        var info = stat()
        let status = name.withCString {
            fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              ArchiveTreeIdentity(device: info.st_dev, inode: info.st_ino) == expected else {
            let errorCode = status == 0 ? ESTALE : errno
            throw NSError(
                domain: "com.grove.decompress.commit",
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Private archive tree identity changed at \(displayURL.path); it was retained."]
            )
        }
    }

    private func identityBoundRemoveArchiveTree(
        named name: String,
        in parentDescriptor: Int32,
        expected: ArchiveTreeIdentity,
        displayURL: URL,
        afterIntentPersisted: ((URL) throws -> Void)? = nil,
        afterQuarantineVerification: ((URL) throws -> Void)? = nil,
        immediatelyBeforeRootRemoval: ((URL) throws -> Void)? = nil,
        immediatelyBeforeChildRetention: ((URL) throws -> Void)? = nil,
        treeRetained: ((URL) -> Void)? = nil
    ) throws {
        do {
            try verifyArchiveTreeIdentity(
                named: name,
                in: parentDescriptor,
                expected: expected,
                displayURL: displayURL
            )
        } catch {
            reportRetainedArchiveCleanupTree(displayURL, status: .failed, error: error)
            treeRetained?(displayURL)
            throw error
        }
        let sourceParentURL: URL
        do {
            if forceArchiveCleanupDescriptorPathFailureForTesting, treeRetained != nil {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF))
            }
            sourceParentURL = try descriptorRelativeURL(parentDescriptor: parentDescriptor, name: ".")
                .standardizedFileURL
        } catch {
            reportRetainedArchiveCleanupTree(displayURL, status: .failed, error: error)
            treeRetained?(displayURL)
            throw error
        }
        var quarantineParentDescriptor = parentDescriptor
        var ownedQuarantineParentDescriptor: Int32?
        var quarantineName = ".grove-cleanup-\(UUID().uuidString)"
        var quarantineURL = sourceParentURL.appendingPathComponent(quarantineName, isDirectory: true)
        // Resolve the final opaque quarantine namespace before persisting intent. The one subsequent
        // rename is atomic and restart recovery can always inspect either the source or planned target.
        if !forceArchiveQuarantineSiblingFallbackForTesting,
           let managedDirectory = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: displayURL.deletingLastPathComponent(),
            create: true
        ) {
            let managedDescriptor = open(managedDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if managedDescriptor >= 0 {
                var managedInfo = stat()
                if fstat(managedDescriptor, &managedInfo) == 0,
                   managedInfo.st_dev == expected.device {
                    quarantineParentDescriptor = managedDescriptor
                    ownedQuarantineParentDescriptor = managedDescriptor
                    quarantineName = UUID().uuidString
                    quarantineURL = managedDirectory.appendingPathComponent(quarantineName, isDirectory: true)
                } else {
                    close(managedDescriptor)
                }
            }
        }
        defer {
            if let ownedQuarantineParentDescriptor { close(ownedQuarantineParentDescriptor) }
        }

        let transactionID = UUID()
        let registryID: UUID
        do {
            registryID = try registerArchiveQuarantineIntent(
                sourceParentURL: sourceParentURL,
                sourceName: name,
                plannedURL: quarantineURL,
                identity: expected,
                transactionID: transactionID
            )
        } catch {
            reportRetainedArchiveCleanupTree(displayURL, status: .failed, error: error)
            treeRetained?(displayURL)
            throw error
        }
        do {
            try afterIntentPersisted?(displayURL)
        } catch {
            reportRetainedArchiveCleanupTree(displayURL, status: .intent, error: error)
            treeRetained?(displayURL)
            throw error
        }
        let moveResult = name.withCString { sourceName in
            quarantineName.withCString { targetName in
                renameatx_np(
                    parentDescriptor,
                    sourceName,
                    quarantineParentDescriptor,
                    targetName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moveResult == 0 else {
            let moveError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            do {
                try updateArchiveQuarantine(id: registryID, status: .failed, error: moveError)
            } catch {
                let combined = NSError(
                    domain: "com.grove.decompress.quarantine",
                    code: Int(EIO),
                    userInfo: [NSLocalizedDescriptionKey: "Quarantine relocation failed at \(displayURL.path): \(moveError.localizedDescription). Persisting failure also failed: \(error.localizedDescription)"]
                )
                reportRetainedArchiveCleanupTree(displayURL, status: .intent, error: combined)
                treeRetained?(displayURL)
                throw combined
            }
            reportRetainedArchiveCleanupTree(displayURL, status: .failed, error: moveError)
            treeRetained?(displayURL)
            throw moveError
        }
        do {
            try verifyArchiveTreeIdentity(
                named: quarantineName,
                in: quarantineParentDescriptor,
                expected: expected,
                displayURL: quarantineURL
            )
            try updateArchiveQuarantine(id: registryID, status: .registered)
        } catch {
            // The durable intent already identifies both possible namespaces. Never restore or delete
            // here: restart recovery can resolve it without risking a substitute.
            reportRetainedArchiveCleanupTree(quarantineURL, status: .intent, error: error)
            treeRetained?(quarantineURL)
            throw error
        }
        do {
            try afterQuarantineVerification?(quarantineURL)
            try removeArchiveTreeDescriptorRelative(
                named: quarantineName,
                in: quarantineParentDescriptor,
                expected: expected,
                displayURL: quarantineURL,
                immediatelyBeforeRootRemoval: immediatelyBeforeRootRemoval,
                immediatelyBeforeChildRetention: immediatelyBeforeChildRetention
            )
            var finalQuarantineURL = quarantineURL
            if quarantineName.hasPrefix(".grove-cleanup-") {
                finalQuarantineURL = try handoffSanitizedSiblingQuarantine(
                    id: registryID,
                    named: quarantineName,
                    in: quarantineParentDescriptor,
                    sourceParentURL: sourceParentURL,
                    expected: expected,
                    displayURL: quarantineURL
                )
            }
            try updateArchiveQuarantine(id: registryID, status: .sanitized)
            reportRetainedArchiveCleanupTree(finalQuarantineURL, status: .sanitized)
            treeRetained?(finalQuarantineURL)
        } catch {
            do {
                try updateArchiveQuarantine(id: registryID, status: .failed, error: error)
            } catch let registryError {
                reportRetainedArchiveCleanupTree(quarantineURL, status: .registered, error: error)
                treeRetained?(quarantineURL)
                throw NSError(
                    domain: "com.grove.decompress.quarantine",
                    code: Int(EIO),
                    userInfo: [NSLocalizedDescriptionKey: "Quarantine sanitation failed at \(quarantineURL.path): \(error.localizedDescription). Persisting the failure also failed: \(registryError.localizedDescription)"]
                )
            }
            reportRetainedArchiveCleanupTree(quarantineURL, status: .failed, error: error)
            treeRetained?(quarantineURL)
            throw error
        }
    }

    private func removeArchiveTreeDescriptorRelative(
        named name: String,
        in parentDescriptor: Int32,
        expected: ArchiveTreeIdentity,
        displayURL: URL,
        immediatelyBeforeRootRemoval: ((URL) throws -> Void)? = nil,
        immediatelyBeforeChildRetention: ((URL) throws -> Void)? = nil
    ) throws {
        try verifyArchiveTreeIdentity(
            named: name,
            in: parentDescriptor,
            expected: expected,
            displayURL: displayURL
        )
        let rootDescriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not open verified private tree \(displayURL.path): \(String(cString: strerror(errorCode)))"]
            )
        }
        defer { close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              ArchiveTreeIdentity(device: rootInfo.st_dev, inode: rootInfo.st_ino) == expected else {
            let errorCode = errno == 0 ? ESTALE : errno
            throw NSError(
                domain: "com.grove.decompress.commit",
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Opened private archive tree identity changed at \(displayURL.path); it was retained."]
            )
        }
        // Inventory every owned regular-file directory entry before mutating any inode-shared state.
        // A regular inode is safe to scrub only when its current link count exactly equals this owned
        // reference count; otherwise an external alias may exist and must remain byte/metadata exact.
        let sanitationContext = ArchiveSanitationContext(rootDescriptor: rootDescriptor)
        try inventoryArchiveRegularLinks(from: rootDescriptor, context: sanitationContext)
        try archiveAfterSanitationInventoryForTesting?(displayURL)
        try prepareArchiveDescriptorForSanitation(rootDescriptor, directory: true)
        try sanitizeArchiveDirectoryContents(
            from: rootDescriptor,
            displayURL: displayURL,
            immediatelyBeforeChildRetention: immediatelyBeforeChildRetention,
            context: sanitationContext
        )
        try scrubArchiveExtendedAttributes(from: rootDescriptor)
        if !sanitationContext.restrictedExternalLinks.isEmpty {
            throw NSError(
                domain: "com.grove.decompress.quarantine",
                code: Int(EMLINK),
                userInfo: [NSLocalizedDescriptionKey: "Quarantine retained regular inodes with possible external hard links without mutating them: \(sanitationContext.restrictedExternalLinks.joined(separator: ", "))"]
            )
        }

        // macOS has no inode-conditional unlinkat. Even after these checks, deleting by name would
        // leave a wrong-name race, so retain the sanitized quarantine root for explicit recovery.
        try verifyArchiveTreeIdentity(
            named: name,
            in: parentDescriptor,
            expected: expected,
            displayURL: displayURL
        )
        try immediatelyBeforeRootRemoval?(displayURL)
        // The hook models a name substitution after the last pre-retention identity check. Revalidate
        // only to report the precise mismatch; neither the expected root nor a substitute is unlinked.
        try verifyArchiveTreeIdentity(
            named: name,
            in: parentDescriptor,
            expected: expected,
            displayURL: displayURL
        )
    }

    private func handoffSanitizedSiblingQuarantine(
        id: UUID,
        named sourceName: String,
        in sourceParentDescriptor: Int32,
        sourceParentURL: URL,
        expected: ArchiveTreeIdentity,
        displayURL: URL
    ) throws -> URL {
        try verifyArchiveTreeIdentity(
            named: sourceName,
            in: sourceParentDescriptor,
            expected: expected,
            displayURL: displayURL
        )
        let managedDirectory = try archiveRetirementDirectory(
            appropriateFor: displayURL,
            device: UInt64(expected.device)
        )
        let managedDescriptor = open(managedDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard managedDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(managedDescriptor) }
        var managedInfo = stat()
        guard fstat(managedDescriptor, &managedInfo) == 0,
              managedInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              managedInfo.st_dev == expected.device else {
            throw NSError(domain: "com.grove.decompress.quarantine", code: Int(EXDEV))
        }
        guard fchmod(managedDescriptor, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let targetName = UUID().uuidString
        let targetURL = managedDirectory.appendingPathComponent(targetName, isDirectory: true)
        // Persist the current source and planned managed target before the atomic move. Restart retry
        // can therefore resolve either namespace without an unaccounted relocation window.
        try replanArchiveQuarantine(
            id: id,
            to: targetURL,
            sourceParentURL: sourceParentURL,
            sourceName: sourceName
        )
        let result = sourceName.withCString { sourceName in
            targetName.withCString { targetName in
                renameatx_np(
                    sourceParentDescriptor,
                    sourceName,
                    managedDescriptor,
                    targetName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try verifyArchiveTreeIdentity(
            named: targetName,
            in: managedDescriptor,
            expected: expected,
            displayURL: targetURL
        )
        try updateArchiveQuarantine(id: id, status: .registered)
        return targetURL
    }

    private func archiveRetirementDirectory(
        appropriateFor url: URL,
        device: UInt64
    ) throws -> URL {
        retainedCleanupLock.lock()
        if let cached = archiveRetirementDirectoriesByDevice[device] {
            retainedCleanupLock.unlock()
            var info = stat()
            if lstat(cached.path, &info) == 0,
               UInt64(info.st_dev) == device,
               info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                return cached
            }
        } else {
            // On restart, recover the single managed parent from a recent sanitized record.
            if let records = try? loadArchiveQuarantineRecordsLocked(),
               let existing = records.first(where: {
                   $0.device == device
                       && $0.sanitationStatus == .sanitized
                       && !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(".grove-cleanup-")
               }) {
                let parent = URL(fileURLWithPath: existing.path).deletingLastPathComponent()
                archiveRetirementDirectoriesByDevice[device] = parent
                retainedCleanupLock.unlock()
                var info = stat()
                if lstat(parent.path, &info) == 0,
                   UInt64(info.st_dev) == device,
                   info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    return parent
                }
            } else {
                retainedCleanupLock.unlock()
            }
        }
        let created = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: true
        )
        guard chmod(created.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        retainedCleanupLock.lock()
        archiveRetirementDirectoriesByDevice[device] = created
        retainedCleanupLock.unlock()
        return created
    }

    private final class ArchiveSanitationContext {
        let rootDescriptor: Int32
        var ownedRegularLinkCounts: [ArchiveTreeIdentity: UInt64] = [:]
        var restrictedExternalLinks: [String] = []

        init(rootDescriptor: Int32) {
            self.rootDescriptor = rootDescriptor
        }
    }

    private func inventoryArchiveRegularLinks(
        from descriptor: Int32,
        context: ArchiveSanitationContext
    ) throws {
        let enumerationDescriptor = openat(
            descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closedir(directory) }
        while let rawEntry = readdir(directory) {
            let name = withUnsafePointer(to: rawEntry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(rawEntry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFREG) || type == mode_t(S_IFLNK) {
                let identity = ArchiveTreeIdentity(device: info.st_dev, inode: info.st_ino)
                context.ownedRegularLinkCounts[identity, default: 0] += 1
            } else if type == mode_t(S_IFDIR) {
                let child = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                try { () throws in
                    defer { close(child) }
                    try inventoryArchiveRegularLinks(from: child, context: context)
                }()
            }
        }
    }

    private func archiveInodeIsExclusivelyOwned(
        _ identity: ArchiveTreeIdentity,
        openedDescriptor: Int32,
        context: ArchiveSanitationContext
    ) throws -> (isExclusive: Bool, owned: UInt64, linkCount: UInt64) {
        let freshContext = ArchiveSanitationContext(rootDescriptor: context.rootDescriptor)
        try inventoryArchiveRegularLinks(from: context.rootDescriptor, context: freshContext)
        var currentInfo = stat()
        guard fstat(openedDescriptor, &currentInfo) == 0,
              ArchiveTreeIdentity(device: currentInfo.st_dev, inode: currentInfo.st_ino) == identity else {
            throw NSError(domain: "com.grove.decompress.commit", code: Int(ESTALE))
        }
        let initialOwned = context.ownedRegularLinkCounts[identity] ?? 0
        let freshOwned = freshContext.ownedRegularLinkCounts[identity] ?? 0
        let linkCount = UInt64(currentInfo.st_nlink)
        return (
            initialOwned > 0 && freshOwned == initialOwned && freshOwned == linkCount,
            freshOwned,
            linkCount
        )
    }

    private func sanitizeArchiveDirectoryContents(
        from descriptor: Int32,
        displayURL: URL,
        immediatelyBeforeChildRetention: ((URL) throws -> Void)?,
        context: ArchiveSanitationContext
    ) throws {
        struct Entry {
            let name: String
            let info: stat
        }
        let enumerationDescriptor = dup(descriptor)
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var entries: [Entry] = []
        while let rawEntry = readdir(directory) {
            let name = withUnsafePointer(to: rawEntry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(rawEntry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                let errorCode = errno
                closedir(directory)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            entries.append(Entry(name: name, info: info))
        }
        closedir(directory)

        for entry in entries {
            let expected = ArchiveTreeIdentity(device: entry.info.st_dev, inode: entry.info.st_ino)
            let retainedName = UUID().uuidString
            let renameResult = entry.name.withCString { originalName in
                retainedName.withCString { retainedName in
                    renameatx_np(descriptor, originalName, descriptor, retainedName, UInt32(RENAME_EXCL))
                }
            }
            guard renameResult == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            do {
                try verifyArchiveTreeIdentity(
                    named: retainedName,
                    in: descriptor,
                    expected: expected,
                    displayURL: displayURL.appendingPathComponent(retainedName)
                )
            } catch {
                _ = retainedName.withCString { retainedName in
                    entry.name.withCString { originalName in
                        renameatx_np(descriptor, retainedName, descriptor, originalName, UInt32(RENAME_EXCL))
                    }
                }
                throw error
            }
            if entry.info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let childDescriptor = retainedName.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard childDescriptor >= 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                try { () throws in
                    defer { close(childDescriptor) }
                    var openedInfo = stat()
                    guard fstat(childDescriptor, &openedInfo) == 0,
                          ArchiveTreeIdentity(device: openedInfo.st_dev, inode: openedInfo.st_ino) == expected else {
                        throw NSError(
                            domain: "com.grove.decompress.commit",
                            code: Int(ESTALE),
                            userInfo: [NSLocalizedDescriptionKey: "Private cleanup member changed at \(displayURL.appendingPathComponent(retainedName).path); it was retained."]
                        )
                    }
                    try prepareArchiveDescriptorForSanitation(childDescriptor, directory: true)
                    try sanitizeArchiveDirectoryContents(
                        from: childDescriptor,
                        displayURL: displayURL.appendingPathComponent(retainedName, isDirectory: true),
                        immediatelyBeforeChildRetention: immediatelyBeforeChildRetention,
                        context: context
                    )
                    try scrubArchiveExtendedAttributes(from: childDescriptor)
                }()
                let childURL = displayURL.appendingPathComponent(retainedName, isDirectory: true)
                try verifyArchiveTreeIdentity(
                    named: retainedName,
                    in: descriptor,
                    expected: expected,
                    displayURL: childURL
                )
                try immediatelyBeforeChildRetention?(childURL)
                try verifyArchiveTreeIdentity(
                    named: retainedName,
                    in: descriptor,
                    expected: expected,
                    displayURL: childURL
                )
            } else {
                let flags = entry.info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
                    ? O_RDONLY | O_SYMLINK | O_CLOEXEC
                    : O_RDWR | O_NOFOLLOW | O_CLOEXEC
                let childDescriptor = retainedName.withCString { openat(descriptor, $0, flags) }
                guard childDescriptor >= 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                try { () throws in
                    defer { close(childDescriptor) }
                    var openedInfo = stat()
                    guard fstat(childDescriptor, &openedInfo) == 0,
                          ArchiveTreeIdentity(device: openedInfo.st_dev, inode: openedInfo.st_ino) == expected else {
                        throw NSError(domain: "com.grove.decompress.commit", code: Int(ESTALE))
                    }
                    if entry.info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                        let identity = ArchiveTreeIdentity(device: openedInfo.st_dev, inode: openedInfo.st_ino)
                        let ownership = try archiveInodeIsExclusivelyOwned(
                            identity,
                            openedDescriptor: childDescriptor,
                            context: context
                        )
                        if ownership.isExclusive {
                            try prepareArchiveDescriptorForSanitation(childDescriptor, directory: false)
                            guard ftruncate(childDescriptor, 0) == 0 else {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                            try scrubArchiveExtendedAttributes(from: childDescriptor)
                        } else {
                            context.restrictedExternalLinks.append(
                                "\(displayURL.appendingPathComponent(retainedName).path) [\(identity.device):\(identity.inode), owned=\(ownership.owned), nlink=\(ownership.linkCount)]"
                            )
                        }
                    } else if entry.info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        let identity = ArchiveTreeIdentity(device: openedInfo.st_dev, inode: openedInfo.st_ino)
                        let ownership = try archiveInodeIsExclusivelyOwned(
                            identity,
                            openedDescriptor: childDescriptor,
                            context: context
                        )
                        if ownership.isExclusive {
                            try prepareArchiveSymbolicLinkDescriptorForSanitation(childDescriptor)
                            try scrubArchiveExtendedAttributes(from: childDescriptor)
                        } else {
                            context.restrictedExternalLinks.append(
                                "\(displayURL.appendingPathComponent(retainedName).path) [symlink \(identity.device):\(identity.inode), owned=\(ownership.owned), nlink=\(ownership.linkCount)]"
                            )
                        }
                    } else {
                        try scrubArchiveExtendedAttributes(from: childDescriptor)
                    }
                }()
                if entry.info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    try neutralizeArchiveSymbolicLink(
                        named: retainedName,
                        in: descriptor,
                        expected: expected,
                        displayURL: displayURL.appendingPathComponent(retainedName)
                    )
                    continue
                }
                let childURL = displayURL.appendingPathComponent(retainedName)
                try verifyArchiveTreeIdentity(
                    named: retainedName,
                    in: descriptor,
                    expected: expected,
                    displayURL: childURL
                )
                try immediatelyBeforeChildRetention?(childURL)
                try verifyArchiveTreeIdentity(
                    named: retainedName,
                    in: descriptor,
                    expected: expected,
                    displayURL: childURL
                )
            }
        }
    }

    private func scrubArchiveExtendedAttributes(from descriptor: Int32) throws {
        let byteCount = flistxattr(descriptor, nil, 0, 0)
        guard byteCount >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard byteCount > 0 else { return }
        var names = [CChar](repeating: 0, count: byteCount)
        let readCount = flistxattr(descriptor, &names, names.count, 0)
        guard readCount == byteCount else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var start = 0
        while start < readCount {
            let end = names[start...].firstIndex(of: 0) ?? readCount
            if end > start {
                let name = String(cString: Array(names[start...end]))
                guard name.withCString({ fremovexattr(descriptor, $0, 0) }) == 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
            }
            start = end + 1
        }
    }

    private func prepareArchiveDescriptorForSanitation(_ descriptor: Int32, directory: Bool) throws {
        if archiveSanitationFailureStageForTesting == (directory ? .directory : .regular) {
            throw NSError(domain: "com.grove.test.sanitation-stage", code: Int(EIO))
        }
        guard fchflags(descriptor, 0) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard fchmod(descriptor, directory ? 0o700 : 0o600) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        if groveACLDeleteFD(descriptor, ACL_TYPE_EXTENDED) != 0,
           errno != ENOENT,
           errno != ENOTSUP {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
    }

    private func prepareArchiveSymbolicLinkDescriptorForSanitation(_ descriptor: Int32) throws {
        if archiveSanitationFailureStageForTesting == .symbolicLink {
            throw NSError(domain: "com.grove.test.sanitation-stage", code: Int(EIO))
        }
        guard fchflags(descriptor, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if groveACLDeleteFD(descriptor, ACL_TYPE_EXTENDED) != 0,
           errno != ENOENT,
           errno != ENOTSUP {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Symlink contents cannot be rewritten through `O_SYMLINK`. Atomically exchange the verified
    /// inode for a newly-created opaque neutral symlink inside the private directory, verify that the
    /// original inode moved to the unguessable one-use name, and consume that name before exposing any
    /// callback. A mismatch is retained and reported; no unrelated public namespace is traversed.
    private func neutralizeArchiveSymbolicLink(
        named name: String,
        in parentDescriptor: Int32,
        expected: ArchiveTreeIdentity,
        displayURL: URL
    ) throws {
        let consumedName = UUID().uuidString
        guard consumedName.withCString({ symlinkat(".", parentDescriptor, $0) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let consumedURL = displayURL.deletingLastPathComponent().appendingPathComponent(consumedName)
        var neutralInfo = stat()
        guard consumedName.withCString({
            fstatat(parentDescriptor, $0, &neutralInfo, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        neutralInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? ESTALE : errno))
        }
        let neutralIdentity = ArchiveTreeIdentity(device: neutralInfo.st_dev, inode: neutralInfo.st_ino)
        try archiveSymlinkBeforeSwapForTesting?(consumedURL)
        let swapResult: Int32
        if forceArchiveSymlinkSwapFailureForTesting {
            errno = EIO
            swapResult = -1
        } else {
            swapResult = name.withCString { name in
                consumedName.withCString { consumedName in
                    renameatx_np(parentDescriptor, name, parentDescriptor, consumedName, UInt32(RENAME_SWAP))
                }
            }
        }
        guard swapResult == 0 else {
            let errorCode = errno
            // The neutral symlink is harmless and stays under its opaque name. Never delete a mutable
            // name merely because the swap failed; the containing quarantine record accounts for it.
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var sensitiveAfterSwap = stat()
        var neutralAfterSwap = stat()
        let sensitiveStatus = consumedName.withCString {
            fstatat(parentDescriptor, $0, &sensitiveAfterSwap, AT_SYMLINK_NOFOLLOW)
        }
        let neutralStatus = name.withCString {
            fstatat(parentDescriptor, $0, &neutralAfterSwap, AT_SYMLINK_NOFOLLOW)
        }
        let sensitiveActual = sensitiveStatus == 0
            ? ArchiveTreeIdentity(device: sensitiveAfterSwap.st_dev, inode: sensitiveAfterSwap.st_ino)
            : nil
        let neutralActual = neutralStatus == 0
            ? ArchiveTreeIdentity(device: neutralAfterSwap.st_dev, inode: neutralAfterSwap.st_ino)
            : nil
        guard sensitiveActual == expected, neutralActual == neutralIdentity else {
            // Never mutate either name after this joint gate. The containing quarantine catches this
            // exact error, persists `.failed`, and reports every opaque path/identity for recovery.
            throw NSError(
                domain: "com.grove.decompress.quarantine",
                code: Int(ESTALE),
                userInfo: [NSLocalizedDescriptionKey: "Symlink exchange identity mismatch: expected sensitive \(expected.device):\(expected.inode) at \(consumedURL.path), found \(String(describing: sensitiveActual)); expected neutral \(neutralIdentity.device):\(neutralIdentity.inode) at \(displayURL.path), found \(String(describing: neutralActual)). All opaque names were retained."]
            )
        }
        let sourceParentURL = displayURL.deletingLastPathComponent()
        let vaultDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: sourceParentURL,
            create: true
        )
        guard chmod(vaultDirectory.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let vaultDescriptor = open(vaultDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard vaultDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(vaultDescriptor) }
        let vaultName = UUID().uuidString
        let vaultURL = vaultDirectory.appendingPathComponent(vaultName)
        let registryID = try registerArchiveQuarantineIntent(
            sourceParentURL: sourceParentURL,
            sourceName: consumedName,
            plannedURL: vaultURL,
            identity: expected,
            transactionID: UUID()
        )
        try archiveSymlinkBeforeSensitiveRelocationForTesting?(
            sourceParentURL.appendingPathComponent(consumedName)
        )
        try verifyArchiveTreeIdentity(
            named: consumedName,
            in: parentDescriptor,
            expected: expected,
            displayURL: sourceParentURL.appendingPathComponent(consumedName)
        )
        let relocation = consumedName.withCString { sourceName in
            vaultName.withCString { vaultName in
                renameatx_np(
                    parentDescriptor,
                    sourceName,
                    vaultDescriptor,
                    vaultName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard relocation == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try updateArchiveQuarantine(id: registryID, status: .failed, error: error)
            reportRetainedArchiveCleanupTree(sourceParentURL.appendingPathComponent(consumedName), status: .failed, error: error)
            throw error
        }
        try verifyArchiveTreeIdentity(
            named: vaultName,
            in: vaultDescriptor,
            expected: expected,
            displayURL: vaultURL
        )
        let restricted = NSError(
            domain: "com.grove.decompress.quarantine",
            code: Int(ENOTSUP),
            userInfo: [NSLocalizedDescriptionKey: "Original symlink contents are immutable and retained under an opaque restricted quarantine."]
        )
        try updateArchiveQuarantine(id: registryID, status: .failed, error: restricted)
        reportRetainedArchiveCleanupTree(vaultURL, status: .failed, error: restricted)
    }

    private func reportRetainedArchiveCleanupTree(
        _ url: URL,
        status: ArchiveQuarantineSanitationStatus,
        error: Error? = nil
    ) {
        retainedCleanupLock.lock()
        retainedArchiveCleanupTrees.append(url)
        if retainedArchiveCleanupTrees.count > 64 {
            retainedArchiveCleanupTrees.removeFirst(retainedArchiveCleanupTrees.count - 64)
        }
        retainedCleanupLock.unlock()
        if let error {
            Self.logger.error(
                "Private archive quarantine retained with status \(status.rawValue, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        } else {
            Self.logger.warning(
                "Private archive quarantine retained with status \(status.rawValue, privacy: .public) at \(url.path, privacy: .public)"
            )
        }
    }

    private func loadArchiveQuarantineRecordsLocked() throws -> [ArchiveQuarantineRecord] {
        let registryURL = archiveQuarantineRegistryURL
        var info = stat()
        guard lstat(registryURL.path, &info) == 0 else {
            let errorCode = errno
            if errorCode == ENOENT { return [] }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw NSError(
                domain: "com.grove.decompress.quarantine",
                code: Int(EBADMSG),
                userInfo: [NSLocalizedDescriptionKey: "Archive quarantine registry is not a regular file: \(registryURL.path)"]
            )
        }
        let data = try Data(contentsOf: registryURL, options: .mappedIfSafe)
        do {
            return try PropertyListDecoder().decode([ArchiveQuarantineRecord].self, from: data)
        } catch {
            throw NSError(
                domain: "com.grove.decompress.quarantine",
                code: Int(EBADMSG),
                userInfo: [NSLocalizedDescriptionKey: "Archive quarantine registry is corrupt and was not overwritten: \(registryURL.path): \(error.localizedDescription)"]
            )
        }
    }

    private func persistArchiveQuarantineRecordsLocked(_ records: [ArchiveQuarantineRecord]) throws {
        let registryURL = archiveQuarantineRegistryURL
        let registryParent = registryURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: registryParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(registryParent.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let unresolvedOrSiblingFallback = records.filter {
            $0.sanitationStatus != .sanitized
                || URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(".grove-cleanup-")
        }
        let resolvedManaged = records.filter {
            $0.sanitationStatus == .sanitized
                && !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(".grove-cleanup-")
        }
            .sorted { $0.sanitationUpdatedAt > $1.sanitationUpdatedAt }
            .prefix(Self.maximumResolvedArchiveQuarantineAuditRecords)
        // Resolved, privacy-scrubbed trees are handed to the same-volume OS replacement/temp area.
        // Retain only a bounded recent managed audit. Unresolved evidence and sibling fallbacks that
        // have no OS expiration handoff are never discarded for a size cap.
        let boundedRecords = unresolvedOrSiblingFallback + resolvedManaged
        let data = try PropertyListEncoder().encode(boundedRecords)
        try data.write(to: registryURL, options: .atomic)
        guard chmod(registryURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func registerArchiveQuarantineIntent(
        sourceParentURL: URL,
        sourceName: String,
        plannedURL: URL,
        identity: ArchiveTreeIdentity,
        transactionID: UUID
    ) throws -> UUID {
        retainedCleanupLock.lock()
        defer { retainedCleanupLock.unlock() }
        var records = try loadArchiveQuarantineRecordsLocked()
        let id = UUID()
        records.append(
            ArchiveQuarantineRecord(
                id: id,
                transactionID: transactionID,
                path: plannedURL.path,
                sourceParentPath: sourceParentURL.path,
                sourceName: sourceName,
                device: UInt64(identity.device),
                inode: UInt64(identity.inode),
                registeredAt: Date(),
                sanitationStatus: .intent,
                sanitationUpdatedAt: Date(),
                sanitationError: nil
            )
        )
        try persistArchiveQuarantineRecordsLocked(records)
        return id
    }

    private func updateArchiveQuarantine(
        id: UUID,
        status: ArchiveQuarantineSanitationStatus,
        error: Error? = nil
    ) throws {
        retainedCleanupLock.lock()
        defer { retainedCleanupLock.unlock() }
        var records = try loadArchiveQuarantineRecordsLocked()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "com.grove.decompress.quarantine", code: Int(ENOENT))
        }
        records[index].sanitationStatus = status
        records[index].sanitationUpdatedAt = Date()
        records[index].sanitationError = error?.localizedDescription
        try persistArchiveQuarantineRecordsLocked(records)
    }

    private func replanArchiveQuarantine(
        id: UUID,
        to plannedURL: URL,
        sourceParentURL: URL? = nil,
        sourceName: String? = nil
    ) throws {
        retainedCleanupLock.lock()
        defer { retainedCleanupLock.unlock() }
        var records = try loadArchiveQuarantineRecordsLocked()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "com.grove.decompress.quarantine", code: Int(ENOENT))
        }
        records[index].path = plannedURL.path
        if let sourceParentURL { records[index].sourceParentPath = sourceParentURL.path }
        if let sourceName { records[index].sourceName = sourceName }
        records[index].sanitationStatus = .intent
        records[index].sanitationUpdatedAt = Date()
        records[index].sanitationError = nil
        try persistArchiveQuarantineRecordsLocked(records)
    }

    /// Durable production view of all safety-retained archive quarantine records, including entries
    /// recovered after app restart and sanitation failures requiring operator attention.
    func archiveQuarantineRecords() throws -> [ArchiveQuarantineRecord] {
        retainedCleanupLock.lock()
        defer { retainedCleanupLock.unlock() }
        return try loadArchiveQuarantineRecordsLocked()
    }

    /// Production lifecycle consumer. It retries crash/interruption states, prunes records whose OS
    /// managed quarantine has expired, bounds resolved audit history, and reports every unresolved
    /// item through the app notification consumed by AppDelegate.
    @discardableResult
    func performArchiveQuarantineMaintenance() throws -> [ArchiveQuarantineRecord] {
        let initial = try archiveQuarantineRecords()
        var errors: [Error] = []
        for record in initial where record.sanitationStatus != .sanitized {
            do {
                _ = try retryArchiveQuarantineSanitation(id: record.id)
            } catch {
                errors.append(error)
                Self.logger.error(
                    "Archive quarantine maintenance failed for \(record.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        _ = try pruneMissingArchiveQuarantineRecords()
        // Re-persist even when no record changed so old unbounded resolved audit histories are compacted.
        retainedCleanupLock.lock()
        do {
            let records = try loadArchiveQuarantineRecordsLocked()
            try persistArchiveQuarantineRecordsLocked(records)
            retainedCleanupLock.unlock()
        } catch {
            retainedCleanupLock.unlock()
            throw error
        }
        let remaining = try archiveQuarantineRecords()
        let unresolved = remaining.filter { $0.sanitationStatus != .sanitized }
        if !unresolved.isEmpty || !errors.isEmpty {
            NotificationCenter.default.post(
                name: Self.archiveQuarantineNeedsAttentionNotification,
                object: self,
                userInfo: [
                    "records": unresolved,
                    "errors": errors
                ]
            )
        }
        return remaining
    }

    func startArchiveQuarantineLifecycle() {
        retainedCleanupLock.lock()
        guard archiveQuarantineMaintenanceTimer == nil else {
            retainedCleanupLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        archiveQuarantineMaintenanceTimer = timer
        retainedCleanupLock.unlock()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                _ = try self.performArchiveQuarantineMaintenance()
            } catch {
                Self.logger.error(
                    "Archive quarantine lifecycle could not read or persist its registry: \(error.localizedDescription, privacy: .public)"
                )
                NotificationCenter.default.post(
                    name: Self.archiveQuarantineNeedsAttentionNotification,
                    object: self,
                    userInfo: [NSUnderlyingErrorKey: error]
                )
            }
        }
        timer.schedule(deadline: .now(), repeating: .seconds(6 * 60 * 60), leeway: .seconds(5 * 60))
        timer.resume()
    }

    func retryArchiveQuarantineSanitation(id: UUID) throws -> ArchiveQuarantineRecord {
        let storedRecord = try archiveQuarantineRecords().first(where: { $0.id == id })
        guard var record = storedRecord else {
            throw NSError(domain: "com.grove.decompress.quarantine", code: Int(ENOENT))
        }
        let expected = ArchiveTreeIdentity(device: dev_t(record.device), inode: ino_t(record.inode))
        var url = URL(fileURLWithPath: record.path, isDirectory: true)
        if record.sanitationStatus == .intent || record.sanitationStatus == .failed {
            var plannedInfo = stat()
            let plannedStatus = lstat(url.path, &plannedInfo)
            if plannedStatus == 0,
               ArchiveTreeIdentity(device: plannedInfo.st_dev, inode: plannedInfo.st_ino) == expected {
                try updateArchiveQuarantine(id: id, status: .registered)
                record.sanitationStatus = .registered
            } else if let sourceParentPath = record.sourceParentPath,
                      let sourceName = record.sourceName {
                let sourceParent = URL(fileURLWithPath: sourceParentPath, isDirectory: true)
                let sourceParentDescriptor = open(sourceParent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard sourceParentDescriptor >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                defer { close(sourceParentDescriptor) }
                do {
                    try verifyArchiveTreeIdentity(
                        named: sourceName,
                        in: sourceParentDescriptor,
                        expected: expected,
                        displayURL: sourceParent.appendingPathComponent(sourceName)
                    )
                } catch {
                    let mismatch = NSError(
                        domain: "com.grove.decompress.quarantine",
                        code: Int(ESTALE),
                        userInfo: [NSLocalizedDescriptionKey: "Quarantine identity mismatch; source and planned paths were retained."]
                    )
                    try updateArchiveQuarantine(id: id, status: .failed, error: mismatch)
                    throw mismatch
                }
                var plannedParent = url.deletingLastPathComponent()
                var plannedParentDescriptor = open(plannedParent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                if plannedParentDescriptor < 0, errno == ENOENT {
                    url = sourceParent.appendingPathComponent(".grove-cleanup-\(UUID().uuidString)")
                    plannedParent = sourceParent
                    try replanArchiveQuarantine(id: id, to: url)
                    plannedParentDescriptor = dup(sourceParentDescriptor)
                }
                guard plannedParentDescriptor >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                defer { close(plannedParentDescriptor) }
                let moveResult = sourceName.withCString { sourceName in
                    url.lastPathComponent.withCString { plannedName in
                        renameatx_np(
                            sourceParentDescriptor,
                            sourceName,
                            plannedParentDescriptor,
                            plannedName,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard moveResult == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                try verifyArchiveTreeIdentity(
                    named: url.lastPathComponent,
                    in: plannedParentDescriptor,
                    expected: expected,
                    displayURL: url
                )
                try updateArchiveQuarantine(id: id, status: .registered)
                record.sanitationStatus = .registered
            } else {
                let error = NSError(
                    domain: "com.grove.decompress.quarantine",
                    code: Int(ESTALE),
                    userInfo: [NSLocalizedDescriptionKey: "Quarantine intent identity mismatch; source and planned paths were retained."]
                )
                try updateArchiveQuarantine(id: id, status: .failed, error: error)
                throw error
            }
        }
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            let errorCode = errno
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            do {
                try updateArchiveQuarantine(id: id, status: .failed, error: error)
            } catch let registryError {
                throw NSError(
                    domain: "com.grove.decompress.quarantine",
                    code: Int(EIO),
                    userInfo: [NSLocalizedDescriptionKey: "Opening quarantine failed: \(error.localizedDescription). Persisting failure also failed: \(registryError.localizedDescription)"]
                )
            }
            throw error
        }
        defer { close(parentDescriptor) }
        do {
            try removeArchiveTreeDescriptorRelative(
                named: url.lastPathComponent,
                in: parentDescriptor,
                expected: expected,
                displayURL: url
            )
            try updateArchiveQuarantine(id: id, status: .sanitized)
        } catch {
            try updateArchiveQuarantine(id: id, status: .failed, error: error)
            throw error
        }
        guard let updated = try archiveQuarantineRecords().first(where: { $0.id == id }) else {
            throw NSError(domain: "com.grove.decompress.quarantine", code: Int(ENOENT))
        }
        return updated
    }

    /// Removes only registry entries whose recorded path is absent. It never deletes a filesystem
    /// name, so an operator or OS cleanup cannot make Grove erase a later substitute.
    @discardableResult
    func pruneMissingArchiveQuarantineRecords() throws -> Int {
        retainedCleanupLock.lock()
        defer { retainedCleanupLock.unlock() }
        var records = try loadArchiveQuarantineRecordsLocked()
        let originalCount = records.count
        records.removeAll { record in
            var info = stat()
            guard lstat(record.path, &info) != 0, errno == ENOENT else { return false }
            if record.sanitationStatus == .intent,
               let sourceParentPath = record.sourceParentPath,
               let sourceName = record.sourceName {
                let sourcePath = URL(fileURLWithPath: sourceParentPath, isDirectory: true)
                    .appendingPathComponent(sourceName).path
                return lstat(sourcePath, &info) != 0 && errno == ENOENT
            }
            return true
        }
        try persistArchiveQuarantineRecordsLocked(records)
        return originalCount - records.count
    }

    /// Test/support seam for using an isolated durable registry, and for simulating restart recovery.
    func configureArchiveQuarantineRegistry(at url: URL?) {
        retainedCleanupLock.lock()
        quarantineRegistryURLOverride = url
        archiveRetirementDirectoriesByDevice.removeAll()
        retainedCleanupLock.unlock()
    }

    func configureArchiveQuarantineSiblingFallbackForTesting(_ forced: Bool) {
        retainedCleanupLock.lock()
        forceArchiveQuarantineSiblingFallbackForTesting = forced
        retainedCleanupLock.unlock()
    }

    func configureArchiveCleanupDescriptorPathFailureForTesting(_ forced: Bool) {
        retainedCleanupLock.lock()
        forceArchiveCleanupDescriptorPathFailureForTesting = forced
        retainedCleanupLock.unlock()
    }

    func configureArchiveSanitationFailureForTesting(_ stage: ArchiveSanitationFailureStage?) {
        retainedCleanupLock.lock()
        archiveSanitationFailureStageForTesting = stage
        retainedCleanupLock.unlock()
    }

    func configureArchiveAfterSanitationInventoryForTesting(
        _ hook: ((URL) throws -> Void)?
    ) {
        retainedCleanupLock.lock()
        archiveAfterSanitationInventoryForTesting = hook
        retainedCleanupLock.unlock()
    }

    func configureArchiveSymlinkNeutralizationHooksForTesting(
        beforeSwap: ((URL) throws -> Void)? = nil,
        beforeSensitiveRelocation: ((URL) throws -> Void)? = nil,
        forceSwapFailure: Bool = false
    ) {
        retainedCleanupLock.lock()
        archiveSymlinkBeforeSwapForTesting = beforeSwap
        archiveSymlinkBeforeSensitiveRelocationForTesting = beforeSensitiveRelocation
        forceArchiveSymlinkSwapFailureForTesting = forceSwapFailure
        retainedCleanupLock.unlock()
    }

    /// Returns and clears paths of sanitized quarantine trees intentionally retained for safety.
    /// Callers may present or manage these paths, but must not assume a later path still identifies
    /// the same inode without their own descriptor-bound policy.
    func consumeRetainedArchiveCleanupTrees() -> [URL] {
        retainedCleanupLock.lock()
        defer { retainedCleanupLock.unlock() }
        let paths = retainedArchiveCleanupTrees
        retainedArchiveCleanupTrees.removeAll()
        return paths
    }

    private func verifyArchiveParentNamespace(_ parent: URL, expected: ArchiveTreeIdentity) throws {
        var info = stat()
        let status = lstat(parent.path, &info)
        guard status == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              ArchiveTreeIdentity(device: info.st_dev, inode: info.st_ino) == expected else {
            let errorCode = status == 0 ? ESTALE : errno
            throw NSError(
                domain: "com.grove.decompress.commit",
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "The archive destination parent namespace changed before commit; no archive was published."]
            )
        }
    }

    private func createArchiveExtractionTransaction(appropriateFor destination: URL) throws -> URL {
        if let directory = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        ) {
            return directory
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            ".grove-extract-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private struct PreparedEncryptedArchiveMetadataEntry {
        let manifestEntry: EncryptedArchiveMetadataEntry
        let target: URL
        let isSymbolicLink: Bool
    }

    /// Preflights every metadata entry against members in a fresh private extraction tree before applying
    /// anything. The exact control name comes from the ZIP EOCD comment and is repeated inside manifest
    /// v2, so similarly prefixed user roots are never scanned or consumed. The control tree is removed on
    /// every exit. Third-party extractors can read the regular encrypted ZIP members, but will expose the
    /// private control directory and will not restore Grove's macOS metadata.
    func rehydrateEncryptedArchiveMetadata(
        in destination: URL,
        metadataDirectoryName: String,
        cancellationRequested: @escaping () -> Bool
    ) throws {
        guard isValidEncryptedArchiveMetadataDirectoryName(metadataDirectoryName) else {
            throw invalidEncryptedArchiveMetadataPath(metadataDirectoryName)
        }
        let canonicalDestination = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let metadataRoot = destination.appendingPathComponent(metadataDirectoryName, isDirectory: true)
        let destinationDescriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destinationDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(destinationDescriptor) }

        var metadataInfo = stat()
        guard lstat(metadataRoot.path, &metadataInfo) == 0,
              metadataInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw invalidEncryptedArchiveMetadataPath(metadataDirectoryName)
        }
        let metadataIdentity = ArchiveTreeIdentity(device: metadataInfo.st_dev, inode: metadataInfo.st_ino)
        var metadataCleanupCompleted = false
        defer {
            if !metadataCleanupCompleted {
                do {
                    try identityBoundRemoveArchiveTree(
                        named: metadataDirectoryName,
                        in: destinationDescriptor,
                        expected: metadataIdentity,
                        displayURL: metadataRoot
                    )
                } catch {
                    // identityBoundRemoveArchiveTree durably records and reports every retained tree.
                    Self.logger.error(
                        "Deferred encrypted metadata cleanup failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        let manifestURL = metadataRoot.appendingPathComponent(Self.encryptedArchiveMetadataManifestName)
        var manifestInfo = stat()
        guard lstat(manifestURL.path, &manifestInfo) == 0,
              manifestInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw invalidEncryptedArchiveMetadataPath(manifestURL.lastPathComponent)
        }
        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try PropertyListDecoder().decode(
            EncryptedArchiveMetadataManifest.self,
            from: manifestData
        )
        guard manifest.version == 2,
              manifest.controlDirectoryName == metadataDirectoryName else {
            throw NSError(
                domain: "com.grove.archive-metadata",
                code: Int(EBADMSG),
                userInfo: [NSLocalizedDescriptionKey: "The encrypted archive metadata locator is invalid or unsupported."]
            )
        }

        var relativePaths = Set<String>()
        var preparedEntries: [PreparedEncryptedArchiveMetadataEntry] = []
        for entry in manifest.entries {
            guard !cancellationRequested() else {
                throw archiveCancellationError(domain: "com.grove.decompress")
            }
            let components = entry.relativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard !components.isEmpty,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  components.first != metadataDirectoryName,
                  relativePaths.insert(entry.relativePath).inserted,
                  entry.modificationNanoseconds >= 0,
                  entry.modificationNanoseconds < 1_000_000_000,
                  entry.permissions & ~0o7777 == 0 else {
                throw invalidEncryptedArchiveMetadataPath(entry.relativePath)
            }
            var attributeNames = Set<String>()
            guard entry.attributes.allSatisfy({ attribute in
                !attribute.name.isEmpty
                    && !attribute.name.contains("\0")
                    && attributeNames.insert(attribute.name).inserted
            }) else {
                throw invalidEncryptedArchiveMetadataPath(entry.relativePath)
            }

            let target = components.reduce(destination) { partial, component in
                partial.appendingPathComponent(component)
            }
            let canonicalParent = target.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalParent == canonicalDestination
                    || canonicalParent.hasPrefix(canonicalDestination + "/") else {
                throw invalidEncryptedArchiveMetadataPath(entry.relativePath)
            }
            var targetInfo = stat()
            guard lstat(target.path, &targetInfo) == 0,
                  UInt32(targetInfo.st_mode & mode_t(S_IFMT)) == entry.fileType else {
                throw invalidEncryptedArchiveMetadataPath(entry.relativePath)
            }

            let isSymbolicLink = entry.fileType == UInt32(S_IFLNK)
            if !isSymbolicLink {
                let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonicalTarget == canonicalDestination
                        || canonicalTarget.hasPrefix(canonicalDestination + "/") else {
                    throw invalidEncryptedArchiveMetadataPath(entry.relativePath)
                }
            }
            preparedEntries.append(
                PreparedEncryptedArchiveMetadataEntry(
                    manifestEntry: entry,
                    target: target,
                    isSymbolicLink: isSymbolicLink
                )
            )
        }

        // Directories are applied after their descendants so writing child metadata cannot perturb the
        // final directory modification time. All entries were validated above before this first mutation.
        preparedEntries.sort {
            $0.manifestEntry.relativePath.split(separator: "/").count
                > $1.manifestEntry.relativePath.split(separator: "/").count
        }
        for prepared in preparedEntries {
            guard !cancellationRequested() else {
                throw archiveCancellationError(domain: "com.grove.decompress")
            }
            for attribute in prepared.manifestEntry.attributes {
                try setArchiveExtendedAttribute(
                    attribute,
                    at: prepared.target,
                    noFollow: prepared.isSymbolicLink
                )
            }
            if let accessControlList = prepared.manifestEntry.accessControlList {
                try setArchiveAccessControlList(
                    accessControlList,
                    at: prepared.target,
                    noFollow: prepared.isSymbolicLink
                )
            }
            if !prepared.isSymbolicLink {
                guard Darwin.chmod(prepared.target.path, mode_t(prepared.manifestEntry.permissions)) == 0 else {
                    let errorCode = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
            }
            let times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(
                    tv_sec: time_t(prepared.manifestEntry.modificationSeconds),
                    tv_nsec: Int(prepared.manifestEntry.modificationNanoseconds)
                )
            ]
            let timeFlags = prepared.isSymbolicLink ? AT_SYMLINK_NOFOLLOW : 0
            let timeResult = times.withUnsafeBufferPointer { buffer in
                utimensat(AT_FDCWD, prepared.target.path, buffer.baseAddress, timeFlags)
            }
            guard timeResult == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if let flags = prepared.manifestEntry.flags {
                let flagResult = prepared.isSymbolicLink
                    ? lchflags(prepared.target.path, flags)
                    : chflags(prepared.target.path, flags)
                guard flagResult == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
        try identityBoundRemoveArchiveTree(
            named: metadataDirectoryName,
            in: destinationDescriptor,
            expected: metadataIdentity,
            displayURL: metadataRoot
        )
        metadataCleanupCompleted = true
    }

    private func invalidEncryptedArchiveMetadataPath(_ path: String) -> NSError {
        NSError(
            domain: "com.grove.archive-metadata",
            code: Int(EBADMSG),
            userInfo: [NSLocalizedDescriptionKey: "The encrypted archive contains an invalid metadata path: \(path)"]
        )
    }

    private func isValidEncryptedArchiveMetadataDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(Self.encryptedArchiveMetadataDirectoryPrefix) else { return false }
        let identifier = String(name.dropFirst(Self.encryptedArchiveMetadataDirectoryPrefix.count))
        return identifier.count == 36 && UUID(uuidString: identifier) != nil
    }

    private func encryptedArchiveEOCD(in tail: Data) -> (offset: Int, commentLength: Int)? {
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { return nil }
        for offset in stride(from: bytes.count - 22, through: 0, by: -1) {
            guard bytes[offset] == 0x50,
                  bytes[offset + 1] == 0x4B,
                  bytes[offset + 2] == 0x05,
                  bytes[offset + 3] == 0x06 else { continue }
            let commentLength = Int(bytes[offset + 20]) | (Int(bytes[offset + 21]) << 8)
            guard offset + 22 + commentLength == bytes.count else { continue }
            return (offset, commentLength)
        }
        return nil
    }

    private func encryptedArchiveEOCDTail(
        from handle: FileHandle
    ) throws -> (fileSize: UInt64, tailOffset: UInt64, tail: Data, eocdOffset: Int, commentLength: Int) {
        let fileSize = try handle.seekToEnd()
        let maximumEOCDSize = UInt64(22 + Int(UInt16.max))
        let tailSize = min(fileSize, maximumEOCDSize)
        let tailOffset = fileSize - tailSize
        try handle.seek(toOffset: tailOffset)
        guard let tail = try handle.read(upToCount: Int(tailSize)),
              let eocd = encryptedArchiveEOCD(in: tail) else {
            throw NSError(
                domain: "com.grove.archive-metadata",
                code: Int(EBADMSG),
                userInfo: [NSLocalizedDescriptionKey: "The encrypted ZIP central directory is invalid."]
            )
        }
        return (fileSize, tailOffset, tail, eocd.offset, eocd.commentLength)
    }

    /// Stores the exact random control-directory locator in the ZIP EOCD comment. The comment is not
    /// secret (ZIP central-directory names are also visible), while the manifest itself remains encrypted.
    /// Traditional ZipCrypto does not authenticate the EOCD or central directory, so the locator is exact
    /// routing rather than an authenticity claim; safety comes from fresh-tree extraction, member binding,
    /// and manifest preflight. A third-party tool that strips/changes the comment will still extract regular
    /// ZIP members, but will expose the control directory and will not restore Grove-specific metadata.
    /// The locator is validated again against manifest v2 after password-protected extraction.
    func writeEncryptedArchiveMetadataLocator(_ metadataDirectoryName: String, to archiveURL: URL) throws {
        guard isValidEncryptedArchiveMetadataDirectoryName(metadataDirectoryName) else {
            throw invalidEncryptedArchiveMetadataPath(metadataDirectoryName)
        }
        let comment = Data(
            (Self.encryptedArchiveMetadataCommentPrefix + metadataDirectoryName).utf8
        )
        guard comment.count <= Int(UInt16.max) else {
            throw invalidEncryptedArchiveMetadataPath(metadataDirectoryName)
        }

        let handle = try FileHandle(forUpdating: archiveURL)
        defer { try? handle.close() }
        let eocd = try encryptedArchiveEOCDTail(from: handle)
        let absoluteEOCDOffset = eocd.tailOffset + UInt64(eocd.eocdOffset)
        var littleEndianLength = UInt16(comment.count).littleEndian
        try handle.seek(toOffset: absoluteEOCDOffset + 20)
        try withUnsafeBytes(of: &littleEndianLength) { bytes in
            try handle.write(contentsOf: Data(bytes))
        }
        try handle.seek(toOffset: absoluteEOCDOffset + 22)
        try handle.write(contentsOf: comment)
        try handle.truncate(atOffset: absoluteEOCDOffset + 22 + UInt64(comment.count))
        try handle.synchronize()
    }

    func encryptedArchiveMetadataLocator(in archiveURL: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let eocd = try encryptedArchiveEOCDTail(from: handle)
        guard eocd.commentLength > 0 else { return nil }
        let commentStart = eocd.eocdOffset + 22
        let comment = eocd.tail.subdata(
            in: commentStart..<(commentStart + eocd.commentLength)
        )
        guard let value = String(data: comment, encoding: .utf8) else { return nil }
        guard value.hasPrefix(Self.encryptedArchiveMetadataCommentPrefix) else { return nil }
        let metadataDirectoryName = String(
            value.dropFirst(Self.encryptedArchiveMetadataCommentPrefix.count)
        )
        guard isValidEncryptedArchiveMetadataDirectoryName(metadataDirectoryName) else {
            throw invalidEncryptedArchiveMetadataPath(metadataDirectoryName)
        }
        return metadataDirectoryName
    }

    /// `zip -P` and `unzip -P` expose the password in their process arguments. macOS's archive tools
    /// also support a terminal prompt, so use `expect` solely as a pseudo-terminal bridge and provide
    /// the password through its standard input. The password is never placed in arguments, the
    /// environment, a log, or a temporary file.
    func passwordProtectedArchiveInvocation(
        toolPath: String,
        arguments: [String],
        password: String,
        promptTimeout: TimeInterval = 30,
        operationTimeout: TimeInterval? = nil,
        expectedPasswordPrompts: Int = 1
    ) -> PasswordProtectedArchiveInvocation {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GROVE_ARCHIVE_") {
            environment.removeValue(forKey: key)
        }
        environment["GROVE_ARCHIVE_TOOL"] = toolPath
        environment["GROVE_ARCHIVE_ARGUMENT_COUNT"] = String(arguments.count)
        let normalizedPromptTimeout = promptTimeout.isFinite ? promptTimeout : 30
        environment["GROVE_ARCHIVE_PROMPT_TIMEOUT_SECONDS"] = String(
            min(3600, max(1, Int(ceil(normalizedPromptTimeout))))
        )
        if let operationTimeout, operationTimeout.isFinite {
            environment["GROVE_ARCHIVE_OPERATION_TIMEOUT_SECONDS"] = String(max(1, Int(ceil(operationTimeout))))
        } else {
            environment["GROVE_ARCHIVE_OPERATION_TIMEOUT_SECONDS"] = "-1"
        }
        environment["GROVE_ARCHIVE_EXPECTED_PASSWORD_PROMPTS"] = String(max(1, expectedPasswordPrompts))
        for (index, argument) in arguments.enumerated() {
            environment["GROVE_ARCHIVE_ARGUMENT_\(index)"] = argument
        }

        let encodedPassword = password.utf8.map { String(format: "%02x", $0) }.joined()
        return PasswordProtectedArchiveInvocation(
            executablePath: "/usr/bin/expect",
            arguments: ["-c", Self.passwordProtectedArchiveExpectScript],
            environment: environment,
            // Hex framing keeps the secret on stdin while supporting any UTF-8 character without
            // treating a newline in the password as the end of the input record.
            standardInput: Data("\(encodedPassword)\n".utf8),
            archiveToolPath: toolPath,
            archiveToolArguments: arguments
        )
    }

    private static let passwordProtectedArchiveExpectScript = #"""
    log_user 0
    set timeout $env(GROVE_ARCHIVE_PROMPT_TIMEOUT_SECONDS)
    fconfigure stdin -encoding utf-8 -translation lf
    if {[gets stdin encodedPassword] < 0 || [string length $encodedPassword] == 0} {
        puts stderr "Archive password input was unavailable."
        exit 125
    }
    if {[catch {set password [encoding convertfrom utf-8 [binary format H* $encodedPassword]]}]} {
        puts stderr "Archive password input was invalid."
        exit 125
    }

    set command [list $env(GROVE_ARCHIVE_TOOL)]
    for {set index 0} {$index < $env(GROVE_ARCHIVE_ARGUMENT_COUNT)} {incr index} {
        set key GROVE_ARCHIVE_ARGUMENT_$index
        lappend command $env($key)
    }

    set childSpawned 0
    proc terminateArchiveTool {} {
        global spawn_id childSpawned
        if {!$childSpawned || [catch {set childPID [exp_pid -i $spawn_id]}]} {
            return
        }
        catch {exec /bin/kill -TERM -- -$childPID}
        catch {exec /bin/kill -TERM -- $childPID}
        after 200
        catch {exec /bin/kill -KILL -- -$childPID}
        catch {exec /bin/kill -KILL -- $childPID}
        catch {close -i $spawn_id}
        catch {wait -i $spawn_id}
        set childSpawned 0
    }

    trap {terminateArchiveTool; exit 130} {SIGHUP SIGINT SIGTERM}

    set childSpawned 1
    if {[catch {spawn -noecho {*}$command}]} {
        set childSpawned 0
        puts stderr "Could not start the archive tool."
        exit 126
    }

    puts stdout "GROVE_ARCHIVE_CHILD_PID:[exp_pid -i $spawn_id]"
    flush stdout

    set promptCount 0
    set expectedPromptCount $env(GROVE_ARCHIVE_EXPECTED_PASSWORD_PROMPTS)
    while {1} {
        expect {
            -re {(incorrect password|password incorrect|unable to get password)} {
                puts stderr "Incorrect password or invalid encrypted archive."
                terminateArchiveTool
                exit 82
            }
            -re {password: $} {
                incr promptCount
            if {$promptCount > $expectedPromptCount} {
                puts stderr "Archive tool requested an unexpected additional password."
                terminateArchiveTool
                exit 82
            }
            # Give the child time to finish changing the PTY line discipline after printing its
            # prompt. Sending immediately can race zip/zipcloak before canonical input is ready.
            after 200
            send -- "$password\r"
                if {$promptCount == $expectedPromptCount} {
                    puts stdout "GROVE_ARCHIVE_AUTHENTICATED"
                    flush stdout
                    set timeout $env(GROVE_ARCHIVE_OPERATION_TIMEOUT_SECONDS)
                }
                exp_continue
            }
            eof { break }
            timeout {
                if {$promptCount == 0} {
                    puts stderr "Archive tool timed out while waiting for a password prompt."
                } elseif {$promptCount < $expectedPromptCount} {
                    puts stderr "Archive tool timed out while waiting for password confirmation."
                } else {
                    puts stderr "Archive operation exceeded its configured deadline."
                }
                terminateArchiveTool
                exit 124
            }
        }
    }

    set result [wait]
    if {[llength $result] != 4} {
        puts stderr "Archive tool terminated unexpectedly."
        exit 128
    }
    if {[lindex $result 2] != 0} {
        puts stderr "The archive tool could not be completed."
        exit 1
    }
    set exitStatus [lindex $result 3]
    if {![string is integer -strict $exitStatus] || $exitStatus < 0 || $exitStatus > 255} {
        puts stderr "Archive tool terminated unexpectedly."
        exit 128
    }
    exit $exitStatus
    """#

    func runPasswordProtectedArchiveTool(
        _ executablePath: String,
        arguments: [String],
        password: String,
        currentDirectory: URL? = nil,
        errorDomain: String,
        fallbackMessage: String,
        promptTimeout: TimeInterval = 30,
        operationTimeout: TimeInterval? = nil,
        expectedPasswordPrompts: Int = 1,
        cancellationRequested: @escaping () -> Bool = { false },
        processStarted: ((pid_t) -> Void)? = nil,
        childProcessStarted: ((pid_t) -> Void)? = nil
    ) throws {
        guard !cancellationRequested() else {
            throw NSError(
                domain: errorDomain,
                code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: "Archive operation cancelled."]
            )
        }
        let boundedPromptTimeout = promptTimeout.isFinite
            ? min(3600, max(1, promptTimeout))
            : 30
        let boundedOperationTimeout = operationTimeout.flatMap { timeout in
            timeout.isFinite ? max(1, timeout) : nil
        }
        let invocation = passwordProtectedArchiveInvocation(
            toolPath: executablePath,
            arguments: arguments,
            password: password,
            promptTimeout: boundedPromptTimeout,
            operationTimeout: boundedOperationTimeout,
            expectedPasswordPrompts: expectedPasswordPrompts
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let inputPipe = Pipe()
        let controlPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = controlPipe
        process.standardError = errorPipe

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminationSemaphore.signal() }
        let controlLock = NSLock()
        var controlParser = ArchiveControlRecordParser()
        var controlError: NSError?
        var childPID: pid_t?
        var authenticatedAt: Date?
        controlPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            controlLock.lock()
            do {
                for record in try controlParser.append(data) {
                    switch record {
                    case .childPID(let parsedPID):
                        guard childPID == nil else {
                            throw ArchiveControlRecordError.malformed
                        }
                        childPID = parsedPID
                    case .authenticated:
                        guard childPID != nil, authenticatedAt == nil else {
                            throw ArchiveControlRecordError.malformed
                        }
                        authenticatedAt = Date()
                    }
                }
            } catch {
                controlError = NSError(
                    domain: errorDomain,
                    code: Int(EBADMSG),
                    userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
                )
            }
            controlLock.unlock()
        }
        defer { controlPipe.fileHandleForReading.readabilityHandler = nil }

        guard invocation.standardInput.count <= 32 * 1024 else {
            throw NSError(
                domain: errorDomain,
                code: Int(E2BIG),
                userInfo: [NSLocalizedDescriptionKey: "Archive password is too long."]
            )
        }

        try process.run()
        processStarted?(process.processIdentifier)

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: invocation.standardInput)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            terminatePasswordProtectedArchiveProcess(process, childPID: nil)
            throw error
        }

        let promptDeadline = Date().addingTimeInterval(boundedPromptTimeout + 3)
        var didNotifyChildStart = false
        var forcedError: NSError?
        var didTerminate = false
        while !didTerminate {
            if terminationSemaphore.wait(timeout: .now() + .milliseconds(50)) == .success {
                didTerminate = true
                break
            }

            controlLock.lock()
            let capturedChildPID = childPID
            let capturedAuthenticatedAt = authenticatedAt
            let capturedControlError = controlError
            controlLock.unlock()

            if let capturedControlError {
                forcedError = capturedControlError
                break
            }

            if let capturedChildPID, !didNotifyChildStart {
                didNotifyChildStart = true
                childProcessStarted?(capturedChildPID)
            }

            // Cancellation is intentionally deferred until the PID/process-group handshake. Before
            // that point Swift cannot safely distinguish "wrapper stopped" from "child orphaned".
            if capturedChildPID != nil && cancellationRequested() {
                forcedError = NSError(
                    domain: errorDomain,
                    code: NSUserCancelledError,
                    userInfo: [NSLocalizedDescriptionKey: "Archive operation cancelled."]
                )
                break
            }

            if capturedAuthenticatedAt == nil && Date() >= promptDeadline {
                forcedError = NSError(
                    domain: errorDomain,
                    code: 124,
                    userInfo: [NSLocalizedDescriptionKey: "Archive tool timed out while waiting for a password prompt."]
                )
                break
            }

            if let boundedOperationTimeout,
               let capturedAuthenticatedAt,
               Date() >= capturedAuthenticatedAt.addingTimeInterval(boundedOperationTimeout + 1) {
                forcedError = NSError(
                    domain: errorDomain,
                    code: 124,
                    userInfo: [NSLocalizedDescriptionKey: "Archive operation exceeded its configured deadline."]
                )
                break
            }
        }

        if let forcedError {
            controlLock.lock()
            let capturedChildPID = childPID
            controlLock.unlock()
            terminatePasswordProtectedArchiveProcess(process, childPID: capturedChildPID)
            _ = terminationSemaphore.wait(timeout: .now() + .seconds(1))
            throw forcedError
        }

        process.waitUntilExit()
        controlPipe.fileHandleForReading.readabilityHandler = nil
        controlLock.lock()
        if controlError == nil {
            do {
                try controlParser.finish()
            } catch {
                controlError = NSError(
                    domain: errorDomain,
                    code: Int(EBADMSG),
                    userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
                )
            }
        }
        let finalControlError = controlError
        let finalChildPID = childPID
        controlLock.unlock()
        let outputData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if let finalControlError {
            throw finalControlError
        }
        if process.terminationStatus == 0 && finalChildPID == nil {
            throw NSError(
                domain: errorDomain,
                code: Int(EBADMSG),
                userInfo: [NSLocalizedDescriptionKey: "Archive control channel did not identify its child process."]
            )
        }

        if process.terminationStatus != 0 {
            let rawMessage = String(data: outputData, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            // Defense in depth: even if a future archive tool unexpectedly echoes its input, never
            // surface the supplied secret in an NSError that callers may display or log.
            let message = rawMessage?
                .replacingOccurrences(of: password, with: "[redacted]")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: errorDomain,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackMessage]
            )
        }
    }

    private func terminatePasswordProtectedArchiveProcess(_ process: Process, childPID: pid_t?) {
        if let childPID, childPID > 0 {
            // Expect's PTY child is its own process-group leader. Signal both the group and PID so any
            // archive-tool descendants are cleaned up even if the wrapper is no longer responsive.
            _ = Darwin.kill(-childPID, SIGTERM)
            _ = Darwin.kill(childPID, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }

        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < graceDeadline {
            usleep(10_000)
        }

        if let childPID, childPID > 0 {
            _ = Darwin.kill(-childPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGKILL)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }

        // Never turn cleanup itself into another unbounded wait. Foundation's termination handler
        // reaps the wrapper; callers wait on its semaphore with their own deadline.
        let reapDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < reapDeadline {
            usleep(10_000)
        }
    }

    /// Runs an external archiving tool while draining stderr and polling cancellation. This bounds both
    /// pipe back-pressure and cancellation latency instead of blocking in `readDataToEndOfFile()` until
    /// the child happens to exit.
    func runArchiveTool(
        _ executablePath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        errorDomain: String,
        fallbackMessage: String,
        cancellationRequested: @escaping () -> Bool = { false },
        processStarted: ((pid_t) -> Void)? = nil
    ) throws {
        guard !cancellationRequested() else {
            throw archiveCancellationError(domain: errorDomain)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorCollector = ArchivePipeCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorCollector.append(data) }
        }
        defer { errorPipe.fileHandleForReading.readabilityHandler = nil }

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminationSemaphore.signal() }

        try process.run()
        processStarted?(process.processIdentifier)

        while terminationSemaphore.wait(timeout: .now() + .milliseconds(50)) != .success {
            if cancellationRequested() {
                terminateArchiveProcess(process)
                _ = terminationSemaphore.wait(timeout: .now() + .seconds(1))
                throw archiveCancellationError(domain: errorDomain)
            }
        }

        process.waitUntilExit()
        errorPipe.fileHandleForReading.readabilityHandler = nil
        errorCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        if process.terminationStatus != 0 {
            let message = String(data: errorCollector.snapshot(), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackMessage
            throw NSError(domain: errorDomain, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func terminateArchiveProcess(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private func archiveCancellationError(domain: String = "com.grove.compress") -> NSError {
        NSError(
            domain: domain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "Archive operation cancelled."]
        )
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

    struct ArchiveStagingReport: Equatable {
        var createdDirectories = 0
        var hardLinkedFiles = 0
        var copiedFiles = 0
        var symbolicLinks = 0
        var hardLinkedBytes: Int64 = 0
        var copiedBytes: Int64 = 0

        static func += (lhs: inout ArchiveStagingReport, rhs: ArchiveStagingReport) {
            lhs.createdDirectories += rhs.createdDirectories
            lhs.hardLinkedFiles += rhs.hardLinkedFiles
            lhs.copiedFiles += rhs.copiedFiles
            lhs.symbolicLinks += rhs.symbolicLinks
            lhs.hardLinkedBytes += rhs.hardLinkedBytes
            lhs.copiedBytes += rhs.copiedBytes
        }
    }

    private struct ArchiveStagingExclusion {
        let device: dev_t
        let inode: ino_t
        let canonicalPath: String
    }

    struct EncryptedArchiveMetadataManifest: Codable {
        let version: Int
        let controlDirectoryName: String
        let entries: [EncryptedArchiveMetadataEntry]
    }

    struct EncryptedArchiveMetadataEntry: Codable {
        let relativePath: String
        let fileType: UInt32
        let permissions: UInt16
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let attributes: [EncryptedArchiveExtendedAttribute]
        let flags: UInt32?
        let accessControlList: Data?

        init(
            relativePath: String,
            fileType: UInt32,
            permissions: UInt16,
            modificationSeconds: Int64,
            modificationNanoseconds: Int64,
            attributes: [EncryptedArchiveExtendedAttribute],
            flags: UInt32? = nil,
            accessControlList: Data? = nil
        ) {
            self.relativePath = relativePath
            self.fileType = fileType
            self.permissions = permissions
            self.modificationSeconds = modificationSeconds
            self.modificationNanoseconds = modificationNanoseconds
            self.attributes = attributes
            self.flags = flags
            self.accessControlList = accessControlList
        }
    }

    struct EncryptedArchiveExtendedAttribute: Codable {
        let name: String
        let value: Data
    }

    static let encryptedArchiveMetadataDirectoryPrefix = ".GroveArchiveMetadata-"
    static let encryptedArchiveMetadataManifestName = "manifest.plist"
    private static let encryptedArchiveMetadataCommentPrefix = "GROVE-METADATA-V2:"

    struct ArchiveCompressionHooks {
        var hardLinkItem: ((URL, URL) throws -> Void)?
        var stagingDirectoryCreated: ((URL) -> Void)?
        var encryptedArchiveTransformer: ((URL) throws -> Void)?

        init(
            hardLinkItem: ((URL, URL) throws -> Void)? = nil,
            stagingDirectoryCreated: ((URL) -> Void)? = nil,
            encryptedArchiveTransformer: ((URL) throws -> Void)? = nil
        ) {
            self.hardLinkItem = hardLinkItem
            self.stagingDirectoryCreated = stagingDirectoryCreated
            self.encryptedArchiveTransformer = encryptedArchiveTransformer
        }
    }

    struct ArchiveExtractionHooks {
        var extractionDirectoryCreated: ((URL) -> Void)?
        var replacementDirectoryCreated: ((URL) -> Void)?
        var finalMerge: ((URL, URL, @escaping () -> Bool) throws -> Void)?
        var immediatelyBeforeCommit: ((URL, URL) throws -> Void)?
        var immediatelyBeforeCleanup: ((URL) throws -> Void)?
        var immediatelyAfterQuarantineVerification: ((URL) throws -> Void)?
        var immediatelyAfterQuarantineIntentPersisted: ((URL) throws -> Void)?
        var immediatelyBeforeQuarantineRootRemoval: ((URL) throws -> Void)?
        var destinationPreparationStarted: (() throws -> Void)?
        var destinationPreparationFinished: (() throws -> Void)?
        var internalCopyStatus: ((Int64) -> Void)?
        var cleanupTreeRetained: ((URL) -> Void)?
        var immediatelyBeforeCleanupChildRetention: ((URL) throws -> Void)?
        var postCommitCleanupWarning: ((Error) -> Void)?

        init(
            extractionDirectoryCreated: ((URL) -> Void)? = nil,
            replacementDirectoryCreated: ((URL) -> Void)? = nil,
            finalMerge: ((URL, URL, @escaping () -> Bool) throws -> Void)? = nil,
            immediatelyBeforeCommit: ((URL, URL) throws -> Void)? = nil,
            immediatelyBeforeCleanup: ((URL) throws -> Void)? = nil,
            immediatelyAfterQuarantineVerification: ((URL) throws -> Void)? = nil,
            immediatelyAfterQuarantineIntentPersisted: ((URL) throws -> Void)? = nil,
            immediatelyBeforeQuarantineRootRemoval: ((URL) throws -> Void)? = nil,
            destinationPreparationStarted: (() throws -> Void)? = nil,
            destinationPreparationFinished: (() throws -> Void)? = nil,
            internalCopyStatus: ((Int64) -> Void)? = nil,
            cleanupTreeRetained: ((URL) -> Void)? = nil,
            immediatelyBeforeCleanupChildRetention: ((URL) throws -> Void)? = nil,
            postCommitCleanupWarning: ((Error) -> Void)? = nil
        ) {
            self.extractionDirectoryCreated = extractionDirectoryCreated
            self.replacementDirectoryCreated = replacementDirectoryCreated
            self.finalMerge = finalMerge
            self.immediatelyBeforeCommit = immediatelyBeforeCommit
            self.immediatelyBeforeCleanup = immediatelyBeforeCleanup
            self.immediatelyAfterQuarantineVerification = immediatelyAfterQuarantineVerification
            self.immediatelyAfterQuarantineIntentPersisted = immediatelyAfterQuarantineIntentPersisted
            self.immediatelyBeforeQuarantineRootRemoval = immediatelyBeforeQuarantineRootRemoval
            self.destinationPreparationStarted = destinationPreparationStarted
            self.destinationPreparationFinished = destinationPreparationFinished
            self.internalCopyStatus = internalCopyStatus
            self.cleanupTreeRetained = cleanupTreeRetained
            self.immediatelyBeforeCleanupChildRetention = immediatelyBeforeCleanupChildRetention
            self.postCommitCleanupWarning = postCommitCleanupWarning
        }
    }

    func compress(
        _ urls: [URL],
        to archiveURL: URL,
        level: CompressionLevel = .normal,
        password: String? = nil,
        operationTimeout: TimeInterval? = nil,
        cancellationRequested: @escaping () -> Bool = { false },
        archiveToolStarted: ((pid_t) -> Void)? = nil,
        archiveChildStarted: ((pid_t) -> Void)? = nil,
        hooks: ArchiveCompressionHooks = ArchiveCompressionHooks(),
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        backgroundQueue.async {
            let result: Result<URL, Error> = {
                do {
                guard !cancellationRequested() else {
                    throw self.archiveCancellationError()
                }
                try self.validateArchiveRootNames(urls)
                let tempDir = try self.createArchiveStagingDirectory(for: urls)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                hooks.stagingDirectoryCreated?(tempDir)
                let temporaryArchive = self.temporaryArchiveURL(for: archiveURL)
                defer { try? FileManager.default.removeItem(at: temporaryArchive) }

                // Stage sources into the temp directory so the archive members are named by their leaf
                // name. The staging directory is placed on the first source's volume when possible.
                // Directory structure and symlinks are recreated, while regular files are hard-linked
                // individually. Sources from other volumes fall back to per-file copies.
                for url in urls {
                    let dest = tempDir.appendingPathComponent(url.lastPathComponent)
                    try self.stageForArchiving(
                        url,
                        to: dest,
                        hardLinkItem: hooks.hardLinkItem,
                        excluding: tempDir,
                        cancellationRequested: cancellationRequested
                    )
                }
                guard !cancellationRequested() else {
                    throw self.archiveCancellationError()
                }

                if let password = password, !password.isEmpty {
                    if let encryptedArchiveTransformer = hooks.encryptedArchiveTransformer {
                        try encryptedArchiveTransformer(temporaryArchive)
                    } else {
                        // Serialize macOS-only metadata without copying regular data forks, then
                        // encrypt both selected roots and the private manifest tree.
                        let metadataRoot = try self.createEncryptedArchiveMetadata(
                            in: tempDir,
                            cancellationRequested: cancellationRequested
                        )
                        let members = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
                        let args = [
                            "-r", "-y", "-nw", "-q", "-e", "-\(level.rawValue)",
                            temporaryArchive.path, "--"
                        ] + members
                        try self.runPasswordProtectedArchiveTool(
                            "/usr/bin/zip",
                            arguments: args,
                            password: password,
                            currentDirectory: tempDir,
                            errorDomain: "com.grove.compress",
                            fallbackMessage: "Compression failed",
                            operationTimeout: operationTimeout,
                            expectedPasswordPrompts: 2,
                            cancellationRequested: cancellationRequested,
                            processStarted: archiveToolStarted,
                            childProcessStarted: archiveChildStarted
                        )
                        try self.writeEncryptedArchiveMetadataLocator(
                            metadataRoot.lastPathComponent,
                            to: temporaryArchive
                        )
                    }
                } else {
                    let args = [
                        "-c", "-k", "--norsrc", "--noextattr", "--noacl",
                        "--zlibCompressionLevel", "\(level.rawValue)", tempDir.path, temporaryArchive.path
                    ]
                    try self.runArchiveTool(
                        "/usr/bin/ditto",
                        arguments: args,
                        errorDomain: "com.grove.compress",
                        fallbackMessage: "Compression failed",
                        cancellationRequested: cancellationRequested,
                        processStarted: archiveToolStarted
                    )
                }

                guard !cancellationRequested() else {
                    throw self.archiveCancellationError()
                }
                try self.promoteArchive(temporaryArchive, to: archiveURL)

                    return .success(archiveURL)
                } catch {
                    return .failure(error)
                }
            }()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Uses an item-replacement directory because it is created on the selected source's volume. This
    /// makes the common single-volume selection eligible for hard links even when that volume is not the
    /// system volume. If the volume cannot host temporary files (for example, read-only media), staging
    /// falls back to the system temporary directory and the per-file copy path below remains correct.
    func createArchiveStagingDirectory(for sources: [URL]) throws -> URL {
        if let firstSource = sources.first,
           let directory = try? fileManager.url(
               for: .itemReplacementDirectory,
               in: .userDomainMask,
               appropriateFor: firstSource,
               create: true
           ) {
            return directory
        }

        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func temporaryArchiveURL(for archiveURL: URL) -> URL {
        archiveURL.deletingLastPathComponent().appendingPathComponent(
            ".grove-archive-\(UUID().uuidString).zip"
        )
    }

    /// Serializes macOS metadata into one encrypted binary property-list manifest. The regular data
    /// forks remain hard-linked in the main staging tree; only metadata bytes are duplicated.
    func createEncryptedArchiveMetadata(
        in stagingDirectory: URL,
        cancellationRequested: @escaping () -> Bool
    ) throws -> URL {
        let selectedRoots = try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let metadataRoot = stagingDirectory.appendingPathComponent(
            "\(Self.encryptedArchiveMetadataDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: metadataRoot, withIntermediateDirectories: false)
        var entries: [EncryptedArchiveMetadataEntry] = []
        for root in selectedRoots {
            try collectEncryptedArchiveMetadata(
                from: root,
                relativeComponents: [root.lastPathComponent],
                cancellationRequested: cancellationRequested,
                entries: &entries
            )
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let manifest = EncryptedArchiveMetadataManifest(
            version: 2,
            controlDirectoryName: metadataRoot.lastPathComponent,
            entries: entries
        )
        try encoder.encode(manifest).write(
            to: metadataRoot.appendingPathComponent(Self.encryptedArchiveMetadataManifestName),
            options: .withoutOverwriting
        )
        return metadataRoot
    }

    private func collectEncryptedArchiveMetadata(
        from source: URL,
        relativeComponents: [String],
        cancellationRequested: @escaping () -> Bool,
        entries: inout [EncryptedArchiveMetadataEntry]
    ) throws {
        guard !cancellationRequested() else { throw archiveCancellationError() }
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        let fileType = sourceInfo.st_mode & mode_t(S_IFMT)
        let noFollow = fileType == mode_t(S_IFLNK)
        entries.append(
            EncryptedArchiveMetadataEntry(
                relativePath: relativeComponents.joined(separator: "/"),
                fileType: UInt32(fileType),
                permissions: UInt16(sourceInfo.st_mode & 0o7777),
                modificationSeconds: Int64(sourceInfo.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(sourceInfo.st_mtimespec.tv_nsec),
                attributes: try archiveExtendedAttributes(at: source, noFollow: noFollow),
                flags: UInt32(sourceInfo.st_flags),
                accessControlList: try archiveAccessControlList(at: source, noFollow: noFollow)
            )
        )

        guard fileType == mode_t(S_IFDIR) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            try collectEncryptedArchiveMetadata(
                from: child,
                relativeComponents: relativeComponents + [child.lastPathComponent],
                cancellationRequested: cancellationRequested,
                entries: &entries
            )
        }
    }

    private func archiveExtendedAttributes(
        at url: URL,
        noFollow: Bool
    ) throws -> [EncryptedArchiveExtendedAttribute] {
        let options = noFollow ? XATTR_NOFOLLOW : 0
        let byteCount = url.path.withCString { path in
            listxattr(path, nil, 0, options)
        }
        guard byteCount >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard byteCount > 0 else { return [] }

        var namesData = Data(count: byteCount)
        let readCount = namesData.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                listxattr(
                    path,
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    bytes.count,
                    options
                )
            }
        }
        guard readCount == byteCount else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }

        return try namesData.split(separator: 0).map { nameData in
            let name = String(decoding: nameData, as: UTF8.self)
            let valueSize = url.path.withCString { path in
                name.withCString { attributeName in
                    getxattr(path, attributeName, nil, 0, 0, options)
                }
            }
            guard valueSize >= 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            var value = Data(count: valueSize)
            let valueReadCount = value.withUnsafeMutableBytes { bytes in
                url.path.withCString { path in
                    name.withCString { attributeName in
                        getxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, options)
                    }
                }
            }
            guard valueReadCount == valueSize else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            return EncryptedArchiveExtendedAttribute(name: name, value: value)
        }
    }

    private func setArchiveExtendedAttribute(
        _ attribute: EncryptedArchiveExtendedAttribute,
        at url: URL,
        noFollow: Bool
    ) throws {
        guard !attribute.name.isEmpty, !attribute.name.contains("\0") else {
            throw NSError(domain: "com.grove.archive-metadata", code: Int(EBADMSG))
        }
        let options = noFollow ? XATTR_NOFOLLOW : 0
        let result = attribute.value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                attribute.name.withCString { name in
                    setxattr(path, name, bytes.baseAddress, bytes.count, 0, options)
                }
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
    }

    private func archiveAccessControlList(at url: URL, noFollow: Bool) throws -> Data? {
        errno = 0
        let acl = url.path.withCString { path in
            noFollow
                ? acl_get_link_np(path, ACL_TYPE_EXTENDED)
                : acl_get_file(path, ACL_TYPE_EXTENDED)
        }
        guard let acl else {
            let errorCode = errno
            if errorCode == ENOENT || errorCode == ENOTSUP { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let byteCount = acl_size(acl)
        guard byteCount >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard byteCount > 0 else { return nil }
        var data = Data(count: Int(byteCount))
        let copied = data.withUnsafeMutableBytes { bytes in
            acl_copy_ext(bytes.baseAddress, acl, byteCount)
        }
        guard copied == byteCount else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return data
    }

    private func setArchiveAccessControlList(
        _ data: Data,
        at url: URL,
        noFollow: Bool
    ) throws {
        let acl = data.withUnsafeBytes { bytes in
            acl_copy_int(bytes.baseAddress)
        }
        guard let acl else {
            throw NSError(domain: "com.grove.archive-metadata", code: Int(EBADMSG))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let result = url.path.withCString { path in
            noFollow
                ? acl_set_link_np(path, ACL_TYPE_EXTENDED, acl)
                : acl_set_file(path, ACL_TYPE_EXTENDED, acl)
        }
        if result != 0, noFollow, errno == ENOTSUP {
            // acl_set_link_np is unavailable on some APFS/macOS combinations even though chmod(1)
            // supports no-follow ACL replacement. Pass the already-validated ACL as stdin (never as
            // shell text or argv) so the symbolic-link target is not followed.
            try setArchiveSymbolicLinkAccessControlListWithChmod(acl, at: url)
            return
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not restore archive ACL at \(url.path): \(String(cString: strerror(errorCode)))"]
            )
        }
    }

    private func setArchiveSymbolicLinkAccessControlListWithChmod(
        _ acl: acl_t,
        at url: URL
    ) throws {
        var textLength: ssize_t = 0
        guard let textPointer = acl_to_text(acl, &textLength), textLength >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { acl_free(UnsafeMutableRawPointer(textPointer)) }
        let serialized = Data(bytes: textPointer, count: Int(textLength))
        guard var text = String(data: serialized, encoding: .utf8) else {
            throw NSError(domain: "com.grove.archive-metadata", code: Int(EBADMSG))
        }
        if text.hasPrefix("!#acl") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst()
                .joined(separator: "\n")
        }
        let chmodEntries = try text.split(whereSeparator: { $0.isNewline }).map { line -> String in
            let fields = line.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6,
                  (fields[0] == "user" || fields[0] == "group"),
                  !fields[2].isEmpty,
                  (fields[4] == "allow" || fields[4] == "deny"),
                  !fields[5].isEmpty else {
                throw NSError(domain: "com.grove.archive-metadata", code: Int(EBADMSG))
            }
            return "\(fields[0]):\(fields[2]) \(fields[4]) \(fields[5])"
        }
        let input = Data((chmodEntries.joined(separator: "\n") + "\n").utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-h", "-E", url.path]
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try? inputPipe.fileHandleForWriting.close()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.grove.archive-metadata",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not restore symbolic-link ACL at \(url.path): \(String(data: errorData, encoding: .utf8) ?? "chmod failed")"]
            )
        }
    }

    private func promoteArchive(_ temporaryArchive: URL, to archiveURL: URL) throws {
        let result = temporaryArchive.path.withCString { temporaryPath in
            archiveURL.path.withCString { archivePath in
                Darwin.rename(temporaryPath, archivePath)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }
    }

    private func validateArchiveRootNames(_ sources: [URL]) throws {
        var names = Set<String>()
        for source in sources {
            let name = source.lastPathComponent
            guard !name.isEmpty, names.insert(name).inserted else {
                throw NSError(
                    domain: "com.grove.archive-staging",
                    code: Int(EEXIST),
                    userInfo: [
                        NSLocalizedDescriptionKey: name.isEmpty
                            ? "The selected item does not have a valid archive name."
                            : "Multiple selected items are named \"\(name)\". Rename one before creating the archive."
                    ]
                )
            }
        }
    }

    /// Recursively stages a source without recursively copying same-volume file data. Directories are
    /// represented by new, empty directory nodes; symlinks are recreated without following them; and
    /// regular files are hard-linked. A failed hard link (most notably EXDEV for a source on another
    /// volume) falls back to copying that one file. The report makes the storage behavior measurable in
    /// tests without relying on noisy free-space readings.
    @discardableResult
    func stageForArchiving(
        _ source: URL,
        to destination: URL,
        hardLinkItem: ((URL, URL) throws -> Void)? = nil,
        excluding stagingDirectory: URL? = nil,
        cancellationRequested: @escaping () -> Bool = { false }
    ) throws -> ArchiveStagingReport {
        let exclusion = try stagingDirectory.map { try archiveStagingExclusion(for: $0) }
        do {
            return try stageForArchivingRecursively(
                source,
                to: destination,
                hardLinkItem: hardLinkItem,
                exclusion: exclusion,
                cancellationRequested: cancellationRequested
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func stageForArchivingRecursively(
        _ source: URL,
        to destination: URL,
        hardLinkItem: ((URL, URL) throws -> Void)?,
        exclusion: ArchiveStagingExclusion?,
        cancellationRequested: @escaping () -> Bool
    ) throws -> ArchiveStagingReport {
        guard !cancellationRequested() else {
            throw archiveCancellationError()
        }
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }

        if let exclusion,
           (sourceInfo.st_dev == exclusion.device && sourceInfo.st_ino == exclusion.inode
               || canonicalArchivePath(source) == exclusion.canonicalPath) {
            return ArchiveStagingReport()
        }

        var destinationInfo = stat()
        if lstat(destination.path, &destinationInfo) == 0 {
            throw NSError(
                domain: "com.grove.archive-staging",
                code: Int(EEXIST),
                userInfo: [NSLocalizedDescriptionKey: "An archive item named \"\(destination.lastPathComponent)\" already exists."]
            )
        }
        if errno != ENOENT {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }

        let fileType = sourceInfo.st_mode & mode_t(S_IFMT)
        switch fileType {
        case mode_t(S_IFDIR):
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            var report = ArchiveStagingReport(createdDirectories: 1)
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children {
                report += try stageForArchivingRecursively(
                    child,
                    to: destination.appendingPathComponent(child.lastPathComponent),
                    hardLinkItem: hardLinkItem,
                    exclusion: exclusion,
                    cancellationRequested: cancellationRequested
                )
            }
            guard !cancellationRequested() else {
                throw archiveCancellationError()
            }
            try copyArchiveDirectoryMetadata(from: source, to: destination)
            return report

        case mode_t(S_IFLNK):
            let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            try copyArchiveSymbolicLinkMetadata(from: source, to: destination)
            return ArchiveStagingReport(symbolicLinks: 1)

        case mode_t(S_IFREG):
            let byteCount = Int64(sourceInfo.st_size)
            do {
                if let hardLinkItem {
                    try hardLinkItem(source, destination)
                } else {
                    try fileManager.linkItem(at: source, to: destination)
                }
                return ArchiveStagingReport(hardLinkedFiles: 1, hardLinkedBytes: byteCount)
            } catch {
                try? fileManager.removeItem(at: destination)
                try copyArchiveRegularFile(
                    from: source,
                    to: destination,
                    byteCount: byteCount,
                    cancellationRequested: cancellationRequested
                )
                return ArchiveStagingReport(copiedFiles: 1, copiedBytes: byteCount)
            }

        default:
            // Sockets, devices, and other uncommon nodes cannot be hard-linked portably. Preserve the
            // previous behavior by asking FileManager to copy the individual node.
            try fileManager.copyItem(at: source, to: destination)
            return ArchiveStagingReport(copiedFiles: 1, copiedBytes: Int64(sourceInfo.st_size))
        }
    }

    private func archiveStagingExclusion(for directory: URL) throws -> ArchiveStagingExclusion {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }
        return ArchiveStagingExclusion(
            device: info.st_dev,
            inode: info.st_ino,
            canonicalPath: canonicalArchivePath(directory)
        )
    }

    private func canonicalArchivePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func copyArchiveRegularFile(
        from source: URL,
        to destination: URL,
        byteCount: Int64,
        cancellationRequested: @escaping () -> Bool
    ) throws {
        guard !cancellationRequested() else { throw archiveCancellationError() }
        let tracker = CopyfileProgress(
            total: byteCount,
            base: 0,
            isCancelled: cancellationRequested,
            report: { _ in }
        )
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(Self.copyfileProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(tracker).toOpaque())
        let flags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW))
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, state, flags)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            try? fileManager.removeItem(at: destination)
            if tracker.didCancel || cancellationRequested() {
                throw archiveCancellationError()
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }
        guard !cancellationRequested() else {
            try? fileManager.removeItem(at: destination)
            throw archiveCancellationError()
        }
    }

    private func copyArchiveDirectoryMetadata(from source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }
    }

    private func copyArchiveSymbolicLinkMetadata(from source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(UInt32(bitPattern: COPYFILE_METADATA | COPYFILE_NOFOLLOW))
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Could not preserve symbolic-link metadata: \(String(cString: strerror(errorCode)))"]
            )
        }
    }

    func decompressToUniqueFolder(
        _ archiveURL: URL,
        password: String? = nil,
        operationTimeout: TimeInterval? = nil,
        cancellationRequested: @escaping () -> Bool = { false },
        hooks: ArchiveExtractionHooks = ArchiveExtractionHooks(),
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        backgroundQueue.async {
            var destinationDir: URL?

            do {
                let parentDir = archiveURL.deletingLastPathComponent()
                let folderName = self.archiveExtractionFolderName(for: archiveURL)
                let createdDir = try self.createUniqueDirectory(named: folderName, in: parentDir)
                destinationDir = createdDir

                try self.extractArchive(
                    archiveURL,
                    to: createdDir,
                    password: password,
                    operationTimeout: operationTimeout,
                    cancellationRequested: cancellationRequested,
                    hooks: hooks
                )

                DispatchQueue.main.async { completion(.success(createdDir)) }
            } catch {
                if let destinationDir = destinationDir {
                    try? self.fileManager.removeItem(at: destinationDir)
                }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func decompress(
        _ archiveURL: URL,
        to destinationDir: URL,
        password: String? = nil,
        operationTimeout: TimeInterval? = nil,
        cancellationRequested: @escaping () -> Bool = { false },
        hooks: ArchiveExtractionHooks = ArchiveExtractionHooks(),
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        backgroundQueue.async {
            do {
                try self.extractArchive(
                    archiveURL,
                    to: destinationDir,
                    password: password,
                    operationTimeout: operationTimeout,
                    cancellationRequested: cancellationRequested,
                    hooks: hooks
                )

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
