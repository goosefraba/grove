import SwiftUI
import AppKit

struct InspectorView: View {
    let fileItem: FileItem?

    var body: some View {
        if let item = fileItem {
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
                    DetailRow(label: "Modified", value: item.formattedDateModified)
                    DetailRow(label: "Created", value: formattedDate(item.dateCreated))
                    DetailRow(label: "Path", value: (item.url.path as NSString).abbreviatingWithTildeInPath)

                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 200)
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
