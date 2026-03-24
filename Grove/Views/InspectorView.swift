import SwiftUI
import AppKit

struct InspectorView: View {
    let items: [FileItem]

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

    private func singleSelectionView(_ item: FileItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 64, height: 64)

                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Divider()

                DetailRow(label: "Kind", value: item.kind)
                DetailRow(label: "Size", value: item.formattedSize)
                DetailRow(label: "Modified", value: formattedDate(item.dateModified))
                DetailRow(label: "Created", value: formattedDate(item.dateCreated))
                DetailRow(label: "Permissions", value: "\(item.formattedPermissions) (\(item.octalPermissions))")

                if item.isImage, let dimensions = item.imageDimensions {
                    DetailRow(label: "Dimensions", value: "\(Int(dimensions.width)) \u{00D7} \(Int(dimensions.height))")
                }

                DetailRow(label: "Path", value: (item.url.path as NSString).abbreviatingWithTildeInPath)

                if !item.tags.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TagView(tags: item.tags)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                DetailRow(label: "Total Size", value: formattedTotalSize)
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
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
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

    private var formattedTotalSize: String {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var typeSummary: String {
        var counts: [String: Int] = [:]
        for item in items {
            let type = item.isDirectory && !item.isPackage ? "folder" : item.kind.lowercased()
            counts[type, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }
            .joined(separator: ", ")
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
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
