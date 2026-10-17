import XCTest
import Combine
@testable import Grove

final class DiskUsageScannerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GroveStorageTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = try DiskUsageScanner.canonicalURL(root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }
    private func allocated(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? 0)
    }
    private func scan(_ url: URL? = nil) throws -> DiskUsageSnapshot {
        try DiskUsageScanner().scan(url ?? root, cancellation: DiskUsageCancellation())
    }

    func testIncludesHiddenAndPackageContentsAndReconcilesCategories() throws {
        let a = try file(".cache/hidden.txt", bytes: 5)
        let b = try file("Example.app/Contents/binary", bytes: 9000)
        let c = try file("nested/image.jpg", bytes: 19000)
        try file("empty", bytes: 0)
        let result = try scan()
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(result.fileCount, 4)
        XCTAssertEqual(result.logicalBytes, 28005)
        XCTAssertEqual(result.folderCount, 4)
        XCTAssertEqual(result.allocatedBytes, try allocated(a) + allocated(b) + allocated(c))
        XCTAssertEqual(result.entries.reduce(0) { $0 + $1.allocatedBytes }, result.allocatedBytes)
        XCTAssertEqual(result.categories.values.reduce(0, +), result.allocatedBytes)
        XCTAssertEqual(result.categories[.applications], try allocated(b))
        XCTAssertTrue(result.entries.contains { $0.name == ".cache" })
        XCTAssertEqual(result.largestFiles.first?.url, c)
    }

    func testSymlinkedRootSpellingStillReconcilesEnumeratorPaths() throws {
        try file("nested/a.txt", bytes: 9000)
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("GroveStorageAlias-\(UUID())")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        let result = try scan(alias)
        XCTAssertEqual(result.root, root)
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.logicalBytes, 9000)
        XCTAssertEqual(result.entries.reduce(0) { $0 + $1.allocatedBytes }, result.allocatedBytes)
    }

    func testSparseAndTinyFilesKeepAllocatedSeparateFromLogical() throws {
        let sparse = try file("sparse", bytes: 0)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
        let tiny = try file("tiny", bytes: 1)
        let result = try scan()
        XCTAssertEqual(result.logicalBytes, 64 * 1024 * 1024 + 1)
        XCTAssertEqual(result.allocatedBytes, try allocated(sparse) + allocated(tiny))
        XCTAssertLessThan(result.allocatedBytes, result.logicalBytes)
        XCTAssertEqual(result.entries.first { $0.name == "sparse" }?.allocatedBytes, try allocated(sparse))
    }

    func testHardLinksCountOnceAndDrillDownIsMeasuredIndependently() throws {
        let source = try file("one/source.bin", bytes: 15000)
        let sibling = root.appendingPathComponent("two/link.bin")
        try FileManager.default.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: sibling)
        let result = try scan()
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.logicalBytes, 30000)
        XCTAssertEqual(result.duplicateHardlinks, 1)
        XCTAssertEqual(result.allocatedBytes, try allocated(source))
        XCTAssertEqual(try scan(source.deletingLastPathComponent()).allocatedBytes, try allocated(source))
        XCTAssertEqual(try scan(sibling.deletingLastPathComponent()).allocatedBytes, try allocated(source))
    }

    func testSymlinkLoopOutsideAndDanglingLinksAreNeverFollowed() throws {
        try file("inside/real", bytes: 12000)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID())")
        try Data(repeating: 7, count: 30000).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "/missing-\(UUID())")
        let result = try scan()
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.logicalBytes, 12000)
        XCTAssertEqual(result.skippedLinks, 3)
        XCTAssertEqual(result.entries.filter(\.isSymbolicLink).count, 3)
    }

    func testMetadataFailureKeepsReadableDataAndReportsPartial() throws {
        let readable = try file("readable.txt", bytes: 9000)
        let denied = try file("denied.txt", bytes: 12000)
        let scanner = DiskUsageScanner(resourceValues: { url, keys in
            if url == denied { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return try url.resourceValues(forKeys: keys)
        })
        let result = try scanner.scan(root, cancellation: DiskUsageCancellation())
        XCTAssertTrue(result.isPartial)
        XCTAssertGreaterThan(result.issueCount, 0)
        XCTAssertEqual(result.allocatedBytes, try allocated(readable))
        XCTAssertTrue(result.issues.contains { $0.url == denied })
        XCTAssertGreaterThan(result.entries.first { $0.url == denied }?.issueCount ?? 0, 0)
        XCTAssertThrowsError(try scan(root.appendingPathComponent("missing")))
    }

    func testNestedMountGapKeepsAncestorDrillableAndExcludesOnlyMountRow() throws {
        let kept = try file("parent/kept.txt", bytes: 9000)
        try file("parent/nested-mount/ignored", bytes: 12000)
        try file("direct-mount/ignored", bytes: 12000)
        let nested = root.appendingPathComponent("parent/nested-mount")
        let direct = root.appendingPathComponent("direct-mount")
        let scanner = DiskUsageScanner(deviceIdentifier: { url, actual in
            url.path == nested.path || url.path == direct.path ? actual &+ 1 : actual
        })
        let result = try scanner.scan(root, cancellation: DiskUsageCancellation())
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.skippedVolumes, 2)
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.allocatedBytes, try allocated(kept))
        let ancestor = try XCTUnwrap(result.entries.first { $0.name == "parent" })
        XCTAssertFalse(ancestor.isExcluded)
        XCTAssertGreaterThan(ancestor.issueCount, 0)
        XCTAssertTrue(try XCTUnwrap(result.entries.first { $0.name == "direct-mount" }).isExcluded)
    }

    func testTopFilesAndIssueExamplesAreBounded() throws {
        for index in 0..<75 { try file("file-\(index)", bytes: (index + 1) * 500) }
        let result = try scan()
        XCTAssertEqual(result.largestFiles.count, 32)
        XCTAssertEqual(result.fileCount, 75)
        XCTAssertEqual(result.largestFiles.map(\.id), result.largestFiles.sorted(by: DiskUsageScanner.largestFirst).map(\.id))
        let denied = DiskUsageScanner(resourceValues: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) })
        let partial = try denied.scan(root, cancellation: DiskUsageCancellation())
        XCTAssertEqual(partial.issues.count, 40)
        XCTAssertGreaterThan(partial.issueCount, 40)
    }

    func testCancellationBeforeAndDuringScanNeverReturnsComplete() throws {
        try file("first", bytes: 1000)
        try file("second", bytes: 1000)
        let early = DiskUsageCancellation(); early.cancel()
        XCTAssertThrowsError(try DiskUsageScanner().scan(root, cancellation: early)) { XCTAssertTrue($0 is CancellationError) }
        let token = DiskUsageCancellation()
        XCTAssertThrowsError(try DiskUsageScanner().scan(root, cancellation: token) { _ in token.cancel() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testOverflowSaturatesAndCategoriesAreNameBased() {
        XCTAssertEqual(DiskUsageScanner.adding(Int64.max - 2, 10), Int64.max)
        XCTAssertEqual(DiskUsageCategory.classify(URL(fileURLWithPath: "/a/node_modules/lib/data")), .developer)
        XCTAssertEqual(DiskUsageCategory.classify(URL(fileURLWithPath: "/a/Test.app/Contents/image.png")), .applications)
    }

    @MainActor
    func testRapidNavigationRejectsStaleScanDelivery() async throws {
        try file("first/a", bytes: 3000)
        try file("second/b", bytes: 12000)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let model = StorageDashboardModel(scope: first)
        let finished = expectation(description: "Newest scope completes")
        var observation: AnyCancellable?
        observation = model.$phase.sink { value in
            if value == .finished && model.snapshot?.root == second { finished.fulfill() }
        }
        model.startScan()
        model.select(second)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(model.snapshot?.root, second)
        XCTAssertEqual(model.snapshot?.logicalBytes, 12000)
        XCTAssertEqual(model.scope, second)
        observation?.cancel()
        model.stop()
    }

    @MainActor
    func testFailedRescanInvalidatesParentCacheBeforeBack() async throws {
        try file("child/a", bytes: 3000)
        let model = StorageDashboardModel(scope: root)
        func finish(_ action: () -> Void) async {
            let done = expectation(description: "Scan completes")
            let observation = model.$phase.dropFirst().sink { if $0 == .finished { done.fulfill() } }
            action()
            await fulfillment(of: [done], timeout: 5)
            observation.cancel()
        }
        await finish { model.startScan() }
        let child = try XCTUnwrap(model.snapshot?.entries.first { $0.name == "child" })
        await finish { model.enter(child) }
        try FileManager.default.removeItem(at: child.url)
        let failed = expectation(description: "Rescan fails")
        let observation = model.$phase.sink { if case .failed = $0 { failed.fulfill() } }
        model.startScan()
        await fulfillment(of: [failed], timeout: 5)
        observation.cancel()
        try file("new.txt", bytes: 18000)
        await finish { model.goBack(to: 0) }
        XCTAssertEqual(model.snapshot?.logicalBytes, 18000)
        model.stop()
    }

    @MainActor
    func testSidebarOpensStorageAtItsFolderAndReusesWindow() throws {
        let browser = BrowserWindowController(initialURL: root)
        let delegate = AppDelegate()
        defer { delegate.storageWindowController?.close(); browser.close() }
        let split = try XCTUnwrap(browser.contentViewController as? MainSplitViewController)
        let originalURL = browser.currentURL
        delegate.showStorage(split.sidebarVC)
        let storage = try XCTUnwrap(delegate.storageWindowController)
        XCTAssertEqual(storage.model.scope, originalURL)
        delegate.showStorage(split.sidebarVC)
        XCTAssertTrue(storage === delegate.storageWindowController)
        XCTAssertEqual(browser.currentURL, originalURL)
    }

    @MainActor
    func testStorageWindowIsSeparateAndClosingCancelsScan() throws {
        let controller = StorageWindowController(scope: root) { _ in }
        defer { controller.close() }
        XCTAssertEqual(controller.window?.tabbingMode, .disallowed)
        XCTAssertEqual(controller.model.phase, .ready)
        XCTAssertNotNil(controller.window?.contentViewController)
        controller.model.startScan()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(controller.model.phase, .stopped)
        XCTAssertFalse(controller.model.isScanning)
    }
}
