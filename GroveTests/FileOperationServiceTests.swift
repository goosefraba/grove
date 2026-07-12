import XCTest
@testable import Grove

final class FileOperationServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testRenameRejectsPathComponents() throws {
        let file = tempRoot.appendingPathComponent("file.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FileOperationService.shared.rename(file, to: "../escaped.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
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

    // MARK: - #9 / #47 Password compress/extract round-trip

    func testCompressWithPasswordProducesEncryptedArchiveThatOnlyDecryptsWithPassword() throws {
        let workspace = tempRoot.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let secret = workspace.appendingPathComponent("secret.txt")
        try "top-secret".write(to: secret, atomically: true, encoding: .utf8)
        let archive = tempRoot.appendingPathComponent("out.zip")
        let password = "hunter2"

        let compressed = expectation(description: "compressed")
        var compressResult: Result<URL, Error>?
        FileOperationService.shared.compress([secret], to: archive, level: .normal, password: password) {
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
        FileOperationService.shared.decompress(archive, to: wrongDir, password: "nope") { wrongResult = $0; wrong.fulfill() }
        wait(for: [wrong], timeout: 15)
        if case .success = try XCTUnwrap(wrongResult) {
            XCTFail("extraction with the wrong password should fail")
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
        XCTAssertEqual(try String(contentsOf: rightDir.appendingPathComponent("secret.txt")), "top-secret")
    }
}
