import Foundation
import AppKit

struct SearchBatch: Equatable {
    let range: Range<Int>
    let moreAvailable: Bool
    var isFinal: Bool
}

struct SearchBatchPlanner {
    let maximumResultCount: Int
    let batchSize: Int

    private(set) var nextResultIndex = 0
    private var lastPlannedMoreAvailable: Bool?
    private var didFinish = false

    init(maximumResultCount: Int = 2_000, batchSize: Int = 100) {
        precondition(maximumResultCount > 0)
        precondition(batchSize > 0)
        self.maximumResultCount = maximumResultCount
        self.batchSize = batchSize
    }

    mutating func makeBatches(resultCount: Int, isFinished: Bool) -> [SearchBatch] {
        guard !didFinish else { return [] }

        let normalizedCount = max(0, resultCount)
        let cappedCount = min(normalizedCount, maximumResultCount)
        let moreAvailable = normalizedCount > maximumResultCount
        var batches: [SearchBatch] = []

        while nextResultIndex < cappedCount {
            let upperBound = min(nextResultIndex + batchSize, cappedCount)
            batches.append(
                SearchBatch(
                    range: nextResultIndex..<upperBound,
                    moreAvailable: moreAvailable,
                    isFinal: false
                )
            )
            nextResultIndex = upperBound
        }

        let moreAvailableChanged = lastPlannedMoreAvailable.map { $0 != moreAvailable } ?? false
        if batches.isEmpty && (isFinished || moreAvailableChanged) {
            // A status-only batch covers an empty result set and the transition
            // from exactly the cap to "more available" without reloading files.
            batches.append(
                SearchBatch(
                    range: nextResultIndex..<nextResultIndex,
                    moreAvailable: moreAvailable,
                    isFinal: isFinished
                )
            )
        } else if isFinished {
            batches[batches.count - 1].isFinal = true
        }

        if !batches.isEmpty {
            lastPlannedMoreAvailable = moreAvailable
        }
        if isFinished {
            didFinish = true
        }
        return batches
    }
}

struct SearchSessionState {
    private var generation: UInt = 0
    private(set) var activeGeneration: UInt?

    mutating func start() -> UInt {
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    mutating func stop() {
        generation &+= 1
        activeGeneration = nil
    }

    func allowsDelivery(for generation: UInt) -> Bool {
        activeGeneration == generation
    }

    @discardableResult
    mutating func finish(generation: UInt) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }
}

private final class SearchCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

protocol SearchMetadataQuery: AnyObject {
    var notificationObject: AnyObject { get }
    var resultCount: Int { get }

    func resultPath(at index: Int) -> String?
    func start() -> Bool
    func stop()
    func disableUpdates()
    func enableUpdates()
}

protocol SearchWorkScheduling: AnyObject {
    func schedule(_ work: @escaping () -> Void)
}

private final class SpotlightMetadataQuery: SearchMetadataQuery {
    private let query = NSMetadataQuery()

    init(searchText: String, directory: URL) {
        query.searchScopes = [directory]
        let filenamePredicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", searchText)
        let contentPredicate = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", searchText)
        query.predicate = NSCompoundPredicate(
            orPredicateWithSubpredicates: [filenamePredicate, contentPredicate]
        )
    }

    var notificationObject: AnyObject { query }
    var resultCount: Int { query.resultCount }

    func resultPath(at index: Int) -> String? {
        guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
        return item.value(forAttribute: kMDItemPath as String) as? String
    }

    func start() -> Bool { query.start() }
    func stop() { query.stop() }
    func disableUpdates() { query.disableUpdates() }
    func enableUpdates() { query.enableUpdates() }
}

private final class DispatchSearchWorkScheduler: SearchWorkScheduling {
    private let queue = DispatchQueue(
        label: "at.goosefraba.Grove.spotlight-results",
        qos: .userInitiated
    )

    func schedule(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}

private struct PendingSearchDelivery {
    let items: [FileItem]
    let batch: SearchBatch
}

@MainActor
final class SearchService {

    static let shared = SearchService()

    private var metadataQuery: SearchMetadataQuery?
    private var observerTokens: [NSObjectProtocol] = []
    private var completion: (([FileItem], Bool) -> Void)?
    private var sessionState = SearchSessionState()
    private var batchPlanner = SearchBatchPlanner()
    private var cancellationToken: SearchCancellationToken?
    private var accumulatedResults: [FileItem] = []
    private var accumulatedResultURLs: Set<URL> = []
    private var nextScheduledDeliverySequence = 0
    private var nextExpectedDeliverySequence = 0
    private var pendingDeliveries: [Int: PendingSearchDelivery] = [:]

    private let notificationCenter: NotificationCenter
    private let queryFactory: (String, URL) -> SearchMetadataQuery
    private let itemLoader: (URL) -> FileItem?
    private let workScheduler: SearchWorkScheduling

    private convenience init() {
        self.init(
            notificationCenter: .default,
            queryFactory: { SpotlightMetadataQuery(searchText: $0, directory: $1) },
            itemLoader: { FileItem.load(from: $0, includeTags: false) },
            workScheduler: DispatchSearchWorkScheduler()
        )
    }

    init(
        notificationCenter: NotificationCenter,
        queryFactory: @escaping (String, URL) -> SearchMetadataQuery,
        itemLoader: @escaping (URL) -> FileItem?,
        workScheduler: SearchWorkScheduling
    ) {
        self.notificationCenter = notificationCenter
        self.queryFactory = queryFactory
        self.itemLoader = itemLoader
        self.workScheduler = workScheduler
    }

    var activeObserverCount: Int { observerTokens.count }
    var pendingDeliveryCount: Int { pendingDeliveries.count }

    /// Delivers cumulative result snapshots in batches while Spotlight gathers.
    /// File metadata is materialized by `workScheduler`; callbacks run on main.
    func search(query: String, in directory: URL, completion: @escaping ([FileItem], Bool) -> Void) {
        stop()

        let generation = sessionState.start()
        let cancellationToken = SearchCancellationToken()
        self.cancellationToken = cancellationToken
        self.completion = completion
        batchPlanner = SearchBatchPlanner()
        accumulatedResults = []
        accumulatedResultURLs = []
        nextScheduledDeliverySequence = 0
        nextExpectedDeliverySequence = 0
        pendingDeliveries = [:]

        let mdQuery = queryFactory(query, directory)

        observerTokens = [
            notificationCenter.addObserver(
                forName: .NSMetadataQueryGatheringProgress,
                object: mdQuery.notificationObject,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.consumeResults(generation: generation, isFinished: false)
                }
            },
            notificationCenter.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: mdQuery.notificationObject,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.consumeResults(generation: generation, isFinished: true)
                }
            },
        ]

        metadataQuery = mdQuery
        guard mdQuery.start() else {
            removeObservers()
            metadataQuery = nil
            enqueue(batches: batchPlanner.makeBatches(resultCount: 0, isFinished: true),
                    urlsByBatch: [[]],
                    generation: generation,
                    cancellationToken: cancellationToken)
            return
        }
    }

    func stop() {
        cancellationToken?.cancel()
        cancellationToken = nil
        sessionState.stop()

        if let query = metadataQuery {
            query.stop()
        }
        metadataQuery = nil
        removeObservers()
        completion = nil
        accumulatedResults = []
        accumulatedResultURLs = []
        nextScheduledDeliverySequence = 0
        nextExpectedDeliverySequence = 0
        pendingDeliveries = [:]
    }

    private func consumeResults(generation: UInt, isFinished: Bool) {
        guard let query = metadataQuery, sessionState.allowsDelivery(for: generation) else { return }

        query.disableUpdates()
        let batches = batchPlanner.makeBatches(resultCount: query.resultCount, isFinished: isFinished)
        let urlsByBatch = batches.map { batch in
            batch.range.compactMap { index -> URL? in
                guard let path = query.resultPath(at: index) else { return nil }
                return URL(fileURLWithPath: path)
            }
        }

        query.enableUpdates()
        if isFinished {
            query.stop()
            metadataQuery = nil
            removeObservers()
        }

        guard let cancellationToken else { return }
        enqueue(
            batches: batches,
            urlsByBatch: urlsByBatch,
            generation: generation,
            cancellationToken: cancellationToken
        )
    }

    private func enqueue(
        batches: [SearchBatch],
        urlsByBatch: [[URL]],
        generation: UInt,
        cancellationToken: SearchCancellationToken
    ) {
        for (batch, urls) in zip(batches, urlsByBatch) {
            let itemLoader = self.itemLoader
            let deliverySequence = nextScheduledDeliverySequence
            nextScheduledDeliverySequence += 1
            workScheduler.schedule {
                guard !cancellationToken.isCancelled else { return }

                var materialized: [FileItem] = []
                materialized.reserveCapacity(urls.count)
                for url in urls {
                    guard !cancellationToken.isCancelled else { return }
                    if let item = itemLoader(url) {
                        materialized.append(item)
                    }
                }

                guard !cancellationToken.isCancelled else { return }
                Task { @MainActor [weak self] in
                    self?.receive(
                        materialized,
                        for: batch,
                        deliverySequence: deliverySequence,
                        generation: generation,
                        cancellationToken: cancellationToken
                    )
                }
            }
        }
    }

    private func receive(
        _ materialized: [FileItem],
        for batch: SearchBatch,
        deliverySequence: Int,
        generation: UInt,
        cancellationToken: SearchCancellationToken
    ) {
        guard sessionState.allowsDelivery(for: generation),
              self.cancellationToken === cancellationToken else {
            return
        }

        pendingDeliveries[deliverySequence] = PendingSearchDelivery(items: materialized, batch: batch)
        while let pending = pendingDeliveries.removeValue(forKey: nextExpectedDeliverySequence) {
            nextExpectedDeliverySequence += 1
            deliver(pending.items, for: pending.batch, generation: generation)
        }
    }

    private func deliver(_ materialized: [FileItem], for batch: SearchBatch, generation: UInt) {
        guard sessionState.allowsDelivery(for: generation) else { return }

        for item in materialized where accumulatedResultURLs.insert(item.url).inserted {
            accumulatedResults.append(item)
        }

        let handler = completion
        if batch.isFinal {
            _ = sessionState.finish(generation: generation)
            completion = nil
            self.cancellationToken = nil
            pendingDeliveries.removeAll()
        }
        handler?(accumulatedResults, batch.moreAvailable)
    }

    private func removeObservers() {
        observerTokens.forEach(notificationCenter.removeObserver)
        observerTokens.removeAll()
    }
}
