import SwiftUI
import Charts

private enum StorageStyle {
    static let background = Color(nsColor: GroveUI.contentBackground)
    static let card = Color(nsColor: GroveUI.elevatedBackground)
    static let line = Color.white.opacity(0.075)
    static let blue = Color(nsColor: GroveUI.accentSoft)
    static let palette: [Color] = [blue, .init(red: 0.55, green: 0.50, blue: 0.95), .init(red: 0.25, green: 0.76, blue: 0.70),
        .init(red: 0.91, green: 0.66, blue: 0.35), .init(red: 0.87, green: 0.47, blue: 0.59), .init(red: 0.48, green: 0.57, blue: 0.63)]
    static func category(_ category: DiskUsageCategory) -> Color { palette[DiskUsageCategory.allCases.firstIndex(of: category) ?? 5] }
    static func bytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    static func number(_ value: Int) -> String { value.formatted() }
}

private struct StorageCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20).background(StorageStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StorageStyle.line))
    }
}

struct StorageDashboardView: View {
    @ObservedObject var model: StorageDashboardModel
    @State private var filter = ""
    @State private var foldersOnly = false
    @State private var showDetails = false
    @State private var showReadIssues = false
    @State private var selectedAngle: Int64?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    volumes
                    scopeHeader(compact: geometry.size.width < 650)
                    if let snapshot = model.snapshot {
                        results(snapshot, wide: geometry.size.width > 880, compact: geometry.size.width < 600)
                    } else { scanState }
                    footer
                }
                .padding(geometry.size.width > 880 ? 32 : 22)
                .frame(maxWidth: 1380)
                .frame(maxWidth: .infinity)
            }
            .background(StorageStyle.background)
        }
        .preferredColorScheme(.dark)
        .tint(StorageStyle.blue)
        .onChange(of: model.scope) { _, _ in filter = ""; foldersOnly = false; selectedAngle = nil; showDetails = false }
        .onChange(of: selectedAngle) { _, value in
            guard let value, let snapshot = model.snapshot else { return }
            var end: Int64 = 0
            for entry in snapshot.entries.prefix(6) where entry.allocatedBytes > 0 {
                end = DiskUsageScanner.adding(end, entry.allocatedBytes)
                if value < end {
                    if entry.isDirectory { model.enter(entry) }
                    return
                }
            }
        }
        .accessibilityIdentifier("storageDashboard")
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("GROVE  /  INSIGHTS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(StorageStyle.blue)
                Text("Storage").font(.system(size: 32, weight: .semibold))
                Text("See what takes up space. Follow it to the source.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshVolumes() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).controlSize(.large).disabled(model.isLoadingVolumes)
                .help("Refresh volume capacity").accessibilityLabel("Refresh volume capacity")
        }
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("YOUR VOLUMES", detail: model.isLoadingVolumes ? "Updating…" : "System-reported capacity")
            if model.volumes.isEmpty {
                Text(model.isLoadingVolumes ? "Reading volume capacity…" : "Volume capacity is unavailable. You can still analyze a folder.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                    ForEach(model.volumes, id: \.stableIdentifier) { volume in volumeCard(volume) }
                }
            }
        }
    }

    private func volumeCard(_ volume: MountedVolume) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: volume.systemImage).font(.system(size: 22)).foregroundStyle(StorageStyle.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(volume.kind.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.chooseFolder?(volume.url) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Choose a folder on \(volume.displayName)")
                    .accessibilityLabel("Explore \(volume.displayName)")
            }
            if let total = volume.totalCapacity, total > 0, let available = volume.availableCapacity {
                let free = min(total, max(0, available))
                let used = total - free
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(StorageStyle.bytes(Int64(free))).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("available").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((Double(used) / Double(total) * 100).rounded()))% used")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(StorageStyle.blue)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule().fill(LinearGradient(colors: [capacityColor(Double(used) / Double(total)).opacity(0.6), capacityColor(Double(used) / Double(total))], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * Double(used) / Double(total))
                    }.frame(height: 6).accessibilityHidden(true)
                    HStack {
                        Text("\(StorageStyle.bytes(Int64(used))) used")
                        Spacer()
                        Text("\(StorageStyle.bytes(Int64(total))) total")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("Capacity unavailable").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
            }
        }.modifier(StorageCard())
    }

    private var scopeIdentity: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.system(size: 22)).foregroundStyle(StorageStyle.blue)
                .frame(width: 44, height: 44).background(StorageStyle.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.scope.lastPathComponent.isEmpty ? "/" : model.scope.lastPathComponent)
                    .font(.system(size: 20, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(model.scope.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).id(model.scope.path).help(model.scope.path)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scopeActions: some View {
        HStack {
            Button("Choose Folder…") { model.chooseFolder?(model.scope) }.controlSize(.regular)
                .accessibilityIdentifier("storageChooseFolder")
            if model.isScanning {
                Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command).accessibilityIdentifier("storageStop")
            } else {
                Button(model.snapshot == nil ? "Analyze" : "Rescan") { model.startScan() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: .command).accessibilityIdentifier("storageAnalyze")
            }
        }
    }

    private func scopeHeader(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if compact {
                scopeIdentity
                scopeActions.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 10) { scopeIdentity; scopeActions }
            }
            if model.trail.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { model.goBack(to: model.trail.count - 2) } label: { Image(systemName: "arrow.left") }
                            .buttonStyle(.plain).keyboardShortcut("[", modifiers: .command)
                            .help("Back (⌘[)").accessibilityLabel("Back to previous folder")
                        ForEach(Array(model.trail.enumerated()), id: \.offset) { index, url in
                            if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                            Button(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent) { model.goBack(to: index) }
                                .buttonStyle(.plain).foregroundStyle(index == model.trail.count - 1 ? .primary : .secondary)
                                .disabled(index == model.trail.count - 1)
                                .help(url.path).accessibilityLabel("Back to \(url.path)")
                        }
                    }.font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder private var scanState: some View {
        VStack(spacing: 18) {
            if model.isScanning {
                ProgressView().controlSize(.regular)
                Text("Reading your storage…").font(.system(size: 21, weight: .medium))
                Text("\(StorageStyle.number(model.progress?.fileCount ?? 0)) files · \(StorageStyle.bytes(model.progress?.allocatedBytes ?? 0)) measured")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(StorageStyle.blue)
                Text(model.progress?.currentPath ?? "Preparing folder scan…")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: stateSymbol).font(.system(size: 36, weight: .light)).foregroundStyle(StorageStyle.blue)
                Text(stateTitle).font(.system(size: 23, weight: .medium))
                Text(stateDetail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack(spacing: 10) {
                    Button("Analyze Home") { model.select(FileManager.default.homeDirectoryForCurrentUser) }
                    Button("Downloads") { model.select(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }
                }.padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 52).padding(.horizontal, 24).modifier(StorageCard())
    }

    private var stateSymbol: String {
        switch model.phase { case .failed: return "folder.badge.questionmark"; case .stopped: return "pause.circle"; default: return "chart.pie" }
    }
    private var stateTitle: String {
        switch model.phase { case .failed: return "This folder couldn’t be read"; case .stopped: return "Scan stopped"; default: return "Find your space" }
    }
    private var stateDetail: String {
        switch model.phase {
        case .failed(let message): return "\(message) Choose another folder or retry Analyze. If macOS denied access, selecting the folder again may help."
        case .stopped: return "Analyze again when you’re ready. Completed folder results remain available when you go back."
        default: return "Analyze a folder to see its largest contents, file types, and the files taking up the most room."
        }
    }

    private func results(_ snapshot: DiskUsageSnapshot, wide: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            let statusLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 8))
            statusLayout {
                HStack(spacing: 8) {
                    Circle().fill(snapshot.isPartial ? Color.orange : Color.green.opacity(0.8)).frame(width: 5, height: 5)
                    Text(snapshot.isPartial ? "Partial result" : "Scan complete").fontWeight(.medium)
                    Text("·")
                    Text(snapshot.finishedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text("· \(String(format: "%.1f", snapshot.finishedAt.timeIntervalSince(snapshot.startedAt)))s")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Open in Grove") { model.openInGrove?(snapshot.root) }.buttonStyle(.link)
                    .fixedSize().frame(maxWidth: compact ? .infinity : nil, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if snapshot.isPartial { coverageBanner(snapshot) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: wide ? 4 : 2), spacing: 14) {
                metric("ALLOCATED FILES", StorageStyle.bytes(snapshot.allocatedBytes), accent: true)
                metric("LOGICAL SIZE", StorageStyle.bytes(snapshot.logicalBytes))
                metric("FILES", StorageStyle.number(snapshot.fileCount))
                metric("FOLDERS", StorageStyle.number(snapshot.folderCount))
            }
            if snapshot.entries.isEmpty {
                Text("This folder is empty.").font(.system(size: 15)).frame(maxWidth: .infinity).padding(35).modifier(StorageCard())
            } else {
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        breakdown(snapshot, compact: false).frame(maxWidth: .infinity)
                        fileTypes(snapshot).frame(width: 260)
                    }
                } else {
                    breakdown(snapshot, compact: compact)
                    fileTypes(snapshot)
                }
                folderList(snapshot, compact: compact)
                largestFiles(snapshot, compact: compact)
            }
            DisclosureGroup("About this measurement", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Allocated file size includes hidden files and package contents. Logical size is the total file length. Directory metadata is excluded. Symbolic links and nested volumes are skipped.")
                    Text("APFS snapshots, shared clone blocks, and unreadable files mean these totals can differ from volume usage. Allocated size is not a promise of reclaimable space. File types are estimated from names and extensions.")
                    if snapshot.duplicateHardlinks > 0 { Text("\(snapshot.duplicateHardlinks) additional hard links share already-counted allocation. A folder measured on its own can differ from its contribution here.") }
                    Text("\(snapshot.skippedLinks) symbolic links skipped · \(snapshot.skippedVolumes) nested volumes excluded. Results are a snapshot; use Rescan after files change.")
                    ForEach(snapshot.issues) { issue in
                        Text("\(issue.url.path) — \(issue.message)").textSelection(.enabled)
                    }
                    if snapshot.issueCount > snapshot.issues.count { Text("And \(snapshot.issueCount - snapshot.issues.count) more read errors.") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 11)).padding(.top, 2)
        }
    }

    private func metric(_ title: String, _ value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(accent ? StorageStyle.blue : .primary).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(StorageCard())
    }

    private func coverageBanner(_ snapshot: DiskUsageSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text("Some locations weren’t included").font(.system(size: 12, weight: .medium))
                Text("\(snapshot.issueCount) read errors · \(snapshot.skippedVolumes) nested volumes skipped. Readable files are shown below.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Details") { showReadIssues = true }.buttonStyle(.link)
                .popover(isPresented: $showReadIssues) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Scan coverage").font(.headline)
                            Text("\(snapshot.skippedVolumes) nested volumes were excluded. Analyze their folders separately.")
                            ForEach(snapshot.issues) { issue in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.url.path).fontWeight(.medium)
                                    Text(issue.message).foregroundStyle(.secondary)
                                }.textSelection(.enabled)
                            }
                            if snapshot.issueCount > snapshot.issues.count { Text("And \(snapshot.issueCount - snapshot.issues.count) more read errors.") }
                        }.font(.system(size: 11)).padding(20)
                    }.frame(width: 420, height: 280)
                }
        }.padding(14).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func breakdown(_ snapshot: DiskUsageSnapshot, compact: Bool) -> some View {
        let entries = Array(snapshot.entries.prefix(6).filter { $0.allocatedBytes > 0 })
        let remainder = max(0, snapshot.allocatedBytes - entries.reduce(0) { DiskUsageScanner.adding($0, $1.allocatedBytes) })
        return VStack(alignment: .leading, spacing: 18) {
            sectionLabel("SPACE BY ITEM", detail: "Click a folder to explore")
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(spacing: 24))
            layout {
                Chart {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        SectorMark(angle: .value("Allocated size", entry.allocatedBytes), innerRadius: .ratio(0.76), angularInset: 2)
                            .cornerRadius(3).foregroundStyle(StorageStyle.palette[index % 6])
                    }
                    if remainder > 0 {
                        SectorMark(angle: .value("Remaining items", remainder), innerRadius: .ratio(0.76), angularInset: 2)
                            .foregroundStyle(Color.white.opacity(0.10))
                    }
                }.chartAngleSelection(value: $selectedAngle).chartLegend(.hidden)
                    .chartGesture { proxy in
                        SpatialTapGesture().onEnded { tap in
                            let x = tap.location.x - 75
                            let y = 75 - tap.location.y
                            guard hypot(x, y) >= 55 else { return }
                            let angle = atan2(x, y)
                            proxy.selectAngleValue(at: .radians(angle < 0 ? angle + 2 * .pi : angle))
                        }
                    }
                    .frame(width: 150, height: 150)
                    .chartBackground { _ in
                        VStack(spacing: 4) {
                            Text(StorageStyle.bytes(snapshot.allocatedBytes)).font(.system(size: 20, weight: .medium, design: .rounded))
                            Text("allocated files").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Allocated file size by item. Use the item list to explore folders.")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button { activate(entry) } label: {
                            HStack(spacing: 7) {
                                Circle().fill(StorageStyle.palette[index % 6]).frame(width: 6, height: 6)
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 3)
                                Text(percent(entry.allocatedBytes, of: snapshot.allocatedBytes)).foregroundStyle(.secondary).monospacedDigit()
                            }.font(.system(size: 11))
                        }.buttonStyle(.plain).help(entry.url.path)
                    }
                    if remainder > 0 { Text("Other items · \(percent(remainder, of: snapshot.allocatedBytes))").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity)
            }.frame(minHeight: 160)
        }.modifier(StorageCard())
    }

    private func fileTypes(_ snapshot: DiskUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("FILE TYPES", detail: nil)
            VStack(spacing: 12) {
                ForEach(DiskUsageCategory.allCases) { category in
                    let size = snapshot.categories[category, default: 0]
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(StorageStyle.category(category)).frame(width: 6, height: 6)
                        Text(category.rawValue)
                        Spacer()
                        Text(StorageStyle.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                    }.font(.system(size: 11))
                }
            }.frame(minHeight: 160)
        }.modifier(StorageCard())
    }

    private func folderList(_ snapshot: DiskUsageSnapshot, compact: Bool) -> some View {
        let entries = snapshot.entries.filter { (!foldersOnly || $0.isDirectory) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
        return VStack(alignment: .leading, spacing: 12) {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
            layout {
                sectionLabel("FOLDER CONTENTS", detail: nil)
                Spacer()
                Toggle("Folders", isOn: $foldersOnly).toggleStyle(.checkbox).font(.system(size: 11))
                TextField("Filter items", text: $filter).textFieldStyle(.roundedBorder).frame(width: 150)
                    .accessibilityLabel("Filter folder contents")
            }
            HStack {
                Text("NAME")
                Spacer()
                Text("ALLOCATED SIZE").frame(width: 100, alignment: .trailing)
                if !compact { Text("SHARE").frame(width: 48, alignment: .trailing) }
            }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 10)
            Divider().overlay(StorageStyle.line)
            if entries.isEmpty { Text("No matching items").font(.system(size: 12)).foregroundStyle(.secondary).padding(12) }
            LazyVStack(spacing: 2) {
                ForEach(entries) { entry in itemRow(entry, total: snapshot.allocatedBytes, showPath: false, compact: compact) }
            }
        }.modifier(StorageCard())
    }

    private func largestFiles(_ snapshot: DiskUsageSnapshot, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("LARGEST FILES", detail: "Top \(min(12, snapshot.largestFiles.count)) in this folder tree")
            if snapshot.largestFiles.isEmpty {
                Text("No files with allocated data found.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.largestFiles.prefix(12)) { entry in itemRow(entry, total: snapshot.allocatedBytes, showPath: true, compact: compact) }
        }.modifier(StorageCard())
    }

    private func itemRow(_ entry: DiskUsageEntry, total: Int64, showPath: Bool, compact: Bool) -> some View {
        Button { activate(entry) } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isSymbolicLink ? "link" : (entry.isDirectory ? "folder.fill" : "doc"))
                    .font(.system(size: 16)).foregroundStyle(entry.isDirectory ? StorageStyle.blue : .secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if entry.issueCount > 0 { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Some contents could not be read") }
                        if entry.isExcluded { Text("Skipped").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    if showPath {
                        Text(entry.url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        GeometryReader { proxy in
                            Capsule().fill(StorageStyle.blue.opacity(0.45))
                                .frame(width: max(0, proxy.size.width * (total > 0 ? Double(entry.allocatedBytes) / Double(total) : 0)))
                        }.frame(maxWidth: 200).frame(height: 3).accessibilityHidden(true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.issueCount > 0 && entry.allocatedBytes == 0 ? "Unavailable" : StorageStyle.bytes(entry.allocatedBytes))
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 100, alignment: .trailing)
                if !compact { Text(percent(entry.allocatedBytes, of: total)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing) }
                Image(systemName: entry.isDirectory && !entry.isExcluded ? "chevron.right" : "arrow.up.right")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 10)
            }.padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(StorageRowButtonStyle())
            .help(entry.url.path)
            .accessibilityLabel("\(entry.name), \(StorageStyle.bytes(entry.allocatedBytes)), \(entry.isDirectory ? "explore folder" : "show in Grove")")
            .contextMenu {
                Button("Open in Grove") { model.openInGrove?(entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                if entry.isDirectory && !entry.isExcluded { Button("Analyze Folder") { model.enter(entry) } }
            }
    }

    private func activate(_ entry: DiskUsageEntry) {
        if entry.isDirectory && !entry.isSymbolicLink && !entry.isExcluded { model.enter(entry) }
        else { model.openInGrove?(entry.url.deletingLastPathComponent()) }
    }

    private func capacityColor(_ fraction: Double) -> Color {
        fraction >= 0.95 ? .red : (fraction >= 0.85 ? .orange : StorageStyle.blue)
    }

    private func percent(_ bytes: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        let value = Double(bytes) / Double(total) * 100
        return value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }

    private func sectionLabel(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            if let detail { Spacer(minLength: 6); Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf")
            Text("Analyzed on your Mac. No files uploaded.")
            Spacer()
            Text("Grove Storage")
        }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
    }
}

private struct StorageRowButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color.white.opacity(configuration.isPressed ? 0.08 : (hovered ? 0.035 : 0)), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}
