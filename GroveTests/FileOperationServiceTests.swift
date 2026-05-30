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
}
