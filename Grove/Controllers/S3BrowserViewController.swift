import AppKit

private final class S3DropScrollView: NSScrollView {
    var onValidateBackgroundDrop: ((any NSDraggingInfo) -> NSDragOperation)?
    var onAcceptBackgroundDrop: ((any NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onValidateBackgroundDrop?(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onValidateBackgroundDrop?(sender) ?? []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        (onValidateBackgroundDrop?(sender) ?? []).isEmpty == false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onAcceptBackgroundDrop?(sender) ?? false
    }
}

enum S3ContextMenuCommand: Equatable {
    case openPrefix
    case uploadFiles
    case download
    case copyURI
}

struct S3ContextMenuItemDescriptor: Equatable {
    let title: String
    let command: S3ContextMenuCommand?
    let isEnabled: Bool
}

final class S3BrowserViewController: NSViewController, FileViewControllerProtocol, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSComboBoxDelegate, NSSearchFieldDelegate {
    weak var delegate: FileListViewControllerDelegate?

    private let profileStore: AWSProfileStore
    private let service: S3BrowserService

    private let rootStack = NSStackView()
    private let controlsStack = NSStackView()
    private let headerTitleLabel = NSTextField(labelWithString: "Amazon S3")
    private let locationSummaryLabel = NSTextField(labelWithString: "")
    private let profileComboBox = NSComboBox()
    private let regionComboBox = NSComboBox()
    private let bucketField = NSSearchField()
    private let browseButton = NSButton(title: "Open", target: nil, action: nil)
    private let uploadButton = NSButton(title: "Upload...", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download...", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let detailsButton = NSButton(title: "Details", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator()
    private let tableView = NSTableView()
    private let scrollView = S3DropScrollView()
    private let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")

    private var profiles: [AWSProfile] = []
    private var items: [S3Item] = []
    private var allBucketItems: [S3Item] = []
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private let staleLoadGuard = StaleLoadGuard()
    private var lastError: S3BrowserError?
    private var nextContinuationToken: String?
    private var suppressControlActions = false
    private var isLoading = false
    private var bucketListingUnavailable = false

    private(set) var s3Location = S3Location()
    private let nameColumn = NSUserInterfaceItemIdentifier("S3NameColumn")
    private let modifiedColumn = NSUserInterfaceItemIdentifier("S3ModifiedColumn")
    private let sizeColumn = NSUserInterfaceItemIdentifier("S3SizeColumn")
    private let kindColumn = NSUserInterfaceItemIdentifier("S3KindColumn")

    init(profileStore: AWSProfileStore = AWSProfileStore(), service: S3BrowserService = S3BrowserService(gateway: AWSS3Gateway())) {
        self.profileStore = profileStore
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        loadTask?.cancel()
        metadataTask?.cancel()
        transferTask?.cancel()
    }

    var currentURL: URL { FileManager.default.homeDirectoryForCurrentUser }
    var currentLocation: StorageLocation { .s3(s3Location) }
    var showHiddenFiles: Bool {
        get { false }
        set {}
    }
    var selectedItems: [FileItem] { [] }
    var selectedBrowserItems: [BrowserItem] {
        tableView.selectedRowIndexes.compactMap { row in
            row < items.count ? .s3(items[row]) : nil
        }
    }
    var capabilities: StorageCapabilities { .s3Browser }
    var supportsToolbarSearch: Bool { false }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
        GroveUI.prepareSurface(view)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupControls()
        setupTable()
        setupLayout()
        setupAccessibility()
        if reloadProfiles() {
            renderIdleState()
        }
    }

    func loadDirectory(_ url: URL) {}

    func loadLocation(_ location: StorageLocation) {
        guard case .s3(let newLocation) = location else { return }
        s3Location = newLocation
        syncControlsFromLocation()
        if newLocation.bucket?.isEmpty == false {
            loadPrefix(resetItems: true)
        } else {
            loadBuckets()
        }
    }

    func toggleHiddenFiles() {}
    func setShowsHiddenFiles(_ visible: Bool) {}

    func createNewFolder() {
        showInlineError(.permission("S3 browsing is read-only in this version."))
    }

    func setToolbarFilterText(_ text: String) {}
    func performToolbarSearch(_ query: String) {}
    func clearToolbarSearch() {}

    private func setupControls() {
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.distribution = .fill
        rootStack.spacing = 6
        rootStack.detachesHiddenViews = true
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        controlsStack.orientation = .vertical
        controlsStack.spacing = 6
        controlsStack.alignment = .width
        controlsStack.distribution = .fill
        controlsStack.detachesHiddenViews = true
        controlsStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)

        headerTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitleLabel.textColor = .labelColor
        headerTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        locationSummaryLabel.font = .systemFont(ofSize: GroveUI.statusFontSize)
        locationSummaryLabel.textColor = .secondaryLabelColor
        locationSummaryLabel.lineBreakMode = .byTruncatingMiddle

        profileComboBox.completes = true
        profileComboBox.numberOfVisibleItems = 12
        profileComboBox.font = .systemFont(ofSize: GroveUI.contentFontSize)
        profileComboBox.delegate = self
        profileComboBox.target = self
        profileComboBox.action = #selector(profileChanged(_:))
        profileComboBox.widthAnchor.constraint(equalToConstant: 180).isActive = true

        regionComboBox.completes = true
        regionComboBox.numberOfVisibleItems = 14
        regionComboBox.font = .systemFont(ofSize: GroveUI.contentFontSize)
        regionComboBox.delegate = self
        regionComboBox.target = self
        regionComboBox.action = #selector(regionChanged(_:))
        regionComboBox.widthAnchor.constraint(equalToConstant: 135).isActive = true

        bucketField.placeholderString = "Filter buckets"
        bucketField.font = .systemFont(ofSize: GroveUI.contentFontSize)
        bucketField.delegate = self
        bucketField.target = self
        bucketField.action = #selector(bucketFilterSubmitted(_:))
        bucketField.widthAnchor.constraint(equalToConstant: 210).isActive = true

        browseButton.target = self
        browseButton.action = #selector(browseRequested(_:))
        browseButton.bezelStyle = .rounded
        browseButton.image = NSImage(systemSymbolName: "arrow.forward.circle", accessibilityDescription: "Open")
        browseButton.imagePosition = .imageLeading

        uploadButton.target = self
        uploadButton.action = #selector(uploadRequested(_:))
        uploadButton.bezelStyle = .rounded
        uploadButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Upload")
        uploadButton.imagePosition = .imageLeading

        downloadButton.target = self
        downloadButton.action = #selector(downloadRequested(_:))
        downloadButton.bezelStyle = .rounded
        downloadButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Download")
        downloadButton.imagePosition = .imageLeading

        retryButton.target = self
        retryButton.action = #selector(retryRequested(_:))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true

        detailsButton.target = self
        detailsButton.action = #selector(showDetails(_:))
        detailsButton.bezelStyle = .rounded
        detailsButton.isHidden = true

        statusLabel.font = .systemFont(ofSize: GroveUI.statusFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false

        let titleTextStack = NSStackView()
        titleTextStack.orientation = .vertical
        titleTextStack.alignment = .leading
        titleTextStack.spacing = 1
        titleTextStack.addArrangedSubview(headerTitleLabel)
        titleTextStack.addArrangedSubview(locationSummaryLabel)

        let titleRow = makeControlRow()
        titleRow.addArrangedSubview(titleTextStack)
        titleRow.addArrangedSubview(makeFlexibleSpacer())
        titleRow.addArrangedSubview(retryButton)
        titleRow.addArrangedSubview(detailsButton)
        titleRow.addArrangedSubview(loadingSpinner)

        let selectionRow = makeControlRow()
        selectionRow.spacing = 10
        selectionRow.addArrangedSubview(makeLabeledControl("Profile", control: profileComboBox))
        selectionRow.addArrangedSubview(makeLabeledControl("Region", control: regionComboBox))
        selectionRow.addArrangedSubview(makeFlexibleSpacer())

        let bucketRow = makeControlRow()
        bucketRow.addArrangedSubview(makeLabeledControl("Bucket", control: bucketField))
        bucketRow.addArrangedSubview(browseButton)
        bucketRow.addArrangedSubview(uploadButton)
        bucketRow.addArrangedSubview(downloadButton)
        bucketRow.addArrangedSubview(makeFlexibleSpacer())

        controlsStack.addArrangedSubview(titleRow)
        controlsStack.addArrangedSubview(selectionRow)
        controlsStack.addArrangedSubview(bucketRow)
    }

    private func makeControlRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.detachesHiddenViews = true
        return row
    }

    private func makeControlLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: GroveUI.contentFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func makeLabeledControl(_ title: String, control: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(makeControlLabel(title))
        stack.addArrangedSubview(control)
        return stack
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func setupTable() {
        let name = NSTableColumn(identifier: nameColumn)
        name.title = "Name"
        name.width = 300
        name.minWidth = 160
        tableView.addTableColumn(name)

        let modified = NSTableColumn(identifier: modifiedColumn)
        modified.title = "Modified"
        modified.width = 160
        modified.minWidth = 100
        tableView.addTableColumn(modified)

        let size = NSTableColumn(identifier: sizeColumn)
        size.title = "Size"
        size.width = 90
        size.minWidth = 70
        tableView.addTableColumn(size)

        let kind = NSTableColumn(identifier: kindColumn)
        kind.title = "Kind"
        kind.width = 120
        kind.minWidth = 90
        tableView.addTableColumn(kind)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.rowHeight = GroveUI.listRowHeight
        tableView.backgroundColor = GroveUI.contentBackground
        tableView.gridColor = GroveUI.separator
        tableView.intercellSpacing = .zero
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        tableView.registerForDraggedTypes([.fileURL])

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = GroveUI.contentBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.registerForDraggedTypes([.fileURL])
        scrollView.onValidateBackgroundDrop = { [weak self] info in
            self?.validateS3FileDrop(info) ?? []
        }
        scrollView.onAcceptBackgroundDrop = { [weak self] info in
            self?.acceptS3FileDrop(info) ?? false
        }

        emptyLabel.font = .systemFont(ofSize: GroveUI.emptyFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreRequested(_:))
        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.isHidden = true
    }

    private func setupLayout() {
        view.addSubview(rootStack)
        view.addSubview(emptyLabel)

        rootStack.addArrangedSubview(controlsStack)
        rootStack.addArrangedSubview(statusLabel)
        rootStack.addArrangedSubview(scrollView)
        rootStack.addArrangedSubview(loadMoreButton)
        rootStack.setCustomSpacing(4, after: statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor, constant: 10).isActive = true
        statusLabel.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor, constant: -10).isActive = true

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
    }

    private func setupAccessibility() {
        profileComboBox.setAccessibilityIdentifier("s3ProfileComboBox")
        regionComboBox.setAccessibilityIdentifier("s3RegionComboBox")
        bucketField.setAccessibilityIdentifier("s3BucketField")
        browseButton.setAccessibilityIdentifier("s3BrowseButton")
        uploadButton.setAccessibilityIdentifier("s3UploadButton")
        downloadButton.setAccessibilityIdentifier("s3DownloadButton")
        tableView.setAccessibilityIdentifier("s3ObjectTable")
        statusLabel.setAccessibilityIdentifier("s3StatusLabel")
        locationSummaryLabel.setAccessibilityIdentifier("s3LocationSummaryLabel")
    }

    @discardableResult
    private func reloadProfiles() -> Bool {
        profiles = profileStore.profiles()
        profileComboBox.removeAllItems()
        profileComboBox.addItems(withObjectValues: profiles.map(\.name))

        if profiles.isEmpty {
            browseButton.isEnabled = false
            updateActionAvailability()
            showInlineError(.noProfiles)
            return false
        }

        browseButton.isEnabled = true
        let preferred = s3Location.profileName ?? profiles.first?.name
        if let preferred {
            profileComboBox.stringValue = preferred
        }
        reloadRegionSuggestions(selectedProfile?.regionHint)
        if regionComboBox.stringValue.isEmpty {
            regionComboBox.stringValue = selectedProfile?.regionHint ?? Self.defaultRegion
        }
        updateLocationSummary()
        updateActionAvailability()
        return true
    }

    private func syncControlsFromLocation() {
        if profiles.isEmpty {
            reloadProfiles()
        }
        suppressControlActions = true
        defer { suppressControlActions = false }

        profileComboBox.stringValue = s3Location.profileName ?? profiles.first?.name ?? ""
        reloadRegionSuggestions(selectedProfile?.regionHint ?? s3Location.regionOverride)
        let profileRegion = selectedProfile?.regionHint
        regionComboBox.stringValue = s3Location.regionOverride ?? profileRegion ?? Self.defaultRegion
        bucketField.stringValue = s3Location.bucket ?? ""
        updateLocationSummary()
        updateActionAvailability()
    }

    @objc private func profileChanged(_ sender: Any?) {
        guard !suppressControlActions else { return }
        guard let profile = selectedProfile else { return }
        reloadRegionSuggestions(profile.regionHint)
        regionComboBox.stringValue = profile.regionHint ?? regionComboBox.stringValue.nonEmpty ?? Self.defaultRegion
        bucketField.stringValue = ""
        navigateToBucketList(profile: profile)
    }

    @objc private func regionChanged(_ sender: Any?) {
        guard !suppressControlActions else { return }
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
            return
        }
        bucketField.stringValue = ""
        navigateToBucketList(profile: profile)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else { return }
        if comboBox === profileComboBox {
            profileChanged(comboBox)
        } else if comboBox === regionComboBox {
            regionChanged(comboBox)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else { return }
        if comboBox === profileComboBox {
            profileChanged(comboBox)
        } else if comboBox === regionComboBox {
            regionChanged(comboBox)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === bucketField,
              !suppressControlActions,
              s3Location.bucket == nil,
              !bucketListingUnavailable else { return }
        applyBucketFilter()
    }

    @objc private func bucketFilterSubmitted(_ sender: Any?) {
        guard s3Location.bucket == nil, !bucketListingUnavailable else {
            browseRequested(sender)
            return
        }
        applyBucketFilter()
    }

    @objc private func browseRequested(_ sender: Any?) {
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
            return
        }
        if s3Location.bucket == nil, !bucketListingUnavailable {
            if let selectedBucket = selectedBrowserItems.compactMap(\.s3Item).first(where: \.isBucket) {
                delegate?.fileListDidNavigate(to: .s3(selectedBucket.location))
                return
            }

            let query = bucketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exactBucket = allBucketItems.first(where: {
                $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame
            }) {
                delegate?.fileListDidNavigate(to: .s3(exactBucket.location))
                return
            }

            if allBucketItems.isEmpty, let bucket = query.nonEmpty {
                let location = S3Location(
                    profileName: profile.name,
                    regionOverride: selectedRegion(profile: profile),
                    bucket: bucket,
                    prefix: ""
                )
                delegate?.fileListDidNavigate(to: .s3(location))
                return
            }

            applyBucketFilter()
            return
        }

        guard let bucket = bucketField.stringValue.nonEmpty else {
            showInlineError(.noBucketSelected)
            return
        }
        let location = S3Location(
            profileName: profile.name,
            regionOverride: selectedRegion(profile: profile),
            bucket: bucket,
            prefix: ""
        )
        delegate?.fileListDidNavigate(to: .s3(location))
    }

    @objc private func retryRequested(_ sender: Any?) {
        if s3Location.bucket?.isEmpty == false {
            loadPrefix(resetItems: true)
        } else {
            loadBuckets()
        }
    }

    @objc private func loadMoreRequested(_ sender: Any?) {
        loadPrefix(resetItems: false)
    }

    @objc private func showDetails(_ sender: Any?) {
        guard let lastError else { return }
        let alert = NSAlert()
        alert.messageText = "S3 Error Details"
        alert.informativeText = lastError.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc private func uploadRequested(_ sender: Any?) {
        guard S3TransferValidator.canUpload(to: s3Location) else {
            showInlineError(.permission("Open a concrete S3 bucket or prefix before uploading."))
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Upload"
        runPanel(panel) { [weak self] response in
            guard response == .OK, let self else { return }
            self.promptForStorageClass { [weak self] storageClass in
                guard let self, let storageClass else { return }
                self.performUpload(fileURLs: panel.urls, storageClass: storageClass)
            }
        }
    }

    @objc private func downloadRequested(_ sender: Any?) {
        let selected = selectedBrowserItems.compactMap(\.s3Item)
        if let rejection = S3TransferValidator.downloadRejectionReason(for: selected) {
            showInlineError(.permission(rejection))
            return
        }

        if selected.count == 1, let item = selected.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = item.name
            panel.canCreateDirectories = true
            panel.prompt = "Download"
            runPanel(panel) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.performDownload(items: selected, destination: .file(url))
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose a destination folder."
            runPanel(panel) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.performDownload(items: selected, destination: .directory(url))
            }
        }
    }

    private func runPanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func promptForStorageClass(completion: @escaping (S3StorageClass?) -> Void) {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for storageClass in S3StorageClass.allCases {
            popup.addItem(withTitle: storageClass.displayName)
            popup.lastItem?.representedObject = storageClass.rawValue
        }
        popup.selectItem(withTitle: S3StorageClass.standard.displayName)

        let alert = NSAlert()
        alert.messageText = "Upload to S3"
        alert.informativeText = "Choose the storage class for new objects."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            let rawValue = popup.selectedItem?.representedObject as? String
            completion(rawValue.flatMap(S3StorageClass.init(rawValue:)) ?? .standard)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func performUpload(fileURLs: [URL], storageClass: S3StorageClass) {
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
            return
        }
        if let rejection = S3TransferValidator.uploadRejectionReason(localFileURLs: fileURLs, to: s3Location) {
            showInlineError(.permission(rejection))
            return
        }

        let progressVC = FileProgressViewController()
        progressVC.configure(operationVerb: "Uploading")
        presentAsSheet(progressVC)
        setTransferInProgress(true, message: "Uploading to \(s3Location.bucket ?? "S3")...")

        let task = Task { [weak self, profile, location = s3Location] in
            guard let self else { return }
            do {
                let results = try await self.service.upload(
                    localFileURLs: fileURLs,
                    to: location,
                    profile: profile,
                    storageClass: storageClass
                ) { progress in
                    Task { @MainActor in
                        progressVC.updateProgress(progress.fractionCompleted ?? 0, fileName: progress.fileName)
                    }
                }
                await MainActor.run {
                    self.dismiss(progressVC)
                    self.transferTask = nil
                    self.setTransferInProgress(false, message: "Uploaded \(results.count) \(results.count == 1 ? "object" : "objects").")
                    self.loadPrefix(resetItems: true)
                }
            } catch {
                let classified = S3BrowserError.classify(error, bucket: location.bucket, requestedRegion: location.regionOverride)
                await MainActor.run {
                    self.dismiss(progressVC)
                    self.transferTask = nil
                    self.setTransferInProgress(false, message: nil)
                    self.showInlineError(classified)
                }
            }
        }
        transferTask = task
        progressVC.onCancel = { task.cancel() }
        updateActionAvailability()
    }

    private func performDownload(items: [S3Item], destination: S3DownloadDestination) {
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
            return
        }

        let progressVC = FileProgressViewController()
        progressVC.configure(operationVerb: "Downloading")
        presentAsSheet(progressVC)
        setTransferInProgress(true, message: "Downloading \(items.count) \(items.count == 1 ? "object" : "objects")...")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.service.download(
                    items: items,
                    to: destination,
                    profile: profile
                ) { progress in
                    Task { @MainActor in
                        progressVC.updateProgress(progress.fractionCompleted ?? 0, fileName: progress.fileName)
                    }
                }
                await MainActor.run {
                    self.dismiss(progressVC)
                    self.transferTask = nil
                    self.setTransferInProgress(false, message: "Downloaded \(results.count) \(results.count == 1 ? "object" : "objects").")
                }
            } catch {
                let item = items.first
                let classified = S3BrowserError.classify(error, bucket: item?.bucket, requestedRegion: item?.location.regionOverride)
                await MainActor.run {
                    self.dismiss(progressVC)
                    self.transferTask = nil
                    self.setTransferInProgress(false, message: nil)
                    self.showInlineError(classified)
                }
            }
        }
        transferTask = task
        progressVC.onCancel = { task.cancel() }
        updateActionAvailability()
    }

    private func setTransferInProgress(_ active: Bool, message: String?) {
        if !active {
            transferTask = nil
        }
        updateActionAvailability()
        if let message {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = message
        }
    }

    private func loadPrefix(resetItems: Bool) {
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
            return
        }
        guard s3Location.bucket?.isEmpty == false else {
            showInlineError(.noBucketSelected)
            return
        }

        loadTask?.cancel()
        let generation = staleLoadGuard.begin()
        let token = resetItems ? nil : nextContinuationToken
        let requestedLocation = s3Location
        if resetItems {
            items = []
            tableView.reloadData()
        }
        setLoading(true, message: "Loading \(requestedLocation.bucket ?? "bucket")...")

        loadTask = Task { [weak self] in
            do {
                guard let self else { return }
                let page = try await self.service.list(location: requestedLocation, profile: profile, continuationToken: token)
                await MainActor.run {
                    guard self.staleLoadGuard.isCurrent(generation) else { return }
                    self.s3Location = page.location
                    self.syncControlsFromLocation()
                    if resetItems {
                        self.items = page.items
                    } else {
                        self.items.append(contentsOf: page.items)
                    }
                    self.nextContinuationToken = page.nextContinuationToken
                    self.tableView.reloadData()
                    self.setLoading(false, message: self.statusText())
                    self.emptyLabel.stringValue = "This S3 prefix is empty"
                    self.emptyLabel.isHidden = !self.items.isEmpty
                    self.loadMoreButton.isHidden = page.nextContinuationToken == nil
                    self.retryButton.isHidden = true
                    self.detailsButton.isHidden = true
                    self.lastError = nil
                }
            } catch {
                let classified = S3BrowserError.classify(error, bucket: requestedLocation.bucket, requestedRegion: requestedLocation.regionOverride)
                await MainActor.run {
                    guard self?.staleLoadGuard.isCurrent(generation) == true else { return }
                    self?.showInlineError(classified)
                }
            }
        }
    }

    private func navigateToBucketList(profile: AWSProfile) {
        let location = S3Location(
            profileName: profile.name,
            regionOverride: selectedRegion(profile: profile),
            bucket: nil,
            prefix: ""
        )
        delegate?.fileListDidNavigate(to: .s3(location))
    }

    private func loadBuckets() {
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
            return
        }

        loadTask?.cancel()
        metadataTask?.cancel()
        let generation = staleLoadGuard.begin()
        let region = selectedRegion(profile: profile)
        s3Location = S3Location(profileName: profile.name, regionOverride: region, bucket: nil, prefix: "")
        bucketListingUnavailable = false
        bucketField.placeholderString = "Filter buckets"
        updateLocationSummary()
        updateActionAvailability()
        nextContinuationToken = nil
        allBucketItems = []
        items = []
        tableView.reloadData()
        emptyLabel.stringValue = "Loading buckets..."
        emptyLabel.isHidden = false
        loadMoreButton.isHidden = true
        setLoading(true, message: "Loading buckets for \(profile.name)...")

        loadTask = Task { [weak self] in
            do {
                guard let self else { return }
                let buckets = try await self.service.listBuckets(profile: profile, regionOverride: region)
                let bucketItems = Self.bucketItems(
                    from: buckets,
                    profileName: profile.name,
                    region: region
                )
                await MainActor.run {
                    guard self.staleLoadGuard.isCurrent(generation) else { return }
                    self.allBucketItems = bucketItems
                    self.bucketListingUnavailable = false
                    self.bucketField.placeholderString = "Filter buckets"
                    self.nextContinuationToken = nil
                    self.setLoading(false, message: nil)
                    self.applyBucketFilter()
                    self.loadMoreButton.isHidden = true
                    self.retryButton.isHidden = true
                    self.detailsButton.isHidden = true
                    self.lastError = nil
                }
            } catch {
                let classified = S3BrowserError.classify(error, requestedRegion: region)
                await MainActor.run {
                    guard self?.staleLoadGuard.isCurrent(generation) == true else { return }
                    self?.bucketListingUnavailable = true
                    self?.bucketField.placeholderString = "Enter exact bucket name"
                    self?.showInlineError(.permission("Bucket listing unavailable. \(classified.localizedDescription) Enter an exact bucket name to continue."))
                }
            }
        }
    }

    static func bucketItems(from buckets: [S3BucketSummary], profileName: String, region: String?) -> [S3Item] {
        buckets
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { bucket in
                S3Item(
                    bucket: bucket.name,
                    key: "",
                    name: bucket.name,
                    isPrefix: true,
                    size: nil,
                    lastModified: bucket.creationDate,
                    eTag: nil,
                    storageClass: nil,
                    location: S3Location(profileName: profileName, regionOverride: region, bucket: bucket.name, prefix: ""),
                    metadata: nil
                )
            }
    }

    static func filteredBucketItems(_ items: [S3Item], query: String) -> [S3Item] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    private func applyBucketFilter() {
        guard s3Location.bucket == nil, !isLoading, !bucketListingUnavailable else { return }
        let query = bucketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tableView.deselectAll(nil)
        items = Self.filteredBucketItems(allBucketItems, query: query)
        tableView.reloadData()
        delegate?.fileListDidSelect(browserItems: [])
        statusLabel.textColor = .secondaryLabelColor

        let total = allBucketItems.count
        if query.isEmpty {
            setLoading(false, message: statusText())
            emptyLabel.stringValue = "No buckets were returned. Enter a bucket manually to continue."
        } else {
            setLoading(false, message: "\(items.count) of \(total) buckets match \u{201C}\(query)\u{201D}")
            emptyLabel.stringValue = "No buckets match \u{201C}\(query)\u{201D}"
        }
        emptyLabel.isHidden = !items.isEmpty
        retryButton.isHidden = true
        detailsButton.isHidden = true
        lastError = nil
    }

    private var selectedProfile: AWSProfile? {
        let name = profileComboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = profiles.first(where: { $0.name == name }) {
            return exact
        }
        if name.isEmpty {
            return profiles.first
        }
        return nil
    }

    private func selectedRegion(profile: AWSProfile) -> String {
        Self.resolvedRegion(input: regionComboBox.stringValue, profileRegion: profile.regionHint)
    }

    private func reloadRegionSuggestions(_ preferredRegion: String?) {
        let selected = regionComboBox.stringValue
        regionComboBox.removeAllItems()
        regionComboBox.addItems(withObjectValues: Self.regionSuggestions(preferredRegion: preferredRegion))
        regionComboBox.stringValue = selected
    }

    private func setLoading(_ loading: Bool, message: String?) {
        isLoading = loading
        if loading {
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
        }
        browseButton.isEnabled = !loading && !profiles.isEmpty
        uploadButton.isEnabled = !loading && transferTask == nil && S3TransferValidator.canUpload(to: s3Location)
        downloadButton.isEnabled = !loading && transferTask == nil && S3TransferValidator.canDownload(selectedBrowserItems.compactMap(\.s3Item))
        loadMoreButton.isEnabled = !loading
        if let message {
            statusLabel.stringValue = message
        }
    }

    private func updateActionAvailability() {
        let isBusy = isLoading || transferTask != nil
        browseButton.isEnabled = !isBusy && !profiles.isEmpty
        uploadButton.isEnabled = !isBusy && S3TransferValidator.canUpload(to: s3Location)
        downloadButton.isEnabled = !isBusy && S3TransferValidator.canDownload(selectedBrowserItems.compactMap(\.s3Item))
    }

    private func updateLocationSummary() {
        let profileText = profileComboBox.stringValue.nonEmpty ?? "No profile"
        let regionText = regionComboBox.stringValue.nonEmpty ?? "No region"
        if let bucket = s3Location.bucket, !bucket.isEmpty {
            let prefix = s3Location.prefix.isEmpty ? "/" : "/\(s3Location.prefix)"
            locationSummaryLabel.stringValue = "\(profileText)  -  \(regionText)  -  s3://\(bucket)\(prefix)"
        } else {
            locationSummaryLabel.stringValue = "\(profileText)  -  \(regionText)  -  bucket list"
        }
    }

    private func renderIdleState() {
        showInlineMessage("Choose a profile and region to list buckets, or enter a bucket manually.")
        emptyLabel.stringValue = "Select a profile and region to list buckets"
        emptyLabel.isHidden = false
        loadMoreButton.isHidden = true
    }

    private func showInlineMessage(_ message: String) {
        isLoading = false
        lastError = nil
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = message
        retryButton.isHidden = true
        detailsButton.isHidden = true
        loadingSpinner.stopAnimation(nil)
        updateActionAvailability()
    }

    private func showInlineError(_ error: S3BrowserError) {
        isLoading = false
        lastError = error
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = error.inlineDescription
        retryButton.isHidden = false
        detailsButton.isHidden = false
        loadingSpinner.stopAnimation(nil)
        browseButton.isEnabled = !profiles.isEmpty
        loadMoreButton.isHidden = true
        loadMoreButton.isEnabled = false
        emptyLabel.stringValue = error.inlineDescription
        emptyLabel.isHidden = false
        updateActionAvailability()
    }

    private func statusText() -> String {
        let count = items.count
        let noun: String
        if s3Location.bucket == nil {
            noun = count == 1 ? "bucket" : "buckets"
        } else {
            noun = count == 1 ? "item" : "items"
        }
        let itemText = "\(count) \(noun)"
        let selectedCount = tableView.selectedRowIndexes.count
        let selectionText = selectedCount > 0 ? " (\(selectedCount) selected)" : ""
        let profileText = s3Location.profileName.map { "  -  \($0)" } ?? ""
        let regionText = s3Location.regionOverride.map { "  -  \($0)" } ?? ""
        return "\(itemText)\(selectionText)\(profileText)\(regionText)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        GroveUI.listRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        if cell.textField == nil {
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: GroveUI.contentFontSize)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let item = items[row]
        switch identifier {
        case nameColumn:
            cell.textField?.stringValue = item.name
            cell.imageView?.image = nil
        case modifiedColumn:
            cell.textField?.stringValue = item.lastModified.map { Self.dateFormatter.string(from: $0) } ?? "--"
        case sizeColumn:
            cell.textField?.stringValue = item.formattedSize
        case kindColumn:
            cell.textField?.stringValue = item.kind
        default:
            cell.textField?.stringValue = ""
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = GroveTableRowView()
        rowView.backgroundColor = row.isMultiple(of: 2)
            ? GroveUI.contentBackground
            : GroveUI.alternateRowBackground
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = selectedBrowserItems
        delegate?.fileListDidSelect(browserItems: selected)
        statusLabel.stringValue = statusText()
        updateActionAvailability()
        loadMetadataForSingleSelection()
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isPrefix {
            delegate?.fileListDidNavigate(to: .s3(item.location))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {
            let row = tableView.selectedRow
            if row >= 0, row < items.count, items[row].isPrefix {
                delegate?.fileListDidNavigate(to: .s3(items[row].location))
                return
            }
        }
        super.keyDown(with: event)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        validateS3FileDrop(info)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        acceptS3FileDrop(info)
    }

    private func validateS3FileDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard transferTask == nil,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              let urls = fileURLs(from: info),
              S3TransferValidator.uploadRejectionReason(localFileURLs: urls, to: s3Location) == nil else {
            return []
        }
        return .copy
    }

    private func acceptS3FileDrop(_ info: any NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: info), !urls.isEmpty else {
            showInlineError(.permission("Drop local files to upload."))
            return false
        }
        if let rejection = S3TransferValidator.uploadRejectionReason(localFileURLs: urls, to: s3Location) {
            showInlineError(.permission(rejection))
            return false
        }
        promptForStorageClass { [weak self] storageClass in
            guard let self, let storageClass else { return }
            self.performUpload(fileURLs: urls, storageClass: storageClass)
        }
        return true
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private func loadMetadataForSingleSelection() {
        metadataTask?.cancel()
        guard selectedBrowserItems.count == 1,
              let item = selectedBrowserItems.first?.s3Item,
              !item.isPrefix else { return }
        let selectedID = item.id
        metadataTask = Task { [weak self] in
            guard let self else { return }
            let updated = await self.service.loadMetadata(for: item)
            await MainActor.run {
                guard let index = self.items.firstIndex(where: { $0.id == selectedID }),
                      self.tableView.selectedRowIndexes.contains(index) else { return }
                self.items[index] = updated
                self.delegate?.fileListDidSelect(browserItems: [.s3(updated)])
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let selected = selectedBrowserItems.compactMap(\.s3Item)
        for descriptor in Self.contextMenuItems(for: selected, location: s3Location) {
            let item = menu.addItem(
                withTitle: descriptor.title,
                action: selector(for: descriptor.command),
                keyEquivalent: ""
            )
            item.target = descriptor.command == nil ? nil : self
            item.isEnabled = descriptor.isEnabled
        }
    }

    @objc private func contextOpenPrefix(_ sender: Any?) {
        guard let item = selectedBrowserItems.first?.s3Item, item.isPrefix else { return }
        delegate?.fileListDidNavigate(to: .s3(item.location))
    }

    @objc private func contextUploadFiles(_ sender: Any?) {
        uploadRequested(sender)
    }

    @objc private func contextDownload(_ sender: Any?) {
        downloadRequested(sender)
    }

    @objc private func contextCopyS3URI(_ sender: Any?) {
        let values = selectedBrowserItems.compactMap(\.s3Item).map { item in
            item.key.isEmpty ? "s3://\(item.bucket)" : "s3://\(item.bucket)/\(item.key)"
        }
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    static let forbiddenLocalCommandTitles: Set<String> = [
        "Move to Trash", "Open in Terminal", "Reveal in Finder", "Tags", "Compress",
        "Checksum", "Rename", "Duplicate", "Cut", "Paste", "Quick Look",
    ]

    static func contextMenuItems(for selected: [S3Item], location: S3Location) -> [S3ContextMenuItemDescriptor] {
        var descriptors: [S3ContextMenuItemDescriptor] = []

        if selected.isEmpty {
            if S3TransferValidator.canUpload(to: location) {
                descriptors.append(S3ContextMenuItemDescriptor(title: "Upload Files...", command: .uploadFiles, isEnabled: true))
            }
            return descriptors
        }

        if selected.count == 1, let item = selected.first, item.isPrefix {
            descriptors.append(S3ContextMenuItemDescriptor(
                title: item.isBucket ? "Open Bucket" : "Open Prefix",
                command: .openPrefix,
                isEnabled: true
            ))
        }

        if S3TransferValidator.canDownload(selected) {
            descriptors.append(S3ContextMenuItemDescriptor(title: "Download...", command: .download, isEnabled: true))
        } else if selected.contains(where: \.isPrefix) {
            descriptors.append(S3ContextMenuItemDescriptor(title: "Download Unavailable for Prefixes", command: nil, isEnabled: false))
        }

        if S3TransferValidator.canUpload(to: location) {
            descriptors.append(S3ContextMenuItemDescriptor(title: "Upload Files...", command: .uploadFiles, isEnabled: true))
        }

        descriptors.append(S3ContextMenuItemDescriptor(title: "Copy S3 URI", command: .copyURI, isEnabled: true))
        return descriptors
    }

    private func selector(for command: S3ContextMenuCommand?) -> Selector? {
        switch command {
        case .openPrefix:
            return #selector(contextOpenPrefix(_:))
        case .uploadFiles:
            return #selector(contextUploadFiles(_:))
        case .download:
            return #selector(contextDownload(_:))
        case .copyURI:
            return #selector(contextCopyS3URI(_:))
        case nil:
            return nil
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let defaultRegion = "us-east-1"

    // Keep this list broad enough for autocomplete while still allowing typed future regions.
    static let awsRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "af-south-1",
        "ap-east-1", "ap-east-2", "ap-northeast-1", "ap-northeast-2", "ap-northeast-3",
        "ap-south-1", "ap-south-2",
        "ap-southeast-1", "ap-southeast-2", "ap-southeast-3", "ap-southeast-4", "ap-southeast-5", "ap-southeast-7",
        "ca-central-1", "ca-west-1",
        "eu-central-1", "eu-central-2",
        "eu-north-1",
        "eu-south-1", "eu-south-2",
        "eu-west-1", "eu-west-2", "eu-west-3",
        "il-central-1",
        "me-central-1", "me-south-1",
        "mx-central-1",
        "sa-east-1",
        "us-gov-east-1", "us-gov-west-1",
        "cn-north-1", "cn-northwest-1",
    ]

    static func regionSuggestions(preferredRegion: String?, knownRegions: [String] = awsRegions) -> [String] {
        ([preferredRegion].compactMap { $0?.nonEmpty } + knownRegions)
            .reduce(into: [String]()) { result, region in
                if !result.contains(region) {
                    result.append(region)
                }
            }
    }

    static func resolvedRegion(input: String, profileRegion: String?) -> String {
        input.nonEmpty ?? profileRegion?.nonEmpty ?? defaultRegion
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
