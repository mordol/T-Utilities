import AppKit
import SwiftUI
import TUCore

/// Sizes of the switcher grid.
private enum Metrics {
    static let cellWidth: CGFloat = 196
    static let thumbnailHeight: CGFloat = 120
    static let cellHeight: CGFloat = 154
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 20
}

@MainActor
@Observable
final class SwitcherModel {
    var windows: [SwitcherWindow]
    let columns: Int
    /// Index into `windows`, like every index below.
    var selected: Int
    /// The window under the pointer; its close button is shown.
    var hovered: Int?
    var thumbnails: [CGWindowID: NSImage] = [:]
    @ObservationIgnored var onClick: (Int) -> Void = { _ in }
    @ObservationIgnored var onHover: (Int) -> Void = { _ in }
    @ObservationIgnored var onClose: (Int) -> Void = { _ in }

    init(windows: [SwitcherWindow], columns: Int, selected: Int) {
        self.windows = windows
        self.columns = columns
        self.selected = selected
    }
}

/// Floating, non-activating panel: it never takes focus, so the app being switched from keeps it until commit.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, its model and the thumbnail capture of one switcher session. Everything is created when the
/// switcher opens and released when it closes.
@MainActor
final class SwitcherPresenter {
    /// Thumbnails are captured only when this returns true.
    var capturesThumbnails: () -> Bool = { true }
    var mouseMode: () -> SwitcherMouseMode = { .click }

    private var panel: NSPanel?
    private var model: SwitcherModel?
    private var captureTask: Task<Void, Never>?
    /// Pointer location when the panel opened. The panel can appear under a resting pointer, which must not
    /// select anything until it really moves.
    private var openingMouseLocation: NSPoint?

    func handle(_ command: SwitcherCommand) {
        switch command {
        case .step(let backward):
            if let model {
                model.selected = SwitcherLogic.moved(model.selected, by: backward ? -1 : 1, count: model.windows.count)
            } else {
                open(backward: backward)
            }
        case .move(let delta):
            guard let model else { return }
            model.selected = SwitcherLogic.moved(model.selected, by: delta, count: model.windows.count)
        case .moveRow(let delta):
            guard let model else { return }
            model.selected = SwitcherLogic.movedRow(model.selected, by: delta, columns: model.columns, count: model.windows.count)
        case .cancel:
            close()
        case .commit:
            commit()
        }
    }

    func close() {
        captureTask?.cancel()
        captureTask = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
        openingMouseLocation = nil
    }

    private func hover(_ index: Int) {
        guard let model, NSEvent.mouseLocation != openingMouseLocation else { return }
        openingMouseLocation = nil
        model.selected = SwitcherLogic.selectionAfterHover(model.selected, hovered: index, mode: mouseMode())
    }

    /// Closes the window and drops it from the list; the switcher stays open unless it was the last one.
    private func closeWindow(_ index: Int) {
        guard let model, SwitcherWindows.close(model.windows[index]) else { return }
        model.windows.remove(at: index)
        model.hovered = nil
        guard !model.windows.isEmpty else { return close() }
        model.selected = SwitcherLogic.selectionAfterRemoving(index, selected: model.selected, count: model.windows.count)
    }

    private func commit(_ index: Int? = nil) {
        guard let model else { return }
        let target = model.windows[index ?? model.selected]
        close()
        SwitcherWindows.focus(target)
    }

    private func open(backward: Bool) {
        let windows = SwitcherWindows.current()
        guard !windows.isEmpty else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let area = screen.visibleFrame
        let columns = SwitcherLogic.gridColumns(
            count: windows.count, availableWidth: area.width * 0.85 - 2 * Metrics.padding,
            cellWidth: Metrics.cellWidth, spacing: Metrics.spacing
        )
        let rows = (windows.count + columns - 1) / columns
        let size = CGSize(
            width: CGFloat(columns) * Metrics.cellWidth + CGFloat(columns - 1) * Metrics.spacing + 2 * Metrics.padding,
            height: min(
                CGFloat(rows) * Metrics.cellHeight + CGFloat(rows - 1) * Metrics.spacing + 2 * Metrics.padding,
                area.height * 0.85
            )
        )

        let model = SwitcherModel(
            windows: windows, columns: columns,
            selected: SwitcherLogic.initialSelection(count: windows.count, backward: backward)
        )
        model.onClick = { [weak self] in self?.commit($0) }
        model.onHover = { [weak self] in self?.hover($0) }
        model.onClose = { [weak self] in self?.closeWindow($0) }

        let panel = SwitcherPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SwitcherGridView(model: model, size: size))
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        panel.orderFrontRegardless()

        self.model = model
        self.panel = panel
        openingMouseLocation = NSEvent.mouseLocation
        startCapture(for: model, scale: screen.backingScaleFactor)
    }

    /// Icons are already on screen; thumbnails replace them as the captures finish.
    private func startCapture(for model: SwitcherModel, scale: CGFloat) {
        guard capturesThumbnails(), Permission.screenRecording.isGranted else { return }
        let ids = model.windows.compactMap(\.windowID)
        guard !ids.isEmpty else { return }
        let maxPixelSize = CGSize(width: Metrics.cellWidth * scale, height: Metrics.thumbnailHeight * scale)
        captureTask = Task { [weak model] in
            await ThumbnailCapture.capture(windowIDs: ids, maxPixelSize: maxPixelSize) { id, image in
                model?.thumbnails[id] = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}

private struct SwitcherGridView: View {
    let model: SwitcherModel
    let size: CGSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Metrics.cellWidth), spacing: Metrics.spacing), count: model.columns),
                    spacing: Metrics.spacing
                ) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                        SwitcherCell(
                            window: window, thumbnail: window.windowID.flatMap { model.thumbnails[$0] },
                            isSelected: index == model.selected,
                            showsCloseButton: index == model.selected || index == model.hovered,
                            onClose: { model.onClose(index) }
                        )
                        .id(window.id)
                        .onTapGesture { model.onClick(index) }
                        .onHover { inside in
                            if inside {
                                model.hovered = index
                                model.onHover(index)
                            } else if model.hovered == index {
                                model.hovered = nil
                            }
                        }
                    }
                }
                .padding(Metrics.padding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.selected) { _, selected in
                if model.windows.indices.contains(selected) { proxy.scrollTo(model.windows[selected].id) }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct SwitcherCell: View {
    let window: SwitcherWindow
    let thumbnail: NSImage?
    let isSelected: Bool
    let showsCloseButton: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .opacity(window.isMinimized ? 0.6 : 1)
                }
            }
            .frame(height: Metrics.thumbnailHeight)
            HStack(spacing: 6) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(width: Metrics.cellWidth, height: Metrics.cellHeight)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : .clear)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "power.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .help("창 닫기")
                .padding(2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
