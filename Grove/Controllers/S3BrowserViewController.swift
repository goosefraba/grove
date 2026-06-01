import AppKit

final class S3BrowserViewController: NSViewController, FileViewControllerProtocol, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSComboBoxDelegate {
    weak var delegate: FileListViewControllerDelegate?

    private let profileStore: AWSProfileStore
    private let service: S3BrowserService

    private let rootStack = NSStackView()
    private let controlsStack = NSStackView()
    private let profileComboBox = NSComboBox()
    private let regionComboBox = NSComboBox()
    private let bucketField = NSTextField()
    private let browseButton = NSButton(title: "Open", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let detailsButton = NSButton(title: "Details", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")

    private var profiles: [AWSProfile] = []
    private var items: [S3Item] = []
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private let staleLoadGuard = StaleLoadGuard()
    private var lastError: S3BrowserError?
    private var nextContinuationToken: String?
    private var suppressControlActions = false

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
    var capabilities: StorageCapabilities { .s3ReadOnly }
    var supportsToolbarSearch: Bool { false }

    override func loadView() {
        view = NSView()
        view.setFrameSize(NSSize(width: 600, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupControls()
        setupTable()
        setupLayout()
        setupAccessibility()
        reloadProfiles()
        renderIdleState()
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

        bucketField.placeholderString = "Bucket"
        bucketField.font = .systemFont(ofSize: GroveUI.contentFontSize)
        bucketField.target = self
        bucketField.action = #selector(browseRequested(_:))
        bucketField.widthAnchor.constraint(equalToConstant: 210).isActive = true

        browseButton.target = self
        browseButton.action = #selector(browseRequested(_:))
        browseButton.bezelStyle = .rounded

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

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false

        let profileRow = makeControlRow()
        profileRow.addArrangedSubview(makeControlLabel("Profile"))
        profileRow.addArrangedSubview(profileComboBox)
        profileRow.addArrangedSubview(makeControlLabel("Region"))
        profileRow.addArrangedSubview(regionComboBox)
        profileRow.addArrangedSubview(makeControlLabel("Open bucket"))
        profileRow.addArrangedSubview(bucketField)
        profileRow.addArrangedSubview(browseButton)
        profileRow.addArrangedSubview(retryButton)
        profileRow.addArrangedSubview(detailsButton)
        profileRow.addArrangedSubview(loadingSpinner)
        profileRow.addArrangedSubview(makeFlexibleSpacer())

        controlsStack.addArrangedSubview(profileRow)
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
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.rowHeight = GroveUI.listRowHeight
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: GroveUI.emptyFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
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
        ])
    }

    private func setupAccessibility() {
        profileComboBox.setAccessibilityIdentifier("s3ProfileComboBox")
        regionComboBox.setAccessibilityIdentifier("s3RegionComboBox")
        bucketField.setAccessibilityIdentifier("s3BucketField")
        browseButton.setAccessibilityIdentifier("s3BrowseButton")
        tableView.setAccessibilityIdentifier("s3ObjectTable")
        statusLabel.setAccessibilityIdentifier("s3StatusLabel")
    }

    private func reloadProfiles() {
        profiles = profileStore.profiles()
        profileComboBox.removeAllItems()
        profileComboBox.addItems(withObjectValues: profiles.map(\.name))

        if profiles.isEmpty {
            browseButton.isEnabled = false
            showInlineError(.noProfiles)
            return
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

    @objc private func browseRequested(_ sender: Any?) {
        guard let profile = selectedProfile else {
            showInlineError(.noProfileSelected)
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
        nextContinuationToken = nil
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
                    self.items = bucketItems
                    self.nextContinuationToken = nil
                    self.tableView.reloadData()
                    self.setLoading(false, message: self.statusText())
                    self.emptyLabel.stringValue = "No buckets were returned. Enter a bucket manually to continue."
                    self.emptyLabel.isHidden = !self.items.isEmpty
                    self.loadMoreButton.isHidden = true
                    self.retryButton.isHidden = true
                    self.detailsButton.isHidden = true
                    self.lastError = nil
                }
            } catch {
                let classified = S3BrowserError.classify(error, requestedRegion: region)
                await MainActor.run {
                    guard self?.staleLoadGuard.isCurrent(generation) == true else { return }
                    self?.showInlineError(.permission("Bucket listing unavailable. \(classified.localizedDescription) Enter a bucket manually to continue."))
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
        regionComboBox.stringValue.nonEmpty ?? profile.regionHint ?? Self.defaultRegion
    }

    private func reloadRegionSuggestions(_ preferredRegion: String?) {
        let selected = regionComboBox.stringValue
        let regions = ([preferredRegion].compactMap { $0?.nonEmpty } + Self.awsRegions)
            .reduce(into: [String]()) { result, region in
                if !result.contains(region) {
                    result.append(region)
                }
            }
        regionComboBox.removeAllItems()
        regionComboBox.addItems(withObjectValues: regions)
        regionComboBox.stringValue = selected
    }

    private func setLoading(_ loading: Bool, message: String?) {
        if loading {
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
        }
        browseButton.isEnabled = !loading && !profiles.isEmpty
        loadMoreButton.isEnabled = !loading
        if let message {
            statusLabel.stringValue = message
        }
    }

    private func renderIdleState() {
        showInlineMessage("Choose a profile and region to list buckets, or enter a bucket manually.")
        emptyLabel.stringValue = "Select a profile and region to list buckets"
        emptyLabel.isHidden = false
        loadMoreButton.isHidden = true
    }

    private func showInlineMessage(_ message: String) {
        lastError = nil
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = message
        retryButton.isHidden = true
        detailsButton.isHidden = true
        loadingSpinner.stopAnimation(nil)
    }

    private func showInlineError(_ error: S3BrowserError) {
        lastError = error
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = error.localizedDescription
        retryButton.isHidden = false
        detailsButton.isHidden = false
        loadingSpinner.stopAnimation(nil)
        browseButton.isEnabled = !profiles.isEmpty
        loadMoreButton.isHidden = true
        loadMoreButton.isEnabled = false
        emptyLabel.stringValue = error.localizedDescription
        emptyLabel.isHidden = false
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = selectedBrowserItems
        delegate?.fileListDidSelect(browserItems: selected)
        statusLabel.stringValue = statusText()
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
            guard row >= 0, row < items.count, items[row].isPrefix else { return }
            delegate?.fileListDidNavigate(to: .s3(items[row].location))
            return
        }
        super.keyDown(with: event)
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
        guard !selected.isEmpty else { return }

        if selected.count == 1, selected[0].isPrefix {
            let title = selected[0].isBucket ? "Open Bucket" : "Open Prefix"
            let openItem = menu.addItem(withTitle: title, action: #selector(contextOpenPrefix(_:)), keyEquivalent: "")
            openItem.target = self
        }

        let copyURI = menu.addItem(withTitle: "Copy S3 URI", action: #selector(contextCopyS3URI(_:)), keyEquivalent: "")
        copyURI.target = self
    }

    @objc private func contextOpenPrefix(_ sender: Any?) {
        guard let item = selectedBrowserItems.first?.s3Item, item.isPrefix else { return }
        delegate?.fileListDidNavigate(to: .s3(item.location))
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let defaultRegion = "us-east-1"

    // Keep this list broad enough for autocomplete while still allowing typed future regions.
    private static let awsRegions = [
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
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
