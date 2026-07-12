import SwiftUI
import AppKit

struct InspectorView: View {
    let items: [BrowserItem]

    var body: some View {
        if items.count > 1 {
            multiSelectionView
        } else if let item = items.first {
            singleSelectionView(item)
        } else {
            VStack {
                Spacer()
                Text("No Selection")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minWidth: 200)
        }
    }

    // MARK: - Single Selection

    @ViewBuilder
    private func singleSelectionView(_ item: BrowserItem) -> some View {
        switch item {
        case .local(let fileItem):
            LocalSelectionView(item: fileItem)
        case .s3(let s3Item):
            s3SelectionView(s3Item)
        }
    }

    private func s3SelectionView(_ item: S3Item) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: item.isBucket ? "externaldrive.connected.to.line.below" : (item.isPrefix ? "folder" : "doc"))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.secondary)

                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Divider()

                DetailRow(label: "Kind", value: item.kind)
                DetailRow(label: "Bucket", value: item.bucket)
                if !item.isBucket {
                    DetailRow(label: "Key", value: item.key)
                }
                DetailRow(label: "Size", value: item.metadata?.contentLength.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? item.formattedSize)
                DetailRow(label: "Modified", value: formattedOptionalDate(item.metadata?.lastModified ?? item.lastModified))

                if let contentType = item.metadata?.contentType {
                    DetailRow(label: "Content Type", value: contentType)
                }
                if let eTag = item.metadata?.eTag ?? item.eTag {
                    DetailRow(label: "ETag", value: eTag)
                }
                if let storageClass = item.metadata?.storageClass ?? item.storageClass {
                    DetailRow(label: "Storage Class", value: storageClass)
                }
                if let warning = item.metadata?.warning {
                    DetailRow(label: "Metadata", value: warning)
                }

                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 200)
    }

    // MARK: - Multi Selection

    private var multiSelectionView: some View {
        ScrollView {
            VStack(spacing: 16) {
                iconGrid

                Text("\(items.count) items selected")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Divider()

                DetailRow(label: totalSizeLabel, value: formattedTotalSize)
                DetailRow(label: "Types", value: typeSummary)

                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 200)
    }

    private var iconGrid: some View {
        let displayItems = Array(items.prefix(9))
        let hasMore = items.count > 9
        let columns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 3)

        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(displayItems) { item in
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            if hasMore {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Directory sizes aren't summed (FileItem.size is 0 for folders), so flag the exclusion.
    private var totalSizeLabel: String {
        items.contains { $0.isContainer } ? "Total Size (files only)" : "Total Size"
    }

    private var formattedTotalSize: String {
        let total = items.reduce(Int64(0)) { total, item in
            switch item {
            case .local(let fileItem):
                return total + fileItem.size
            case .s3(let s3Item):
                return total + (s3Item.size ?? 0)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var typeSummary: String {
        var counts: [String: Int] = [:]
        for item in items {
            let type: String
            switch item {
            case .local(let fileItem):
                type = fileItem.isDirectory && !fileItem.isPackage ? "folder" : fileItem.kind.lowercased()
            case .s3(let s3Item):
                type = s3Item.isBucket ? "S3 bucket" : (s3Item.isPrefix ? "S3 prefix" : "S3 object")
            }
            counts[type, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }
            .joined(separator: ", ")
    }

    // MARK: - Helpers

    private func formattedOptionalDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return inspectorFormattedDate(date)
    }
}

private let inspectorDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return formatter
}()

private func inspectorFormattedDate(_ date: Date) -> String {
    inspectorDateFormatter.string(from: date)
}

// Loads icon and image dimensions off the main thread once per selection,
// instead of doing disk I/O in the SwiftUI body on every render.
private struct LocalSelectionView: View {
    let item: FileItem

    @State private var icon: NSImage?
    @State private var dimensions: NSSize?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: icon ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)

                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Divider()

                DetailRow(label: "Kind", value: item.kind)
                DetailRow(label: "Size", value: item.formattedSize)
                DetailRow(label: "Modified", value: item.metadataUnavailable ? "--" : inspectorFormattedDate(item.dateModified))
                DetailRow(label: "Created", value: item.metadataUnavailable ? "--" : inspectorFormattedDate(item.dateCreated))
                DetailRow(label: "Permissions", value: item.metadataUnavailable ? "--" : "\(item.formattedPermissions) (\(item.octalPermissions))")

                if item.isImage, let dimensions {
                    DetailRow(label: "Dimensions", value: "\(Int(dimensions.width)) \u{00D7} \(Int(dimensions.height))")
                }

                DetailRow(label: "Path", value: (item.url.path as NSString).abbreviatingWithTildeInPath)

                if !item.tags.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TagView(tags: item.tagMetadata)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 200)
        .task(id: item.url) {
            icon = nil
            dimensions = nil
            let url = item.url
            let isImage = item.isImage
            let loaded = await Task.detached(priority: .userInitiated) { () -> (NSImage, NSSize?) in
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let dims = isImage ? FileItem.imageDimensions(for: url) : nil
                return (icon, dims)
            }.value
            icon = loaded.0
            dimensions = loaded.1
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
