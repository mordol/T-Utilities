import AppKit
import SwiftUI

@MainActor
final class TranslationPanelModel: ObservableObject {
    enum Phase: Equatable {
        case recognizing
        case translating
        case done
        case failed(String)
        /// OCR found no text; the panel closes itself after `TranslationPanelController.noTextCloseDelay`.
        case noText
    }

    @Published var phase: Phase
    @Published var source = ""
    @Published var result = ""
    @Published var target: TranslationLanguage?
    let engineTitle: String

    init(engineTitle: String, phase: Phase) {
        self.engineTitle = engineTitle
        self.phase = phase
    }
}

/// A floating panel near the cursor that never activates the app, so the app the user was in keeps focus.
@MainActor
final class TranslationPanelController {
    static let noTextCloseDelay: Duration = .seconds(5)
    private static let size = NSSize(width: 440, height: 320)

    private var panel: TranslationPanel?
    private var closeObserver: NSObjectProtocol?
    private var autoClose: Task<Void, Never>?

    /// Called with the translation when the user copies it.
    var onCopy: ((String) -> Void)?
    /// Called whenever the panel goes away (button, Esc, close box, auto-close).
    var onClose: (() -> Void)?

    func show(_ model: TranslationPanelModel) {
        close()
        let panel = TranslationPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "번역"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 320, height: 200)
        panel.contentView = NSHostingView(rootView: TranslationView(
            model: model,
            onCopy: { [weak self] text in
                self?.onCopy?(text)
                self?.close()
            },
            onClose: { [weak self] in self?.close() }
        ))
        panel.setFrame(Self.frameNearCursor(), display: false)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func closeAfterDelay() {
        autoClose?.cancel()
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: Self.noTextCloseDelay)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        panel?.close()
    }

    private func didClose() {
        autoClose?.cancel()
        autoClose = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel = nil
        onClose?()
    }

    private static func frameNearCursor() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private struct TranslationView: View {
    @ObservedObject var model: TranslationPanelModel
    let onCopy: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.target.map { "→ \($0.title)" } ?? "번역")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(model.engineTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !model.source.isEmpty {
                Text(model.source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                Button("닫기", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("클립보드로 복사") { onCopy(model.result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase != .done)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recognizing:
            progress("이미지에서 텍스트를 읽는 중…")
        case .translating where model.result.isEmpty:
            progress("번역 중…")
        case .translating, .done:
            ScrollView {
                Text(model.result)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            ScrollView {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .noText:
            VStack(alignment: .leading, spacing: 6) {
                Label("이미지에서 텍스트를 찾지 못했습니다", systemImage: "text.viewfinder")
                    .foregroundStyle(.orange)
                Text("글자가 선명한 이미지인지 확인해 주세요. 이 창은 5초 뒤 자동으로 닫힙니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
    }
}
