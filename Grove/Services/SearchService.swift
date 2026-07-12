import Foundation
import AppKit

final class SearchService {

    static let shared = SearchService()

    private var metadataQuery: NSMetadataQuery?
    private var completion: (([FileItem], Bool) -> Void)?
    private var searchGeneration: UInt = 0

    private let maxResults = 2000

    private init() {}

    func search(query: String, in directory: URL, completion: @escaping ([FileItem], Bool) -> Void) {
        stop()
        searchGeneration += 1

        self.completion = completion

        let mdQuery = NSMetadataQuery()
        mdQuery.searchScopes = [directory]

        // Search by filename and content
        let filenamePredicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", query)
        let contentPredicate = NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", query)
        mdQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [filenamePredicate, contentPredicate])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: mdQuery
        )

        self.metadataQuery = mdQuery
        mdQuery.start()
    }

    func stop() {
        searchGeneration += 1
        if let query = metadataQuery {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        metadataQuery = nil
        completion = nil
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        let generation = searchGeneration

        // Stop the query before processing so results can't keep accumulating
        // while the current batch is materialized.
        query.disableUpdates()
        query.stop()

        // Snapshot result paths on the query's thread (cheap), capping the count.
        // NSMetadataItem access must happen here, not off-thread.
        let totalCount = query.resultCount
        let cap = min(totalCount, maxResults)
        var urls: [URL] = []
        urls.reserveCapacity(cap)
        for i in 0..<cap {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: kMDItemPath as String) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        let moreAvailable = totalCount > cap
        query.enableUpdates()

        // Materialize FileItems (stat/UTType/xattr syscalls) off the main thread.
        let handler = completion
        DispatchQueue.global(qos: .userInitiated).async {
            let results = urls.compactMap { FileItem.load(from: $0, includeTags: false) }
            DispatchQueue.main.async {
                guard self.searchGeneration == generation else { return }
                handler?(results, moreAvailable)
                self.stop()
            }
        }
    }
}
