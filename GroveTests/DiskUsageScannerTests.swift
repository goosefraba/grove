import XCTest
import Combine
import AppKit
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
    func testStorageOpensInReusableTabAndPreservesOriginalBrowser() throws {
        let automatic = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false
        defer { NSWindow.allowsAutomaticWindowTabbing = automatic }
        let browser = BrowserWindowController(initialURL: root)
        browser.showWindow(nil)
        let delegate = AppDelegate()
        let originalURL = browser.currentURL
        let originalSplit = try XCTUnwrap(browser.contentViewController as? MainSplitViewController)
        originalSplit.switchViewMode(.icons)
        originalSplit.setPreviewPaneVisible(true)
        originalSplit.setInspectorCollapsed(false)
        let storage = delegate.openStorageTab(relativeTo: browser)
        defer { storage.close(); browser.close() }
        XCTAssertEqual(storage.storageDashboardModel?.scope, originalURL)
        XCTAssertEqual(storage.window?.tabGroup?.windows.count, 2)
        XCTAssertTrue(storage.window?.tabGroup === browser.window?.tabGroup)
        XCTAssertEqual(storage.window?.tab.title, "Storage")
        XCTAssertTrue(storage === delegate.openStorageTab(relativeTo: browser))
        XCTAssertEqual(storage.window?.tabGroup?.windows.count, 2)
        XCTAssertEqual(browser.currentURL, originalURL)
        XCTAssertEqual(originalSplit.currentViewMode, .icons)
        XCTAssertTrue(originalSplit.isPreviewPaneVisible)
        XCTAssertFalse(originalSplit.inspectorIsCollapsed)
        let split = try XCTUnwrap(storage.contentViewController as? MainSplitViewController)
        XCTAssertFalse(split.fileListVC.isViewLoaded, "Opening Storage must not start an unrelated Home listing or stop another tab's Spotlight search")
        XCTAssertNil(split.activeContentViewController)
        XCTAssertTrue(split.currentCapabilities.isEmpty)
        XCTAssertFalse(split.supportsToolbarSearch)
        XCTAssertFalse(split.isPreviewPaneVisible)
        XCTAssertTrue(split.inspectorIsCollapsed)
        split.toggleInspector(); split.togglePreviewPane(); split.toggleDualPane()
        XCTAssertTrue(split.inspectorIsCollapsed)
        XCTAssertFalse(split.isPreviewPaneVisible)
        XCTAssertFalse(split.isDualPaneVisible)
    }

    @MainActor
    func testDashboardTabClosingCancelsScan() throws {
        let controller = BrowserWindowController(initialLocation: .dashboard(root))
        let model = try XCTUnwrap(controller.storageDashboardModel)
        XCTAssertEqual(controller.window?.tabbingIdentifier, "com.grove.browser")
        XCTAssertEqual(model.phase, .ready)
        model.startScan()
        controller.close()
        XCTAssertEqual(model.phase, .stopped)
    }

    @MainActor
    func testOpenInGroveStaysInTabAndBackRestoresScanThenFolderTrail() async throws {
        try file("child/a", bytes: 9000)
        let controller = BrowserWindowController(initialLocation: .dashboard(root))
        defer { controller.close() }
        let model = try XCTUnwrap(controller.storageDashboardModel)
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
        let scope = model.scope
        model.openInGrove?(scope)
        XCTAssertTrue(controller.currentLocation.isLocal)
        XCTAssertTrue(controller.canGoBack)
        controller.goBack(nil)
        XCTAssertTrue(controller.currentLocation.isDashboard)
        XCTAssertTrue(controller.storageDashboardModel === model)
        XCTAssertEqual(model.scope, scope)
        XCTAssertEqual(model.snapshot?.logicalBytes, 9000)
        controller.goBack(nil)
        XCTAssertEqual(model.scope, root)
        XCTAssertFalse(controller.canGoBack)
        controller.goForward(nil)
        XCTAssertTrue(controller.currentLocation.isLocal)
        XCTAssertEqual(try DiskUsageScanner.canonicalURL(controller.currentURL), scope)
    }

    @MainActor
    func testStorageRoundTripPreservesActiveDualPaneHiddenFiles() throws {
        let controller = BrowserWindowController(initialLocation: .dashboard(root))
        defer { controller.close() }
        let model = try XCTUnwrap(controller.storageDashboardModel)
        model.openInGrove?(root)
        let split = try XCTUnwrap(controller.contentViewController as? MainSplitViewController)
        split.setDualPaneVisible(true)
        split.setShowsHiddenFiles(true)
        XCTAssertTrue(split.showsHiddenFiles)
        controller.goBack(nil)
        XCTAssertTrue(controller.currentLocation.isDashboard)
        controller.goForward(nil)
        XCTAssertTrue(controller.currentLocation.isLocal)
        XCTAssertTrue(split.showsHiddenFiles)
    }

    @MainActor
    func testDashboardLayoutAtCompactAndRegularWindowWidths() async throws {
        try file("Projects/Grove/Sources/StorageDashboard.swift", bytes: 180_000)
        try file("Projects/Grove/Build/app", bytes: 900_000)
        try file("Photos/Autumn in Vienna.jpg", bytes: 600_000)
        try file("Documents/House plans.pdf", bytes: 240_000)
        try file("archive.zip", bytes: 110_000)
        let controller = BrowserWindowController(initialLocation: .dashboard(root))
        defer { controller.close() }
        let model = try XCTUnwrap(controller.storageDashboardModel)
        let done = expectation(description: "Layout fixture scan completes")
        let observation = model.$phase.dropFirst().sink { if $0 == .finished { done.fulfill() } }
        model.startScan()
        await fulfillment(of: [done], timeout: 5)
        observation.cancel()
        let split = try XCTUnwrap(controller.contentViewController as? MainSplitViewController)
        let dashboard = try XCTUnwrap(split.storageDashboardVC)
        let window = try XCTUnwrap(controller.window)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/storage-tabs-verification", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        controller.showWindow(nil)
        for (name, width) in [("compact", 600.0), ("regular", 1200.0)] {
            window.setContentSize(NSSize(width: width, height: name == "compact" ? 2300 : 1400))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            dashboard.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bounds = dashboard.view.bounds
            XCTAssertGreaterThan(bounds.width, 290)
            let bitmap = try XCTUnwrap(dashboard.view.bitmapImageRepForCachingDisplay(in: bounds))
            dashboard.view.cacheDisplay(in: bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("dashboard-\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Storage \(name) layout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testDashboardSessionRestoresInsideOriginalTabGroupWithoutScanning() throws {
        let browser = BrowserWindowController(initialURL: root)
        browser.showWindow(nil)
        let delegate = AppDelegate()
        let storage = delegate.openStorageTab(relativeTo: browser)
        let states = AppDelegate.sessionStates(for: [browser, storage])
        storage.close(); browser.close()
        let restored = AppDelegate.restoreSession(states)
        defer { restored.forEach { $0.close() } }
        XCTAssertEqual(restored.count, 2)
        let dashboard = try XCTUnwrap(restored.first { $0.currentLocation.isDashboard })
        XCTAssertEqual(dashboard.storageDashboardModel?.phase, .ready)
        XCTAssertEqual(dashboard.storageDashboardModel?.scope.path, root.standardizedFileURL.path)
        XCTAssertEqual(dashboard.window?.tabGroup?.windows.count, 2)
        XCTAssertTrue(dashboard.window?.tabGroup?.selectedWindow === dashboard.window)
    }
}
