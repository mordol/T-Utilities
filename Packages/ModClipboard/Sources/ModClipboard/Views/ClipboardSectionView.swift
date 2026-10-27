import AppKit
import SwiftUI
import TUCore

/// Clipboard section of the main popover. Adapted from CopyNinja's MainPopoverView:
/// section header / search / scrollable history / shortcut hints. The app-level header and footer
/// (version, updates, launch at login, quit) live in the shell instead.
struct ClipboardSectionView: View {
    @ObservedObject var store: ClipboardStore
    var autoPaste: Bool
    var onClose: () -> Void

    @FocusState private var searchFocused: Bool

    // module-rules: allow shell-owned popover geometry (PopoverSize), read-only here
    @AppStorage(PopoverSize.listHeightKey) private var listHeight = Double(PopoverSize.defaultListHeight)

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider()
            content
                .frame(height: listHeight)
            Divider()
            hints
        }
        .onAppear {
            searchFocused = true
        }
        .onChange(of: store.focusSearchToken) { _, _ in
            searchFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text("Clipboard")
            Spacer()
            if store.isOCRing {
                ProgressView()
                    .controlSize(.small)
                    .help("텍스트 인식 중…")
            }
            Button {
                store.clearAll()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(store.items.isEmpty)
            .help("히스토리 전체 삭제 (⌘K)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("히스토리 검색", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("검색어 지우기")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.12))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            mainContent
            if let quickLookItem = store.quickLookItem {
                QuickLookOverlay(
                    item: quickLookItem,
                    imageCache: store.imageCache,
                    onClose: { store.dismissQuickLook() }
                )
                .zIndex(1)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.filteredItems.isEmpty {
            emptyState
        } else {
            historyList
        }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(store.filteredItems.enumerated()), id: \.element.id) { index, item in
                        HistoryRowView(
                            item: item,
                            isSelected: store.selectedItem?.id == item.id,
                            imageCache: store.imageCache,
                            quickSlotLabel: Self.quickSlotLabel(for: index),
                            onCopy: {
                                store.copyToClipboard(item)
                                onClose()
                            },
                            onOCR: {
                                store.performOCRCopy(for: item)
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: store.selectedIndex) { _, newIndex in
                guard let index = newIndex,
                      store.filteredItems.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(store.filteredItems[index].id, anchor: .center)
                }
            }
        }
    }

    /// 1–9 → "1"…"9", 10th → "0".
    private static func quickSlotLabel(for index: Int) -> String? {
        guard index < 10 else { return nil }
        return index == 9 ? "0" : "\(index + 1)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(Color.gray.opacity(0.35))
            Text(store.searchText.isEmpty ? "아직 히스토리가 없습니다" : "검색 결과가 없습니다")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(store.searchText.isEmpty
                 ? "복사한 텍스트와 이미지가 여기에 표시됩니다."
                 : "다른 검색어를 입력해 보세요.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hints

    private var hints: some View {
        Text(verbatim: "↑↓ 이동 · ↩ \(autoPaste ? "붙여넣기" : "복사") · ⌘1~0 바로 복사 · ⇧클릭/⌘⇧1~0 OCR · Space 미리보기 · ⌘K 삭제")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}
