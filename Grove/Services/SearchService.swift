import Foundation
import AppKit

final class SearchService {

    static let shared = SearchService()

    private var metadataQuery: NSMetadataQuery?
    private var completion: (([FileItem]) -> Void)?

    private init() {}

    func search(query: String, in directory: URL, completion: @escaping ([FileItem]) -> Void) {
        stop()

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
        if let query = metadataQuery {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        metadataQuery = nil
        completion = nil
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()

        var results: [FileItem] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            if let fileItem = FileItem.load(from: url) {
                results.append(fileItem)
            }
        }

        query.enableUpdates()

        let handler = completion
        DispatchQueue.main.async {
            handler?(results)
        }
    }
}
