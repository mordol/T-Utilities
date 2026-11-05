import AppKit
import SwiftUI

/// Maccy-style history row: leading type icon, thumbnail for images,
/// two-line ellipsized preview, quick-slot badge (⌘1~⌘0) and a
/// `MM-dd HH:mm:ss` timestamp. Hovering a row swaps the timestamp for a
/// translate button (image rows: OCR + translate); Shift+clicking runs OCR on image items.
struct HistoryRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let imageCache: ImageCache
    var quickSlotLabel: String?
    var onCopy: () -> Void
    var onOCR: () -> Void
    var onTranslate: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    @MainActor
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            if item.kind == .image {
                thumbnailView
            }

            Text(preview)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let quickSlotLabel {
                Text("⌘\(quickSlotLabel)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.15))
                    )
            }

            if isHovering {
                HStack(spacing: 10) {
                    if item.kind == .image {
                        rowButton("text.viewfinder", help: "Copy extracted text (OCR)", action: onOCR)
                    }
                    rowButton("translate", help: "번역", action: onTranslate)
                }
            } else {
                Text(Self.timestampFormatter.string(from: item.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            let shift = NSEvent.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.shift)
            if shift {
                onOCR()
            } else {
                onCopy()
            }
        }
        .task(id: item.id) {
            guard item.kind == .image, let fileName = item.imageFileName else { return }
            thumbnail = imageCache.thumbnail(for: fileName)
        }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .help(help)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 46, height: 34)
        }
    }

    private var preview: String {
        item.previewText
            .replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    private var iconName: String {
        switch item.kind {
        case .text: return "doc.on.doc"
        case .image: return "photo"
        }
    }
}
