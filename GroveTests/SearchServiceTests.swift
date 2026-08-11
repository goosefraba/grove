import XCTest
@testable import Grove

final class SearchServiceTests: XCTestCase {
    @MainActor
    func testServiceStreamsProgressBeforeFinishInCumulativeOrder() async {
        let center = NotificationCenter()
        let query = FakeSearchMetadataQuery()
        let scheduler = ManualSearchWorkScheduler()
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let progressCallback = expectation(description: "progress callback")
        let finalCallback = expectation(description: "final callback")
        var deliveries: [[URL]] = []

        let service = SearchService(
            notificationCenter: center,
            queryFactory: { _, _ in query },
            itemLoader: makeSearchTestFileItem,
            workScheduler: scheduler
        )
        defer { service.stop() }

        service.search(query: "txt", in: URL(fileURLWithPath: "/tmp")) { items, _ in
            XCTAssertTrue(Thread.isMainThread)
            deliveries.append(items.map(\.url))
            if deliveries.count == 1 {
                progressCallback.fulfill()
            } else if deliveries.count == 2 {
                finalCallback.fulfill()
            }
        }

        XCTAssertEqual(service.activeObserverCount, 2)
        query.paths = [firstURL.path]
        query.postProgress(to: center)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.runNext()
        await fulfillment(of: [progressCallback], timeout: 1)

        XCTAssertEqual(deliveries, [[firstURL]])
        XCTAssertEqual(service.activeObserverCount, 2)

        query.paths = [firstURL.path, secondURL.path]
        query.postFinish(to: center)
        XCTAssertEqual(service.activeObserverCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.runNext()
        await fulfillment(of: [finalCallback], timeout: 1)

        XCTAssertEqual(deliveries, [[firstURL], [firstURL, secondURL]])
        XCTAssertEqual(query.disableUpdatesCallCount, 2)
        XCTAssertEqual(query.enableUpdatesCallCount, 2)
        XCTAssertEqual(query.stopCallCount, 1)
        XCTAssertTrue(query.lifecycleMainThreadSamples.allSatisfy { $0 })
    }

    @MainActor
    func testServiceBuffersOutOfOrderFinalWorkUntilProgressCanDeliverFirst() async {
        let center = NotificationCenter()
        let query = FakeSearchMetadataQuery()
        let scheduler = ManualSearchWorkScheduler()
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let callbacksCalled = expectation(description: "ordered callbacks")
        callbacksCalled.expectedFulfillmentCount = 2
        callbacksCalled.assertForOverFulfill = true
        var deliveries: [[URL]] = []

        let service = SearchService(
            notificationCenter: center,
            queryFactory: { _, _ in query },
            itemLoader: makeSearchTestFileItem,
            workScheduler: scheduler
        )
        defer { service.stop() }

        service.search(query: "txt", in: URL(fileURLWithPath: "/tmp")) { items, _ in
            deliveries.append(items.map(\.url))
            callbacksCalled.fulfill()
        }

        query.paths = [firstURL.path]
        query.postProgress(to: center)
        query.paths = [firstURL.path, secondURL.path]
        query.postFinish(to: center)
        XCTAssertEqual(scheduler.pendingCount, 2)

        // Complete final materialization first. It must remain buffered behind
        // the earlier progress sequence instead of ending the session.
        scheduler.runLast()
        for _ in 0..<10 where service.pendingDeliveryCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(service.pendingDeliveryCount, 1)
        XCTAssertTrue(deliveries.isEmpty)

        scheduler.runNext()
        await fulfillment(of: [callbacksCalled], timeout: 1)

        XCTAssertEqual(deliveries, [[firstURL], [firstURL, secondURL]])
        XCTAssertEqual(service.pendingDeliveryCount, 0)
    }

    @MainActor
    func testServiceLoadsFilesOffMainAndDeliversCallbacksOnMain() async {
        let center = NotificationCenter()
        let query = FakeSearchMetadataQuery(paths: ["/tmp/background.txt"])
        let scheduler = BackgroundSearchWorkScheduler()
        let loaderThreadSamples = LockedThreadSamples()
        let loaderCalled = expectation(description: "loader called")
        let callbackCalled = expectation(description: "callback called")

        let service = SearchService(
            notificationCenter: center,
            queryFactory: { _, _ in query },
            itemLoader: { url in
                loaderThreadSamples.append(Thread.isMainThread)
                loaderCalled.fulfill()
                return makeSearchTestFileItem(url)
            },
            workScheduler: scheduler
        )
        defer { service.stop() }

        service.search(query: "background", in: URL(fileURLWithPath: "/tmp")) { items, _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(items.map(\.url), [URL(fileURLWithPath: "/tmp/background.txt")])
            callbackCalled.fulfill()
        }
        query.postFinish(to: center)

        await fulfillment(of: [loaderCalled, callbackCalled], timeout: 2)
        XCTAssertEqual(loaderThreadSamples.values, [false])
        XCTAssertEqual(service.activeObserverCount, 0)
    }

    @MainActor
    func testServiceReplacementAndStopSuppressQueuedLoadingAndCallbacks() {
        let center = NotificationCenter()
        let firstQuery = FakeSearchMetadataQuery(paths: ["/tmp/old.txt"])
        let secondQuery = FakeSearchMetadataQuery(paths: ["/tmp/new.txt"])
        let scheduler = ManualSearchWorkScheduler()
        var queries: [FakeSearchMetadataQuery] = [firstQuery, secondQuery]
        var loadedURLs: [URL] = []
        var callbacks: [String] = []

        let service = SearchService(
            notificationCenter: center,
            queryFactory: { _, _ in queries.removeFirst() },
            itemLoader: { url in
                loadedURLs.append(url)
                return makeSearchTestFileItem(url)
            },
            workScheduler: scheduler
        )

        service.search(query: "old", in: URL(fileURLWithPath: "/tmp")) { _, _ in callbacks.append("old") }
        firstQuery.postProgress(to: center)
        XCTAssertEqual(scheduler.pendingCount, 1)

        service.search(query: "new", in: URL(fileURLWithPath: "/tmp")) { _, _ in callbacks.append("new") }
        XCTAssertEqual(firstQuery.stopCallCount, 1)
        scheduler.runNext()
        XCTAssertTrue(loadedURLs.isEmpty)
        XCTAssertTrue(callbacks.isEmpty)

        secondQuery.postProgress(to: center)
        XCTAssertEqual(scheduler.pendingCount, 1)
        service.stop()
        XCTAssertEqual(service.activeObserverCount, 0)
        XCTAssertEqual(secondQuery.stopCallCount, 1)
        scheduler.runNext()

        XCTAssertTrue(loadedURLs.isEmpty)
        XCTAssertTrue(callbacks.isEmpty)
    }

    @MainActor
    func testServiceStopRemovesObserversAndIgnoresLaterNotifications() {
        let center = NotificationCenter()
        let query = FakeSearchMetadataQuery(paths: ["/tmp/ignored.txt"])
        let scheduler = ManualSearchWorkScheduler()
        var callbackCount = 0
        let service = SearchService(
            notificationCenter: center,
            queryFactory: { _, _ in query },
            itemLoader: makeSearchTestFileItem,
            workScheduler: scheduler
        )

        service.search(query: "ignored", in: URL(fileURLWithPath: "/tmp")) { _, _ in callbackCount += 1 }
        XCTAssertEqual(service.activeObserverCount, 2)
        service.stop()
        XCTAssertEqual(service.activeObserverCount, 0)

        query.postProgress(to: center)
        query.postFinish(to: center)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(callbackCount, 0)
    }

    @MainActor
    func testServiceFailedStartRemovesObserversAndDeliversEmptyFinalSnapshot() async {
        let center = NotificationCenter()
        let query = FakeSearchMetadataQuery(startResult: false)
        let scheduler = ManualSearchWorkScheduler()
        let callbackCalled = expectation(description: "failed start callback")
        var callbackValues: [([FileItem], Bool)] = []
        let service = SearchService(
            notificationCenter: center,
            queryFactory: { _, _ in query },
            itemLoader: makeSearchTestFileItem,
            workScheduler: scheduler
        )
        defer { service.stop() }

        service.search(query: "unavailable", in: URL(fileURLWithPath: "/tmp")) { items, moreAvailable in
            XCTAssertTrue(Thread.isMainThread)
            callbackValues.append((items, moreAvailable))
            callbackCalled.fulfill()
        }

        XCTAssertEqual(query.startCallCount, 1)
        XCTAssertEqual(service.activeObserverCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.runNext()
        await fulfillment(of: [callbackCalled], timeout: 1)

        XCTAssertEqual(callbackValues.count, 1)
        XCTAssertTrue(callbackValues[0].0.isEmpty)
        XCTAssertFalse(callbackValues[0].1)

        query.postProgress(to: center)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testPlannerStreamsOnlyNewResultsInBoundedBatches() {
        var planner = SearchBatchPlanner(maximumResultCount: 2_000, batchSize: 100)

        let firstProgress = planner.makeBatches(resultCount: 150, isFinished: false)
        XCTAssertEqual(firstProgress.map(\.range), [0..<100, 100..<150])
        XCTAssertTrue(firstProgress.allSatisfy { !$0.isFinal })

        XCTAssertTrue(planner.makeBatches(resultCount: 150, isFinished: false).isEmpty)

        let secondProgress = planner.makeBatches(resultCount: 260, isFinished: false)
        XCTAssertEqual(secondProgress.map(\.range), [150..<250, 250..<260])
        XCTAssertTrue(secondProgress.allSatisfy { $0.range.count <= 100 })
    }

    func testPlannerMarksFinishAfterEarlierProgressWithStatusOnlyBatch() {
        var planner = SearchBatchPlanner(maximumResultCount: 2_000, batchSize: 100)

        let progress = planner.makeBatches(resultCount: 12, isFinished: false)
        XCTAssertEqual(progress, [SearchBatch(range: 0..<12, moreAvailable: false, isFinal: false)])

        let finish = planner.makeBatches(resultCount: 12, isFinished: true)
        XCTAssertEqual(finish, [SearchBatch(range: 12..<12, moreAvailable: false, isFinal: true)])
        XCTAssertTrue(planner.makeBatches(resultCount: 20, isFinished: true).isEmpty)
    }

    func testPlannerCapsResultsAtTwoThousandAndUsesProductionBatchSize() {
        var planner = SearchBatchPlanner()

        let batches = planner.makeBatches(resultCount: 2_501, isFinished: true)

        XCTAssertEqual(batches.count, 20)
        XCTAssertEqual(batches.first?.range, 0..<100)
        XCTAssertEqual(batches.last?.range, 1_900..<2_000)
        XCTAssertTrue(batches.allSatisfy { $0.range.count == 100 })
        XCTAssertTrue(batches.allSatisfy(\.moreAvailable))
        XCTAssertEqual(batches.filter(\.isFinal).count, 1)
        XCTAssertTrue(batches.last?.isFinal == true)
    }

    func testPlannerReportsMoreAvailableWhenCountCrossesCapWithoutNewResults() {
        var planner = SearchBatchPlanner(maximumResultCount: 5, batchSize: 2)

        let atCap = planner.makeBatches(resultCount: 5, isFinished: false)
        XCTAssertEqual(atCap.map(\.range), [0..<2, 2..<4, 4..<5])
        XCTAssertTrue(atCap.allSatisfy { !$0.moreAvailable })

        let beyondCap = planner.makeBatches(resultCount: 6, isFinished: false)
        XCTAssertEqual(beyondCap, [SearchBatch(range: 5..<5, moreAvailable: true, isFinal: false)])

        let finish = planner.makeBatches(resultCount: 7, isFinished: true)
        XCTAssertEqual(finish, [SearchBatch(range: 5..<5, moreAvailable: true, isFinal: true)])
    }

    func testPlannerFinishesAnEmptySearch() {
        var planner = SearchBatchPlanner()

        XCTAssertTrue(planner.makeBatches(resultCount: 0, isFinished: false).isEmpty)
        XCTAssertEqual(
            planner.makeBatches(resultCount: 0, isFinished: true),
            [SearchBatch(range: 0..<0, moreAvailable: false, isFinal: true)]
        )
    }

    func testSessionRejectsStoppedAndStaleGenerations() {
        var state = SearchSessionState()
        let first = state.start()
        XCTAssertTrue(state.allowsDelivery(for: first))

        state.stop()
        XCTAssertFalse(state.allowsDelivery(for: first))

        let second = state.start()
        XCTAssertFalse(state.allowsDelivery(for: first))
        XCTAssertTrue(state.allowsDelivery(for: second))
        XCTAssertFalse(state.finish(generation: first))
        XCTAssertTrue(state.finish(generation: second))
        XCTAssertFalse(state.allowsDelivery(for: second))
    }
}

private final class FakeSearchMetadataQuery: NSObject, SearchMetadataQuery {
    var paths: [String]
    let startResult: Bool
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var disableUpdatesCallCount = 0
    private(set) var enableUpdatesCallCount = 0
    private(set) var lifecycleMainThreadSamples: [Bool] = []

    init(paths: [String] = [], startResult: Bool = true) {
        self.paths = paths
        self.startResult = startResult
    }

    var notificationObject: AnyObject { self }
    var resultCount: Int {
        recordLifecycleThread()
        return paths.count
    }

    func resultPath(at index: Int) -> String? {
        recordLifecycleThread()
        return paths.indices.contains(index) ? paths[index] : nil
    }

    func start() -> Bool {
        recordLifecycleThread()
        startCallCount += 1
        return startResult
    }

    func stop() {
        recordLifecycleThread()
        stopCallCount += 1
    }

    func disableUpdates() {
        recordLifecycleThread()
        disableUpdatesCallCount += 1
    }

    func enableUpdates() {
        recordLifecycleThread()
        enableUpdatesCallCount += 1
    }

    private func recordLifecycleThread() {
        lifecycleMainThreadSamples.append(Thread.isMainThread)
    }

    func postProgress(to center: NotificationCenter) {
        center.post(name: .NSMetadataQueryGatheringProgress, object: self)
    }

    func postFinish(to center: NotificationCenter) {
        center.post(name: .NSMetadataQueryDidFinishGathering, object: self)
    }
}

private final class ManualSearchWorkScheduler: SearchWorkScheduling {
    private var pending: [() -> Void] = []

    var pendingCount: Int { pending.count }

    func schedule(_ work: @escaping () -> Void) {
        pending.append(work)
    }

    func runNext() {
        precondition(!pending.isEmpty)
        pending.removeFirst()()
    }

    func runLast() {
        precondition(!pending.isEmpty)
        pending.removeLast()()
    }
}

private final class BackgroundSearchWorkScheduler: SearchWorkScheduling {
    private let queue = DispatchQueue(label: "SearchServiceTests.background")

    func schedule(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}

private final class LockedThreadSamples {
    private let lock = NSLock()
    private var samples: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func append(_ value: Bool) {
        lock.lock()
        samples.append(value)
        lock.unlock()
    }
}

private func makeSearchTestFileItem(_ url: URL) -> FileItem {
    FileItem(
        id: url,
        url: url,
        name: url.lastPathComponent,
        isDirectory: false,
        isPackage: false,
        isHidden: false,
        size: 0,
        dateModified: .distantPast,
        dateCreated: .distantPast,
        kind: "Document",
        contentType: nil,
        posixPermissions: 0,
        tags: [],
        tagMetadata: []
    )
}
