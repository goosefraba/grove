import XCTest
import Darwin
@testable import Grove

final class FileOperationServiceTests: XCTestCase {
    private var tempRoot: URL!

    private struct ArchiveTreeEntrySnapshot: Equatable {
        let relativePath: String
        let fileType: UInt32
        let permissions: UInt16
        let flags: UInt32
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let contents: Data?
        let symbolicLinkDestination: String?
        let extendedAttributes: [String: Data]
        let accessControlList: Data?
    }

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        FileOperationService.shared.configureArchiveQuarantineRegistry(
            at: tempRoot.appendingPathComponent("archive-quarantines.plist")
        )
        FileOperationService.shared.configureArchiveQuarantineSiblingFallbackForTesting(false)
        FileOperationService.shared.configureArchiveCleanupDescriptorPathFailureForTesting(false)
        FileOperationService.shared.configureArchiveSanitationFailureForTesting(nil)
        FileOperationService.shared.configureArchiveAfterSanitationInventoryForTesting(nil)
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting()
    }

    override func tearDownWithError() throws {
        for retainedCleanupTree in FileOperationService.shared.consumeRetainedArchiveCleanupTrees() {
            // The service deliberately never path-deletes these safety quarantines. Tests own the
            // isolated paths recorded by this test process and remove them only after assertions.
            try? FileManager.default.removeItem(at: retainedCleanupTree)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        FileOperationService.shared.configureArchiveQuarantineRegistry(at: nil)
        FileOperationService.shared.configureArchiveQuarantineSiblingFallbackForTesting(false)
        FileOperationService.shared.configureArchiveCleanupDescriptorPathFailureForTesting(false)
        FileOperationService.shared.configureArchiveSanitationFailureForTesting(nil)
        FileOperationService.shared.configureArchiveAfterSanitationInventoryForTesting(nil)
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting()
        tempRoot = nil
    }

    func testRenameRejectsPathComponents() throws {
        let file = tempRoot.appendingPathComponent("file.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FileOperationService.shared.rename(file, to: "../escaped.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }

    func testArchiveAttentionPostedFromBackgroundPresentsOnceOnMainQueue() {
        let delegate = AppDelegate()
        let presented = expectation(description: "archive attention presented on main")
        var presentationCount = 0
        delegate.archiveQuarantineAlertPresenterForTesting = { _ in
            XCTAssertTrue(Thread.isMainThread)
            dispatchPrecondition(condition: .onQueue(.main))
            presentationCount += 1
            presented.fulfill()
        }
        delegate.beginObservingArchiveQuarantineAttention()

        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            for _ in 0..<2 {
                NotificationCenter.default.post(
                    name: FileOperationService.archiveQuarantineNeedsAttentionNotification,
                    object: FileOperationService.shared,
                    userInfo: ["records": []]
                )
            }
        }
        wait(for: [presented], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(presentationCount, 1, "duplicate notifications must share the main-queue gate")
    }

    func testCopyResolvingConflictsInSameDirectoryUsesCopySuffixBeforeExtension() throws {
        let source = tempRoot.appendingPathComponent("report.final.pdf")
        try "data".write(to: source, atomically: true, encoding: .utf8)

        var resolverCallCount = 0
        let firstRecords = try FileOperationService.shared.copyResolvingConflictsWithRecords([source], to: tempRoot) { _ in
            resolverCallCount += 1
            return .skip
        }

        let firstCopy = tempRoot.appendingPathComponent("report.final_copy.pdf")
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(firstRecords.map { $0.destinationURL.standardizedFileURL }, [firstCopy.standardizedFileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: firstCopy), "data")

        let secondRecords = try FileOperationService.shared.copyResolvingConflictsWithRecords([source], to: tempRoot) { _ in
            resolverCallCount += 1
            return .skip
        }

        let secondCopy = tempRoot.appendingPathComponent("report.final_copy_2.pdf")
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(secondRecords.map { $0.destinationURL.standardizedFileURL }, [secondCopy.standardizedFileURL])
        XCTAssertEqual(try String(contentsOf: secondCopy), "data")
    }

    func testCopyResolvingConflictsInSameDirectoryUsesCopySuffixWithoutExtension() throws {
        let source = tempRoot.appendingPathComponent("README")
        try "data".write(to: source, atomically: true, encoding: .utf8)

        let records = try FileOperationService.shared.copyResolvingConflictsWithRecords([source], to: tempRoot) { _ in
            XCTFail("Same-directory copy should not show a conflict prompt")
            return .skip
        }

        let copy = tempRoot.appendingPathComponent("README_copy")
        XCTAssertEqual(records.map { $0.destinationURL.standardizedFileURL }, [copy.standardizedFileURL])
        XCTAssertEqual(try String(contentsOf: copy), "data")
    }

    func testSkippedConflictDoesNotCorruptMoveRecordSource() throws {
        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let conflicted = source.appendingPathComponent("a.txt")
        let moved = source.appendingPathComponent("b.txt")
        try "source-a".write(to: conflicted, atomically: true, encoding: .utf8)
        try "source-b".write(to: moved, atomically: true, encoding: .utf8)
        try "dest-a".write(to: destination.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let records = try FileOperationService.shared.moveResolvingConflictsWithRecords([conflicted, moved], to: destination) { _ in
            .skip
        }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sourceURL.standardizedFileURL, moved.standardizedFileURL)
        XCTAssertEqual(records[0].destinationURL.standardizedFileURL, destination.appendingPathComponent("b.txt").standardizedFileURL)
    }

    func testMergeUndoDoesNotTrashExistingDestinationFolder() throws {
        let sourceParent = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destinationParent = tempRoot.appendingPathComponent("destination", isDirectory: true)
        let sourceFolder = sourceParent.appendingPathComponent("Folder", isDirectory: true)
        let destinationFolder = destinationParent.appendingPathComponent("Folder", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try "new".write(to: sourceFolder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "existing".write(to: destinationFolder.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        let records = try FileOperationService.shared.copyResolvingConflictsWithRecords([sourceFolder], to: destinationParent) { _ in
            .merge
        }

        XCTAssertFalse(records.contains { $0.destinationURL.standardizedFileURL == destinationFolder.standardizedFileURL })
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFolder.appendingPathComponent("new.txt").path))

        try FileOperationService.shared.undoTransferRecords(records)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFolder.appendingPathComponent("existing.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFolder.appendingPathComponent("new.txt").path))
    }

    func testReplaceRestoresDestinationWhenIncomingTransferFails() throws {
        let destination = tempRoot.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationFile = destination.appendingPathComponent("missing.txt")
        try "original".write(to: destinationFile, atomically: true, encoding: .utf8)

        let missingSource = tempRoot.appendingPathComponent("source", isDirectory: true).appendingPathComponent("missing.txt")

        XCTAssertThrowsError(try FileOperationService.shared.copyResolvingConflictsWithRecords([missingSource], to: destination) { _ in
            .replace
        })
        XCTAssertEqual(try String(contentsOf: destinationFile), "original")
    }

    func testDestinationIsWithinDetectsSelfChildAndDescendantButNotPrefixSibling() {
        XCTAssertTrue(FileOperationService.destination("/foo", isWithin: "/foo"))            // identical path
        XCTAssertTrue(FileOperationService.destination("/foo/bar", isWithin: "/foo"))        // direct child
        XCTAssertTrue(FileOperationService.destination("/foo/bar/baz", isWithin: "/foo"))    // deep descendant
        XCTAssertFalse(FileOperationService.destination("/foobar", isWithin: "/foo"))        // sibling common prefix
        XCTAssertFalse(FileOperationService.destination("/foo", isWithin: "/foo/bar"))       // parent is not within child
    }

    func testCopyIntoOwnSubfolderIsRejected() throws {
        let folder = tempRoot.appendingPathComponent("A", isDirectory: true)
        let sub = folder.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FileOperationService.shared.copyResolvingConflictsWithRecords([folder], to: sub) { _ in .keepBoth }) { error in
            guard case FileOperationService.FileOperationError.invalidDestination = error else {
                return XCTFail("Expected invalidDestination, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.appendingPathComponent("A").path))
    }

    func testMoveToTrashPartialFailureCarriesCompletedRecordAndUndoRestores() throws {
        let file1 = tempRoot.appendingPathComponent("one.txt")
        let file3 = tempRoot.appendingPathComponent("three.txt")
        try "1".write(to: file1, atomically: true, encoding: .utf8)
        try "3".write(to: file3, atomically: true, encoding: .utf8)
        let missing = tempRoot.appendingPathComponent("missing.txt")

        var completed: [FileOperationService.FileTransferRecord] = []
        XCTAssertThrowsError(try FileOperationService.shared.moveToTrashRecords([file1, missing, file3])) { error in
            guard case FileOperationService.FileOperationError.partialFailure(let records, _) = error else {
                return XCTFail("Expected partialFailure, got \(error)")
            }
            completed = records
        }

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].sourceURL.standardizedFileURL, file1.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path))

        try FileOperationService.shared.undoTransferRecords(completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
    }

    func testBatchRenameThrowsOnCollisionWithoutRenamingAnything() throws {
        let f1 = tempRoot.appendingPathComponent("foo1.txt")
        let f2 = tempRoot.appendingPathComponent("foo2.txt")
        try "a".write(to: f1, atomically: true, encoding: .utf8)
        try "b".write(to: f2, atomically: true, encoding: .utf8)

        let preview = try FileOperationService.shared.batchRenamePreview([f1, f2], find: "[0-9]", replace: "", useRegex: true)
        XCTAssertTrue(preview.allSatisfy(\.isCollision))

        XCTAssertThrowsError(try FileOperationService.shared.batchRename([f1, f2], find: "[0-9]", replace: "", useRegex: true)) { error in
            guard case FileOperationService.FileOperationError.nameCollision = error else {
                return XCTFail("Expected nameCollision, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f2.path))
    }

    func testBatchRenamePartialFailureCarriesCompletedRecords() throws {
        var urls: [URL] = []
        for i in 1...5 {
            let url = tempRoot.appendingPathComponent("item\(i).txt")
            if i != 4 {
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
            urls.append(url)
        }

        var completed: [FileOperationService.FileTransferRecord] = []
        XCTAssertThrowsError(try FileOperationService.shared.batchRename(urls, find: "item", replace: "doc", useRegex: false)) { error in
            guard case FileOperationService.FileOperationError.partialFailure(let records, _) = error else {
                return XCTFail("Expected partialFailure, got \(error)")
            }
            completed = records
        }

        XCTAssertEqual(completed.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("doc1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("doc3.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("item5.txt").path))

        try FileOperationService.shared.undoTransferRecords(completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("item1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("item3.txt").path))
    }

    func testRedoTransferRecordsReappliesCopyAndMove() throws {
        // Copy record: source is preserved, destination is recreated on redo.
        let copySource = tempRoot.appendingPathComponent("c.txt")
        try "x".write(to: copySource, atomically: true, encoding: .utf8)
        let sub = tempRoot.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let copyDest = sub.appendingPathComponent("c.txt")
        try FileManager.default.copyItem(at: copySource, to: copyDest)
        let copyRecord = FileOperationService.FileTransferRecord(sourceURL: copySource, destinationURL: copyDest, undoBehavior: .trashDestination)

        try FileOperationService.shared.undoTransferRecords([copyRecord])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyDest.path))
        try FileOperationService.shared.redoTransferRecords([copyRecord])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyDest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copySource.path))

        // Move record: undo returns to source, redo moves back to destination.
        let moveSource = tempRoot.appendingPathComponent("m.txt")
        try "y".write(to: moveSource, atomically: true, encoding: .utf8)
        let moveDest = tempRoot.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: moveSource, to: moveDest)
        let moveRecord = FileOperationService.FileTransferRecord(sourceURL: moveSource, destinationURL: moveDest, undoBehavior: .moveBackToSource)

        try FileOperationService.shared.undoTransferRecords([moveRecord])
        XCTAssertTrue(FileManager.default.fileExists(atPath: moveSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveDest.path))
        try FileOperationService.shared.redoTransferRecords([moveRecord])
        XCTAssertTrue(FileManager.default.fileExists(atPath: moveDest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveSource.path))
    }

    func testAvailableDiskCapacityUsesActualFreeVolumeCapacity() throws {
        let values = try tempRoot.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let expected = Int64(try XCTUnwrap(values.volumeAvailableCapacity))
        let actual = try XCTUnwrap(FileOperationService.shared.availableDiskCapacity(at: tempRoot))
        let tolerance: Int64 = 64 * 1024 * 1024

        XCTAssertLessThanOrEqual(abs(actual - expected), tolerance)

        if let important = values.volumeAvailableCapacityForImportantUsage,
           abs(important - expected) > 1024 * 1024 * 1024 {
            XCTAssertLessThan(abs(actual - expected), abs(actual - important))
        }
    }

    func testLocalFooterStatusFormatterShowsSelectionOutOfTotalAndAvailableSpace() {
        let status = LocalFooterStatusFormatter.string(
            totalItemCount: 46,
            selectedItemCount: 1,
            availableDiskSpace: "121.1 GB"
        )

        XCTAssertEqual(status, "1 of 46 selected, 121.1 GB available")
    }

    func testLocalFooterStatusFormatterFallsBackToItemCountWithoutSelection() {
        let status = LocalFooterStatusFormatter.string(
            totalItemCount: 46,
            selectedItemCount: 0,
            availableDiskSpace: "121.1 GB"
        )

        XCTAssertEqual(status, "46 items, 121.1 GB available")
    }

    func testLocalFooterDiskSpaceCacheCoalescesRefreshesAndServesCachedValue() {
        let refreshed = expectation(description: "disk space refreshed once")
        refreshed.expectedFulfillmentCount = 1

        let cache = LocalFooterDiskSpaceCache(
            freshnessInterval: 60,
            refreshDelay: 0,
            queueLabel: "com.grove.tests.local-footer-disk-space",
            diskSpaceProvider: { _ in
                "120 GB"
            }
        )

        XCTAssertNil(cache.diskSpace(at: tempRoot))

        cache.refreshIfNeeded(at: tempRoot) { _ in
            refreshed.fulfill()
        }
        cache.refreshIfNeeded(at: tempRoot) { _ in
            XCTFail("Concurrent refresh should be coalesced")
        }

        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(cache.diskSpace(at: tempRoot), "120 GB")

        cache.refreshIfNeeded(at: tempRoot) { _ in
            XCTFail("Fresh cached disk space should not refresh")
        }
    }

    // MARK: - #29 Replace transfer leaves no stranded backup

    func testReplaceTransferLeavesNoVisibleBackupFile() throws {
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appendingPathComponent("file.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let source = tempRoot.appendingPathComponent("file.txt")
        try "new".write(to: source, atomically: true, encoding: .utf8)

        let records = try FileOperationService.shared.copyResolvingConflictsWithRecords([source], to: dest) { _ in .replace }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try String(contentsOf: target), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            .filter { $0.contains("grove-replace") }
        XCTAssertTrue(leftovers.isEmpty, "stranded backup files: \(leftovers)")
    }

    // MARK: - #53 Merge-move source semantics

    func testMergeMoveRemovesEmptiedSourceFolder() throws {
        let sourceParent = tempRoot.appendingPathComponent("src", isDirectory: true)
        let destParent = tempRoot.appendingPathComponent("dst", isDirectory: true)
        let sourceFolder = sourceParent.appendingPathComponent("Folder", isDirectory: true)
        let destFolder = destParent.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try "new".write(to: sourceFolder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "existing".write(to: destFolder.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)

        _ = try FileOperationService.shared.moveResolvingConflictsWithRecords([sourceFolder], to: destParent) { _ in .merge }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFolder.path), "merged source folder should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("new.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("existing.txt").path))
    }

    // MARK: - #53 Undo ordering and destination fallback

    func testUndoMoveRestoresSourceAndUsesFallbackWhenOccupied() throws {
        let srcDir = tempRoot.appendingPathComponent("src", isDirectory: true)
        let dstDir = tempRoot.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let source = srcDir.appendingPathComponent("a.txt")
        try "a".write(to: source, atomically: true, encoding: .utf8)

        let records = try FileOperationService.shared.moveResolvingConflictsWithRecords([source], to: dstDir) { _ in .keepBoth }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("a.txt").path))

        // Re-occupy the original source path so undo must fall back to a unique name.
        try "occupied".write(to: source, atomically: true, encoding: .utf8)
        try FileOperationService.shared.undoTransferRecords(records)

        XCTAssertEqual(try String(contentsOf: source), "occupied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcDir.appendingPathComponent("a 1.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.appendingPathComponent("a.txt").path))
    }

    // MARK: - #32 TOCTOU-free unique naming

    func testConcurrentCreateNewFolderProducesDistinctNames() {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String] = []
        var errors: [Error] = []
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                do {
                    let url = try FileOperationService.shared.createNewFolder(in: self.tempRoot, name: "New Folder")
                    lock.lock(); results.append(url.path); lock.unlock()
                } catch {
                    lock.lock(); errors.append(error); lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(errors.isEmpty, "concurrent creation errored: \(errors)")
        XCTAssertEqual(Set(results).count, 8, "expected 8 distinct folder names, got \(results)")
    }

    func testCopyChoosesNextFreeNameWhenCandidatesPreexist() throws {
        let source = tempRoot.appendingPathComponent("file.txt")
        try "data".write(to: source, atomically: true, encoding: .utf8)
        let dest = tempRoot.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "x".write(to: dest.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: dest.appendingPathComponent("file 1.txt"), atomically: true, encoding: .utf8)

        let copied = try FileOperationService.shared.copy([source], to: dest)
        XCTAssertEqual(copied.first?.lastPathComponent, "file 2.txt")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("file 2.txt")), "data")
    }

    // MARK: - #44 Batch rename compiles regex once, validates up front

    func testBatchRenameInvalidRegexThrowsBeforeAnyRename() throws {
        let a = tempRoot.appendingPathComponent("a.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FileOperationService.shared.batchRename([a], find: "(unterminated", replace: "x", useRegex: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "no file should be renamed when the pattern is invalid")
    }

    // MARK: - #24 Byte-level progress for large single-file copies

    func testCopyWithProgressReportsIntermediateProgressForLargeFile() throws {
        let source = tempRoot.appendingPathComponent("big.bin")
        try Data(count: 32 * 1024 * 1024).write(to: source)
        let dest = tempRoot.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let lock = NSLock()
        var fractions: [Double] = []
        _ = try FileOperationService.shared.copyWithProgress([source], to: dest, progress: { fraction, _ in
            lock.lock(); fractions.append(fraction); lock.unlock()
        }, cancelled: { false })

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("big.bin").path))
        let intermediate = fractions.filter { $0 > 0.0 && $0 < 1.0 }
        XCTAssertFalse(intermediate.isEmpty, "expected byte-level progress between 0 and 1, got \(fractions)")
    }

    // MARK: - #14 Process pipe deadlock (large stderr drained concurrently)

    func testRunArchiveToolDrainsLargeStderrWithoutDeadlocking() {
        let done = expectation(description: "helper returns without hanging")
        DispatchQueue.global().async {
            do {
                try FileOperationService.shared.runArchiveTool(
                    "/bin/sh",
                    arguments: ["-c", "head -c 2000000 /dev/zero | tr '\\0' 'x' 1>&2; exit 3"],
                    errorDomain: "com.grove.test",
                    fallbackMessage: "failed"
                )
                XCTFail("expected a non-zero exit to throw")
            } catch let error as NSError {
                XCTAssertEqual(error.code, 3)
                XCTAssertGreaterThan(error.localizedDescription.count, 100_000, "collected stderr text should be large")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testRunArchiveToolCancellationTerminatesTheTool() throws {
        let done = expectation(description: "plain archive tool cancelled")
        let lock = NSLock()
        var cancellationRequested = false
        var processPID: pid_t = 0
        var operationError: Error?

        DispatchQueue.global().async {
            do {
                try FileOperationService.shared.runArchiveTool(
                    "/bin/sh",
                    arguments: ["-c", "exec /bin/sleep 30"],
                    errorDomain: "com.grove.test.plain-archive-cancel",
                    fallbackMessage: "archive helper failed",
                    cancellationRequested: {
                        lock.lock()
                        defer { lock.unlock() }
                        return cancellationRequested
                    },
                    processStarted: { pid in
                        lock.lock()
                        processPID = pid
                        cancellationRequested = true
                        lock.unlock()
                    }
                )
                XCTFail("cancelled archive helper should fail")
            } catch {
                operationError = error
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(operationError as NSError?).code, NSUserCancelledError)
        lock.lock()
        let capturedPID = processPID
        lock.unlock()
        XCTAssertGreaterThan(capturedPID, 0)
        XCTAssertTrue(waitForProcessesToExit([capturedPID]))
    }

    // MARK: - #9 / #47 Password compress/extract round-trip

    func testArchiveControlRecordParserBuffersFragmentedPIDUntilTerminatingNewline() throws {
        var parser = FileOperationService.ArchiveControlRecordParser()

        let firstRecords = try parser.append(Data("GROVE_ARCHIVE_CHILD_PID:123".utf8))
        XCTAssertTrue(firstRecords.isEmpty, "unterminated PID fragment must not notify child start as PID 123")

        let completedRecords = try parser.append(Data("45\n".utf8))
        XCTAssertEqual(completedRecords, [.childPID(12_345)])

        XCTAssertTrue(try parser.append(Data("GROVE_ARCHIVE_AUTH".utf8)).isEmpty)
        XCTAssertEqual(
            try parser.append(Data("ENTICATED\n".utf8)),
            [.authenticated]
        )
        XCTAssertNoThrow(try parser.finish())
    }

    func testArchiveControlRecordParserRejectsMalformedOversizedAndUnterminatedRecords() throws {
        var malformedParser = FileOperationService.ArchiveControlRecordParser()
        XCTAssertThrowsError(try malformedParser.append(Data("GROVE_ARCHIVE_CHILD_PID:12x\n".utf8)))

        var oversizedParser = FileOperationService.ArchiveControlRecordParser(maximumRecordBytes: 16)
        XCTAssertThrowsError(try oversizedParser.append(Data(repeating: 0x41, count: 17)))

        var unterminatedParser = FileOperationService.ArchiveControlRecordParser()
        XCTAssertTrue(try unterminatedParser.append(Data("GROVE_ARCHIVE_CHILD_PID:54321".utf8)).isEmpty)
        XCTAssertThrowsError(try unterminatedParser.finish())
    }

    func testArchiveControlRecordParserRejectsDuplicatePIDWithoutInvalidStartNotification() throws {
        var parser = FileOperationService.ArchiveControlRecordParser()
        var notifiedChildPIDs: [pid_t] = []

        for record in try parser.append(Data("GROVE_ARCHIVE_CHILD_PID:111\n".utf8)) {
            if case .childPID(let pid) = record { notifiedChildPIDs.append(pid) }
        }
        XCTAssertThrowsError(try parser.append(Data("GROVE_ARCHIVE_CHILD_PID:222\n".utf8)))
        XCTAssertEqual(notifiedChildPIDs, [111], "duplicate PID must not notify child start for PID 222")
    }

    func testArchiveControlRecordParserRejectsAuthenticationBeforePIDWithoutStartNotification() {
        var parser = FileOperationService.ArchiveControlRecordParser()
        let notifiedChildPIDs: [pid_t] = []

        XCTAssertThrowsError(try parser.append(Data("GROVE_ARCHIVE_AUTHENTICATED\n".utf8))) { _ in
            XCTAssertTrue(notifiedChildPIDs.isEmpty)
        }
        XCTAssertTrue(notifiedChildPIDs.isEmpty, "authentication-before-PID must not notify child start")
    }

    func testArchiveControlRecordParserRejectsDuplicateAuthenticationRecord() throws {
        var parser = FileOperationService.ArchiveControlRecordParser()
        var authenticationNotifications = 0

        _ = try parser.append(Data("GROVE_ARCHIVE_CHILD_PID:333\n".utf8))
        for record in try parser.append(Data("GROVE_ARCHIVE_AUTHENTICATED\n".utf8)) {
            if record == .authenticated { authenticationNotifications += 1 }
        }
        XCTAssertThrowsError(try parser.append(Data("GROVE_ARCHIVE_AUTHENTICATED\n".utf8)))
        XCTAssertEqual(authenticationNotifications, 1, "duplicate authentication must not emit a second notification")
    }

    func testPasswordProtectedArchiveInvocationKeepsPasswordOutOfAllArgumentsAndEnvironment() throws {
        let password = "argv-secret-$[]{}"
        let toolArguments = ["-r", "-q", "-e", "/tmp/archive.zip", "secret.txt"]
        let invocation = FileOperationService.shared.passwordProtectedArchiveInvocation(
            toolPath: "/usr/bin/zip",
            arguments: toolArguments,
            password: password
        )

        XCTAssertEqual(invocation.executablePath, "/usr/bin/expect")
        XCTAssertEqual(invocation.archiveToolPath, "/usr/bin/zip")
        XCTAssertEqual(invocation.archiveToolArguments, toolArguments)
        XCTAssertEqual(invocation.environment["GROVE_ARCHIVE_PROMPT_TIMEOUT_SECONDS"], "30")
        XCTAssertEqual(invocation.environment["GROVE_ARCHIVE_OPERATION_TIMEOUT_SECONDS"], "-1")
        XCTAssertFalse(invocation.arguments.contains { $0.contains(password) })
        XCTAssertFalse(invocation.archiveToolArguments.contains { $0.contains(password) })
        XCTAssertFalse(
            invocation.environment
                .filter { $0.key.hasPrefix("GROVE_ARCHIVE_") }
                .contains { $0.value.contains(password) }
        )
        XCTAssertFalse(invocation.standardInput.contains(Data(password.utf8)))
        let encodedPassword = try XCTUnwrap(String(data: invocation.standardInput, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedPassword = Data(
            stride(from: 0, to: encodedPassword.count, by: 2).compactMap { offset in
                let start = encodedPassword.index(encodedPassword.startIndex, offsetBy: offset)
                let end = encodedPassword.index(start, offsetBy: 2)
                return UInt8(encodedPassword[start..<end], radix: 16)
            }
        )
        XCTAssertEqual(decodedPassword, Data(password.utf8))
    }

    func testPasswordProtectedArchiveRuntimeHidesSecretAndCleansUpAfterPromptTimeout() throws {
        let password = "runtime-prompt-secret-\(UUID().uuidString)"
        let encodedPassword = password.utf8.map { String(format: "%02x", $0) }.joined()
        let operationFinished = expectation(description: "timed-out operation finishes")
        let wrapperStarted = expectation(description: "expect wrapper starts")
        let stateLock = NSLock()
        var wrapperPID: pid_t = 0
        var operationError: Error?

        DispatchQueue.global().async {
            do {
                try FileOperationService.shared.runPasswordProtectedArchiveTool(
                    "/bin/sh",
                    arguments: ["-c", "exec /bin/sleep 30", "grove-prompt-hold-\(UUID().uuidString)"],
                    password: password,
                    errorDomain: "com.grove.test.archive-timeout",
                    fallbackMessage: "Archive test failed",
                    promptTimeout: 1,
                    processStarted: { pid in
                        stateLock.lock()
                        wrapperPID = pid
                        stateLock.unlock()
                        wrapperStarted.fulfill()
                    }
                )
                XCTFail("the prompt hold should time out")
            } catch {
                operationError = error
            }
            operationFinished.fulfill()
        }

        wait(for: [wrapperStarted], timeout: 3)
        stateLock.lock()
        let capturedWrapperPID = wrapperPID
        stateLock.unlock()
        XCTAssertGreaterThan(capturedWrapperPID, 0)
        let livePIDs = try waitForArchiveProcessTree(rootPID: capturedWrapperPID)
        XCTAssertGreaterThan(livePIDs.count, 1, "expected live Expect wrapper and archive child")

        let snapshot = try processSnapshot(pids: livePIDs)
        XCTAssertFalse(snapshot.contains(password), "live argv/environment exposed the plaintext password")
        XCTAssertFalse(snapshot.contains(encodedPassword), "live argv/environment exposed the encoded password")

        wait(for: [operationFinished], timeout: 8)
        let timeoutError = try XCTUnwrap(operationError as NSError?)
        XCTAssertEqual(timeoutError.code, 124)
        XCTAssertTrue(timeoutError.localizedDescription.localizedCaseInsensitiveContains("timed out"))
        XCTAssertFalse(timeoutError.localizedDescription.contains(password))
        XCTAssertTrue(waitForProcessesToExit(livePIDs), "Expect or its archive child survived timeout cleanup")
    }

    func testPasswordProtectedArchiveRuntimeHidesSecretAfterAuthenticationAndCleansUpOnCancellation() throws {
        let password = "runtime-auth-secret-\(UUID().uuidString)"
        let encodedPassword = password.utf8.map { String(format: "%02x", $0) }.joined()
        let authMarker = tempRoot.appendingPathComponent("authenticated")
        let operationFinished = expectation(description: "cancelled operation finishes")
        let wrapperStarted = expectation(description: "expect wrapper starts")
        let stateLock = NSLock()
        var wrapperPID: pid_t = 0
        var cancellationRequested = false
        var operationError: Error?

        DispatchQueue.global().async {
            do {
                try FileOperationService.shared.runPasswordProtectedArchiveTool(
                    "/bin/sh",
                    arguments: [
                        "-c",
                        "printf 'Enter password: '; IFS= read -r supplied; : > \"$1\"; exec /bin/sleep 30",
                        "grove-auth-hold-\(UUID().uuidString)",
                        authMarker.path
                    ],
                    password: password,
                    errorDomain: "com.grove.test.archive-cancel",
                    fallbackMessage: "Archive test failed",
                    promptTimeout: 10,
                    cancellationRequested: {
                        stateLock.lock()
                        defer { stateLock.unlock() }
                        return cancellationRequested
                    },
                    processStarted: { pid in
                        stateLock.lock()
                        wrapperPID = pid
                        stateLock.unlock()
                        wrapperStarted.fulfill()
                    }
                )
                XCTFail("the authenticated hold should be cancelled")
            } catch {
                operationError = error
            }
            operationFinished.fulfill()
        }

        wait(for: [wrapperStarted], timeout: 3)
        XCTAssertTrue(waitForCondition(timeout: 3) { FileManager.default.fileExists(atPath: authMarker.path) })
        stateLock.lock()
        let capturedWrapperPID = wrapperPID
        stateLock.unlock()
        let livePIDs = try waitForArchiveProcessTree(rootPID: capturedWrapperPID)
        let snapshot = try processSnapshot(pids: livePIDs)
        XCTAssertFalse(snapshot.contains(password), "post-auth argv/environment exposed the plaintext password")
        XCTAssertFalse(snapshot.contains(encodedPassword), "post-auth argv/environment exposed the encoded password")

        stateLock.lock()
        cancellationRequested = true
        stateLock.unlock()
        wait(for: [operationFinished], timeout: 5)
        let cancellationError = try XCTUnwrap(operationError as NSError?)
        XCTAssertEqual(cancellationError.code, NSUserCancelledError)
        XCTAssertTrue(cancellationError.localizedDescription.localizedCaseInsensitiveContains("cancelled"))
        XCTAssertFalse(cancellationError.localizedDescription.contains(password))
        XCTAssertTrue(waitForProcessesToExit(livePIDs), "Expect or its archive child survived cancellation cleanup")
    }

    func testPasswordProtectedArchiveImmediateCancellationWaitsForChildHandshakeAndLeavesNoResistantOrphan() throws {
        let password = "immediate-cancel-secret-\(UUID().uuidString)"
        let operationFinished = expectation(description: "immediate cancellation finishes")
        let wrapperStarted = expectation(description: "wrapper starts")
        let childStarted = expectation(description: "child PID handshake completes")
        let stateLock = NSLock()
        var wrapperPID: pid_t = 0
        var childPID: pid_t = 0
        var cancellationRequested = false
        var operationError: Error?

        DispatchQueue.global().async {
            do {
                try FileOperationService.shared.runPasswordProtectedArchiveTool(
                    "/bin/sh",
                    arguments: [
                        "-c",
                        "trap '' HUP TERM INT; while :; do /bin/sleep 1; done",
                        "grove-immediate-cancel-\(UUID().uuidString)"
                    ],
                    password: password,
                    errorDomain: "com.grove.test.archive-immediate-cancel",
                    fallbackMessage: "Archive test failed",
                    promptTimeout: 5,
                    cancellationRequested: {
                        stateLock.lock()
                        defer { stateLock.unlock() }
                        return cancellationRequested
                    },
                    processStarted: { pid in
                        stateLock.lock()
                        wrapperPID = pid
                        cancellationRequested = true
                        stateLock.unlock()
                        wrapperStarted.fulfill()
                    },
                    childProcessStarted: { pid in
                        stateLock.lock()
                        childPID = pid
                        stateLock.unlock()
                        childStarted.fulfill()
                    }
                )
                XCTFail("immediate cancellation should fail the operation")
            } catch {
                operationError = error
            }
            operationFinished.fulfill()
        }

        wait(for: [wrapperStarted, childStarted, operationFinished], timeout: 6)
        stateLock.lock()
        let capturedPIDs = [wrapperPID, childPID]
        stateLock.unlock()
        XCTAssertTrue(capturedPIDs.allSatisfy { $0 > 0 })
        let cancellationError = try XCTUnwrap(operationError as NSError?)
        XCTAssertEqual(cancellationError.code, NSUserCancelledError)
        XCTAssertFalse(cancellationError.localizedDescription.contains(password))
        XCTAssertTrue(waitForProcessesToExit(capturedPIDs), "immediate cancellation left wrapper or resistant child alive")
        XCTAssertTrue(
            waitForCondition(timeout: 3) { Darwin.kill(-capturedPIDs[1], 0) == -1 && errno == ESRCH },
            "immediate cancellation left a process in the resistant child's process group"
        )
    }

    func testPasswordProtectedArchivePromptTimeoutDoesNotLimitHealthyPostAuthenticationWork() throws {
        let startedAt = Date()
        XCTAssertNoThrow(
            try FileOperationService.shared.runPasswordProtectedArchiveTool(
                "/bin/sh",
                arguments: ["-c", "printf 'Enter password: '; IFS= read -r supplied; /bin/sleep 2"],
                password: "long-operation-secret",
                errorDomain: "com.grove.test.archive-long-operation",
                fallbackMessage: "Archive test failed",
                promptTimeout: 1,
                operationTimeout: nil
            )
        )
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 1.8)
    }

    func testPasswordProtectedArchiveExplicitOperationDeadlineCleansUpPostAuthenticationHold() throws {
        let password = "deadline-secret"
        var wrapperPID: pid_t = 0
        var childPID: pid_t = 0
        XCTAssertThrowsError(
            try FileOperationService.shared.runPasswordProtectedArchiveTool(
                "/bin/sh",
                arguments: ["-c", "trap '' HUP TERM; printf 'Enter password: '; IFS= read -r supplied; exec /bin/sleep 30"],
                password: password,
                errorDomain: "com.grove.test.archive-deadline",
                fallbackMessage: "Archive test failed",
                promptTimeout: 2,
                operationTimeout: 1,
                processStarted: { wrapperPID = $0 },
                childProcessStarted: { childPID = $0 }
            )
        ) { error in
            let error = error as NSError
            XCTAssertEqual(error.code, 124)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("deadline"))
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
        XCTAssertTrue(waitForProcessesToExit([wrapperPID, childPID]), "deadline cleanup left wrapper or child alive")
    }

    func testPasswordProtectedArchiveReportsMissingToolWithoutLeakingPassword() {
        let password = "missing-tool-secret"
        XCTAssertThrowsError(
            try FileOperationService.shared.runPasswordProtectedArchiveTool(
                "/definitely/not/a/grove-archive-tool",
                arguments: [],
                password: password,
                errorDomain: "com.grove.test.archive-missing",
                fallbackMessage: "Archive test failed",
                promptTimeout: 1
            )
        ) { error in
            let error = error as NSError
            XCTAssertEqual(error.code, 126)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("could not start"))
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
    }

    func testPasswordProtectedArchiveTreatsSignalTerminationAsFailure() {
        let password = "signal-secret"
        XCTAssertThrowsError(
            try FileOperationService.shared.runPasswordProtectedArchiveTool(
                "/bin/sh",
                arguments: ["-c", "printf 'Enter password: '; IFS= read -r supplied; kill -TERM $$"],
                password: password,
                errorDomain: "com.grove.test.archive-signal",
                fallbackMessage: "Archive test failed",
                promptTimeout: 2
            )
        ) { error in
            let error = error as NSError
            XCTAssertEqual(error.code, 128)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("terminated unexpectedly"))
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
    }

    func testCompressWithPasswordProducesEncryptedArchiveThatOnlyDecryptsWithPassword() throws {
        let workspace = tempRoot.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let complexRoot = workspace.appendingPathComponent("-leading[box]*?", isDirectory: true)
        let packageContents = complexRoot.appendingPathComponent("Example.app/Contents", isDirectory: true)
        let emptyDirectory = complexRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: packageContents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let adversarialFile = complexRoot.appendingPathComponent("literal[box]*?.txt")
        let packageFile = packageContents.appendingPathComponent("Info.plist")
        let adversarialPayload = Data((0..<32_769).map { UInt8(truncatingIfNeeded: $0 * 13) })
        try adversarialPayload.write(to: adversarialFile)
        try Data("package-secret".utf8).write(to: packageFile)
        try FileManager.default.createSymbolicLink(
            atPath: complexRoot.appendingPathComponent("secret-link").path,
            withDestinationPath: "literal[box]*?.txt"
        )
        let standalone = workspace.appendingPathComponent("-standalone?.bin")
        let standalonePayload = Data((0..<8_193).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try standalonePayload.write(to: standalone)
        let directoryXattr = Data("encrypted-directory-xattr".utf8)
        let fileXattr = Data([0x00, 0x11, 0x7F, 0xFF])
        let resourceFork = Data("encrypted-resource-fork".utf8)
        try setExtendedAttribute("com.grove.tests.encrypted-directory", value: directoryXattr, at: complexRoot)
        try setExtendedAttribute("com.grove.tests.encrypted-file", value: fileXattr, at: adversarialFile)
        let resourceForkSupported = try setResourceForkIfSupported(resourceFork, at: adversarialFile)
        let metadataDate = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertEqual(Darwin.chmod(complexRoot.path, 0o705), 0)
        try FileManager.default.setAttributes([.modificationDate: metadataDate], ofItemAtPath: complexRoot.path)
        let archive = tempRoot.appendingPathComponent("out.zip")
        let password = #"hünter $[]{} "two" \ slash"#

        let compressed = expectation(description: "compressed")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([complexRoot, standalone], to: archive, level: .normal, password: password) {
            compressResult = $0; compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("compression failed: \(String(describing: compressResult))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // Wrong password must fail (confirms the archive is actually encrypted).
        let wrongDir = tempRoot.appendingPathComponent("wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongDir, withIntermediateDirectories: true)
        let wrong = expectation(description: "wrong password")
        var wrongResult: Result<URL, Error>?
        let wrongPassword = "wrong-password-that-must-not-leak"
        FileOperationService.shared.decompress(archive, to: wrongDir, password: wrongPassword) { wrongResult = $0; wrong.fulfill() }
        wait(for: [wrong], timeout: 15)
        if case .success = try XCTUnwrap(wrongResult) {
            XCTFail("extraction with the wrong password should fail")
        }
        if case .failure(let error) = try XCTUnwrap(wrongResult) {
            XCTAssertFalse(error.localizedDescription.contains(wrongPassword))
            XCTAssertFalse(error.localizedDescription.contains(password))
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("password"))
        }

        // Correct password extracts the original contents.
        let rightDir = tempRoot.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)
        let right = expectation(description: "correct password")
        var rightResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: rightDir, password: password) { rightResult = $0; right.fulfill() }
        wait(for: [right], timeout: 15)
        guard case .success = try XCTUnwrap(rightResult) else {
            return XCTFail("extraction with the correct password failed: \(String(describing: rightResult))")
        }
        XCTAssertEqual(
            try Data(contentsOf: rightDir.appendingPathComponent("-leading[box]*?/literal[box]*?.txt")),
            adversarialPayload
        )
        XCTAssertEqual(
            try String(contentsOf: rightDir.appendingPathComponent("-leading[box]*?/Example.app/Contents/Info.plist")),
            "package-secret"
        )
        XCTAssertEqual(try Data(contentsOf: rightDir.appendingPathComponent("-standalone?.bin")), standalonePayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("-leading[box]*?/empty").path))
        let extractedLink = rightDir.appendingPathComponent("-leading[box]*?/secret-link")
        XCTAssertEqual(try fileIdentity(at: extractedLink, followSymbolicLink: false).fileType, mode_t(S_IFLNK))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path),
            "literal[box]*?.txt"
        )
        let extractedRoot = rightDir.appendingPathComponent("-leading[box]*?", isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: extractedRoot.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o705)
        XCTAssertEqual(
            try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970,
            metadataDate.timeIntervalSince1970,
            accuracy: 2
        )
        XCTAssertEqual(
            try extendedAttribute("com.grove.tests.encrypted-directory", at: extractedRoot),
            directoryXattr
        )
        XCTAssertEqual(
            try extendedAttribute("com.grove.tests.encrypted-file", at: rightDir.appendingPathComponent("-leading[box]*?/literal[box]*?.txt")),
            fileXattr
        )
        if resourceForkSupported {
            XCTAssertEqual(
                try extendedAttribute("com.apple.ResourceFork", at: rightDir.appendingPathComponent("-leading[box]*?/literal[box]*?.txt")),
                resourceFork
            )
        }
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: rightDir.path).contains {
                $0.hasPrefix(".GroveArchiveMetadata-")
            },
            "successful encrypted extraction must consume its metadata sidecar tree"
        )
    }

    func testEncryptedArchiveManifestRehydratesFileAndDirectoryMetadata() throws {
        let staging = tempRoot.appendingPathComponent("metadata-stage", isDirectory: true)
        let sourceRoot = staging.appendingPathComponent("Root", isDirectory: true)
        let sourceFile = sourceRoot.appendingPathComponent("file.bin")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: sourceFile)
        let directoryXattr = Data("directory".utf8)
        let fileXattr = Data("file".utf8)
        try setExtendedAttribute("com.grove.tests.pack-directory", value: directoryXattr, at: sourceRoot)
        try setExtendedAttribute("com.grove.tests.pack-file", value: fileXattr, at: sourceFile)
        let directoryTimestamp = timespec(tv_sec: 1_700_010_001, tv_nsec: 123_456_789)
        let fileTimestamp = timespec(tv_sec: 1_700_010_002, tv_nsec: 987_654_321)
        try setModificationTime(directoryTimestamp, at: sourceRoot)
        try setModificationTime(fileTimestamp, at: sourceFile)

        let metadataRoot = try FileOperationService.shared.createEncryptedArchiveMetadata(
            in: staging,
            cancellationRequested: { false }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: metadataRoot.appendingPathComponent(FileOperationService.encryptedArchiveMetadataManifestName).path
            )
        )
        try removeExtendedAttribute("com.grove.tests.pack-directory", at: sourceRoot)
        try removeExtendedAttribute("com.grove.tests.pack-file", at: sourceFile)
        try setModificationTime(timespec(tv_sec: 1, tv_nsec: 1), at: sourceRoot)
        try setModificationTime(timespec(tv_sec: 2, tv_nsec: 2), at: sourceFile)

        try FileOperationService.shared.rehydrateEncryptedArchiveMetadata(
            in: staging,
            metadataDirectoryName: metadataRoot.lastPathComponent,
            cancellationRequested: { false }
        )
        XCTAssertEqual(try extendedAttribute("com.grove.tests.pack-directory", at: sourceRoot), directoryXattr)
        XCTAssertEqual(try extendedAttribute("com.grove.tests.pack-file", at: sourceFile), fileXattr)
        var directoryInfo = stat()
        var fileInfo = stat()
        XCTAssertEqual(lstat(sourceRoot.path, &directoryInfo), 0)
        XCTAssertEqual(lstat(sourceFile.path, &fileInfo), 0)
        XCTAssertEqual(directoryInfo.st_mtimespec.tv_sec, directoryTimestamp.tv_sec)
        XCTAssertEqual(directoryInfo.st_mtimespec.tv_nsec, directoryTimestamp.tv_nsec)
        XCTAssertEqual(fileInfo.st_mtimespec.tv_sec, fileTimestamp.tv_sec)
        XCTAssertEqual(fileInfo.st_mtimespec.tv_nsec, fileTimestamp.tv_nsec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataRoot.path))
    }

    func testEncryptedArchiveManifestRejectsTamperedTraversalPath() throws {
        let destination = tempRoot.appendingPathComponent("tampered-output", isDirectory: true)
        let metadataDirectoryName = "\(FileOperationService.encryptedArchiveMetadataDirectoryPrefix)\(UUID().uuidString)"
        let metadataRoot = destination.appendingPathComponent(
            metadataDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        let outside = tempRoot.appendingPathComponent("outside.txt")
        try Data("outside-safe".utf8).write(to: outside)
        let outsideInfo = try fileIdentity(at: outside)
        let manifest = FileOperationService.EncryptedArchiveMetadataManifest(
            version: 2,
            controlDirectoryName: metadataDirectoryName,
            entries: [
                .init(
                    relativePath: "../outside.txt",
                    fileType: UInt32(outsideInfo.fileType),
                    permissions: 0o777,
                    modificationSeconds: 0,
                    modificationNanoseconds: 0,
                    attributes: [
                        .init(name: "com.grove.tests.must-not-escape", value: Data("bad".utf8))
                    ]
                )
            ]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(manifest).write(
            to: metadataRoot.appendingPathComponent(FileOperationService.encryptedArchiveMetadataManifestName)
        )

        XCTAssertThrowsError(
            try FileOperationService.shared.rehydrateEncryptedArchiveMetadata(
                in: destination,
                metadataDirectoryName: metadataDirectoryName,
                cancellationRequested: { false }
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "com.grove.archive-metadata")
            XCTAssertEqual((error as NSError).code, Int(EBADMSG))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside-safe".utf8))
        XCTAssertThrowsError(try extendedAttribute("com.grove.tests.must-not-escape", at: outside))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: metadataRoot.path),
            "tampered metadata control residue must be consumed even when validation fails"
        )
    }

    func testEncryptedManifestCannotMutatePreExistingMemberAbsentFromArchive() throws {
        let password = "member-binding-secret"
        let staging = tempRoot.appendingPathComponent("crafted-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let included = staging.appendingPathComponent("included.txt")
        try Data("new archive contents".utf8).write(to: included)
        let includedInfo = try fileIdentity(at: included)

        let metadataDirectoryName = "\(FileOperationService.encryptedArchiveMetadataDirectoryPrefix)\(UUID().uuidString)"
        let metadataRoot = staging.appendingPathComponent(metadataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: false)
        let forbiddenAttribute = "com.grove.tests.absent-member"
        let manifest = FileOperationService.EncryptedArchiveMetadataManifest(
            version: 2,
            controlDirectoryName: metadataDirectoryName,
            entries: [
                .init(
                    relativePath: "included.txt",
                    fileType: UInt32(includedInfo.fileType),
                    permissions: 0o600,
                    modificationSeconds: 1_700_000_200,
                    modificationNanoseconds: 0,
                    attributes: [
                        .init(name: "com.grove.tests.preflight-first", value: Data("must-not-apply".utf8))
                    ]
                ),
                .init(
                    relativePath: "victim.txt",
                    fileType: UInt32(S_IFREG),
                    permissions: 0o777,
                    modificationSeconds: 0,
                    modificationNanoseconds: 0,
                    attributes: [
                        .init(name: forbiddenAttribute, value: Data("forbidden".utf8))
                    ]
                )
            ]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(manifest).write(
            to: metadataRoot.appendingPathComponent(FileOperationService.encryptedArchiveMetadataManifestName)
        )

        let archive = tempRoot.appendingPathComponent("crafted.zip")
        try FileOperationService.shared.runPasswordProtectedArchiveTool(
            "/usr/bin/zip",
            arguments: ["-r", "-y", "-nw", "-q", "-e", archive.path, "--", "included.txt", metadataDirectoryName],
            password: password,
            currentDirectory: staging,
            errorDomain: "com.grove.test.member-binding",
            fallbackMessage: "Crafted archive setup failed",
            expectedPasswordPrompts: 2
        )
        try FileOperationService.shared.writeEncryptedArchiveMetadataLocator(
            metadataDirectoryName,
            to: archive
        )

        let destination = tempRoot.appendingPathComponent("member-binding-output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationIncluded = destination.appendingPathComponent("included.txt")
        let victim = destination.appendingPathComponent("victim.txt")
        try Data("existing included".utf8).write(to: destinationIncluded)
        try Data("existing victim".utf8).write(to: victim)

        let completion = expectation(description: "crafted archive rejected")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completion.fulfill()
        }
        wait(for: [completion], timeout: 15)
        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("a manifest referencing an absent archive member must fail")
        }
        XCTAssertEqual(try Data(contentsOf: destinationIncluded), Data("existing included".utf8))
        XCTAssertEqual(try Data(contentsOf: victim), Data("existing victim".utf8))
        XCTAssertThrowsError(try extendedAttribute("com.grove.tests.preflight-first", at: destinationIncluded))
        XCTAssertThrowsError(try extendedAttribute(forbiddenAttribute, at: victim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(metadataDirectoryName).path))
    }

    func testEncryptedArchiveRoundTripsLegitimateMetadataPrefixRoot() throws {
        let sourceName = "\(FileOperationService.encryptedArchiveMetadataDirectoryPrefix)\(UUID().uuidString)"
        let source = tempRoot.appendingPathComponent(sourceName, isDirectory: true)
        let payload = source.appendingPathComponent("manifest.plist")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("legitimate user data".utf8).write(to: payload)
        let archive = tempRoot.appendingPathComponent("prefix-root.zip")
        let password = "prefix-collision-secret"

        let compressed = expectation(description: "prefix root compressed")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([source], to: archive, password: password) {
            compressResult = $0
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("prefix-root compression failed: \(String(describing: compressResult))")
        }
        let locator = try XCTUnwrap(FileOperationService.shared.encryptedArchiveMetadataLocator(in: archive))
        XCTAssertNotEqual(locator, source.lastPathComponent)

        let destination = tempRoot.appendingPathComponent("prefix-root-output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let extracted = expectation(description: "prefix root extracted")
        var extractResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            extractResult = $0
            extracted.fulfill()
        }
        wait(for: [extracted], timeout: 15)
        guard case .success = try XCTUnwrap(extractResult) else {
            return XCTFail("prefix-root extraction failed: \(String(describing: extractResult))")
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("\(sourceName)/manifest.plist")),
            Data("legitimate user data".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(locator).path))
    }

    func testEncryptedExtractionAtomicallyMergesNonEmptyDestination() throws {
        let password = "atomic-success-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "atomic-success")

        let completed = expectation(description: "atomic merge succeeds")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("transactional extraction failed: \(String(describing: result))")
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")), Data("archive collision".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("02-nested/shared.txt")), Data("archive nested collision".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("03-new.txt")), Data("archive new member".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("existing-only.bin")), Data([0x00, 0xFF, 0x7A]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("02-nested/existing-only.txt")), Data("nested existing".utf8))
        XCTAssertEqual(
            try extendedAttribute("com.grove.tests.atomic-existing", at: destination.appendingPathComponent("existing-only.bin")),
            Data("preserve me".utf8)
        )
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionPreservesDestinationOnlyHardLinksAcrossNestedDirectories() throws {
        let password = "hard-link-topology-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "hard-link-destination")
        let first = destination.appendingPathComponent("hard-link-first.bin")
        let nestedDirectory = destination.appendingPathComponent("hard-link-nested", isDirectory: true)
        let second = nestedDirectory.appendingPathComponent("hard-link-second.bin")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try Data("shared hard-link payload".utf8).write(to: first)
        XCTAssertEqual(Darwin.link(first.path, second.path), 0)

        let completed = expectation(description: "hard-link topology preserved")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("hard-link extraction failed: \(String(describing: result))")
        }
        var firstInfo = stat()
        var secondInfo = stat()
        XCTAssertEqual(lstat(first.path, &firstInfo), 0)
        XCTAssertEqual(lstat(second.path, &secondInfo), 0)
        XCTAssertEqual(firstInfo.st_dev, secondInfo.st_dev)
        XCTAssertEqual(firstInfo.st_ino, secondInfo.st_ino)
        XCTAssertEqual(firstInfo.st_nlink, 2)
        XCTAssertEqual(secondInfo.st_nlink, 2)
        XCTAssertEqual(try Data(contentsOf: first), Data("shared hard-link payload".utf8))
    }

    func testArchiveCleanupSanitizesRegularInodeOnlyWhenAllHardLinksAreOwned() throws {
        let password = "owned-hard-link-sanitation-secret"
        let source = tempRoot.appendingPathComponent("owned-links-archive-source.txt")
        try Data("archive member".utf8).write(to: source)
        let archive = tempRoot.appendingPathComponent("owned-links-archive.zip")
        let compressed = expectation(description: "owned-links fixture compressed")
        FileOperationService.shared.compress([source], to: archive, password: password) { result in
            if case .failure(let error) = result { XCTFail("compression failed: \(error)") }
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)

        let destination = tempRoot.appendingPathComponent("owned-links-destination", isDirectory: true)
        let nested = destination.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = destination.appendingPathComponent("first.bin")
        let second = nested.appendingPathComponent("second.bin")
        try Data("private owned payload".utf8).write(to: first)
        XCTAssertEqual(Darwin.link(first.path, second.path), 0)
        try setExtendedAttribute("com.grove.tests.owned-hard-link", value: Data("private".utf8), at: first)

        var retained: [URL] = []
        var warning: Error?
        let completed = expectation(description: "owned links cleanup")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                cleanupTreeRetained: { retained.append($0) },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("owned hard-link extraction failed")
        }
        XCTAssertNil(warning)
        let sanitizedOwnedTree = try retained.compactMap { url -> [ArchiveTreeEntrySnapshot]? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let snapshot = try archiveTreeSnapshot(at: url)
            return snapshot.filter { $0.fileType == UInt32(S_IFREG) }.count == 2 ? snapshot : nil
        }.first
        let regulars = try XCTUnwrap(sanitizedOwnedTree).filter { $0.fileType == UInt32(S_IFREG) }
        XCTAssertEqual(regulars.count, 2)
        XCTAssertTrue(regulars.allSatisfy { $0.contents?.isEmpty == true })
        XCTAssertTrue(regulars.allSatisfy {
            $0.extendedAttributes["com.grove.tests.owned-hard-link"] == nil
        })
    }

    func testSuccessfulArchiveQuarantineLifecycleIsBoundedAndRestartStable() throws {
        let source = tempRoot.appendingPathComponent("bounded-lifecycle-source.txt")
        try Data("bounded archive payload".utf8).write(to: source)
        let archive = tempRoot.appendingPathComponent("bounded-lifecycle.zip")
        let compressed = expectation(description: "bounded lifecycle archive")
        FileOperationService.shared.compress([source], to: archive) { result in
            if case .failure(let error) = result { XCTFail("compression failed: \(error)") }
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)

        var recordCounts: [Int] = []
        for index in 0..<5 {
            let destination = tempRoot.appendingPathComponent("bounded-output-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let completed = expectation(description: "bounded extraction \(index)")
            var result: Result<URL, Error>?
            FileOperationService.shared.decompress(archive, to: destination) {
                result = $0
                completed.fulfill()
            }
            wait(for: [completed], timeout: 15)
            guard case .success = try XCTUnwrap(result) else {
                return XCTFail("bounded extraction failed at iteration \(index)")
            }
            recordCounts.append(try FileOperationService.shared.archiveQuarantineRecords().count)
        }
        XCTAssertLessThanOrEqual(recordCounts.last ?? .max, 8)
        XCTAssertEqual(recordCounts.suffix(2).first, recordCounts.suffix(2).last)
        XCTAssertTrue(try FileOperationService.shared.archiveQuarantineRecords().allSatisfy {
            $0.sanitationStatus == .sanitized
        })

        // A restart consumer reads the durable registry, performs its retry/prune pass, and preserves
        // the same bounded resolved audit rather than adding records merely by starting up.
        let beforeRestart = try FileOperationService.shared.archiveQuarantineRecords()
        FileOperationService.shared.configureArchiveQuarantineRegistry(
            at: tempRoot.appendingPathComponent("archive-quarantines.plist")
        )
        let afterRestart = try FileOperationService.shared.performArchiveQuarantineMaintenance()
        XCTAssertEqual(afterRestart, beforeRestart)
    }

    func testForcedSiblingFallbackHandsSanitizedTreesToOneManagedLifecycleAcrossRestart() throws {
        FileOperationService.shared.configureArchiveQuarantineSiblingFallbackForTesting(true)
        let password = "fallback-retirement-secret"
        let source = tempRoot.appendingPathComponent("fallback-retirement-source.txt")
        try Data("archive payload".utf8).write(to: source)
        let archive = tempRoot.appendingPathComponent("fallback-retirement.zip")
        let compressed = expectation(description: "fallback retirement archive")
        FileOperationService.shared.compress([source], to: archive, password: password) { result in
            if case .failure(let error) = result { XCTFail("compression failed: \(error)") }
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)

        func extract(_ index: Int) throws {
            let destination = tempRoot.appendingPathComponent("fallback-retirement-output-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let completed = expectation(description: "fallback retirement extraction \(index)")
            var result: Result<URL, Error>?
            FileOperationService.shared.decompress(archive, to: destination, password: password) {
                result = $0
                completed.fulfill()
            }
            wait(for: [completed], timeout: 15)
            guard case .success = try XCTUnwrap(result) else {
                return XCTFail("fallback retirement extraction failed at \(index)")
            }
        }
        for index in 0..<4 { try extract(index) }

        let siblingArtifacts = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
            .filter { $0.hasPrefix(".grove-cleanup-") }
        XCTAssertTrue(siblingArtifacts.isEmpty)
        let recordsBeforeRestart = try FileOperationService.shared.archiveQuarantineRecords()
        XCTAssertLessThanOrEqual(recordsBeforeRestart.count, 8)
        let managedParentsBeforeRestart = Set(recordsBeforeRestart.map {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL.path
        })
        XCTAssertEqual(managedParentsBeforeRestart.count, 1, "fallback handoffs must reuse one OS-managed lifecycle root")

        // Clearing the in-memory cache models app restart. The next handoff must recover and reuse the
        // durable managed parent instead of accumulating another per-session handoff root.
        let registry = tempRoot.appendingPathComponent("archive-quarantines.plist")
        FileOperationService.shared.configureArchiveQuarantineRegistry(at: registry)
        _ = try FileOperationService.shared.performArchiveQuarantineMaintenance()
        try extract(4)
        let recordsAfterRestart = try FileOperationService.shared.archiveQuarantineRecords()
        XCTAssertLessThanOrEqual(recordsAfterRestart.count, 8)
        XCTAssertEqual(
            Set(recordsAfterRestart.map {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL.path
            }),
            managedParentsBeforeRestart
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
                .filter { $0.hasPrefix(".grove-cleanup-") }
                .isEmpty
        )
    }

    func testEncryptedExtractionNeverSanitizesExternalHardLinkAlias() throws {
        let password = "external-hard-link-safety-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "external-hard-link-destination")
        let internalFile = destination.appendingPathComponent("existing-only.bin")
        let outside = tempRoot.appendingPathComponent("outside-important-file.bin")
        try FileManager.default.linkItem(at: internalFile, to: outside)
        try setExtendedAttribute(
            "com.grove.tests.external-hard-link",
            value: Data("must remain exact".utf8),
            at: outside
        )
        _ = try setResourceForkIfSupported(Data("external fork".utf8), at: outside)
        XCTAssertEqual(chmod(outside.path, 0o641), 0)
        XCTAssertEqual(chflags(outside.path, UInt32(UF_HIDDEN)), 0)
        try setModificationTime(timespec(tv_sec: 1_700_099_999, tv_nsec: 246_813_579), at: outside)
        let beforeSnapshot = try archiveTreeSnapshot(at: outside)
        let beforeIdentity = try fileIdentity(at: outside)

        let completed = expectation(description: "external hard link retained without mutation")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(postCommitCleanupWarning: { warning = $0 })
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit cleanup warning must preserve successful publication")
        }
        XCTAssertEqual((warning as NSError?)?.domain, "com.grove.decompress.quarantine")
        XCTAssertEqual((warning as NSError?)?.code, Int(EMLINK))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        XCTAssertEqual(try archiveTreeSnapshot(at: outside), beforeSnapshot)
        let afterIdentity = try fileIdentity(at: outside)
        XCTAssertEqual(afterIdentity.device, beforeIdentity.device)
        XCTAssertEqual(afterIdentity.inode, beforeIdentity.inode)
        XCTAssertEqual(afterIdentity.linkCount, beforeIdentity.linkCount)
        XCTAssertTrue(try FileOperationService.shared.archiveQuarantineRecords().contains {
            $0.sanitationStatus == .failed
                && $0.sanitationError?.contains("possible external hard links") == true
        })
    }

    func testArchiveCleanupRechecksOwnedHardLinksImmediatelyBeforeMutation() throws {
        let password = "hard-link-inventory-race-secret"
        let source = tempRoot.appendingPathComponent("inventory-race-archive.txt")
        try Data("published member".utf8).write(to: source)
        let archive = tempRoot.appendingPathComponent("inventory-race.zip")
        let compressed = expectation(description: "inventory-race archive")
        FileOperationService.shared.compress([source], to: archive, password: password) { result in
            if case .failure(let error) = result { XCTFail("compression failed: \(error)") }
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)

        let destination = tempRoot.appendingPathComponent("inventory-race-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let first = destination.appendingPathComponent("first.bin")
        let second = destination.appendingPathComponent("second.bin")
        try Data("must remain exact after inventory".utf8).write(to: first)
        XCTAssertEqual(Darwin.link(first.path, second.path), 0)
        try setExtendedAttribute("com.grove.tests.inventory-race", value: Data("exact".utf8), at: first)
        try setModificationTime(timespec(tv_sec: 1_700_222_333, tv_nsec: 918_273_645), at: first)
        let outside = tempRoot.appendingPathComponent("moved-out-after-inventory.bin")
        var didMove = false
        FileOperationService.shared.configureArchiveAfterSanitationInventoryForTesting { quarantine in
            let candidate = quarantine.appendingPathComponent("first.bin")
            guard !didMove, FileManager.default.fileExists(atPath: candidate.path) else { return }
            try FileManager.default.moveItem(at: candidate, to: outside)
            didMove = true
        }
        var warning: Error?
        let completed = expectation(description: "inventory race retained")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(postCommitCleanupWarning: { warning = $0 })
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveAfterSanitationInventoryForTesting(nil)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit inventory mismatch must preserve publication")
        }
        XCTAssertTrue(didMove)
        XCTAssertEqual((warning as NSError?)?.code, Int(EMLINK))
        XCTAssertEqual(try Data(contentsOf: outside), Data("must remain exact after inventory".utf8))
        XCTAssertEqual(
            try extendedAttribute("com.grove.tests.inventory-race", at: outside),
            Data("exact".utf8)
        )
        let outsideSnapshot = try archiveTreeSnapshot(at: outside)
        XCTAssertEqual(outsideSnapshot[0].modificationNanoseconds, 918_273_645)
        XCTAssertEqual(try fileIdentity(at: outside).linkCount, 2)
    }

    func testArchiveCleanupNeverMutatesExternalHardLinkedSymbolicLinkInode() throws {
        let password = "external-symlink-hard-link-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "external-symlink-hard-link-destination")
        let internalLink = destination.appendingPathComponent("existing-link")
        try configureSupportedSymbolicLinkMetadata(at: internalLink)
        let outsideLink = tempRoot.appendingPathComponent("outside-important-link")
        XCTAssertEqual(
            linkat(AT_FDCWD, internalLink.path, AT_FDCWD, outsideLink.path, 0),
            0
        )
        let before = try archiveTreeSnapshot(at: outsideLink)
        let beforeIdentity = try fileIdentity(at: outsideLink, followSymbolicLink: false)

        var warning: Error?
        let completed = expectation(description: "external symlink inode retained")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(postCommitCleanupWarning: { warning = $0 })
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("external symlink cleanup warning must preserve publication")
        }
        XCTAssertEqual((warning as NSError?)?.code, Int(EMLINK))
        XCTAssertEqual(try archiveTreeSnapshot(at: outsideLink), before)
        let afterIdentity = try fileIdentity(at: outsideLink, followSymbolicLink: false)
        XCTAssertEqual(afterIdentity.device, beforeIdentity.device)
        XCTAssertEqual(afterIdentity.inode, beforeIdentity.inode)
        XCTAssertEqual(afterIdentity.linkCount, beforeIdentity.linkCount)
    }

    func testPostCommitSanitationFailurePreservesPublishedDestinationAndReturnsSuccess() throws {
        let password = "post-commit-sanitation-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "post-commit-sanitation-destination")
        var warning: Error?
        var retained: [URL] = []
        let completed = expectation(description: "post-commit sanitation warning")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyBeforeCleanup: { _ in
                    FileOperationService.shared.configureArchiveSanitationFailureForTesting(.directory)
                },
                cleanupTreeRetained: { retained.append($0) },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveSanitationFailureForTesting(nil)

        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit sanitation failure must not roll back publication")
        }
        XCTAssertNotNil(warning)
        XCTAssertFalse(retained.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        XCTAssertTrue(try FileOperationService.shared.archiveQuarantineRecords().contains {
            $0.sanitationStatus == .failed
        })
    }

    func testUniqueFolderPostCommitFailureNeverDeletesPublishedExtraction() throws {
        let password = "unique-post-commit-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        var warning: Error?
        let completed = expectation(description: "unique-folder post-commit warning")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompressToUniqueFolder(
            archive,
            password: password,
            hooks: .init(
                immediatelyBeforeCleanup: { _ in
                    FileOperationService.shared.configureArchiveSanitationFailureForTesting(.directory)
                },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveSanitationFailureForTesting(nil)

        guard case .success(let published) = try XCTUnwrap(result) else {
            return XCTFail("unique-folder cleanup warning must preserve committed output")
        }
        XCTAssertNotNil(warning)
        XCTAssertEqual(
            try Data(contentsOf: published.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
    }

    func testPostCommitRegistryFailurePreservesPublicationAndReportsRetainedPriorTree() throws {
        let password = "post-commit-registry-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "post-commit-registry-destination")
        let corruptRegistry = tempRoot.appendingPathComponent("post-commit-corrupt-registry.plist")
        try Data("not a property list".utf8).write(to: corruptRegistry)
        let normalRegistry = tempRoot.appendingPathComponent("archive-quarantines.plist")
        var retained: [URL] = []
        var warning: Error?
        let completed = expectation(description: "post-commit registry warning")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyBeforeCleanup: { _ in
                    FileOperationService.shared.configureArchiveQuarantineRegistry(at: corruptRegistry)
                },
                cleanupTreeRetained: { retained.append($0) },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveQuarantineRegistry(at: normalRegistry)

        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit registry persistence failure must not become rollback failure")
        }
        XCTAssertNotNil(warning)
        XCTAssertFalse(retained.isEmpty, "the pre-existing tree must remain explicitly accounted")
        XCTAssertEqual(try Data(contentsOf: corruptRegistry), Data("not a property list".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
    }

    func testEncryptedExtractionArchiveDirectoryMetadataWinsDuringFillOnlyMerge() throws {
        let password = "directory-metadata-precedence-secret"
        let sourceParent = tempRoot.appendingPathComponent("metadata-source", isDirectory: true)
        let sourceContainer = sourceParent.appendingPathComponent("Container", isDirectory: true)
        let sourceDirectory = sourceContainer.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("archive member".utf8).write(to: sourceDirectory.appendingPathComponent("archive.txt"))
        try setExtendedAttribute(
            "com.grove.tests.directory-precedence",
            value: Data("archive metadata".utf8),
            at: sourceDirectory
        )
        XCTAssertEqual(Darwin.chmod(sourceDirectory.path, 0o705), 0)
        let archiveTimestamp = timespec(tv_sec: 1_700_040_000, tv_nsec: 456_789_123)
        try setModificationTime(archiveTimestamp, at: sourceDirectory)

        let archive = tempRoot.appendingPathComponent("directory-metadata-precedence.zip")
        let compressed = expectation(description: "metadata precedence archive compressed")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([sourceContainer], to: archive, password: password) {
            compressResult = $0
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("metadata precedence compression failed")
        }

        let baselineDestination = tempRoot.appendingPathComponent("metadata-precedence-baseline", isDirectory: true)
        let baselineCompleted = expectation(description: "archive metadata baseline extracted")
        var baselineResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: baselineDestination, password: password) {
            baselineResult = $0
            baselineCompleted.fulfill()
        }
        wait(for: [baselineCompleted], timeout: 15)
        guard case .success = try XCTUnwrap(baselineResult) else {
            return XCTFail("metadata baseline extraction failed")
        }
        let baselineDirectory = baselineDestination.appendingPathComponent("Container/Shared", isDirectory: true)
        var baselineInfo = stat()
        XCTAssertEqual(lstat(baselineDirectory.path, &baselineInfo), 0)

        let destination = tempRoot.appendingPathComponent("metadata-precedence-output", isDirectory: true)
        let oldDirectory = destination.appendingPathComponent("Container/Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try Data("destination-only".utf8).write(to: oldDirectory.appendingPathComponent("destination-only.txt"))
        try setExtendedAttribute(
            "com.grove.tests.directory-precedence",
            value: Data("old destination metadata".utf8),
            at: oldDirectory
        )
        XCTAssertEqual(Darwin.chmod(oldDirectory.path, 0o711), 0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: oldDirectory.path
        )

        let extracted = expectation(description: "metadata precedence extracted")
        var extractResult: Result<URL, Error>?
        var precommitInfo: stat?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(immediatelyBeforeCommit: { replacement, _ in
                var info = stat()
                XCTAssertEqual(lstat(replacement.appendingPathComponent("Container/Shared").path, &info), 0)
                precommitInfo = info
            })
        ) {
            extractResult = $0
            extracted.fulfill()
        }
        wait(for: [extracted], timeout: 15)
        guard case .success = try XCTUnwrap(extractResult) else {
            return XCTFail("metadata precedence extraction failed: \(String(describing: extractResult))")
        }
        var info = stat()
        XCTAssertEqual(lstat(oldDirectory.path, &info), 0)
        XCTAssertEqual(precommitInfo?.st_mtimespec.tv_sec, baselineInfo.st_mtimespec.tv_sec)
        XCTAssertEqual(info.st_mode & 0o777, baselineInfo.st_mode & 0o777)
        XCTAssertEqual(info.st_mtimespec.tv_sec, baselineInfo.st_mtimespec.tv_sec)
        XCTAssertEqual(info.st_mtimespec.tv_nsec, baselineInfo.st_mtimespec.tv_nsec)
        XCTAssertEqual(
            try extendedAttribute("com.grove.tests.directory-precedence", at: oldDirectory),
            Data("archive metadata".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: oldDirectory.appendingPathComponent("destination-only.txt")),
            Data("destination-only".utf8)
        )
    }

    func testEncryptedExtractionCancelsInsideLargeInternalCopyAndScrubsPartialReplacement() throws {
        let password = "large-internal-copy-cancel-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "large-copy-cancel-destination")
        let largeFile = destination.appendingPathComponent("destination-only-large.bin")
        try Data(repeating: 0xA7, count: 16 * 1024 * 1024).write(to: largeFile)
        let before = try archiveTreeSnapshot(at: destination)
        let stateLock = NSLock()
        var isCancelled = false
        var didBlockLargeCopy = false
        var retainedTrees: [URL] = []
        let copyBlocked = expectation(description: "large fcopyfile callback blocked")

        let completed = expectation(description: "large internal copy cancelled")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            cancellationRequested: {
                stateLock.lock(); defer { stateLock.unlock() }
                return isCancelled
            },
            hooks: .init(
                internalCopyStatus: { byteCount in
                    guard byteCount >= 16 * 1024 * 1024 else { return }
                    stateLock.lock()
                    if !didBlockLargeCopy {
                        didBlockLargeCopy = true
                        stateLock.unlock()
                        copyBlocked.fulfill()
                    } else {
                        stateLock.unlock()
                    }
                    while true {
                        stateLock.lock()
                        let cancelled = isCancelled
                        stateLock.unlock()
                        if cancelled { return }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                },
                cleanupTreeRetained: { url in
                    stateLock.lock(); retainedTrees.append(url); stateLock.unlock()
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [copyBlocked], timeout: 15)
        stateLock.lock(); isCancelled = true; stateLock.unlock()
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("large internal copy must cancel")
        }
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("cancel"))
        XCTAssertEqual(try archiveTreeSnapshot(at: destination), before)
        stateLock.lock()
        let recordedRetainedTrees = retainedTrees
        stateLock.unlock()
        let replacementQuarantine = try XCTUnwrap(recordedRetainedTrees.first {
            ((try? self.archiveTreeSnapshot(at: $0)) ?? []).contains { $0.fileType == UInt32(S_IFREG) }
        })
        let retainedSnapshot = try archiveTreeSnapshot(at: replacementQuarantine)
        XCTAssertTrue(
            retainedSnapshot.filter { $0.fileType == UInt32(S_IFREG) }.allSatisfy { $0.contents?.isEmpty == true },
            "all partial or copied replacement data must be scrubbed through verified fds"
        )
        XCTAssertTrue(retainedSnapshot.allSatisfy {
            !$0.extendedAttributes.keys.contains(where: { $0.hasPrefix("com.grove.tests.") })
                && $0.extendedAttributes["com.apple.ResourceFork"] == nil
        }, "retained cleanup files and directories must not keep archive xattrs or resource forks")
    }

    func testArchiveQuarantineRegistryRecoversSanitizedPrivacyRecordsAfterRestart() throws {
        let password = "quarantine-restart-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "private-original-name")
        let registryURL = tempRoot.appendingPathComponent("archive-quarantines.plist")

        let completed = expectation(description: "quarantine registered")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("quarantine fixture failed: \(String(describing: result))")
        }
        let beforeRestart = try FileOperationService.shared.archiveQuarantineRecords()
        XCTAssertFalse(beforeRestart.isEmpty)
        XCTAssertTrue(beforeRestart.allSatisfy {
            $0.sanitationStatus == .sanitized || $0.sanitationStatus == .failed
        })
        XCTAssertTrue(beforeRestart.filter { $0.sanitationStatus == .failed }.allSatisfy {
            $0.sanitationError?.contains("symlink contents are immutable") == true
        })
        XCTAssertTrue(beforeRestart.allSatisfy { !$0.path.contains("private-original-name") })
        XCTAssertEqual(Darwin.access(registryURL.path, F_OK), 0)

        // Reconfiguring the service to the same on-disk registry simulates a fresh process with no
        // in-memory quarantine state: the durable report must remain complete.
        FileOperationService.shared.configureArchiveQuarantineRegistry(at: registryURL)
        let afterRestart = try FileOperationService.shared.archiveQuarantineRecords()
        XCTAssertEqual(afterRestart, beforeRestart)
        for record in afterRestart where record.sanitationStatus == .sanitized {
            let root = URL(fileURLWithPath: record.path, isDirectory: true)
            let retained = try archiveTreeSnapshot(at: root)
            XCTAssertEqual(retained.first(where: { $0.relativePath == "." })?.permissions, 0o700)
            XCTAssertTrue(retained.allSatisfy { $0.flags == 0 })
            XCTAssertFalse(retained.contains { $0.symbolicLinkDestination == "existing-only.bin" })
            XCTAssertTrue(retained.filter { $0.fileType == UInt32(S_IFLNK) }.allSatisfy {
                $0.symbolicLinkDestination == "."
            })
            for entry in retained where entry.relativePath != "." {
                for component in entry.relativePath.split(separator: "/") {
                    XCTAssertNotNil(UUID(uuidString: String(component)), "retained node name was not de-identified")
                }
            }
        }
    }

    func testArchiveQuarantineSiblingFallbackIsRestrictedAndNeutralizesSymlinks() throws {
        FileOperationService.shared.configureArchiveQuarantineSiblingFallbackForTesting(true)
        let password = "quarantine-sibling-fallback-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "sibling-fallback-destination")
        let originalLink = destination.appendingPathComponent("existing-link")
        XCTAssertEqual(lchflags(originalLink.path, UInt32(UF_HIDDEN)), 0)
        try setExtendedAttribute(
            "com.grove.tests.symlink-private",
            value: Data("must disappear".utf8),
            at: originalLink,
            noFollow: true
        )
        let completed = expectation(description: "sibling fallback quarantined")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("sibling fallback extraction failed: \(String(describing: result))")
        }
        let siblingArtifacts = try FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".grove-cleanup-") }
        XCTAssertTrue(siblingArtifacts.isEmpty, "sanitized sibling fallbacks must be handed to managed storage")
        let managedRecords = try FileOperationService.shared.archiveQuarantineRecords().filter {
            $0.sanitationStatus == .sanitized
                && !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(".grove-cleanup-")
        }
        XCTAssertFalse(managedRecords.isEmpty)
        for record in managedRecords {
            let snapshot = try archiveTreeSnapshot(at: URL(fileURLWithPath: record.path, isDirectory: true))
            XCTAssertEqual(snapshot.first(where: { $0.relativePath == "." })?.permissions, 0o700)
            XCTAssertTrue(
                snapshot.allSatisfy {
                    $0.flags == 0
                        && !$0.extendedAttributes.keys.contains(where: { $0.hasPrefix("com.grove.tests.") })
                        && $0.extendedAttributes["com.apple.ResourceFork"] == nil
                },
                "unsanitized fallback entries: \(snapshot)"
            )
            XCTAssertFalse(snapshot.contains { $0.symbolicLinkDestination == "existing-only.bin" })
        }
    }

    func testArchiveQuarantineRegistersUnsanitizedFailureBeforeSanitation() throws {
        let password = "quarantine-failure-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "sanitation-failure-destination")
        let injected = NSError(
            domain: "com.grove.test.sanitation",
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "Injected sanitation failure"]
        )

        let completed = expectation(description: "sanitation failure registered")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyAfterQuarantineVerification: { _ in throw injected },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit sanitation warning must preserve publication")
        }
        XCTAssertEqual((warning as NSError?)?.domain, injected.domain)
        let failed = try XCTUnwrap(
            try FileOperationService.shared.archiveQuarantineRecords().first {
                $0.sanitationStatus == .failed
                    && $0.sanitationError?.contains("Injected sanitation failure") == true
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.path))
        let unsanitized = try archiveTreeSnapshot(at: URL(fileURLWithPath: failed.path, isDirectory: true))
        XCTAssertTrue(unsanitized.contains { $0.contents?.isEmpty == false })
        XCTAssertNotNil(try FileManager.default.attributesOfItem(atPath: tempRoot.appendingPathComponent("archive-quarantines.plist").path)[.posixPermissions])
    }

    func testArchiveQuarantineCorruptRegistryIsReportedAndNeverOverwritten() throws {
        let registry = tempRoot.appendingPathComponent("corrupt-quarantines.plist")
        let corrupt = Data("not a property list".utf8)
        try corrupt.write(to: registry)
        FileOperationService.shared.configureArchiveQuarantineRegistry(at: registry)

        XCTAssertThrowsError(try FileOperationService.shared.archiveQuarantineRecords()) { error in
            XCTAssertEqual((error as NSError).domain, "com.grove.decompress.quarantine")
            XCTAssertEqual((error as NSError).code, Int(EBADMSG))
        }
        XCTAssertThrowsError(try FileOperationService.shared.pruneMissingArchiveQuarantineRecords())
        XCTAssertEqual(try Data(contentsOf: registry), corrupt)
    }

    func testArchiveQuarantineIntentRecoversAfterRestartAndRetry() throws {
        let password = "quarantine-intent-recovery-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "intent-recovery-destination")
        let registry = tempRoot.appendingPathComponent("archive-quarantines.plist")
        let injected = NSError(domain: "com.grove.test.crash-phase", code: Int(EINTR))

        let completed = expectation(description: "intent persisted before simulated crash")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyAfterQuarantineIntentPersisted: { _ in throw injected },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("simulated post-commit crash phase must preserve publication")
        }
        XCTAssertEqual((warning as NSError?)?.domain, injected.domain)
        let intent = try XCTUnwrap(
            try FileOperationService.shared.archiveQuarantineRecords().first { $0.sanitationStatus == .intent }
        )
        let source = URL(fileURLWithPath: try XCTUnwrap(intent.sourceParentPath), isDirectory: true)
            .appendingPathComponent(try XCTUnwrap(intent.sourceName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        FileOperationService.shared.configureArchiveQuarantineRegistry(at: registry)
        let recovered = try FileOperationService.shared.retryArchiveQuarantineSanitation(id: intent.id)
        XCTAssertEqual(recovered.sanitationStatus, .sanitized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))
    }

    func testArchiveQuarantineRetryRejectsIdentityMismatchAndPruneAccountsMissingRecords() throws {
        let registry = tempRoot.appendingPathComponent("archive-quarantines.plist")
        let planned = tempRoot.appendingPathComponent("opaque-planned", isDirectory: true)
        try FileManager.default.createDirectory(at: planned, withIntermediateDirectories: false)
        var plannedInfo = stat()
        XCTAssertEqual(lstat(planned.path, &plannedInfo), 0)
        let record = FileOperationService.ArchiveQuarantineRecord(
            id: UUID(),
            transactionID: UUID(),
            path: planned.path,
            sourceParentPath: tempRoot.path,
            sourceName: "missing-source",
            device: UInt64(plannedInfo.st_dev),
            inode: UInt64(plannedInfo.st_ino &+ 1),
            registeredAt: Date(),
            sanitationStatus: .intent,
            sanitationUpdatedAt: Date(),
            sanitationError: nil
        )
        try PropertyListEncoder().encode([record]).write(to: registry, options: .atomic)
        XCTAssertThrowsError(try FileOperationService.shared.retryArchiveQuarantineSanitation(id: record.id))
        let failed = try XCTUnwrap(
            try FileOperationService.shared.archiveQuarantineRecords().first { $0.id == record.id }
        )
        XCTAssertEqual(failed.sanitationStatus, .failed)
        XCTAssertTrue(failed.sanitationError?.contains("identity mismatch") == true)

        try FileManager.default.removeItem(at: planned)
        XCTAssertEqual(try FileOperationService.shared.pruneMissingArchiveQuarantineRecords(), 1)
        XCTAssertTrue(try FileOperationService.shared.archiveQuarantineRecords().isEmpty)
    }

    func testArchiveQuarantineRetryReplansMissingParentAndRetriesFailedRelocation() throws {
        let registry = tempRoot.appendingPathComponent("archive-quarantines.plist")
        let sourceParent = tempRoot.appendingPathComponent("restart-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: false)

        func makeSource(_ name: String) throws -> (URL, stat) {
            let source = sourceParent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("private".utf8).write(to: source.appendingPathComponent("payload"))
            var info = stat()
            XCTAssertEqual(lstat(source.path, &info), 0)
            return (source, info)
        }
        let first = try makeSource("first-source")
        let second = try makeSource("second-source")
        let missingParent = tempRoot.appendingPathComponent("vanished-managed-parent", isDirectory: true)
        let records = [
            FileOperationService.ArchiveQuarantineRecord(
                id: UUID(), transactionID: UUID(),
                path: missingParent.appendingPathComponent(UUID().uuidString).path,
                sourceParentPath: sourceParent.path, sourceName: first.0.lastPathComponent,
                device: UInt64(first.1.st_dev), inode: UInt64(first.1.st_ino), registeredAt: Date(),
                sanitationStatus: .intent, sanitationUpdatedAt: Date(), sanitationError: nil
            ),
            FileOperationService.ArchiveQuarantineRecord(
                id: UUID(), transactionID: UUID(),
                path: sourceParent.appendingPathComponent(".grove-cleanup-failed-retry").path,
                sourceParentPath: sourceParent.path, sourceName: second.0.lastPathComponent,
                device: UInt64(second.1.st_dev), inode: UInt64(second.1.st_ino), registeredAt: Date(),
                sanitationStatus: .failed, sanitationUpdatedAt: Date(), sanitationError: "injected relocation failure"
            )
        ]
        try PropertyListEncoder().encode(records).write(to: registry, options: .atomic)

        let replanned = try FileOperationService.shared.retryArchiveQuarantineSanitation(id: records[0].id)
        XCTAssertEqual(replanned.sanitationStatus, .sanitized)
        XCTAssertEqual(URL(fileURLWithPath: replanned.path).deletingLastPathComponent(), sourceParent)
        XCTAssertTrue(URL(fileURLWithPath: replanned.path).lastPathComponent.hasPrefix(".grove-cleanup-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.0.path))

        let retried = try FileOperationService.shared.retryArchiveQuarantineSanitation(id: records[1].id)
        XCTAssertEqual(retried.sanitationStatus, .sanitized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.0.path))
    }

    func testArchiveQuarantineRegistryWriteFailureReportsRetainedSource() throws {
        let password = "quarantine-write-failure-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "registry-write-failure-destination")
        let blocker = tempRoot.appendingPathComponent("registry-parent-blocker")
        try Data("not a directory".utf8).write(to: blocker)
        FileOperationService.shared.configureArchiveQuarantineRegistry(
            at: blocker.appendingPathComponent("archive-quarantines.plist")
        )
        var reported: URL?
        let completed = expectation(description: "registry write failure surfaced")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(cleanupTreeRetained: { reported = $0 })
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("pre-commit registry persistence failure must fail visibly")
        }
        XCTAssertNotNil(reported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reported).path))
        FileOperationService.shared.configureArchiveQuarantineRegistry(
            at: tempRoot.appendingPathComponent("archive-quarantines.plist")
        )
    }

    func testArchiveQuarantineDescriptorPathFailureIsExplicitlyReported() throws {
        let password = "quarantine-fgetpath-failure-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "fgetpath-failure-destination")
        FileOperationService.shared.configureArchiveCleanupDescriptorPathFailureForTesting(true)
        var reported: URL?
        var warning: Error?
        let completed = expectation(description: "descriptor path failure reported")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                cleanupTreeRetained: { reported = $0 },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit F_GETPATH warning must preserve publication")
        }
        let error = try XCTUnwrap(warning)
        XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        XCTAssertEqual((error as NSError).code, Int(EBADF))
        XCTAssertNotNil(reported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reported).path))
    }

    func testArchiveSanitationStageFailuresDoNotLeakFileDescriptors() throws {
        let stages: [FileOperationService.ArchiveSanitationFailureStage] = [
            .directory, .regular, .symbolicLink
        ]
        for (index, stage) in stages.enumerated() {
            let password = "sanitation-fd-secret-\(index)"
            let archive = try createEncryptedFinalMergeArchive(password: password)
            let destination = try createFinalMergeDestination(named: "sanitation-fd-destination-\(index)")
            let before = try currentOpenFileDescriptorCount()
            let completed = expectation(description: "sanitation stage \(index) failed")
            var result: Result<URL, Error>?
            var warning: Error?
            FileOperationService.shared.decompress(
                archive,
                to: destination,
                password: password,
                hooks: .init(
                    immediatelyBeforeCleanup: { _ in
                        FileOperationService.shared.configureArchiveSanitationFailureForTesting(stage)
                    },
                    postCommitCleanupWarning: { warning = $0 }
                )
            ) {
                result = $0
                completed.fulfill()
            }
            wait(for: [completed], timeout: 15)
            FileOperationService.shared.configureArchiveSanitationFailureForTesting(nil)
            guard case .success = try XCTUnwrap(result) else {
                return XCTFail("post-commit sanitation stage \(index) must preserve publication")
            }
            XCTAssertNotNil(warning)
            let after = try currentOpenFileDescriptorCount()
            XCTAssertLessThanOrEqual(after, before, "sanitation stage \(index) leaked descriptors")
            XCTAssertTrue(try FileOperationService.shared.archiveQuarantineRecords().contains {
                $0.sanitationStatus == .failed
            })
        }
    }

    func testArchiveSymlinkPostSwapJointIdentityGateRetainsSuccessfulIntervalSubstitute() throws {
        let password = "symlink-swap-substitute-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "symlink-swap-substitute-destination")
        let savedNeutral = tempRoot.appendingPathComponent("saved-neutral-link")
        var quarantineRoot: URL?
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting(
            beforeSwap: { neutralURL in
                quarantineRoot = neutralURL.deletingLastPathComponent()
                try FileManager.default.moveItem(at: neutralURL, to: savedNeutral)
                try FileManager.default.createSymbolicLink(
                    atPath: neutralURL.path,
                    withDestinationPath: "competitor-target-must-survive"
                )
            }
        )
        let completed = expectation(description: "post-swap joint identity mismatch retained substitute")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(postCommitCleanupWarning: { warning = $0 })
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting()
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit neutral identity warning must preserve publication")
        }
        XCTAssertNotNil(warning)
        let snapshot = try archiveTreeSnapshot(at: try XCTUnwrap(quarantineRoot))
        XCTAssertTrue(snapshot.contains { $0.symbolicLinkDestination == "competitor-target-must-survive" })
        XCTAssertTrue(snapshot.contains { $0.symbolicLinkDestination == "existing-only.bin" })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: savedNeutral.path), ".")
        let failed = try FileOperationService.shared.archiveQuarantineRecords().filter {
            $0.path == quarantineRoot?.path
        }
        XCTAssertEqual(failed.last?.sanitationStatus, .failed)
        XCTAssertTrue(failed.last?.sanitationError?.contains("expected neutral") == true)
    }

    func testArchiveSymlinkForcedRenameSwapFailureRetainsOriginalAndNeutral() throws {
        let password = "symlink-forced-swap-failure-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "symlink-forced-swap-failure-destination")
        var quarantineRoot: URL?
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting(
            beforeSwap: { quarantineRoot = $0.deletingLastPathComponent() },
            forceSwapFailure: true
        )
        var reported: [URL] = []
        var warning: Error?
        let completed = expectation(description: "forced RENAME_SWAP failure retained both")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                cleanupTreeRetained: { reported.append($0) },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting()
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("forced post-commit RENAME_SWAP cleanup warning must preserve publication")
        }
        let error = try XCTUnwrap(warning)
        XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        XCTAssertEqual((error as NSError).code, Int(EIO))
        let root = try XCTUnwrap(quarantineRoot)
        let snapshot = try archiveTreeSnapshot(at: root)
        XCTAssertTrue(snapshot.contains { $0.symbolicLinkDestination == "existing-only.bin" })
        XCTAssertTrue(snapshot.contains { $0.symbolicLinkDestination == "." })
        XCTAssertTrue(reported.contains { $0.path == root.path })
        let failed = try FileOperationService.shared.archiveQuarantineRecords().filter { $0.path == root.path }
        XCTAssertEqual(failed.last?.sanitationStatus, .failed)
    }

    func testArchiveSymlinkFinalRelocationCheckRetainsSubstituteAndOriginal() throws {
        let password = "symlink-relocation-substitute-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "symlink-relocation-substitute-destination")
        let retainedOriginal = tempRoot.appendingPathComponent("retained-original-sensitive-link")
        var competitor: URL?
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting(
            beforeSensitiveRelocation: { originalURL in
                try FileManager.default.moveItem(at: originalURL, to: retainedOriginal)
                try FileManager.default.createSymbolicLink(
                    atPath: originalURL.path,
                    withDestinationPath: "late-competitor-target"
                )
                competitor = originalURL
            }
        )
        let completed = expectation(description: "symlink relocation mismatch retained both")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(postCommitCleanupWarning: { warning = $0 })
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        FileOperationService.shared.configureArchiveSymlinkNeutralizationHooksForTesting()
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("late post-commit symlink warning must preserve publication")
        }
        XCTAssertNotNil(warning)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: try XCTUnwrap(competitor).path),
            "late-competitor-target"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: retainedOriginal.path),
            "existing-only.bin"
        )
    }

    func testEncryptedExtractionAtomicallyCreatesMissingDestination() throws {
        let password = "atomic-new-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = tempRoot.appendingPathComponent("new-destination", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let completed = expectation(description: "missing destination created")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("transactional creation failed: \(String(describing: result))")
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")), Data("archive collision".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("02-nested/shared.txt")), Data("archive nested collision".utf8))
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionMergeFailureRestoresCompleteDestinationSnapshot() throws {
        let password = "atomic-failure-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "atomic-failure")
        let before = try archiveTreeSnapshot(at: destination)
        let stateLock = NSLock()
        var extractionDirectory: URL?
        var replacementDirectory: URL?

        let completed = expectation(description: "partial final merge fails")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                extractionDirectoryCreated: { directory in
                    stateLock.lock(); extractionDirectory = directory; stateLock.unlock()
                },
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementDirectory = directory; stateLock.unlock()
                },
                finalMerge: { extracted, replacement, _ in
                    try self.applyPartialFinalMerge(from: extracted, to: replacement)
                    throw NSError(
                        domain: "com.grove.test.atomic-merge",
                        code: Int(EIO),
                        userInfo: [NSLocalizedDescriptionKey: "Injected final merge failure"]
                    )
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure = try XCTUnwrap(result) else {
            return XCTFail("the injected partial merge must fail")
        }
        XCTAssertEqual(try archiveTreeSnapshot(at: destination), before)
        stateLock.lock()
        let recordedExtraction = extractionDirectory
        let recordedReplacement = replacementDirectory
        stateLock.unlock()
        XCTAssertNotNil(recordedExtraction)
        XCTAssertNotNil(recordedReplacement)
        XCTAssertFalse(recordedExtraction.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertFalse(recordedReplacement.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionMergeCancellationRestoresCompleteDestinationSnapshot() throws {
        let password = "atomic-cancellation-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "atomic-cancellation")
        let before = try archiveTreeSnapshot(at: destination)
        let stateLock = NSLock()
        var cancellationRequested = false
        var extractionDirectory: URL?
        var replacementDirectory: URL?
        let mergeStarted = expectation(description: "partial final merge started")

        let completed = expectation(description: "partial final merge cancelled")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            cancellationRequested: {
                stateLock.lock(); defer { stateLock.unlock() }
                return cancellationRequested
            },
            hooks: .init(
                extractionDirectoryCreated: { directory in
                    stateLock.lock(); extractionDirectory = directory; stateLock.unlock()
                },
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementDirectory = directory; stateLock.unlock()
                },
                finalMerge: { extracted, replacement, isCancelled in
                    try self.applyPartialFinalMerge(from: extracted, to: replacement)
                    mergeStarted.fulfill()
                    while !isCancelled() {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [mergeStarted], timeout: 15)
        stateLock.lock(); cancellationRequested = true; stateLock.unlock()
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("the partial merge must be cancelled")
        }
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("cancel"))
        XCTAssertEqual(try archiveTreeSnapshot(at: destination), before)
        stateLock.lock()
        let recordedExtraction = extractionDirectory
        let recordedReplacement = replacementDirectory
        stateLock.unlock()
        XCTAssertNotNil(recordedExtraction)
        XCTAssertNotNil(recordedReplacement)
        XCTAssertFalse(recordedExtraction.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertFalse(recordedReplacement.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionRejectsDestinationIdentitySubstitutionBeforeCommit() throws {
        let password = "identity-substitution-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "identity-destination")
        let originalSnapshot = try archiveTreeSnapshot(at: destination)
        let displacedOriginal = tempRoot.appendingPathComponent("identity-original", isDirectory: true)
        let stateLock = NSLock()
        var replacementDirectory: URL?
        var substituteSnapshot: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "identity mismatch rejected")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementDirectory = directory; stateLock.unlock()
                },
                immediatelyBeforeCommit: { _, commitDestination in
                    try FileManager.default.moveItem(at: commitDestination, to: displacedOriginal)
                    try FileManager.default.createDirectory(at: commitDestination, withIntermediateDirectories: false)
                    try Data("competing destination".utf8).write(
                        to: commitDestination.appendingPathComponent("competitor.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.competitor",
                        value: Data("competitor metadata".utf8),
                        at: commitDestination
                    )
                    XCTAssertEqual(Darwin.chmod(commitDestination.path, 0o733), 0)
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: 1_700_020_000)],
                        ofItemAtPath: commitDestination.path
                    )
                    let snapshot = try self.archiveTreeSnapshot(at: commitDestination)
                    stateLock.lock(); substituteSnapshot = snapshot; stateLock.unlock()
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("a substituted destination identity must reject commit")
        }
        XCTAssertEqual((error as NSError).domain, "com.grove.decompress.commit")
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed during commit"))
        stateLock.lock()
        let recordedReplacement = replacementDirectory
        let expectedSubstitute = substituteSnapshot
        stateLock.unlock()
        XCTAssertEqual(try archiveTreeSnapshot(at: displacedOriginal), originalSnapshot)
        XCTAssertEqual(try archiveTreeSnapshot(at: destination), try XCTUnwrap(expectedSubstitute))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("01-collision.txt").path))
        XCTAssertFalse(recordedReplacement.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionRetainsReplacementNameSubstitutionBeforeCleanup() throws {
        let password = "cleanup-substitution-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "cleanup-destination")
        let originalSnapshot = try archiveTreeSnapshot(at: destination)
        let retainedOriginal = tempRoot.appendingPathComponent("cleanup-retained-original", isDirectory: true)
        let stateLock = NSLock()
        var replacementURL: URL?
        var competitorSnapshot: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "cleanup substitution retained")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementURL = directory; stateLock.unlock()
                },
                immediatelyBeforeCleanup: { verifiedOldDestination in
                    try FileManager.default.moveItem(at: verifiedOldDestination, to: retainedOriginal)
                    try FileManager.default.createDirectory(
                        at: verifiedOldDestination,
                        withIntermediateDirectories: false
                    )
                    try Data("cleanup competitor".utf8).write(
                        to: verifiedOldDestination.appendingPathComponent("competitor.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.cleanup-competitor",
                        value: Data("retain competitor".utf8),
                        at: verifiedOldDestination
                    )
                    let snapshot = try self.archiveTreeSnapshot(at: verifiedOldDestination)
                    stateLock.lock(); competitorSnapshot = snapshot; stateLock.unlock()
                },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit cleanup identity warning must preserve publication")
        }
        let error = try XCTUnwrap(warning)
        XCTAssertEqual((error as NSError).domain, "com.grove.decompress.commit")
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("identity changed"))
        stateLock.lock()
        let recordedReplacement = replacementURL
        let expectedCompetitor = competitorSnapshot
        stateLock.unlock()
        XCTAssertEqual(try archiveTreeSnapshot(at: retainedOriginal), originalSnapshot)
        let replacement = try XCTUnwrap(recordedReplacement)
        XCTAssertEqual(try archiveTreeSnapshot(at: replacement), try XCTUnwrap(expectedCompetitor))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        // Explicitly clean the intentionally retained competitor after proving service cleanup refused it.
        try FileManager.default.removeItem(at: replacement)
    }

    func testEncryptedExtractionRetainsSubstituteIntroducedAfterQuarantineVerification() throws {
        let password = "quarantine-last-check-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "quarantine-last-check-destination")
        let originalSnapshot = try archiveTreeSnapshot(at: destination)
        let retainedOriginal = tempRoot.appendingPathComponent("quarantine-retained-original", isDirectory: true)
        let stateLock = NSLock()
        var quarantineURL: URL?
        var competitorSnapshot: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "post-quarantine substitution retained")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyAfterQuarantineVerification: { verifiedQuarantine in
                    try FileManager.default.moveItem(at: verifiedQuarantine, to: retainedOriginal)
                    try FileManager.default.createDirectory(
                        at: verifiedQuarantine,
                        withIntermediateDirectories: false
                    )
                    try Data("post-check competitor".utf8).write(
                        to: verifiedQuarantine.appendingPathComponent("competitor.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.quarantine-competitor",
                        value: Data("must survive".utf8),
                        at: verifiedQuarantine
                    )
                    let snapshot = try self.archiveTreeSnapshot(at: verifiedQuarantine)
                    stateLock.lock()
                    quarantineURL = verifiedQuarantine
                    competitorSnapshot = snapshot
                    stateLock.unlock()
                },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit quarantine substitution warning must preserve publication")
        }
        let error = try XCTUnwrap(warning)
        XCTAssertEqual((error as NSError).domain, "com.grove.decompress.commit")
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("identity changed"))
        XCTAssertEqual(try archiveTreeSnapshot(at: retainedOriginal), originalSnapshot)
        stateLock.lock()
        let recordedQuarantine = quarantineURL
        let expectedCompetitor = competitorSnapshot
        stateLock.unlock()
        let competitor = try XCTUnwrap(recordedQuarantine)
        XCTAssertEqual(try archiveTreeSnapshot(at: competitor), try XCTUnwrap(expectedCompetitor))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        // This residue is deliberate recovery state. The test owns and removes it only after proving
        // Grove refused to recurse into the substituted quarantine name.
        try FileManager.default.removeItem(at: competitor)
        try FileManager.default.removeItem(at: retainedOriginal)
    }

    func testEncryptedExtractionRetainsSubstituteIntroducedAtQuarantineRootRemovalBoundary() throws {
        let password = "quarantine-root-removal-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "quarantine-root-removal-destination")
        let retainedEmptiedOriginal = tempRoot.appendingPathComponent(
            "quarantine-retained-emptied-original",
            isDirectory: true
        )
        var competitorURL: URL?
        var competitorSnapshot: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "root-removal substitution retained")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyBeforeQuarantineRootRemoval: { verifiedQuarantine in
                    // The service has already removed the expected tree's contents through its opened
                    // fd and performed the pre-rmdir identity check. Substitute the mutable root name
                    // at that exact boundary; the competing non-empty tree must not be unlinked.
                    try FileManager.default.moveItem(at: verifiedQuarantine, to: retainedEmptiedOriginal)
                    try FileManager.default.createDirectory(
                        at: verifiedQuarantine,
                        withIntermediateDirectories: false
                    )
                    try Data("last-boundary competitor".utf8).write(
                        to: verifiedQuarantine.appendingPathComponent("competitor.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.quarantine-root-competitor",
                        value: Data("must survive final rmdir".utf8),
                        at: verifiedQuarantine
                    )
                    competitorURL = verifiedQuarantine
                    competitorSnapshot = try self.archiveTreeSnapshot(at: verifiedQuarantine)
                },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit root-name substitution warning must preserve publication")
        }
        let error = try XCTUnwrap(warning)
        XCTAssertEqual((error as NSError).domain, "com.grove.decompress.commit")
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("identity changed"))
        let competitor = try XCTUnwrap(competitorURL)
        XCTAssertEqual(try archiveTreeSnapshot(at: competitor), try XCTUnwrap(competitorSnapshot))
        let sanitizedOriginal = try archiveTreeSnapshot(at: retainedEmptiedOriginal)
        XCTAssertTrue(
            sanitizedOriginal.filter { $0.fileType == UInt32(S_IFREG) }.allSatisfy { $0.contents?.isEmpty == true }
        )
        XCTAssertTrue(sanitizedOriginal.allSatisfy {
            !$0.extendedAttributes.keys.contains(where: { $0.hasPrefix("com.grove.tests.") })
                && $0.extendedAttributes["com.apple.ResourceFork"] == nil
        })
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        try FileManager.default.removeItem(at: competitor)
        try FileManager.default.removeItem(at: retainedEmptiedOriginal)
    }

    func testEncryptedExtractionRetainsChildSubstituteIntroducedAfterFinalIdentityCheck() throws {
        let password = "quarantine-child-retention-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = try createFinalMergeDestination(named: "quarantine-child-destination")
        let retainedExpectedChild = tempRoot.appendingPathComponent("retained-sanitized-child.bin")
        var competitorURL: URL?
        var competitorSnapshot: [ArchiveTreeEntrySnapshot]?
        var didSubstitute = false

        let completed = expectation(description: "child substitution retained")
        var result: Result<URL, Error>?
        var warning: Error?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                immediatelyBeforeCleanupChildRetention: { verifiedChild in
                    var info = stat()
                    guard !didSubstitute,
                          lstat(verifiedChild.path, &info) == 0,
                          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return }
                    didSubstitute = true
                    try FileManager.default.moveItem(at: verifiedChild, to: retainedExpectedChild)
                    try Data("child competitor must survive".utf8).write(to: verifiedChild)
                    try self.setExtendedAttribute(
                        "com.grove.tests.child-competitor",
                        value: Data("untouched competitor metadata".utf8),
                        at: verifiedChild
                    )
                    competitorURL = verifiedChild
                    competitorSnapshot = try self.archiveTreeSnapshot(at: verifiedChild)
                },
                postCommitCleanupWarning: { warning = $0 }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("post-commit child-name substitution warning must preserve publication")
        }
        let error = try XCTUnwrap(warning)
        XCTAssertEqual((error as NSError).domain, "com.grove.decompress.commit")
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("identity changed"))
        XCTAssertEqual(try Data(contentsOf: retainedExpectedChild), Data())
        let retainedAttributes = try extendedAttributesSnapshot(at: retainedExpectedChild, noFollow: false)
        XCTAssertNil(retainedAttributes["com.grove.tests.atomic-existing"])
        XCTAssertNil(retainedAttributes["com.apple.ResourceFork"])
        let competitor = try XCTUnwrap(competitorURL)
        XCTAssertEqual(try archiveTreeSnapshot(at: competitor), try XCTUnwrap(competitorSnapshot))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        try FileManager.default.removeItem(at: competitor.deletingLastPathComponent())
        try FileManager.default.removeItem(at: retainedExpectedChild)
    }

    func testEncryptedExtractionParentNamespaceSubstitutionFailsWithoutTouchingSubstitute() throws {
        let password = "parent-namespace-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let parent = tempRoot.appendingPathComponent("namespace-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("destination", isDirectory: true)
        let nested = destination.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("original parent data".utf8).write(to: nested.appendingPathComponent("original.txt"))
        try setExtendedAttribute("com.grove.tests.parent-original", value: Data("original".utf8), at: destination)
        let originalSnapshot = try archiveTreeSnapshot(at: destination)
        let renamedParent = tempRoot.appendingPathComponent("namespace-parent-renamed", isDirectory: true)
        let stateLock = NSLock()
        var replacementName: String?
        var substituteSnapshot: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "parent namespace substitution rejected")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementName = directory.lastPathComponent; stateLock.unlock()
                },
                immediatelyBeforeCommit: { _, _ in
                    try FileManager.default.moveItem(at: parent, to: renamedParent)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                    let substitute = parent.appendingPathComponent("destination", isDirectory: true)
                    try FileManager.default.createDirectory(at: substitute, withIntermediateDirectories: false)
                    try Data("substitute namespace".utf8).write(
                        to: substitute.appendingPathComponent("substitute.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.parent-substitute",
                        value: Data("substitute".utf8),
                        at: substitute
                    )
                    let snapshot = try self.archiveTreeSnapshot(at: substitute)
                    stateLock.lock(); substituteSnapshot = snapshot; stateLock.unlock()
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("a substituted parent namespace must reject commit")
        }
        XCTAssertEqual((error as NSError).domain, "com.grove.decompress.commit")
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("parent namespace changed"))
        stateLock.lock()
        let recordedReplacementName = replacementName
        let expectedSubstitute = substituteSnapshot
        stateLock.unlock()
        XCTAssertEqual(
            try archiveTreeSnapshot(at: renamedParent.appendingPathComponent("destination")),
            originalSnapshot
        )
        XCTAssertEqual(
            try archiveTreeSnapshot(at: parent.appendingPathComponent("destination")),
            try XCTUnwrap(expectedSubstitute)
        )
        if let recordedReplacementName {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: renamedParent.appendingPathComponent(recordedReplacementName).path
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("destination/01-collision.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedParent.appendingPathComponent("destination/01-collision.txt").path))
    }

    func testEncryptedExtractionInternalMergeStaysBoundWhileParentNamespaceIsTemporarilySubstituted() throws {
        let password = "parent-preparation-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let parent = tempRoot.appendingPathComponent("preparation-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("destination", isDirectory: true)
        let fixture = try createFinalMergeDestination(named: "preparation-fixture")
        try FileManager.default.moveItem(at: fixture, to: destination)
        let existingRootXattr = try extendedAttribute("com.grove.tests.atomic-root", at: destination)

        let displacedParent = tempRoot.appendingPathComponent("preparation-parent-displaced", isDirectory: true)
        let retainedSubstituteParent = tempRoot.appendingPathComponent("preparation-parent-substitute", isDirectory: true)
        var substituteBefore: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "fd relative merge ignores temporary substitute")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                destinationPreparationStarted: {
                    try FileManager.default.moveItem(at: parent, to: displacedParent)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                    let substitute = parent.appendingPathComponent("destination", isDirectory: true)
                    try FileManager.default.createDirectory(at: substitute, withIntermediateDirectories: false)
                    try Data("substitute sentinel".utf8).write(
                        to: substitute.appendingPathComponent("substitute-only.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.preparation-substitute",
                        value: Data("untouched".utf8),
                        at: substitute
                    )
                    substituteBefore = try self.archiveTreeSnapshot(at: substitute)
                },
                destinationPreparationFinished: {
                    try FileManager.default.moveItem(at: parent, to: retainedSubstituteParent)
                    try FileManager.default.moveItem(at: displacedParent, to: parent)
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("fd-relative merge should survive restored parent substitution: \(String(describing: result))")
        }

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("01-collision.txt")),
            Data("archive collision".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("existing-only.bin")),
            Data([0x00, 0xFF, 0x7A])
        )
        XCTAssertEqual(
            try extendedAttribute("com.grove.tests.atomic-root", at: destination),
            existingRootXattr
        )
        let retainedSubstitute = retainedSubstituteParent.appendingPathComponent("destination", isDirectory: true)
        XCTAssertEqual(try archiveTreeSnapshot(at: retainedSubstitute), try XCTUnwrap(substituteBefore))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retainedSubstitute.appendingPathComponent("01-collision.txt").path
            )
        )
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionRejectsInitialDanglingDestinationSymlink() throws {
        let password = "dangling-destination-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = tempRoot.appendingPathComponent("dangling-destination")
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: "missing-target"
        )

        let completed = expectation(description: "dangling destination rejected")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: password) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("a dangling destination symlink must be rejected")
        }
        XCTAssertEqual((error as NSError).code, Int(ENOTDIR))
        XCTAssertEqual(try fileIdentity(at: destination, followSymbolicLink: false).fileType, mode_t(S_IFLNK))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "missing-target")
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionMissingDestinationPreservesDirectoryCreatedBeforeCommit() throws {
        let password = "appeared-directory-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = tempRoot.appendingPathComponent("appeared-directory", isDirectory: true)
        let stateLock = NSLock()
        var replacementDirectory: URL?
        var appearedSnapshot: [ArchiveTreeEntrySnapshot]?

        let completed = expectation(description: "appeared directory preserved")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementDirectory = directory; stateLock.unlock()
                },
                immediatelyBeforeCommit: { _, commitDestination in
                    try FileManager.default.createDirectory(at: commitDestination, withIntermediateDirectories: false)
                    try Data("concurrent directory".utf8).write(
                        to: commitDestination.appendingPathComponent("concurrent.txt")
                    )
                    try self.setExtendedAttribute(
                        "com.grove.tests.concurrent-directory",
                        value: Data([0x00, 0xAA]),
                        at: commitDestination
                    )
                    let snapshot = try self.archiveTreeSnapshot(at: commitDestination)
                    stateLock.lock(); appearedSnapshot = snapshot; stateLock.unlock()
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("RENAME_EXCL must reject a concurrently appeared directory")
        }
        XCTAssertEqual((error as NSError).code, Int(EEXIST))
        stateLock.lock()
        let recordedReplacement = replacementDirectory
        let expectedSnapshot = appearedSnapshot
        stateLock.unlock()
        XCTAssertEqual(try archiveTreeSnapshot(at: destination), try XCTUnwrap(expectedSnapshot))
        XCTAssertFalse(recordedReplacement.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testEncryptedExtractionMissingDestinationPreservesSymlinkCreatedBeforeCommit() throws {
        let password = "appeared-symlink-secret"
        let archive = try createEncryptedFinalMergeArchive(password: password)
        let destination = tempRoot.appendingPathComponent("appeared-symlink")
        let symlinkTarget = tempRoot.appendingPathComponent("appeared-symlink-target", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: false)
        try Data("target remains safe".utf8).write(to: symlinkTarget.appendingPathComponent("target.txt"))
        let targetSnapshot = try archiveTreeSnapshot(at: symlinkTarget)
        let stateLock = NSLock()
        var replacementDirectory: URL?

        let completed = expectation(description: "appeared symlink preserved")
        var result: Result<URL, Error>?
        FileOperationService.shared.decompress(
            archive,
            to: destination,
            password: password,
            hooks: .init(
                replacementDirectoryCreated: { directory in
                    stateLock.lock(); replacementDirectory = directory; stateLock.unlock()
                },
                immediatelyBeforeCommit: { _, commitDestination in
                    try FileManager.default.createSymbolicLink(
                        atPath: commitDestination.path,
                        withDestinationPath: symlinkTarget.path
                    )
                }
            )
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("RENAME_EXCL must reject a concurrently appeared symlink")
        }
        XCTAssertEqual((error as NSError).code, Int(EEXIST))
        XCTAssertEqual(try fileIdentity(at: destination, followSymbolicLink: false).fileType, mode_t(S_IFLNK))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), symlinkTarget.path)
        XCTAssertEqual(try archiveTreeSnapshot(at: symlinkTarget), targetSnapshot)
        stateLock.lock(); let recordedReplacement = replacementDirectory; stateLock.unlock()
        XCTAssertFalse(recordedReplacement.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        XCTAssertTrue(try archiveTransactionResidue(nextTo: destination).isEmpty)
    }

    func testUnencryptedArchiveRoundTripStillWorksWithoutPassword() throws {
        let source = tempRoot.appendingPathComponent("plain.txt")
        try "plain-content".write(to: source, atomically: true, encoding: .utf8)
        let archive = tempRoot.appendingPathComponent("plain.zip")

        let compressed = expectation(description: "compressed without password")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([source], to: archive, password: nil) {
            compressResult = $0
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("unencrypted compression failed: \(String(describing: compressResult))")
        }

        let destination = tempRoot.appendingPathComponent("plain-output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let decompressed = expectation(description: "decompressed without password")
        var decompressResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: destination, password: nil) {
            decompressResult = $0
            decompressed.fulfill()
        }
        wait(for: [decompressed], timeout: 15)
        guard case .success = try XCTUnwrap(decompressResult) else {
            return XCTFail("unencrypted decompression failed: \(String(describing: decompressResult))")
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("plain.txt")), "plain-content")
    }

    func testCancelledCompressionPreservesExistingArchiveAndRemovesTemporaryOutput() throws {
        let source = tempRoot.appendingPathComponent("cancel-source.bin")
        try Data(repeating: 0xA7, count: 2 * 1024 * 1024).write(to: source)
        let archive = tempRoot.appendingPathComponent("existing.zip")
        let originalArchive = Data("existing archive must survive".utf8)
        try originalArchive.write(to: archive)
        let finished = expectation(description: "compression cancellation completes")
        let stateLock = NSLock()
        var cancellationRequested = false
        var archiveToolPID: pid_t = 0
        var result: Result<URL, Error>?

        FileOperationService.shared.compress(
            [source],
            to: archive,
            cancellationRequested: {
                stateLock.lock()
                defer { stateLock.unlock() }
                return cancellationRequested
            },
            archiveToolStarted: { pid in
                stateLock.lock()
                archiveToolPID = pid
                cancellationRequested = true
                stateLock.unlock()
            }
        ) {
            result = $0
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("cancelled compression should fail")
        }
        XCTAssertEqual((error as NSError).code, NSUserCancelledError)
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).contains {
                $0.hasPrefix(".grove-archive-")
            },
            "temporary sibling archives must be removed after cancellation"
        )
        stateLock.lock()
        let capturedPID = archiveToolPID
        stateLock.unlock()
        XCTAssertGreaterThan(capturedPID, 0)
        XCTAssertTrue(waitForProcessesToExit([capturedPID]))
    }

    func testCancelledEncryptedCompressionCleansWholeTransactionAndArchiveProcessTree() throws {
        let source = tempRoot.appendingPathComponent("encrypted-cancel-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x3C, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("payload.bin"))
        let archive = tempRoot.appendingPathComponent("encrypted-existing.zip")
        let existingArchive = Data("existing encrypted destination".utf8)
        try existingArchive.write(to: archive)
        let finished = expectation(description: "encrypted compression cancellation completes")
        let stateLock = NSLock()
        var cancellationRequested = false
        var wrapperPID: pid_t = 0
        var childPID: pid_t = 0
        var stagingDirectory: URL?
        var result: Result<URL, Error>?

        FileOperationService.shared.compress(
            [source],
            to: archive,
            password: "encrypted-cancel-password",
            cancellationRequested: {
                stateLock.lock()
                defer { stateLock.unlock() }
                return cancellationRequested
            },
            archiveToolStarted: { pid in
                stateLock.lock()
                wrapperPID = pid
                cancellationRequested = true
                stateLock.unlock()
            },
            archiveChildStarted: { pid in
                stateLock.lock()
                childPID = pid
                stateLock.unlock()
            },
            hooks: .init(stagingDirectoryCreated: { directory in
                stateLock.lock()
                stagingDirectory = directory
                stateLock.unlock()
            })
        ) {
            result = $0
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("cancelled encrypted compression should fail")
        }
        XCTAssertEqual((error as NSError).code, NSUserCancelledError)
        XCTAssertEqual(try Data(contentsOf: archive), existingArchive)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).contains {
            $0.hasPrefix(".grove-archive-")
        })
        stateLock.lock()
        let capturedStagingDirectory = stagingDirectory
        let capturedPIDs = [wrapperPID, childPID]
        stateLock.unlock()
        XCTAssertNotNil(capturedStagingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturedStagingDirectory?.path ?? ""))
        XCTAssertTrue(capturedPIDs.allSatisfy { $0 > 0 })
        XCTAssertTrue(waitForProcessesToExit(capturedPIDs), "encrypted compression cancellation left an archive process")
    }

    func testEncryptedCompressionFailurePreservesDestinationAndRemovesPartialTransaction() throws {
        let source = tempRoot.appendingPathComponent("encrypted-failure.txt")
        try Data("source".utf8).write(to: source)
        let archive = tempRoot.appendingPathComponent("encrypted-failure-existing.zip")
        let existingArchive = Data("existing archive".utf8)
        try existingArchive.write(to: archive)
        let finished = expectation(description: "injected encrypted failure completes")
        let stateLock = NSLock()
        var stagingDirectory: URL?
        var result: Result<URL, Error>?

        FileOperationService.shared.compress(
            [source],
            to: archive,
            password: "failure-password",
            hooks: .init(
                stagingDirectoryCreated: { directory in
                    stateLock.lock()
                    stagingDirectory = directory
                    stateLock.unlock()
                },
                encryptedArchiveTransformer: { temporaryArchive in
                    try Data("partial encrypted output".utf8).write(to: temporaryArchive)
                    throw NSError(
                        domain: "com.grove.test.injected-encryption",
                        code: 91,
                        userInfo: [NSLocalizedDescriptionKey: "Injected encryption failure"]
                    )
                }
            )
        ) {
            result = $0
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("injected encrypted failure should fail")
        }
        XCTAssertEqual((error as NSError).domain, "com.grove.test.injected-encryption")
        XCTAssertEqual(try Data(contentsOf: archive), existingArchive)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).contains {
            $0.hasPrefix(".grove-archive-")
        })
        stateLock.lock()
        let capturedStagingDirectory = stagingDirectory
        stateLock.unlock()
        XCTAssertNotNil(capturedStagingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturedStagingDirectory?.path ?? ""))
    }

    func testCompressionTransactionUsesCrossVolumeFallbackForMultipleDirectoryRoots() throws {
        let first = tempRoot.appendingPathComponent("transaction-first", isDirectory: true)
        let second = tempRoot.appendingPathComponent("transaction-second", isDirectory: true)
        try FileManager.default.createDirectory(at: first.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let firstPayload = Data((0..<12_345).map { UInt8(truncatingIfNeeded: $0 * 11) })
        let secondPayload = Data((0..<23_456).map { UInt8(truncatingIfNeeded: $0 * 17) })
        try firstPayload.write(to: first.appendingPathComponent("nested/value.bin"))
        try secondPayload.write(to: second.appendingPathComponent("nested/value.bin"))
        let archive = tempRoot.appendingPathComponent("transaction-exdev.zip")
        let stateLock = NSLock()
        var hardLinkAttempts = 0
        var stagingDirectory: URL?
        let compressed = expectation(description: "EXDEV transaction compressed")
        var compressResult: Result<URL, Error>?

        FileOperationService.shared.compress(
            [first, second],
            to: archive,
            hooks: .init(
                hardLinkItem: { _, _ in
                    stateLock.lock()
                    hardLinkAttempts += 1
                    stateLock.unlock()
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
                },
                stagingDirectoryCreated: { directory in
                    stateLock.lock()
                    stagingDirectory = directory
                    stateLock.unlock()
                }
            )
        ) {
            compressResult = $0
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 10)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("EXDEV transaction compression failed: \(String(describing: compressResult))")
        }

        stateLock.lock()
        let capturedAttempts = hardLinkAttempts
        let capturedStagingDirectory = stagingDirectory
        stateLock.unlock()
        XCTAssertEqual(capturedAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturedStagingDirectory?.path ?? ""))

        let output = tempRoot.appendingPathComponent("transaction-exdev-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let decompressed = expectation(description: "EXDEV transaction decompressed")
        var decompressResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: output) {
            decompressResult = $0
            decompressed.fulfill()
        }
        wait(for: [decompressed], timeout: 10)
        guard case .success = try XCTUnwrap(decompressResult) else {
            return XCTFail("EXDEV transaction extraction failed: \(String(describing: decompressResult))")
        }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("transaction-first/nested/value.bin")), firstPayload)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("transaction-second/nested/value.bin")), secondPayload)
    }

    func testArchiveDirectoryStagingHardLinksAllSameVolumeFileData() throws {
        let source = tempRoot.appendingPathComponent("Large Folder", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        let packageContents = source.appendingPathComponent("Example.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageContents, withIntermediateDirectories: true)

        let largePayload = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
        let nestedFile = nested.appendingPathComponent("payload.bin")
        let packageFile = packageContents.appendingPathComponent("Info.plist")
        try largePayload.write(to: nestedFile)
        try Data("package-data".utf8).write(to: packageFile)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("payload-link").path,
            withDestinationPath: "Nested/payload.bin"
        )

        let staged = tempRoot.appendingPathComponent("staged", isDirectory: true)
        let report = try FileOperationService.shared.stageForArchiving(source, to: staged)

        XCTAssertEqual(report.createdDirectories, 4)
        XCTAssertEqual(report.hardLinkedFiles, 2)
        XCTAssertEqual(report.copiedFiles, 0)
        XCTAssertEqual(report.symbolicLinks, 1)
        XCTAssertEqual(report.copiedBytes, 0, "same-volume staging must not duplicate regular-file storage")
        XCTAssertEqual(report.hardLinkedBytes, Int64(largePayload.count + Data("package-data".utf8).count))

        let stagedNestedFile = staged.appendingPathComponent("Nested/payload.bin")
        let stagedPackageFile = staged.appendingPathComponent("Example.app/Contents/Info.plist")
        let sourcePayloadIdentity = try fileIdentity(at: nestedFile)
        let stagedPayloadIdentity = try fileIdentity(at: stagedNestedFile)
        XCTAssertEqual(sourcePayloadIdentity.device, stagedPayloadIdentity.device)
        XCTAssertEqual(sourcePayloadIdentity.inode, stagedPayloadIdentity.inode)
        XCTAssertGreaterThanOrEqual(stagedPayloadIdentity.linkCount, 2)
        XCTAssertEqual(try fileIdentity(at: packageFile).inode, try fileIdentity(at: stagedPackageFile).inode)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("payload-link").path),
            "Nested/payload.bin"
        )
    }

    func testArchiveStagingPreservesSymbolicLinkMetadataWithoutFollowingTarget() throws {
        let source = tempRoot.appendingPathComponent("metadata-link")
        try FileManager.default.createSymbolicLink(
            atPath: source.path,
            withDestinationPath: "../private-target-[*?]"
        )
        try configureSupportedSymbolicLinkMetadata(at: source)
        let expected = try archiveTreeSnapshot(at: source)

        let staged = tempRoot.appendingPathComponent("staged-metadata-link")
        let report = try FileOperationService.shared.stageForArchiving(source, to: staged)

        XCTAssertEqual(report.symbolicLinks, 1)
        XCTAssertEqual(try archiveTreeSnapshot(at: staged), expected)
    }

    func testUnencryptedArchiveRoundTripPreservesSymbolicLinkMetadata() throws {
        try assertSymbolicLinkMetadataArchiveRoundTrip(password: nil)
    }

    func testEncryptedArchiveRoundTripPreservesSymbolicLinkMetadata() throws {
        try assertSymbolicLinkMetadataArchiveRoundTrip(password: "symlink-metadata-secret")
    }

    func testArchiveStagingDirectoryIsCreatedOnSelectedSourceVolume() throws {
        let source = tempRoot.appendingPathComponent("source-volume", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let staging = try FileOperationService.shared.createArchiveStagingDirectory(for: [source])
        defer { try? FileManager.default.removeItem(at: staging) }

        XCTAssertEqual(try fileIdentity(at: source).device, try fileIdentity(at: staging).device)
    }

    func testArchiveStagingExcludesItselfWhenSourceContainsStagingDirectory() throws {
        let sourceRoot = tempRoot.appendingPathComponent("MountedVolume", isDirectory: true)
        let temporaryItems = sourceRoot.appendingPathComponent(".TemporaryItems", isDirectory: true)
        let staging = temporaryItems.appendingPathComponent("GroveArchiveStage", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("outside staging".utf8).write(to: sourceRoot.appendingPathComponent("payload.txt"))

        let destination = staging.appendingPathComponent("MountedVolume", isDirectory: true)
        let report = try FileOperationService.shared.stageForArchiving(
            sourceRoot,
            to: destination,
            excluding: staging
        )

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("payload.txt")), "outside staging")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(".TemporaryItems/GroveArchiveStage").path
            ),
            "the staging tree must not archive itself recursively"
        )
        XCTAssertEqual(report.hardLinkedFiles, 1)
    }

    func testArchiveStagingFallsBackToPerFileCopyWhenHardLinkReportsCrossVolume() throws {
        let source = tempRoot.appendingPathComponent("cross-volume-source.bin")
        let destination = tempRoot.appendingPathComponent("cross-volume-staged.bin")
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: source)

        var attemptedLinks: [(URL, URL)] = []
        let report = try FileOperationService.shared.stageForArchiving(
            source,
            to: destination,
            hardLinkItem: { from, to in
                attemptedLinks.append((from, to))
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
            }
        )

        XCTAssertEqual(attemptedLinks.count, 1)
        XCTAssertEqual(attemptedLinks.first?.0, source)
        XCTAssertEqual(attemptedLinks.first?.1, destination)
        XCTAssertEqual(report.hardLinkedFiles, 0)
        XCTAssertEqual(report.copiedFiles, 1)
        XCTAssertEqual(report.hardLinkedBytes, 0)
        XCTAssertEqual(report.copiedBytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertNotEqual(try fileIdentity(at: source).inode, try fileIdentity(at: destination).inode)
    }

    func testArchiveDirectoryStagingCopiesMultipleRootsWhenEveryHardLinkReportsCrossVolume() throws {
        let first = tempRoot.appendingPathComponent("first-root", isDirectory: true)
        let second = tempRoot.appendingPathComponent("second-root", isDirectory: true)
        try FileManager.default.createDirectory(at: first.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let firstPayload = Data((0..<16_385).map { UInt8(truncatingIfNeeded: $0 * 3) })
        let secondPayload = Data((0..<32_769).map { UInt8(truncatingIfNeeded: $0 * 5) })
        try firstPayload.write(to: first.appendingPathComponent("nested/value.bin"))
        try secondPayload.write(to: second.appendingPathComponent("nested/value.bin"))
        let staged = tempRoot.appendingPathComponent("multi-root-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)

        var report = FileOperationService.ArchiveStagingReport()
        for source in [first, second] {
            report += try FileOperationService.shared.stageForArchiving(
                source,
                to: staged.appendingPathComponent(source.lastPathComponent),
                hardLinkItem: { _, _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
                }
            )
        }

        XCTAssertEqual(report.hardLinkedFiles, 0)
        XCTAssertEqual(report.copiedFiles, 2)
        XCTAssertEqual(report.copiedBytes, Int64(firstPayload.count + secondPayload.count))
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("first-root/nested/value.bin")), firstPayload)
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("second-root/nested/value.bin")), secondPayload)
    }

    func testCrossVolumeArchiveCopyCancellationRemovesPartialStagedRoot() throws {
        let source = tempRoot.appendingPathComponent("cancel-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 16 * 1024 * 1024).write(to: source.appendingPathComponent("large.bin"))
        let destination = tempRoot.appendingPathComponent("cancel-copy-staged", isDirectory: true)
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try FileOperationService.shared.stageForArchiving(
                source,
                to: destination,
                hardLinkItem: { _, _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
                },
                cancellationRequested: {
                    cancellationChecks += 1
                    return cancellationChecks >= 4
                }
            )
        ) { error in
            XCTAssertEqual((error as NSError).code, NSUserCancelledError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCompressRejectsSelectedSourcesWithDuplicateRootNames() throws {
        let firstParent = tempRoot.appendingPathComponent("first", isDirectory: true)
        let secondParent = tempRoot.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
        let first = firstParent.appendingPathComponent("duplicate.txt")
        let second = secondParent.appendingPathComponent("duplicate.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let archive = tempRoot.appendingPathComponent("duplicates.zip")

        let finished = expectation(description: "duplicate roots rejected")
        var result: Result<URL, Error>?
        FileOperationService.shared.compress([first, second], to: archive) {
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        guard case .failure(let error) = try XCTUnwrap(result) else {
            return XCTFail("duplicate root names should fail before archiving")
        }
        let archiveError = error as NSError
        XCTAssertEqual(archiveError.domain, "com.grove.archive-staging")
        XCTAssertEqual(archiveError.code, Int(EEXIST))
        XCTAssertTrue(archiveError.localizedDescription.contains("duplicate.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testComplexDirectoryArchiveRoundTripWithoutPasswordIsByteAndStructureExact() throws {
        try assertComplexArchiveRoundTrip(password: nil, name: "plain-complex")
    }

    private func assertComplexArchiveRoundTrip(password: String?, name: String) throws {
        let workspace = tempRoot.appendingPathComponent("\(name)-workspace", isDirectory: true)
        let project = workspace.appendingPathComponent("Project", isDirectory: true)
        let nested = project.appendingPathComponent("Nested/Deep", isDirectory: true)
        let packageContents = project.appendingPathComponent("Example.app/Contents/Resources", isDirectory: true)
        let emptyDirectory = project.appendingPathComponent("Empty Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageContents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)

        let nestedPayload = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let packagePayload = Data((0..<4_097).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let standalonePayload = Data((0..<8_193).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try nestedPayload.write(to: nested.appendingPathComponent("payload.bin"))
        try packagePayload.write(to: packageContents.appendingPathComponent("asset.dat"))
        try Data("nested duplicate".utf8).write(to: nested.appendingPathComponent("same-name.txt"))
        try Data("package duplicate".utf8).write(to: packageContents.appendingPathComponent("same-name.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: project.appendingPathComponent("payload-link").path,
            withDestinationPath: "Nested/Deep/payload.bin"
        )
        let standalone = workspace.appendingPathComponent("standalone.bin")
        try standalonePayload.write(to: standalone)
        let metadataDirectory = project.appendingPathComponent("Nested", isDirectory: true)
        let metadataDate = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(Darwin.chmod(metadataDirectory.path, 0o701), 0)
        try FileManager.default.setAttributes([.modificationDate: metadataDate], ofItemAtPath: metadataDirectory.path)
        try setExtendedAttribute("com.grove.tests.directory", value: Data("directory-xattr".utf8), at: metadataDirectory)
        try setExtendedAttribute(
            "com.grove.tests.file",
            value: Data([0x00, 0x01, 0x7F, 0xFF]),
            at: nested.appendingPathComponent("payload.bin")
        )

        let archive = tempRoot.appendingPathComponent("\(name).zip")
        let compressed = expectation(description: "\(name) compressed")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([project, standalone], to: archive, password: password) {
            compressResult = $0
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 20)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("complex compression failed: \(String(describing: compressResult))")
        }

        let output = tempRoot.appendingPathComponent("\(name)-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let decompressed = expectation(description: "\(name) decompressed")
        var decompressResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: output, password: password) {
            decompressResult = $0
            decompressed.fulfill()
        }
        wait(for: [decompressed], timeout: 20)
        guard case .success = try XCTUnwrap(decompressResult) else {
            return XCTFail("complex decompression failed: \(String(describing: decompressResult))")
        }

        let roots = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertEqual(Set(roots), Set(["Project", "standalone.bin"]), "archive roots must be selected leaf names")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Project/Nested/Deep/payload.bin")), nestedPayload)
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("Project/Example.app/Contents/Resources/asset.dat")),
            packagePayload
        )
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("standalone.bin")), standalonePayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Project/Empty Folder").path))
        XCTAssertEqual(
            try String(contentsOf: output.appendingPathComponent("Project/Nested/Deep/same-name.txt")),
            "nested duplicate"
        )
        XCTAssertEqual(
            try String(contentsOf: output.appendingPathComponent("Project/Example.app/Contents/Resources/same-name.txt")),
            "package duplicate"
        )
        let extractedLink = output.appendingPathComponent("Project/payload-link")
        XCTAssertEqual(try fileIdentity(at: extractedLink, followSymbolicLink: false).fileType, mode_t(S_IFLNK))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path),
            "Nested/Deep/payload.bin"
        )
        let extractedMetadataDirectory = output.appendingPathComponent("Project/Nested", isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: extractedMetadataDirectory.path)
        let permissions = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        XCTAssertEqual(permissions, 0o701)
        let extractedDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(extractedDate.timeIntervalSince1970, metadataDate.timeIntervalSince1970, accuracy: 2)
        // Standard-compatible plain ZIPs cannot carry arbitrary macOS xattrs without exposing
        // AppleDouble sidecars as archive members. Grove therefore preserves bytes, structure,
        // symlink targets, permissions and timestamps here; encrypted archives carry the private
        // metadata manifest and test exact xattr/resource-fork rehydration separately.
    }

    private func createEncryptedFinalMergeArchive(password: String) throws -> URL {
        let sourceParent = tempRoot.appendingPathComponent("merge-source-\(UUID().uuidString)", isDirectory: true)
        let nested = sourceParent.appendingPathComponent("02-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let collision = sourceParent.appendingPathComponent("01-collision.txt")
        let nestedCollision = nested.appendingPathComponent("shared.txt")
        let newMember = sourceParent.appendingPathComponent("03-new.txt")
        try Data("archive collision".utf8).write(to: collision)
        try Data("archive nested collision".utf8).write(to: nestedCollision)
        try Data("archive new member".utf8).write(to: newMember)
        try setExtendedAttribute("com.grove.tests.atomic-archive", value: Data("archive metadata".utf8), at: nestedCollision)

        let archive = tempRoot.appendingPathComponent("atomic-merge-\(UUID().uuidString).zip")
        let completed = expectation(description: "atomic merge fixture compressed")
        var result: Result<URL, Error>?
        FileOperationService.shared.compress(
            [collision, nested, newMember],
            to: archive,
            password: password
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        switch try XCTUnwrap(result) {
        case .success:
            break
        case .failure(let error):
            throw error
        }
        return archive
    }

    private func createFinalMergeDestination(named name: String) throws -> URL {
        let destination = tempRoot.appendingPathComponent(name, isDirectory: true)
        let nested = destination.appendingPathComponent("02-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let collision = destination.appendingPathComponent("01-collision.txt")
        let nestedCollision = nested.appendingPathComponent("shared.txt")
        let existingOnly = destination.appendingPathComponent("existing-only.bin")
        let nestedExistingOnly = nested.appendingPathComponent("existing-only.txt")
        try Data("existing collision".utf8).write(to: collision)
        try Data("existing nested collision".utf8).write(to: nestedCollision)
        try Data([0x00, 0xFF, 0x7A]).write(to: existingOnly)
        try Data("nested existing".utf8).write(to: nestedExistingOnly)
        try FileManager.default.createSymbolicLink(
            atPath: destination.appendingPathComponent("existing-link").path,
            withDestinationPath: "existing-only.bin"
        )
        try setExtendedAttribute("com.grove.tests.atomic-root", value: Data("root metadata".utf8), at: destination)
        try setExtendedAttribute("com.grove.tests.atomic-nested", value: Data([0x01, 0x00, 0xFE]), at: nested)
        try setExtendedAttribute("com.grove.tests.atomic-existing", value: Data("preserve me".utf8), at: existingOnly)
        XCTAssertEqual(Darwin.chmod(destination.path, 0o751), 0)
        XCTAssertEqual(Darwin.chmod(nested.path, 0o711), 0)
        XCTAssertEqual(Darwin.chmod(existingOnly.path, 0o640), 0)
        let rootDate = Date(timeIntervalSince1970: 1_700_010_001)
        let nestedDate = Date(timeIntervalSince1970: 1_700_010_002)
        let fileDate = Date(timeIntervalSince1970: 1_700_010_003)
        try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: existingOnly.path)
        try FileManager.default.setAttributes([.modificationDate: nestedDate], ofItemAtPath: nested.path)
        try FileManager.default.setAttributes([.modificationDate: rootDate], ofItemAtPath: destination.path)
        return destination
    }

    private func applyPartialFinalMerge(from extracted: URL, to replacement: URL) throws {
        let orderedMembers = ["01-collision.txt", "02-nested"]
        for member in orderedMembers {
            let source = extracted.appendingPathComponent(member)
            let target = replacement.appendingPathComponent(member)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
        try Data("partial added member".utf8).write(
            to: replacement.appendingPathComponent("partial-added.txt")
        )
        try setExtendedAttribute(
            "com.grove.tests.partial-merge",
            value: Data("partial metadata".utf8),
            at: replacement
        )
        XCTAssertEqual(Darwin.chmod(replacement.path, 0o700), 0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 123)],
            ofItemAtPath: replacement.path
        )
    }

    private func archiveTransactionResidue(nextTo destination: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .filter {
                $0.hasPrefix(".grove-extract-replacement-")
                    || $0.hasPrefix(".grove-extract-")
                    || $0.hasPrefix(".grove-cleanup-")
                    || $0.hasPrefix(".GroveArchiveMetadata-")
            }
            .sorted()
    }

    private func archiveTreeSnapshot(at root: URL) throws -> [ArchiveTreeEntrySnapshot] {
        var snapshots: [ArchiveTreeEntrySnapshot] = []
        func append(_ url: URL, relativePath: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            let fileType = info.st_mode & mode_t(S_IFMT)
            let isSymbolicLink = fileType == mode_t(S_IFLNK)
            snapshots.append(
                ArchiveTreeEntrySnapshot(
                    relativePath: relativePath,
                    fileType: UInt32(fileType),
                    permissions: UInt16(info.st_mode & 0o7777),
                    flags: UInt32(info.st_flags),
                    modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                    modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                    contents: fileType == mode_t(S_IFREG) ? try Data(contentsOf: url) : nil,
                    symbolicLinkDestination: isSymbolicLink
                        ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                        : nil,
                    extendedAttributes: try extendedAttributesSnapshot(at: url, noFollow: isSymbolicLink),
                    accessControlList: try accessControlListSnapshot(at: url, noFollow: isSymbolicLink)
                )
            )
            guard fileType == mode_t(S_IFDIR) else { return }
            for child in try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try append(
                    child,
                    relativePath: relativePath == "."
                        ? child.lastPathComponent
                        : "\(relativePath)/\(child.lastPathComponent)"
                )
            }
        }
        try append(root, relativePath: ".")
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }

    private func extendedAttributesSnapshot(at url: URL, noFollow: Bool) throws -> [String: Data] {
        let options = noFollow ? XATTR_NOFOLLOW : 0
        let byteCount = url.path.withCString { listxattr($0, nil, 0, options) }
        guard byteCount >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        guard byteCount > 0 else { return [:] }
        var names = Data(count: byteCount)
        let readCount = names.withUnsafeMutableBytes { bytes in
            url.path.withCString {
                listxattr($0, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count, options)
            }
        }
        guard readCount == byteCount else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var values: [String: Data] = [:]
        for nameData in names.split(separator: 0) {
            let name = String(decoding: nameData, as: UTF8.self)
            let valueSize = url.path.withCString { path in
                name.withCString { getxattr(path, $0, nil, 0, 0, options) }
            }
            guard valueSize >= 0 else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            var value = Data(count: valueSize)
            let valueReadCount = value.withUnsafeMutableBytes { bytes in
                url.path.withCString { path in
                    name.withCString { getxattr(path, $0, bytes.baseAddress, bytes.count, 0, options) }
                }
            }
            guard valueReadCount == valueSize else {
                let errorCode = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
            }
            values[name] = value
        }
        return values
    }

    private func accessControlListSnapshot(at url: URL, noFollow: Bool) throws -> Data? {
        errno = 0
        let acl = url.path.withCString { path in
            noFollow
                ? acl_get_link_np(path, ACL_TYPE_EXTENDED)
                : acl_get_file(path, ACL_TYPE_EXTENDED)
        }
        guard let acl else {
            if [ENOENT, ENOTSUP].contains(errno) { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let byteCount = acl_size(acl)
        guard byteCount > 0 else { return nil }
        var data = Data(count: Int(byteCount))
        let copied = data.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, byteCount) }
        guard copied == byteCount else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return data
    }

    private func setExtendedAttribute(
        _ name: String,
        value: Data,
        at url: URL,
        noFollow: Bool = false
    ) throws {
        let options = noFollow ? XATTR_NOFOLLOW : 0
        let result = url.path.withCString { path in
            name.withCString { attributeName in
                value.withUnsafeBytes { bytes in
                    setxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, options)
                }
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
    }

    private func configureSupportedSymbolicLinkMetadata(at link: URL) throws {
        do {
            try setExtendedAttribute(
                "com.grove.tests.symlink-round-trip",
                value: Data([0x00, 0x7F, 0xFF]),
                at: link,
                noFollow: true
            )
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && [Int(ENOTSUP), Int(EPERM), Int(EINVAL)].contains(error.code) {
            // Some temporary filesystems do not support xattrs on symbolic-link inodes.
        }
        let timestamp = timespec(tv_sec: 1_700_123_456, tv_nsec: 135_792_468)
        do {
            try setModificationTime(timestamp, at: link, noFollow: true)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && [Int(ENOTSUP), Int(EPERM), Int(EINVAL)].contains(error.code) {
            // Conditional only for filesystems that reject no-follow timestamp updates.
        }
        if lchflags(link.path, UInt32(UF_HIDDEN)) != 0,
           ![ENOTSUP, EPERM, EINVAL].contains(errno) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Install an extended ACL when the host filesystem supports ACLs on symbolic links.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-h", "+a", "everyone allow readattr", link.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let acl = try accessControlListSnapshot(at: link, noFollow: true)
            XCTAssertTrue(acl == nil || acl?.isEmpty == true, "ACL setup failed despite a pre-existing ACL")
        }
    }

    private func assertSymbolicLinkMetadataArchiveRoundTrip(password: String?) throws {
        let source = tempRoot.appendingPathComponent(
            password == nil ? "plain-metadata-link" : "encrypted-metadata-link"
        )
        try FileManager.default.createSymbolicLink(
            atPath: source.path,
            withDestinationPath: "../target-[literal]*?.bin"
        )
        try configureSupportedSymbolicLinkMetadata(at: source)
        let expected = try archiveTreeSnapshot(at: source)
        let archive = tempRoot.appendingPathComponent(
            password == nil ? "plain-symlink-metadata.zip" : "encrypted-symlink-metadata.zip"
        )

        let compressed = expectation(description: "symlink metadata compressed")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([source], to: archive, password: password) {
            compressResult = $0
            compressed.fulfill()
        }
        wait(for: [compressed], timeout: 15)
        guard case .success = try XCTUnwrap(compressResult) else {
            return XCTFail("symlink metadata compression failed: \(String(describing: compressResult))")
        }

        let output = tempRoot.appendingPathComponent(
            password == nil ? "plain-symlink-output" : "encrypted-symlink-output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let decompressed = expectation(description: "symlink metadata decompressed")
        var decompressResult: Result<URL, Error>?
        FileOperationService.shared.decompress(archive, to: output, password: password) {
            decompressResult = $0
            decompressed.fulfill()
        }
        wait(for: [decompressed], timeout: 15)
        guard case .success = try XCTUnwrap(decompressResult) else {
            return XCTFail("symlink metadata extraction failed: \(String(describing: decompressResult))")
        }
        let extractedLink = output.appendingPathComponent(source.lastPathComponent)
        if password == nil {
            // Plain ZIP compatibility takes precedence over a visible private metadata sidecar.
            // The platform ZIP format preserves the symlink target, while inode-only metadata is
            // best-effort when ditto cannot encode it invisibly.
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path),
                "../target-[literal]*?.bin"
            )
            XCTAssertEqual(try zipMemberNames(archive), [source.lastPathComponent])
            let externalOutput = tempRoot.appendingPathComponent("external-unzip-output", isDirectory: true)
            try FileManager.default.createDirectory(at: externalOutput, withIntermediateDirectories: false)
            try runTestProcess("/usr/bin/unzip", arguments: ["-q", archive.path, "-d", externalOutput.path])
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: externalOutput.appendingPathComponent(source.lastPathComponent).path
                ),
                "../target-[literal]*?.bin"
            )
        } else {
            XCTAssertEqual(try archiveTreeSnapshot(at: extractedLink), expected)
        }
    }

    private func zipMemberNames(_ archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.grove.test.unzip",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "unzip failed"]
            )
        }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
    }

    private func runTestProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.grove.test.process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "process failed"]
            )
        }
    }

    private func setModificationTime(
        _ modificationTime: timespec,
        at url: URL,
        noFollow: Bool = false
    ) throws {
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            modificationTime
        ]
        let result = times.withUnsafeBufferPointer { buffer in
            utimensat(
                AT_FDCWD,
                url.path,
                buffer.baseAddress,
                noFollow ? AT_SYMLINK_NOFOLLOW : 0
            )
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func setResourceForkIfSupported(_ value: Data, at url: URL) throws -> Bool {
        do {
            try setExtendedAttribute("com.apple.ResourceFork", value: value, at: url)
            return true
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && [Int(ENOTSUP), Int(EPERM), Int(EINVAL)].contains(error.code) {
            return false
        }
    }

    private func removeExtendedAttribute(_ name: String, at url: URL) throws {
        let result = url.path.withCString { path in
            name.withCString { attributeName in
                removexattr(path, attributeName, 0)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
    }

    private func extendedAttribute(_ name: String, at url: URL) throws -> Data {
        let byteCount = url.path.withCString { path in
            name.withCString { attributeName in
                getxattr(path, attributeName, nil, 0, 0, 0)
            }
        }
        guard byteCount >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        var value = Data(count: byteCount)
        let readCount = value.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                name.withCString { attributeName in
                    getxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard readCount == byteCount else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        return value
    }

    private func fileIdentity(
        at url: URL,
        followSymbolicLink: Bool = true
    ) throws -> (device: dev_t, inode: ino_t, linkCount: nlink_t, fileType: mode_t) {
        var info = stat()
        let result = followSymbolicLink ? stat(url.path, &info) : lstat(url.path, &info)
        guard result == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }
        return (info.st_dev, info.st_ino, info.st_nlink, info.st_mode & mode_t(S_IFMT))
    }

    private func waitForArchiveProcessTree(rootPID: pid_t) throws -> [pid_t] {
        var captured: [pid_t] = []
        XCTAssertTrue(waitForCondition(timeout: 2) {
            captured = self.processTree(rootPID: rootPID)
            return captured.count > 1
        }, "archive child did not appear under Expect wrapper \(rootPID)")
        return captured
    }

    private func processTree(rootPID: pid_t) -> [pid_t] {
        var result = [rootPID]
        var pending = [rootPID]
        while let parent = pending.popLast() {
            let children = childPIDs(of: parent)
            result.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return Array(Set(result)).sorted()
    }

    private func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parentPID)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: output, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: { $0.isNewline }).compactMap { pid_t($0) }
        } catch {
            return []
        }
    }

    private func processSnapshot(pids: [pid_t]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["eww", "-p", pids.map(String.init).joined(separator: ","), "-o", "command="]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.grove.test.ps",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: error, encoding: .utf8) ?? "ps failed"]
            )
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    private func waitForProcessesToExit(_ pids: [pid_t]) -> Bool {
        waitForCondition(timeout: 3) {
            pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH }
        }
    }

    private func currentOpenFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return condition()
    }
}
