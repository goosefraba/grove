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
}
