import AppKit
import QuickLookThumbnailing

final class GalleryViewController: NSViewController, FileViewControllerProtocol,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {

    weak var delegate: FileListViewControllerDelegate?

    private let previewImageView = NSImageView()
    private let previewContainer = NSView()
    private let filmstripScrollView = NSScrollView()
    private let filmstripCollectionView = NSCollectionView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Empty Folder")

    private var items: [FileItem] = []
    private(set) var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var showHiddenFiles: Bool = false

    private var watcher: DirectoryWatcher?
    private var reloadWorkItem: DispatchWorkItem?
    private var loadGeneration: UInt = 0
    private var currentPreviewIndex: Int = -1

    private var sortKey: String = "name"
    private var sortAscending: Bool = true

    private static let filmstripItemIdentifier = NSUserInterfaceItemIdentifier("FilmstripItem")

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupPreviewArea()
        setupFilmstrip()
        setupStatusBar()
        setupEmptyLabel()
        loadDirectory(currentURL)
    }

    private func setupPreviewArea() {
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(previewContainer)

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)

        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 16),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -16),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 16),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -16),
        ])
    }

    private func setupFilmstrip() {
        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = NSSize(width: 60, height: 60)
        flowLayout.minimumInteritemSpacing = 4
        flowLayout.minimumLineSpacing = 4
        flowLayout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        filmstripCollectionView.collectionViewLayout = flowLayout
        filmstripCollectionView.dataSource = self
        filmstripCollectionView.delegate = self
        filmstripCollectionView.isSelectable = true
        filmstripCollectionView.allowsMultipleSelection = false
        filmstripCollectionView.allowsEmptySelection = true
        filmstripCollectionView.backgroundColors = [.controlBackgroundColor]

        filmstripCollectionView.register(FilmstripItem.self, forItemWithIdentifier: Self.filmstripItemIdentifier)

        filmstripScrollView.documentView = filmstripCollectionView
        filmstripScrollView.hasHorizontalScroller = true
        filmstripScrollView.hasVerticalScroller = false
        filmstripScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filmstripScrollView)

        let filmstripSeparator = NSBox()
        filmstripSeparator.boxType = .separator
        filmstripSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filmstripSeparator)

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: filmstripSeparator.topAnchor),

            filmstripSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstripSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstripSeparator.bottomAnchor.constraint(equalTo: filmstripScrollView.topAnchor),

            filmstripScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstripScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstripScrollView.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    private func setupStatusBar() {
        GroveUI.configureFooterStatusLabel(statusBar)
        view.addSubview(statusBar)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            filmstripScrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.font = .systemFont(ofSize: GroveUI.emptyFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        ])
    }

    func loadDirectory(_ url: URL) {
        reloadWorkItem?.cancel()
        currentURL = url
        clearLoadedItemsForPendingLoad(message: "Loading folder contents...")

        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] _ in
            self?.scheduleReload()
        }

        reloadContents(preserveSelection: false)
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadContents()
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reloadContents(preserveSelection: Bool = true) {
        loadGeneration += 1
        let generation = loadGeneration
        let requestURL = currentURL.standardizedFileURL
        let requestShowHiddenFiles = showHiddenFiles
        let selectedURL = preserveSelection ? selectedItems.first?.url : nil

        FileOperationService.shared.contentsOfDirectoryAsync(at: requestURL, showHidden: requestShowHiddenFiles) { [weak self] result in
            guard let self = self,
                  self.loadGeneration == generation,
                  self.currentURL.standardizedFileURL == requestURL,
                  self.showHiddenFiles == requestShowHiddenFiles else { return }

            switch result {
            case .success(let loadedItems):
                self.items = FileItem.sorted(loadedItems, key: self.sortKey, ascending: self.sortAscending)
                self.filmstripCollectionView.reloadData()
                self.updateStatusBar()
                self.emptyLabel.stringValue = "This folder is empty"
                self.emptyLabel.isHidden = !self.items.isEmpty

                if !self.items.isEmpty {
                    let selectedIndex = selectedURL.flatMap { url in
                        self.items.firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL }
                    } ?? 0
                    let indexPath = IndexPath(item: selectedIndex, section: 0)
                    self.filmstripCollectionView.selectionIndexPaths = [indexPath]
                    self.selectPreviewItem(at: selectedIndex)
                } else {
                    self.previewImageView.image = nil
                    self.currentPreviewIndex = -1
                }
            case .failure:
                self.items = []
                self.filmstripCollectionView.reloadData()
                self.updateStatusBar()
                self.previewImageView.image = nil
                self.currentPreviewIndex = -1
                self.emptyLabel.stringValue = "Unable to load folder contents."
                self.emptyLabel.isHidden = false
            }
        }
    }

    private func clearLoadedItemsForPendingLoad(message: String) {
        items = []
        currentPreviewIndex = -1
        previewImageView.image = nil
        filmstripCollectionView.selectionIndexPaths = []
        filmstripCollectionView.reloadData()
        updateStatusBar()
        delegate?.fileListDidSelect(items: [])
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    private func sortItems() {
        FileItem.sort(&items, key: sortKey, ascending: sortAscending)
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        reloadContents()
    }

    var selectedItems: [FileItem] {
        guard currentPreviewIndex >= 0, currentPreviewIndex < items.count else { return [] }
        return [items[currentPreviewIndex]]
    }

    private func selectItem(at url: URL) {
        guard let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        filmstripCollectionView.selectionIndexPaths = [indexPath]
        filmstripCollectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
        selectPreviewItem(at: index)
    }

    private func selectPreviewItem(at index: Int) {
        guard index >= 0, index < items.count else { return }
        currentPreviewIndex = index
        let item = items[index]
        let itemURL = item.url

        delegate?.fileListDidSelect(items: [item])

        // Generate thumbnail using QLThumbnailGenerator
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 512, height: 512),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      self.currentPreviewIndex == index,
                      index < self.items.count,
                      self.items[index].url.standardizedFileURL == itemURL.standardizedFileURL else { return }
                if let rep = representation {
                    self.previewImageView.image = rep.nsImage
                } else {
                    // Fall back to file icon
                    let icon = NSWorkspace.shared.icon(forFile: item.url.path)
                    icon.size = NSSize(width: 128, height: 128)
                    self.previewImageView.image = icon
                }
            }
        }

        updateStatusBar()
    }

    private func updateStatusBar() {
        let count = items.count
        let selectedCount = currentPreviewIndex >= 0 ? 1 : 0
        let diskSpace = FileOperationService.shared.availableDiskSpace(at: currentURL)
        statusBar.stringValue = LocalFooterStatusFormatter.string(
            totalItemCount: count,
            selectedItemCount: selectedCount,
            availableDiskSpace: diskSpace
        )
    }

    private func renameSelectedFile() {
        guard let item = selectedItems.first else { return }
        FileRenameHelper.presentRenameSheet(for: item, from: self) { [weak self] newURL in
            self?.reloadContents()
            self?.selectItem(at: newURL)
        }
    }

    // MARK: - Keyboard navigation

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.control) {
            renameSelectedFile()
            return
        }

        switch event.keyCode {
        case 123: // Left arrow
            if currentPreviewIndex > 0 {
                let newIndex = currentPreviewIndex - 1
                let indexPath = IndexPath(item: newIndex, section: 0)
                filmstripCollectionView.selectionIndexPaths = [indexPath]
                filmstripCollectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
                selectPreviewItem(at: newIndex)
            }
        case 124: // Right arrow
            if currentPreviewIndex < items.count - 1 {
                let newIndex = currentPreviewIndex + 1
                let indexPath = IndexPath(item: newIndex, section: 0)
                filmstripCollectionView.selectionIndexPaths = [indexPath]
                filmstripCollectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
                selectPreviewItem(at: newIndex)
            }
        case 36: // Enter — open file
            if currentPreviewIndex >= 0, currentPreviewIndex < items.count {
                let item = items[currentPreviewIndex]
                if item.isDirectory && !item.isPackage {
                    delegate?.fileListDidNavigate(to: item.url.resolvingSymlinksInPath())
                } else {
                    FileOperationService.shared.openFile(item.url)
                }
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.filmstripItemIdentifier, for: indexPath)
        guard let filmstripItem = item as? FilmstripItem, indexPath.item < items.count else { return item }

        let fileItem = items[indexPath.item]
        filmstripItem.configure(with: fileItem)
        return filmstripItem
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        selectPreviewItem(at: indexPath.item)
    }
}

// MARK: - FilmstripItem

final class FilmstripItem: NSCollectionViewItem {

    private let thumbnailImageView = NSImageView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true

        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.imageAlignment = .alignCenter
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailImageView)

        NSLayoutConstraint.activate([
            thumbnailImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            thumbnailImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            thumbnailImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            thumbnailImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    func configure(with fileItem: FileItem) {
        thumbnailImageView.image = ThumbnailCache.shared.icon(
            for: fileItem.url,
            size: NSSize(width: 48, height: 48)
        )
    }

    override var isSelected: Bool {
        didSet {
            if isSelected {
                view.layer?.borderColor = NSColor.controlAccentColor.cgColor
                view.layer?.borderWidth = 2
                view.layer?.cornerRadius = 4
            } else {
                view.layer?.borderWidth = 0
            }
        }
    }
}
