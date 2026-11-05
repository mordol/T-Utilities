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

/// A speech bubble hanging from the menu bar icon. It never activates the app, so the app the user was in keeps
/// focus.
@MainActor
final class TranslationPanelController {
    static let noTextCloseDelay: Duration = .seconds(5)
    private static let size = NSSize(width: 440, height: 320 + SpeechBubble.tailHeight)
    /// Room between the menu bar icon and the tail tip, and between the bubble and the screen edges.
    private static let gap: CGFloat = 4
    private static let screenMargin: CGFloat = 8

    /// Screen frame of the menu bar icon the bubble points at.
    private let anchorFrame: () -> NSRect?

    private var panel: TranslationPanel?
    private var closeObserver: NSObjectProtocol?
    private var autoClose: Task<Void, Never>?

    /// Called with the translation when the user copies it.
    var onCopy: ((String) -> Void)?
    /// Called whenever the panel goes away (button, Esc, close box, auto-close).
    var onClose: (() -> Void)?

    init(anchorFrame: @escaping () -> NSRect?) {
        self.anchorFrame = anchorFrame
    }

    func show(_ model: TranslationPanelModel) {
        close()
        let placement = Self.placement(anchor: anchorFrame())
        let panel = TranslationPanel(
            contentRect: placement.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: TranslationView(
            model: model,
            tailX: placement.tailX,
            onCopy: { [weak self] text in
                self?.onCopy?(text)
                self?.close()
            },
            onClose: { [weak self] in self?.close() }
        ))
        hosting.frame = NSRect(origin: .zero, size: placement.frame.size)
        panel.contentView = hosting
        panel.setFrame(placement.frame, display: true)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        // The shadow follows the bubble's shape only once it has been drawn.
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
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

    /// Hangs the bubble below `anchor` with the tail tip under its center. Near a screen edge only the body slides
    /// inward, so the tail keeps pointing at the icon. Without an anchor: top center of the screen with the mouse.
    static func placement(anchor: NSRect?, screens: [NSScreen] = NSScreen.screens) -> (frame: NSRect, tailX: CGFloat) {
        let tip: NSPoint
        let screen: NSScreen?
        if let anchor {
            tip = NSPoint(x: anchor.midX, y: anchor.minY - gap)
            screen = screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        } else {
            let mouse = NSEvent.mouseLocation
            screen = screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let area = screen?.visibleFrame ?? .zero
            tip = NSPoint(x: area.midX, y: area.maxY - gap)
        }
        let area = screen?.visibleFrame ?? NSRect(x: tip.x - size.width, y: tip.y - size.height, width: 2 * size.width, height: size.height)
        return bubblePlacement(tip: tip, size: size, area: area, margin: screenMargin)
    }

    nonisolated static func bubblePlacement(tip: NSPoint, size: NSSize, area: NSRect, margin: CGFloat) -> (frame: NSRect, tailX: CGFloat) {
        let x = min(max(tip.x - size.width / 2, area.minX + margin), area.maxX - margin - size.width)
        let frame = NSRect(x: x, y: tip.y - size.height, width: size.width, height: size.height)
        return (frame, tip.x - x)
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
    /// Tail tip, from the bubble's left edge.
    let tailX: CGFloat
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
        .padding(.top, SpeechBubble.tailHeight)
        .background(.regularMaterial, in: SpeechBubble(tailX: tailX))
        .overlay(SpeechBubble(tailX: tailX).stroke(Color.primary.opacity(0.15), lineWidth: 1))
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

/// Rounded rectangle with a tail on top pointing up at `tailX` (one outline, so the stroke has no seam).
struct SpeechBubble: Shape {
    static let tailHeight: CGFloat = 11
    static let tailWidth: CGFloat = 22
    static let radius: CGFloat = 14

    var tailX: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + Self.tailHeight
        let r = Self.radius
        // Keep the tail on the straight part of the top edge.
        let x = min(max(tailX, rect.minX + r + Self.tailWidth / 2), rect.maxX - r - Self.tailWidth / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: top))
        path.addLine(to: CGPoint(x: x - Self.tailWidth / 2, y: top))
        path.addLine(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x + Self.tailWidth / 2, y: top))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: top), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}
