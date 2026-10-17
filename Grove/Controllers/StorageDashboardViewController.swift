import AppKit
import SwiftUI
import Combine

@MainActor
final class StorageDashboardModel: ObservableObject {
    enum Phase: Equatable { case ready, scanning, finished, stopped, failed(String) }
    @Published private(set) var volumes: [MountedVolume] = []
    @Published private(set) var isLoadingVolumes = false
    @Published private(set) var scope: URL
    @Published private(set) var trail: [URL]
    @Published private(set) var snapshot: DiskUsageSnapshot?
    @Published private(set) var progress: DiskUsageProgress?
    @Published private(set) var phase: Phase = .ready
    var chooseFolder: ((URL) -> Void)?
    var openInGrove: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "com.grove.storage.scan", qos: .utility)
    private let volumeQueue = DispatchQueue(label: "com.grove.storage.volumes", qos: .utility)
    private var cancellation: DiskUsageCancellation?
    private var generation = UUID()
    private var cache: [URL: DiskUsageSnapshot] = [:]
    private var cacheOrder: [URL] = []
    private(set) var scanStarted = Date()

    init(scope: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.scope = scope
        self.trail = [scope]
    }

    deinit { cancellation?.cancel() }

    var isScanning: Bool { phase == .scanning }

    func refreshVolumes() {
        guard !isLoadingVolumes else { return }
        isLoadingVolumes = true
        volumeQueue.async { [weak self] in
            let volumes = MountedVolume.mountedVolumes()
            DispatchQueue.main.async { [weak self] in
                self?.volumes = volumes
                self?.isLoadingVolumes = false
            }
        }
    }

    func select(_ url: URL) {
        stop()
        scope = url
        trail = [scope]
        loadScope()
    }

    func enter(_ entry: DiskUsageEntry) {
        guard entry.isDirectory, !entry.isSymbolicLink, !entry.isExcluded else { return }
        stop()
        scope = entry.url
        trail.append(scope)
        loadScope()
    }

    func goBack(to index: Int) {
        guard trail.indices.contains(index), index < trail.count - 1 else { return }
        stop()
        trail = Array(trail.prefix(index + 1))
        scope = trail[index]
        loadScope()
    }

    private func loadScope() {
        progress = nil
        if let cached = cache[scope] {
            snapshot = cached; phase = .finished
            touchCache(scope)
        } else { startScan() }
    }

    func startScan() {
        cancellation?.cancel()
        let token = DiskUsageCancellation()
        cancellation = token
        let scanID = UUID()
        generation = scanID
        let root = scope
        cache.removeValue(forKey: root); cacheOrder.removeAll { $0 == root }
        snapshot = nil; progress = nil; phase = .scanning; scanStarted = Date()
        refreshVolumes()
        queue.async { [weak self] in
            do {
                let result = try DiskUsageScanner().scan(root, cancellation: token) { value in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == scanID else { return }
                        self.progress = value
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == scanID else { return }
                    self.scope = result.root
                    if !self.trail.isEmpty { self.trail[self.trail.count - 1] = result.root }
                    self.snapshot = result; self.phase = .finished; self.cancellation = nil
                    self.cache.removeValue(forKey: result.root)
                    self.cacheOrder.removeAll { $0 == result.root }
                    if !result.isPartial {
                        self.cache[result.root] = result
                        self.touchCache(result.root)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == scanID else { return }
                    self.cancellation = nil
                    self.invalidateCache()
                    self.phase = error is CancellationError ? .stopped : .failed(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        cancellation?.cancel(); cancellation = nil
        if isScanning { phase = .stopped }
    }

    func invalidateCache() { cache.removeAll(); cacheOrder.removeAll() }

    private func touchCache(_ url: URL) {
        cacheOrder.removeAll { $0 == url }; cacheOrder.append(url)
        while cacheOrder.count > 12 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
}

@MainActor
final class StorageDashboardViewController: NSViewController {
    let model: StorageDashboardModel
    var navigationDidChange: (() -> Void)?
    private var mountObservers: [NSObjectProtocol] = []
    private var modelObservation: AnyCancellable?

    init(scope: URL) {
        model = StorageDashboardModel(scope: scope)
        super.init(nibName: nil, bundle: nil)
        model.chooseFolder = { [weak self] url in self?.chooseFolder(startingAt: url) }
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.navigationDidChange?() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            mountObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model.invalidateCache()
                    self?.model.refreshVolumes()
                }
            })
        }
        model.refreshVolumes()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    deinit { mountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    override func loadView() {
        let hosting = NSHostingView(rootView: StorageDashboardView(model: model))
        hosting.sizingOptions = []
        view = hosting
    }

    private func chooseFolder(startingAt url: URL) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to analyze"
        panel.prompt = "Analyze Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.select(url)
        }
    }
}
