import AppKit

enum ViewMode: Int, CaseIterable {
    case list = 0
    case columns = 1
    case icons = 2
    case gallery = 3
}

protocol FileViewControllerProtocol: AnyObject {
    var delegate: FileListViewControllerDelegate? { get set }
    var currentURL: URL { get }
    var showHiddenFiles: Bool { get set }
    var selectedItems: [FileItem] { get }
    func loadDirectory(_ url: URL)
    func toggleHiddenFiles()
}
