import SwiftUI
import AppKit

struct TagView: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(TagColors.color(for: tag))
                            .frame(width: 10, height: 10)
                        Text(tag)
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TagColors.color(for: tag).opacity(0.15))
                    )
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
        }
    }
}

enum TagColors {
    static let standardTags: [(name: String, color: Color)] = [
        ("Red", .red),
        ("Orange", .orange),
        ("Yellow", .yellow),
        ("Green", .green),
        ("Blue", .blue),
        ("Purple", .purple),
        ("Gray", .gray),
    ]

    static func color(for tagName: String) -> Color {
        standardTags.first { $0.name == tagName }?.color ?? .secondary
    }

    static func nsColor(for tagName: String) -> NSColor {
        switch tagName {
        case "Red": return .systemRed
        case "Orange": return .systemOrange
        case "Yellow": return .systemYellow
        case "Green": return .systemGreen
        case "Blue": return .systemBlue
        case "Purple": return .systemPurple
        case "Gray": return .systemGray
        default: return .secondaryLabelColor
        }
    }
}

// Simple flow layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, containerWidth: proposal.width ?? .infinity)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, containerWidth: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, containerWidth: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > containerWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}
